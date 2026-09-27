import Darwin
import Foundation
import IOKit

struct MetricPoint: Identifiable, Equatable {
    let time: Date
    let value: Double
    var id: Date { time }
}

struct NetPoint: Identifiable, Equatable {
    let time: Date
    let down: Double
    let up: Double
    var id: Date { time }
}

struct CPUSample: Equatable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64
}

/// 纯计算逻辑,独立于 actor 便于测试
enum MetricMath {
    /// 两次采样差值 -> CPU 繁忙占比 (0...1)
    static func cpuUsage(prev: CPUSample, cur: CPUSample) -> Double {
        let b = cpuBreakdown(prev: prev, cur: cur)
        return b.user + b.system
    }

    /// 两次采样差值 -> (用户态含 nice, 系统态) 占比
    static func cpuBreakdown(prev: CPUSample, cur: CPUSample) -> (user: Double, system: Double) {
        let dUser = cur.user &- prev.user
        let dSystem = cur.system &- prev.system
        let dIdle = cur.idle &- prev.idle
        let dNice = cur.nice &- prev.nice
        let total = dUser &+ dSystem &+ dIdle &+ dNice
        guard total > 0 else { return (0, 0) }
        return (Double(dUser &+ dNice) / Double(total), Double(dSystem) / Double(total))
    }

    /// 单调递增计数器的速率;计数器回绕或重置时返回 0
    static func rate(prev: UInt64, cur: UInt64, seconds: Double) -> Double {
        guard seconds > 0, cur >= prev else { return 0 }
        return Double(cur - prev) / seconds
    }
}

@Observable
@MainActor
final class SystemMetrics {
    // CPU
    private(set) var cpuUsage: Double = 0            // 0...1
    private(set) var cpuUser: Double = 0
    private(set) var cpuSystem: Double = 0
    private(set) var perCore: [Double] = []          // 每核 0...1
    private(set) var cpuHistory: [MetricPoint] = []  // 0...100
    private(set) var loadAverage: [Double] = []

    // GPU(Apple Silicon / 部分 Intel 机型可读)
    private(set) var gpuUsage: Double?               // 0...1
    private(set) var gpuHistory: [MetricPoint] = []

    // 内存
    private(set) var memUsed: UInt64 = 0
    private(set) var memApp: UInt64 = 0
    private(set) var memWired: UInt64 = 0
    private(set) var memCompressed: UInt64 = 0
    private(set) var swapUsed: UInt64 = 0
    private(set) var memHistory: [MetricPoint] = []

    // 磁盘
    private(set) var diskUsed: UInt64 = 0
    private(set) var diskTotal: UInt64 = 0
    private(set) var diskReadBps: Double = 0
    private(set) var diskWriteBps: Double = 0

    // 网络
    private(set) var netDownBps: Double = 0
    private(set) var netUpBps: Double = 0
    private(set) var netTotalDown: UInt64 = 0
    private(set) var netTotalUp: UInt64 = 0
    private(set) var netHistory: [NetPoint] = []
    private(set) var localIP: String?
    private(set) var publicIP: String?
    private(set) var fetchingPublicIP = false

    private var prevCPU: [CPUSample] = []
    private var prevNet: (rx: UInt64, tx: UInt64, time: Date)?
    private var prevDisk: (read: UInt64, write: UInt64, time: Date)?
    private var task: Task<Void, Never>?
    private let historyLimit = 90
    /// 截图/测试用的临时实例不发通知
    private let alertsEnabled: Bool

    init(alertsEnabled: Bool = true) {
        self.alertsEnabled = alertsEnabled
    }

