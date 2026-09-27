import Charts
import SwiftUI

struct MonitorView: View {
    @Environment(SystemMetrics.self) private var metrics
    @Environment(ProcessMonitor.self) private var processes

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                cpuCard
                if metrics.gpuUsage != nil {
                    gpuCard
                }
                memoryCard
                diskCard
                networkCard
                if let message = processes.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("已运行 \(DurationFormatter.uptime(metrics.uptime))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .onAppear { processes.start() }
        .onDisappear { processes.stop() }
    }

    // MARK: - CPU

    private var cpuCard: some View {
        MonitorCard(title: "CPU", systemImage: "cpu", value: metrics.cpuPercentText) {
            UsageChart(points: metrics.cpuHistory, color: .blue)
            HStack(spacing: 12) {
                StatText(label: "用户", value: SystemMetrics.percent(metrics.cpuUser), color: .blue)
                StatText(label: "系统", value: SystemMetrics.percent(metrics.cpuSystem), color: .red)
                Spacer()
                if metrics.loadAverage.count == 3 {
                    StatText(label: "负载", value: metrics.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "))
                }
            }
            if !metrics.perCore.isEmpty {
                CoreBars(values: metrics.perCore)
            }
            ProcessList(
                title: "占用最高",
                entries: processes.topCPU,
                value: { String(format: "%.1f%%", $0.cpu) },
                onTerminate: processes.terminate
            )
        }
    }

    // MARK: - GPU

    private var gpuCard: some View {
        MonitorCard(title: "GPU", systemImage: "cube.transparent", value: metrics.gpuPercentText) {
            UsageChart(points: metrics.gpuHistory, color: .teal)
        }
    }

    // MARK: - 内存

    private var memoryCard: some View {
        MonitorCard(title: "内存", systemImage: "memorychip", value: metrics.memPercentText) {
            UsageChart(points: metrics.memHistory, color: .purple)
            HStack {
                Text("\(ByteFormatter.string(metrics.memUsed)) / \(ByteFormatter.string(metrics.memTotal))")
                Spacer()
                if metrics.swapUsed > 0 {
                    Text("交换 \(ByteFormatter.string(metrics.swapUsed))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                StatText(label: "App", value: ByteFormatter.string(metrics.memApp), color: .purple)
                StatText(label: "联动", value: ByteFormatter.string(metrics.memWired), color: .orange)
                StatText(label: "压缩", value: ByteFormatter.string(metrics.memCompressed), color: .gray)
                Spacer()
            }
            ProcessList(
                title: "占用最高",
                entries: processes.topMemory,
                value: { ByteFormatter.string($0.memBytes) },
                onTerminate: processes.terminate
            )
        }
    }

    // MARK: - 磁盘

    private var diskCard: some View {
        let fraction = metrics.diskTotal > 0 ? Double(metrics.diskUsed) / Double(metrics.diskTotal) : 0
        return MonitorCard(title: "磁盘", systemImage: "internaldrive", value: SystemMetrics.percent(fraction)) {
            ProgressView(value: fraction)
                .tint(.orange)
            HStack {
                Text("已用 \(ByteFormatter.string(metrics.diskUsed)),可用 \(ByteFormatter.string(metrics.diskTotal - min(metrics.diskTotal, metrics.diskUsed)))")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                StatText(label: "读", value: ByteFormatter.rate(metrics.diskReadBps), color: .green)
                StatText(label: "写", value: ByteFormatter.rate(metrics.diskWriteBps), color: .orange)
                Spacer()
            }
        }
    }

    // MARK: - 网络

    private var networkCard: some View {
        MonitorCard(title: "网络", systemImage: "network", value: nil) {
            HStack {
                Label(ByteFormatter.rate(metrics.netDownBps), systemImage: "arrow.down")
                    .foregroundStyle(.green)
                Spacer()
                Label(ByteFormatter.rate(metrics.netUpBps), systemImage: "arrow.up")
                    .foregroundStyle(.blue)
            }
            .font(.callout.monospacedDigit())
            NetworkChart(points: metrics.netHistory)
            VStack(spacing: 3) {
                InfoRow(label: "本机 IP", value: metrics.localIP ?? "未连接")
                HStack {
                    Text("公网 IP").foregroundStyle(.secondary)
                    Spacer()
                    if metrics.fetchingPublicIP {
                        ProgressView().controlSize(.mini)
                    } else if let ip = metrics.publicIP {
                        Text(ip).textSelection(.enabled)
                    } else {
                        Button("点击获取") { Task { await metrics.fetchPublicIP() } }
                            .buttonStyle(.link)
                    }
                }
                InfoRow(label: "开机以来", value: "↓ \(ByteFormatter.string(metrics.netTotalDown))  ↑ \(ByteFormatter.string(metrics.netTotalUp))")
            }
            .font(.caption)
        }
    }
}

// MARK: - 组件

private struct MonitorCard<Content: View>: View {
    let title: String
    let systemImage: String
    let value: String?
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(.top, 2)
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if let value {
                    Text(value)
                        .font(.callout.monospacedDigit().bold())
                }
            }
        }
    }
}

private struct StatText: View {
    let label: String
    let value: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }
}

private struct UsageChart: View {
    let points: [MetricPoint]
    let color: Color

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("时间", point.time), y: .value("占用", point.value))
                .foregroundStyle(color.opacity(0.2))
            LineMark(x: .value("时间", point.time), y: .value("占用", point.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
            }
        }
        .frame(height: 50)
    }
}

private struct NetworkChart: View {
    let points: [NetPoint]

    private struct Sample: Identifiable {
        let time: Date
        let value: Double
        let kind: String
        var id: String { "\(kind)-\(time.timeIntervalSince1970)" }
    }

    private var samples: [Sample] {
        points.flatMap {
            [Sample(time: $0.time, value: $0.down, kind: "下载"), Sample(time: $0.time, value: $0.up, kind: "上传")]
        }
    }

    var body: some View {
        Chart(samples) { sample in
            LineMark(x: .value("时间", sample.time), y: .value("速率", sample.value))
                .foregroundStyle(by: .value("方向", sample.kind))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
        }
        .chartForegroundStyleScale(["下载": Color.green, "上传": Color.blue])
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 44)
    }
}

private struct CoreBars: View {
    let values: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { index in
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color(values[index]))
                            .frame(height: max(1.5, geo.size.height * values[index]))
                    }
                }
                .background(RoundedRectangle(cornerRadius: 1.5).fill(.quaternary.opacity(0.5)))
            }
        }
        .frame(height: 26)
        .help("每个核心的占用")
    }

    private func color(_ usage: Double) -> Color {
        switch usage {
        case ..<0.5: return .blue
        case ..<0.8: return .orange
        default: return .red
        }
    }
}

private struct ProcessList: View {
    let title: String
    let entries: [ProcessEntry]
    let value: (ProcessEntry) -> String
    let onTerminate: (ProcessEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if entries.isEmpty {
                Text("读取中…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(entries) { entry in
                let info = ProcessMonitor.appInfo(for: entry.pid)
                HStack(spacing: 6) {
                    if let icon = info?.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "terminal")
                            .frame(width: 14, height: 14)
                            .foregroundStyle(.secondary)
                    }
                    Text(info?.name ?? entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(value(entry))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("结束进程 \(info?.name ?? entry.name)") { onTerminate(entry) }
                }
                .help("右键可结束进程(PID \(entry.pid))")
            }
        }
    }
}
