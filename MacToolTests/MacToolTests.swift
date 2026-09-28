@testable import MacTool
import XCTest

final class ByteFormatterTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(ByteFormatter.string(0), "0 B")
        XCTAssertEqual(ByteFormatter.string(512), "512 B")
        XCTAssertEqual(ByteFormatter.string(1024), "1.0 KB")
        XCTAssertEqual(ByteFormatter.string(1536), "1.5 KB")
        XCTAssertEqual(ByteFormatter.string(1 << 30), "1.0 GB")
        XCTAssertEqual(ByteFormatter.string(6 * 1024 * 1024), "6.0 MB")
    }

    func testRate() {
        XCTAssertEqual(ByteFormatter.rate(0), "0 B/s")
        XCTAssertEqual(ByteFormatter.rate(2048), "2.0 KB/s")
    }

    func testCompactRate() {
        XCTAssertEqual(ByteFormatter.compactRate(0), "0K")
        XCTAssertEqual(ByteFormatter.compactRate(512 * 1024), "512K")
        XCTAssertEqual(ByteFormatter.compactRate(1.5 * 1024 * 1024), "1.5M")
        XCTAssertEqual(ByteFormatter.compactRate(25 * 1024 * 1024), "25M")
        XCTAssertEqual(ByteFormatter.compactRate(2 * 1024 * 1024 * 1024), "2.0G")
        XCTAssertEqual(ByteFormatter.compactRate(-5), "0K")
    }

    func testUptime() {
        XCTAssertEqual(DurationFormatter.uptime(59), "0 分钟")
        XCTAssertEqual(DurationFormatter.uptime(8 * 60), "8 分钟")
        XCTAssertEqual(DurationFormatter.uptime(5 * 3600 + 12 * 60), "5 小时 12 分")
        XCTAssertEqual(DurationFormatter.uptime(3 * 86_400 + 4 * 3600), "3 天 4 小时")
    }
}

final class BatteryMathTests: XCTestCase {
    func testNewFormatUsesBatteryData() {
        // macOS 26+:顶层 MaxCapacity 是百分比,真实容量在 BatteryData 里
        let props: [String: Any] = [
            "MaxCapacity": 100,
            "BatteryData": ["DesignCapacity": 4629, "NominalChargeCapacity": 4796, "FullChargeCapacity": 4669, "MaxCapacity": 100],
        ]
        let c = BatteryMath.capacities(props)
        XCTAssertEqual(c.design, 4629)
        XCTAssertEqual(c.max, 4796)
        XCTAssertEqual(BatteryMath.health(design: c.design, max: c.max), 100)
    }

    func testLegacyFormat() {
        let props: [String: Any] = ["DesignCapacity": 5000, "MaxCapacity": 4000]
        let c = BatteryMath.capacities(props)
        XCTAssertEqual(c.design, 5000)
        XCTAssertEqual(c.max, 4000)
        XCTAssertEqual(BatteryMath.health(design: c.design, max: c.max), 80)
    }

    func testPercentMaxCapacityIgnored() {
        let c = BatteryMath.capacities(["DesignCapacity": 5000, "MaxCapacity": 100])
        XCTAssertNil(c.max)
        XCTAssertNil(BatteryMath.health(design: c.design, max: c.max))
    }
}

final class ChargePolicyTests: XCTestCase {
    func testManualChargeLimit() {
        let p = ChargePolicyReader.classify([ChargeCtrlPolicy(reason: "manualChargeLimit", soclimit: 80)])
        XCTAssertEqual(p, .chargeLimit(80))
    }

    func testManagedPolicy() {
        XCTAssertEqual(ChargePolicyReader.classify([ChargeCtrlPolicy(reason: "adaptive", soclimit: 80)]),
                       .managed(80))
        // soclimit 为 100/0 时视为读不到上限数值
        XCTAssertEqual(ChargePolicyReader.classify([ChargeCtrlPolicy(reason: "x", soclimit: 100)]),
                       .managed(nil))
    }

    func testTerminatedAndEmpty() {
        XCTAssertEqual(ChargePolicyReader.classify([]), .none)
        XCTAssertEqual(ChargePolicyReader.classify([
            ChargeCtrlPolicy(reason: "manualChargeLimit", soclimit: 80, terminated: true),
        ]), .none)
    }

    /// 模拟 powerd 写入的 NSKeyedArchive:类名必须能对上,且走安全解码
    func testArchiveRoundtrip() throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: [ChargeCtrlPolicy(reason: "manualChargeLimit", soclimit: 85)],
            requiringSecureCoding: true)
        let classes: [AnyClass] = [NSArray.self, NSMutableArray.self, ChargeCtrlPolicy.self, NSString.self, NSUUID.self]
        let policies = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [ChargeCtrlPolicy])
        XCTAssertEqual(policies.first?.soclimit, 85)
        XCTAssertEqual(ChargePolicyReader.classify(policies), .chargeLimit(85))
    }
}