    var memTotal: UInt64 { ProcessInfo.processInfo.physicalMemory }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var cpuPercentText: String { Self.percent(cpuUsage) }
    var memPercentText: String { Self.percent(memFraction) }
    var gpuPercentText: String { gpuUsage.map(Self.percent) ?? "--" }
    var memFraction: Double {
        guard memTotal > 0 else { return 0 }
        return min(1, Double(memUsed) / Double(memTotal))
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(AppSettings.refreshIntervalValue))
            }
        }
    }

    func fetchPublicIP() async {
        guard !fetchingPublicIP, let url = URL(string: "https://api.ipify.org") else { return }
        fetchingPublicIP = true
        defer { fetchingPublicIP = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            publicIP = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            publicIP = "获取失败"
        }
    }

    private func sample() {
        let now = Date()
        sampleCPU()
        sampleGPU()
        sampleMemory()
        sampleDisk(now)
        sampleNetwork(now)
        append(&cpuHistory, MetricPoint(time: now, value: cpuUsage * 100))
        append(&memHistory, MetricPoint(time: now, value: memFraction * 100))
        if let gpuUsage {
            append(&gpuHistory, MetricPoint(time: now, value: gpuUsage * 100))
        }
        append(&netHistory, NetPoint(time: now, down: netDownBps, up: netUpBps))
        if alertsEnabled {
            AlertMonitor.shared.check(cpuUsage: cpuUsage, memFraction: memFraction, diskUsed: diskUsed, diskTotal: diskTotal)
        }
    }

    private func append<T>(_ history: inout [T], _ point: T) {
        history.append(point)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    // MARK: - CPU

    private func sampleCPU() {
        var cpuCount: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &cpuInfoCount)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return }
        defer {
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }

        var cores = [CPUSample]()
        cores.reserveCapacity(Int(cpuCount))
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpuCount) {
            let base = stride * i
            cores.append(CPUSample(
                user: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                system: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                idle: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                nice: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            ))
        }

        if prevCPU.count == cores.count, !cores.isEmpty {
            var usages = [Double]()
            var userSum = 0.0
            var systemSum = 0.0
            for (prev, cur) in zip(prevCPU, cores) {
                let b = MetricMath.cpuBreakdown(prev: prev, cur: cur)
                usages.append(b.user + b.system)
                userSum += b.user
                systemSum += b.system
            }
            let n = Double(usages.count)
            perCore = usages
            cpuUser = userSum / n
            cpuSystem = systemSum / n
            cpuUsage = cpuUser + cpuSystem
        }
        prevCPU = cores

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            loadAverage = loads
        }
    }

    // MARK: - GPU

    private func sampleGPU() {
        var best: Double?
        forEachService(matching: "IOAccelerator") { service in
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            best = max(best ?? 0, util)
        }
        gpuUsage = best.map { min(1, max(0, $0 / 100)) }
    }

    // MARK: - 内存

    private func sampleMemory() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        var pageSize = vm_size_t(0)
        host_page_size(mach_host_self(), &pageSize)
        let p = UInt64(pageSize)
        // 与"活动监视器"一致:App 内存(internal - purgeable) + 联动 + 压缩
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        memApp = (internalPages > purgeable ? internalPages - purgeable : 0) * p
        memWired = UInt64(stats.wire_count) * p
        memCompressed = UInt64(stats.compressor_page_count) * p
        memUsed = memApp + memWired + memCompressed

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            swapUsed = swap.xsu_used
        }
    }

    // MARK: - 磁盘

    private func sampleDisk(_ now: Date) {
        let root = URL(fileURLWithPath: "/")
        if let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let total = values.volumeTotalCapacity,
           let free = values.volumeAvailableCapacityForImportantUsage {
            diskTotal = UInt64(max(0, total))
            diskUsed = UInt64(max(0, Int64(total) - free))
        }

        var read: UInt64 = 0
        var write: UInt64 = 0
        forEachService(matching: "IOBlockStorageDriver") { service in
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { return }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        if let prev = prevDisk {
            let dt = now.timeIntervalSince(prev.time)
            diskReadBps = MetricMath.rate(prev: prev.read, cur: read, seconds: dt)
            diskWriteBps = MetricMath.rate(prev: prev.write, cur: write, seconds: dt)
        }
        prevDisk = (read, write, now)
    }

    // MARK: - 网络

    private func sampleNetwork(_ now: Date) {
        let (rx, tx) = Self.interfaceCounters()
        netTotalDown = rx
        netTotalUp = tx
        if let prev = prevNet {
            let dt = now.timeIntervalSince(prev.time)
            netDownBps = MetricMath.rate(prev: prev.rx, cur: rx, seconds: dt)
            netUpBps = MetricMath.rate(prev: prev.tx, cur: tx, seconds: dt)
        }
        prevNet = (rx, tx, now)
        localIP = Self.primaryIPv4()
    }

    /// 通过 NET_RT_IFLIST2 读取 64 位计数(getifaddrs 的 if_data 是 32 位,超过 4GB 会回绕)。
    /// 只统计 en*(Wi-Fi/以太网),避免 VPN 隧道重复计数
    private static func interfaceCounters() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(msg.ifm_index), &nameBuffer) != nil,
                       String(cString: nameBuffer).hasPrefix("en") {
                        rx += msg.ifm_data.ifi_ibytes
                        tx += msg.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }

    private static func primaryIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }
        var cursor = addrs
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    // MARK: - IOKit

    private func forEachService(matching className: String, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            body(service)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
}
