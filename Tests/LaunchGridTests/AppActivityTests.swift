import XCTest
@testable import LaunchGrid

final class AppActivityTests: XCTestCase {
    func testAttributesNestedHelpersAndDescendantsButNotSimilarAppNames() {
        func process(_ pid: Int32, _ ppid: Int32, _ command: String) -> ProcessEntry {
            ProcessEntry(pid: pid, ppid: ppid, user: "test", cpu: 1, memPercent: 0, rssKB: 10,
                         state: "S", command: command, isApplication: true)
        }
        let entries = [
            process(10, 1, "/Applications/Foo.app/Contents/MacOS/Foo"),
            process(11, 10, "/Applications/Foo.app/Contents/Helpers/Sub.app/Contents/MacOS/Sub"),
            process(12, 11, "/usr/bin/python3"),
            process(13, 1, "/Applications/Foo.app.old/Contents/MacOS/Foo"),
            process(14, 1, "/Applications/Foo Pro.app/Contents/MacOS/Foo"),
            process(15, 1, "/usr/bin/python3"),
        ]
        XCTAssertEqual(Set(AppActivity.processes(for: URL(fileURLWithPath: "/Applications/Foo.app"),
                                               in: entries).map(\.pid)), [10, 11, 12])
    }

    func testHandlesCycleWithoutLoopingAndDoesNotInventRunningApps() {
        XCTAssertTrue(AppActivity.processes(for: URL(fileURLWithPath: "/Applications/Missing.app"), in: []).isEmpty)
        let entries = [ProcessEntry(pid: 3, ppid: 3, user: "test", cpu: 0, memPercent: 0,
                                    rssKB: 0, state: "S", command: "/Applications/Foo.app/Contents/MacOS/Foo",
                                    isApplication: true)]
        XCTAssertEqual(AppActivity.processes(for: URL(fileURLWithPath: "/Applications/Foo.app"), in: entries).count, 1)
    }
}