final class BatteryCareTests: XCTestCase {
    private func texts(_ tips: [CareTip]) -> [String] { tips.map(\.text) }

    func testTempWarning() {
        let tips = BatteryCare.tips(policy: .none, onAC: false, acDuration: nil,
                                    temperatureC: 42, healthPercent: nil)
        XCTAssertTrue(tips.contains(where: \.warning))
    }

    func testLowHealthWarning() {
        let tips = BatteryCare.tips(policy: .chargeLimit(80), onAC: true, acDuration: nil,
                                    temperatureC: nil, healthPercent: 75)
        XCTAssertTrue(tips.contains { $0.warning && $0.text.contains("健康度") })
    }

    func testPluggedNoPolicySuggestsLimit() {
        let tips = BatteryCare.tips(policy: .none, onAC: true, acDuration: nil,
                                    temperatureC: nil, healthPercent: nil)
        XCTAssertTrue(texts(tips).contains { $0.contains("充电上限") })
    }

    func testLongPluggedSuggestsDischarge() {
        let tips = BatteryCare.tips(policy: .none, onAC: true, acDuration: 4 * 86_400,
                                    temperatureC: nil, healthPercent: nil)
        XCTAssertTrue(texts(tips).contains { $0.contains("4 天") })
        // 已开启上限则不再提示放电
        let limited = BatteryCare.tips(policy: .chargeLimit(80), onAC: true, acDuration: 4 * 86_400,
                                       temperatureC: nil, healthPercent: nil)
        XCTAssertFalse(texts(limited).contains { $0.contains("放电") })
    }

    func testChargeLimitShowsOK() {
        let tips = BatteryCare.tips(policy: .chargeLimit(80), onAC: true, acDuration: nil,
                                    temperatureC: nil, healthPercent: nil)
        XCTAssertTrue(tips.contains { !$0.warning })
    }

    func testFallbackTip() {
        let tips = BatteryCare.tips(policy: .chargeLimit(80), onAC: false, acDuration: nil,
                                    temperatureC: nil, healthPercent: nil)
        XCTAssertEqual(tips.count, 1)
    }
}

final class ProcessParserTests: XCTestCase {
    func testParse() {
        let output = """
          123   5.3  20480 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
            1   0.0   1024 /sbin/launchd
          garbage line
          456  120.5 1048576 kernel_task
        """
        let entries = ProcessParser.parse(output)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0], ProcessEntry(pid: 123, name: "Google Chrome", cpu: 5.3, memBytes: 20480 * 1024))
        XCTAssertEqual(entries[1].name, "launchd")
        XCTAssertEqual(entries[2].name, "kernel_task")
        XCTAssertEqual(entries[2].cpu, 120.5)
    }
}

final class LeftoverMatcherTests: XCTestCase {
    func testMatchesBundleIDVariants() {
        let id = "com.tinyspeck.slackmacgap"
        XCTAssertTrue(LeftoverMatcher.matches(entry: id, bundleID: id, appName: "Slack"))
        XCTAssertTrue(LeftoverMatcher.matches(entry: id + ".plist", bundleID: id, appName: "Slack"))
        XCTAssertTrue(LeftoverMatcher.matches(entry: id + ".savedState", bundleID: id, appName: "Slack"))
        XCTAssertTrue(LeftoverMatcher.matches(entry: "BQR82RBBHL." + id, bundleID: id, appName: "Slack"))
        XCTAssertTrue(LeftoverMatcher.matches(entry: "Slack", bundleID: id, appName: "Slack"))
    }

    func testRejectsUnrelated() {
        let id = "com.foo.bar"
        XCTAssertFalse(LeftoverMatcher.matches(entry: "com.foo.barbaz", bundleID: id, appName: "Bar"))
        XCTAssertFalse(LeftoverMatcher.matches(entry: "com.foo", bundleID: id, appName: "Bar"))
        XCTAssertFalse(LeftoverMatcher.matches(entry: "Google", bundleID: id, appName: "Bar"))
        // 过短的应用名不按名字匹配,避免误伤
        XCTAssertFalse(LeftoverMatcher.matches(entry: "Qt", bundleID: nil, appName: "Qt"))
    }

    func testNestedVendorCandidates() throws {
        let chrome = try XCTUnwrap(LeftoverMatcher.nestedCandidates(bundleID: "com.google.Chrome", appName: "Google Chrome"))
        XCTAssertEqual(chrome.vendor, "google")
        XCTAssertEqual(chrome.names, ["google chrome", "chrome"])
        XCTAssertNil(LeftoverMatcher.nestedCandidates(bundleID: "md.obsidian", appName: "Obsidian"))
        XCTAssertNil(LeftoverMatcher.nestedCandidates(bundleID: nil, appName: "Foo"))
    }
}

