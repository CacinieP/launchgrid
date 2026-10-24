import XCTest
@testable import LaunchGrid

/// 纯函数解析层的单元测试：不碰系统命令、不碰网络、不碰 UI
final class LaunchGridTests: XCTestCase {

    // MARK: - ByteFormat

    func testByteFormatBoundaries() {
        XCTAssertEqual(ByteFormat.string(0), "0 B")
        XCTAssertEqual(ByteFormat.string(512), "512 B")
        XCTAssertEqual(ByteFormat.string(1024), "1.0 KB")
        XCTAssertEqual(ByteFormat.string(2048), "2.0 KB")
        XCTAssertEqual(ByteFormat.string(1_572_864), "1.5 MB")
        XCTAssertEqual(ByteFormat.string(1_073_741_824), "1.0 GB")
        XCTAssertEqual(ByteFormat.string(1_099_511_627_776), "1.0 TB")
    }

    // MARK: - netstat 字节计数解析

    /// 标准以太网输出：从表头定位 Ibytes / Obytes 列
    func testParseInterfaceBytesStandardLayout() {
        let output = """
            Name    Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
            en1     1500  <Link#13>     aa:bb:cc:dd:ee:ff 12345     0   1000000   6789     0   2000000     0
            en1     1500  192.168.1.5   192.168.1.5        12345     -   1000000   6789     -   2000000     -
            """
        let bytes = NetworkMonitor.parseInterfaceBytes(output)
        XCTAssertEqual(bytes?.rx, 1_000_000)
        XCTAssertEqual(bytes?.tx, 2_000_000)
    }

    /// utun 没有地址列，后续列整体左移——此时表头定位应取到第一条可解析行
    func testParseInterfaceBytesShiftedLayout() {
        let output = """
            Name      Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
            utun3     1380  <Link#23>                        7     0       300     9     0         400     0
            """
        let bytes = NetworkMonitor.parseInterfaceBytes(output)
        XCTAssertNotNil(bytes)
    }

    func testParseInterfaceBytesEmptyInput() {
        XCTAssertNil(NetworkMonitor.parseInterfaceBytes(""))
        XCTAssertNil(NetworkMonitor.parseInterfaceBytes("Name Mtu Ibytes\nen1 1500"))
    }

    // MARK: - lsof 端点解析

    func testParseLsofEndpoint() {
        XCTAssertEqual(NetworkMonitor.parseLsofEndpoint("[::1]:53")?.address, "::1")
        XCTAssertEqual(NetworkMonitor.parseLsofEndpoint("[::1]:53")?.port, 53)
        XCTAssertEqual(NetworkMonitor.parseLsofEndpoint("1.2.3.4:443")?.address, "1.2.3.4")
        XCTAssertEqual(NetworkMonitor.parseLsofEndpoint("1.2.3.4:443")?.port, 443)
        XCTAssertEqual(NetworkMonitor.parseLsofEndpoint("*:49152")?.address, "*")
        XCTAssertEqual(NetworkMonitor.parseLsofEndpoint("*:49152")?.port, 49152)
        // 无方括号的 IPv6 按最后一个冒号切
        XCTAssertEqual(NetworkMonitor.parseLsofEndpoint("fe80::1:80")?.address, "fe80::1")
        XCTAssertEqual(NetworkMonitor.parseLsofEndpoint("fe80::1:80")?.port, 80)
    }

    // MARK: - 地址归一化与连接去重键

    func testNormalizeAddress() {
        XCTAssertEqual(NetworkMonitor.normalizeAddress("*", isIPv6: false), "0.0.0.0")
        XCTAssertEqual(NetworkMonitor.normalizeAddress("*", isIPv6: true), "::")
        XCTAssertEqual(NetworkMonitor.normalizeAddress("127.0.0.1", isIPv6: false), "127.0.0.1")
    }

    func testConnectionKey() {
        let key = NetworkMonitor.connectionKey(
            local: ("*", 80), remote: ("1.2.3.4", 443), isIPv6: false
        )
        XCTAssertEqual(key, "0.0.0.0:80->1.2.3.4:443")
    }

    // MARK: - lsof COMMAND 转义还原

    func testUnescapeLsofCommand() {
        XCTAssertEqual(NetworkMonitor.unescapeLsofCommand(#"a\x20b"#), "a b")
        XCTAssertEqual(NetworkMonitor.unescapeLsofCommand(#"\x41\x42\x43"#), "ABC")
        // 非十六进制的 \x 序列原样保留
        XCTAssertEqual(NetworkMonitor.unescapeLsofCommand(#"a\xzzb"#), #"a\xzzb"#)
        XCTAssertEqual(NetworkMonitor.unescapeLsofCommand("plain"), "plain")
    }

    // MARK: - 日期键

    func testDayKey() {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 24
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(NetworkMonitor.dayKey(date), "2026-10-24")
    }

    // MARK: - 进程条目派生字段

    func testProcessEntryDerivedFields() {
        let entry = ProcessEntry(
            pid: 42, ppid: 1, user: "caciniep", cpu: 3.5, memPercent: 1.2,
            rssKB: 262_144, state: "S",
            command: "/Applications/Foo.app/Contents/MacOS/Foo",
            isApplication: true
        )
        XCTAssertEqual(entry.displayName, "Foo")
        XCTAssertEqual(entry.appBundlePath, "/Applications/Foo.app")
        XCTAssertEqual(entry.memoryText, "256 MB")
        XCTAssertEqual(entry.cpuText, "3.5%")
    }

    func testProcessEntryWithoutAppBundle() {
        let entry = ProcessEntry(
            pid: 1, ppid: 0, user: "root", cpu: 0, memPercent: 0,
            rssKB: 1024, state: "Ss", command: "/sbin/launchd", isApplication: false
        )
        XCTAssertNil(entry.appBundlePath)
    }

    // MARK: - 剪贴板预览

    func testClipboardPreviewFlattensNewlines() {
        let entry = ClipboardEntry(
            id: UUID(), text: "第一行\n第二行\t缩进", createdAt: Date(),
            sourceBundleID: nil, sourceName: nil
        )
        XCTAssertEqual(entry.preview, "第一行 ⏎ 第二行 缩进")
    }

    func testClipboardPreviewTruncatesLongText() {
        let long = String(repeating: "字", count: 300)
        let entry = ClipboardEntry(
            id: UUID(), text: long, createdAt: Date(),
            sourceBundleID: nil, sourceName: nil
        )
        XCTAssertEqual(entry.preview.count, 161) // 160 + 省略号
        XCTAssertTrue(entry.preview.hasSuffix("…"))
    }
}
