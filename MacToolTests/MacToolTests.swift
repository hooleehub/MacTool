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