final class ThresholdTriggerTests: XCTestCase {
    func testFiresOnceUntilRearmed() {
        var trigger = ThresholdTrigger(threshold: 0.9, rearm: 0.8)
        XCTAssertFalse(trigger.update(0.5))
        XCTAssertTrue(trigger.update(0.95))
        XCTAssertFalse(trigger.update(0.97))
        XCTAssertFalse(trigger.update(0.85))   // 未低于 rearm,不重新布防
        XCTAssertFalse(trigger.update(0.95))
        XCTAssertFalse(trigger.update(0.7))
        XCTAssertTrue(trigger.update(0.92))
    }

    func testSustain() {
        let t0 = Date(timeIntervalSince1970: 0)
        var trigger = ThresholdTrigger(threshold: 0.9, rearm: 0.7, sustain: 120)
        XCTAssertFalse(trigger.update(0.95, now: t0))
        XCTAssertFalse(trigger.update(0.95, now: t0.addingTimeInterval(60)))
        // 中途回落会重新计时
        XCTAssertFalse(trigger.update(0.5, now: t0.addingTimeInterval(90)))
        XCTAssertFalse(trigger.update(0.95, now: t0.addingTimeInterval(100)))
        XCTAssertFalse(trigger.update(0.95, now: t0.addingTimeInterval(200)))
        XCTAssertTrue(trigger.update(0.95, now: t0.addingTimeInterval(220)))
    }
}

final class SpeedTestParserTests: XCTestCase {
    func testParse() throws {
        let json = #"{"dl_throughput": 80000000, "ul_throughput": 16000000, "base_rtt": 23.5, "responsiveness": 1234.5, "interface_name": "en0"}"#
        let result = try XCTUnwrap(SpeedTestParser.parse(Data(json.utf8)))
        XCTAssertEqual(result.downloadBps, 10_000_000)
        XCTAssertEqual(result.uploadBps, 2_000_000)
        XCTAssertEqual(result.latencyMs, 23.5)
        XCTAssertEqual(result.responsivenessLevel, "高")
        XCTAssertEqual(result.interface, "en0")
        XCTAssertEqual(ByteFormatter.mbps(result.downloadBps), "80.0 Mbps")
        XCTAssertEqual(ByteFormatter.mbps(125_000_000), "1.0 Gbps")
    }

    func testParseInvalid() {
        XCTAssertNil(SpeedTestParser.parse(Data("oops".utf8)))
        XCTAssertNil(SpeedTestParser.parse(Data(#"{"base_rtt": 20}"#.utf8)))
    }
}

final class BluetoothBatteryParserTests: XCTestCase {
    func testParse() {
        let json = """
        {"SPBluetoothDataType": [{
          "device_connected": [
            {"AirPods Pro": {"device_minorType": "Headphones", "device_batteryLevelLeft": "90%", "device_batteryLevelRight": "85%", "device_batteryLevelCase": "40%"}},
            {"Magic Mouse": {"device_minorType": "Mouse", "device_batteryLevelMain": "15%"}},
            {"iPhone": {"device_address": "00:11"}}
          ],
          "device_not_connected": [{"Old Keyboard": {"device_batteryLevelMain": "50%"}}]
        }]}
        """
        let devices = BluetoothBatteryParser.parse(Data(json.utf8))
        XCTAssertEqual(devices.map(\.name), ["AirPods Pro", "Magic Mouse"])
        XCTAssertEqual(devices[0].levels.map(\.percent), [90, 85, 40])
        XCTAssertEqual(devices[0].levels.map(\.label), ["左", "右", "充电盒"])
        XCTAssertEqual(devices[0].symbolName, "airpodspro")
        XCTAssertEqual(devices[1].levels, [.init(label: nil, percent: 15)])
        XCTAssertEqual(devices[1].symbolName, "magicmouse")
    }
}

@MainActor
final class ClipboardStoreTests: XCTestCase {
    private func makeStore() -> ClipboardStore {
        ClipboardStore(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    func testDedupMovesToTopAndKeepsPin() {
        let store = makeStore()
        store.add(.text("a"))
        store.add(.text("b"))
        store.togglePin(store.items[1])  // 置顶 a
        store.add(.text("a"))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items[0].content, .text("a"))
        XCTAssertTrue(store.items[0].pinned)
    }

    func testPinnedFirstAndSurviveClearAndLimit() {
        let store = makeStore()
        store.add(.text("pinned"))
        store.togglePin(store.items[0])
        for i in 0..<(ClipboardStore.limit + 5) {
            store.add(.text("item \(i)"))
        }
        XCTAssertEqual(store.items.count, ClipboardStore.limit + 1)
        XCTAssertEqual(store.sortedItems.first?.content, .text("pinned"))
        store.clear()
        XCTAssertEqual(store.items.map(\.content), [.text("pinned")])
    }

    func testSearch() {
        let store = makeStore()
        store.add(.text("Hello World"))
        store.add(.files(["/Users/me/Documents/report.pdf"]))
        XCTAssertEqual(store.filtered("world").count, 1)
        XCTAssertEqual(store.filtered("report").count, 1)
        XCTAssertEqual(store.filtered("Documents").count, 1)
        XCTAssertEqual(store.filtered("").count, 2)
    }
}

final class MetricMathTests: XCTestCase {
    func testCPUDelta() {
        let prev = CPUSample(user: 0, system: 0, idle: 100, nice: 0)
        let cur = CPUSample(user: 25, system: 25, idle: 150, nice: 0)
        XCTAssertEqual(MetricMath.cpuUsage(prev: prev, cur: cur), 0.5, accuracy: 0.001)
    }

    func testCPUDeltaAllIdle() {
        let prev = CPUSample(user: 10, system: 5, idle: 85, nice: 0)
        let cur = CPUSample(user: 10, system: 5, idle: 185, nice: 0)
        XCTAssertEqual(MetricMath.cpuUsage(prev: prev, cur: cur), 0, accuracy: 0.001)
    }

    func testCPUDeltaZeroTotal() {
        let s = CPUSample(user: 1, system: 1, idle: 1, nice: 1)
        XCTAssertEqual(MetricMath.cpuUsage(prev: s, cur: s), 0)
    }
}

final class ScreenCaptureTests: XCTestCase {
    private let output = URL(fileURLWithPath: "/tmp/shot.png")

    func testArguments() {
        XCTAssertEqual(ScreenCaptureCommand.arguments(mode: .region, output: output), ["-i", "/tmp/shot.png"])
        XCTAssertEqual(ScreenCaptureCommand.arguments(mode: .window, output: output, sound: false, shadow: false),
                       ["-i", "-W", "-x", "-o", "/tmp/shot.png"])
        XCTAssertEqual(ScreenCaptureCommand.arguments(mode: .screen, output: output, delay: 5, display: 2),
                       ["-D", "2", "-T", "5", "/tmp/shot.png"])
        // 延时只对全屏生效(交互模式下倒计时没有意义)
        XCTAssertEqual(ScreenCaptureCommand.arguments(mode: .region, output: output, delay: 5), ["-i", "/tmp/shot.png"])
    }

    func testFileNameAndUnique() throws {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute, components.second) = (2026, 9, 8, 7, 5, 3)
        let date = try XCTUnwrap(Calendar.current.date(from: components))
        let name = CaptureFiles.fileName(for: date)
        XCTAssertEqual(name, "截图 2026-09-08 07.05.03.png")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(CaptureFiles.uniqueURL(in: folder, fileName: name).lastPathComponent, name)
        try Data().write(to: folder.appendingPathComponent(name))
        XCTAssertEqual(CaptureFiles.uniqueURL(in: folder, fileName: name).lastPathComponent, "截图 2026-09-08 07.05.03 (2).png")
        try Data().write(to: folder.appendingPathComponent("截图 2026-09-08 07.05.03 (2).png"))
        XCTAssertEqual(CaptureFiles.uniqueURL(in: folder, fileName: name).lastPathComponent, "截图 2026-09-08 07.05.03 (3).png")
    }

    func testAfterAction() {
        XCTAssertTrue(CaptureAfterAction.copy.copies)
        XCTAssertFalse(CaptureAfterAction.copy.saves)
        XCTAssertFalse(CaptureAfterAction.save.copies)
        XCTAssertTrue(CaptureAfterAction.copyAndSave.copies && CaptureAfterAction.copyAndSave.saves)
    }

    func testHotKeyPresetsDistinct() {
        XCTAssertNil(ScreenshotHotKey.off.carbonKey)
        let keys = ScreenshotHotKey.allCases.compactMap(\.carbonKey).map { "\($0.keyCode)-\($0.modifiers)" }
        let clipboardKeys = ClipboardHotKey.allCases.compactMap(\.carbonKey).map { "\($0.keyCode)-\($0.modifiers)" }
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(Set(keys).isDisjoint(with: clipboardKeys))
        XCTAssertNotEqual(ScreenshotHotKey.slot, ClipboardHotKey.slot)
    }

    func testRecognizeText() async throws {
        let size = NSSize(width: 600, height: 160)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("Hello MacTool" as NSString).draw(at: NSPoint(x: 20, y: 60), withAttributes: [
                .font: NSFont.systemFont(ofSize: 48, weight: .semibold),
                .foregroundColor: NSColor.black,
            ])
            return true
        }
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let text = try await CaptureActions.recognizeText(cgImage)
        XCTAssertTrue(text.contains("MacTool"), "识别结果:\(text)")
    }
}
