import XCTest
import Combine
@testable import LaunchGrid

final class LauncherTests: XCTestCase {
    private var directory: URL!
    private var storageURL: URL { directory.appendingPathComponent("layout.json") }
    private let alpha = AppItem(url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha")
    private let beta = AppItem(url: URL(fileURLWithPath: "/Applications/Beta.app"), name: "Beta")
    private let gamma = AppItem(url: URL(fileURLWithPath: "/Applications/Gamma.app"), name: "Gamma")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchGrid-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func populatedStore() -> LauncherLayoutStore {
        let store = LauncherLayoutStore(fileURL: storageURL)
        store.synchronize(with: [alpha, beta, gamma])
        return store
    }

    func testSearchFindsChinesePinyinAndInitials() {
        let app = AppItem(url: URL(fileURLWithPath: "/Applications/WeChat.app"), name: "微信")
        XCTAssertTrue(LauncherSearch.matches(app, query: "微信"))
        XCTAssertTrue(LauncherSearch.matches(app, query: "wei xin"))
        XCTAssertTrue(LauncherSearch.matches(app, query: "weixin"))
        XCTAssertTrue(LauncherSearch.matches(app, query: "WX"))
        XCTAssertFalse(LauncherSearch.matches(app, query: "calculator"))
    }

    func testSearchHandlesAliasesAccentsWidthAndWhitespace() {
        let app = AppItem(url: URL(fileURLWithPath: "/Applications/Cafe.app"), name: "Café")
        XCTAssertTrue(LauncherSearch.matches(app, query: " CAFE "))
        XCTAssertTrue(LauncherSearch.matches(app, query: "ＣＡＦＥ"))
        XCTAssertTrue(LauncherSearch.matches(app, query: "工作", aliases: ["工作浏览器"]))
        XCTAssertTrue(LauncherSearch.matches(app, query: "gzllq", aliases: ["工作浏览器"]))
        XCTAssertTrue(LauncherSearch.matches(app, query: "   "))
    }

    func testReorderedLayoutSurvivesRelaunchAndAppDiscovery() {
        let store = populatedStore()
        store.reorder(.app(gamma.id), before: .app(alpha.id), inFolder: nil)
        let restored = LauncherLayoutStore(fileURL: storageURL)
        XCTAssertEqual(restored.layout.orderedAppPaths, [gamma.id, alpha.id, beta.id])
        let delta = AppItem(url: URL(fileURLWithPath: "/Applications/Delta.app"), name: "Delta")
        restored.synchronize(with: [alpha, beta, delta, gamma])
        XCTAssertEqual(restored.layout.orderedAppPaths, [gamma.id, alpha.id, beta.id, delta.id])
        restored.synchronize(with: [alpha, delta, gamma])
        XCTAssertEqual(restored.layout.orderedAppPaths, [gamma.id, alpha.id, delta.id])
    }

    func testFolderCreationMembershipRenameReorderAndDissolve() throws {
        let store = populatedStore()
        let folder = try XCTUnwrap(store.createFolder(named: " 工作 ", appPaths: [alpha.id]))
        XCTAssertEqual(store.layout.folders.first?.name, "工作")
        store.moveApp(beta.id, toFolder: folder)
        XCTAssertEqual(store.layout.folders.first?.appPaths, [alpha.id, beta.id])
        store.reorder(.app(beta.id), before: .app(alpha.id), inFolder: folder)
        store.renameFolder(folder, to: "工具")
        XCTAssertEqual(store.layout.folders.first?.name, "工具")
        XCTAssertEqual(store.layout.folders.first?.appPaths, [beta.id, alpha.id])
        let restored = LauncherLayoutStore(fileURL: storageURL)
        XCTAssertEqual(restored.layout, store.layout)
        store.moveApp(alpha.id, toFolder: nil)
        XCTAssertEqual(store.layout.folders.first?.appPaths, [beta.id])
        store.dissolveFolder(folder)
        XCTAssertTrue(store.layout.folders.isEmpty)
        XCTAssertEqual(store.layout.orderedAppPaths, [gamma.id, beta.id, alpha.id])
        XCTAssertEqual(Set(store.layout.orderedAppPaths).count, 3)
    }

    func testInvalidFolderOperationsDoNotLoseApps() {
        let store = populatedStore()
        XCTAssertNil(store.createFolder(named: " \n "))
        store.moveApp(alpha.id, toFolder: "missing")
        store.reorder(.app(alpha.id), before: .app(beta.id), inFolder: "missing")
        store.dissolveFolder("missing")
        XCTAssertEqual(store.layout.orderedAppPaths, [alpha.id, beta.id, gamma.id])
    }

    func testMoveToEndAndFolderToRootReorder() throws {
        let store = populatedStore()
        store.move(.app(alpha.id), toEndOfFolder: nil)
        XCTAssertEqual(store.layout.orderedAppPaths, [beta.id, gamma.id, alpha.id])
        let folder = try XCTUnwrap(store.createFolder(named: "Folder", appPaths: [beta.id]))
        store.reorder(.folder(folder), before: .app(gamma.id), inFolder: nil)
        XCTAssertEqual(store.layout.root.first, .folder(folder))
        store.move(.folder(folder), toEndOfFolder: nil)
        XCTAssertEqual(store.layout.root.last, .folder(folder))
    }

    func testCrossPageMovesPersistInBothDirectionsAndInsideFolders() throws {
        let apps = (0..<80).map {
            AppItem(url: URL(fileURLWithPath: "/Applications/App\($0).app"), name: "App\($0)")
        }
        let store = LauncherLayoutStore(fileURL: storageURL)
        store.synchronize(with: apps)
        store.move(.app(apps[70].id), toIndex: 0, inFolder: nil)
        XCTAssertEqual(store.layout.root[0], .app(apps[70].id))
        store.move(.app(apps[70].id), toIndex: 35, inFolder: nil)
        XCTAssertEqual(store.layout.root[35], .app(apps[70].id), "Moving forward must land on the next page, not its preceding last cell")
        XCTAssertEqual(LauncherLayoutStore(fileURL: storageURL).layout, store.layout)
        let folder = try XCTUnwrap(store.createFolder(named: "All apps", appPaths: apps.map(\.id)))
        store.move(.app(apps[79].id), toIndex: 0, inFolder: folder)
        XCTAssertEqual(store.layout.folders.first?.appPaths.first, apps[79].id)
        store.move(.app(apps[79].id), toIndex: 35, inFolder: folder)
        XCTAssertEqual(store.layout.folders.first?.appPaths[35], apps[79].id)
        XCTAssertEqual(LauncherLayoutStore(fileURL: storageURL).layout, store.layout)
    }

    func testAliasesPersistAndStayWhenRestoringOrder() {
        let store = populatedStore()
        store.setAliases([" 浏览器 ", "browser", "", "browser"], for: alpha.id)
        store.reorder(.app(gamma.id), before: .app(alpha.id), inFolder: nil)
        store.restoreAlphabetical(apps: [gamma, beta, alpha])
        XCTAssertEqual(store.layout.root, [alpha, beta, gamma].map { .app($0.id) })
        XCTAssertEqual(LauncherLayoutStore(fileURL: storageURL).layout.aliases[alpha.id], ["浏览器", "browser"])
    }

    func testBackupRoundTripSkipsMissingAppsAndAppendsNewApps() throws {
        let source = populatedStore()
        let folder = try XCTUnwrap(source.createFolder(named: "Work", appPaths: [gamma.id, alpha.id]))
        source.setAliases(["g"], for: gamma.id)
        let data = try source.exportData()
        let destination = LauncherLayoutStore(fileURL: directory.appendingPathComponent("other.json"))
        XCTAssertEqual(try destination.importData(data, apps: [beta, gamma]), 2)
        XCTAssertEqual(destination.layout.folders.first { $0.id == folder }?.appPaths, [gamma.id])
        XCTAssertEqual(destination.layout.orderedAppPaths, [beta.id, gamma.id])
        XCTAssertEqual(destination.layout.aliases[gamma.id], ["g"])
    }

    func testMalformedImportLeavesExistingLayoutUnchanged() throws {
        let store = populatedStore()
        let original = store.layout
        var duplicate = original
        duplicate.root.append(.app(alpha.id))
        XCTAssertThrowsError(try store.importData(JSONEncoder().encode(duplicate), apps: [alpha, beta, gamma]))
        var invalidFolder = original
        invalidFolder.root.append(.folder("missing"))
        XCTAssertThrowsError(try store.importData(JSONEncoder().encode(invalidFolder), apps: [alpha, beta, gamma]))
        var newer = original
        newer.version = 99
        XCTAssertThrowsError(try store.importData(JSONEncoder().encode(newer), apps: [alpha, beta, gamma]))
        XCTAssertThrowsError(try store.importData(Data("invalid".utf8), apps: [alpha, beta, gamma]))
        XCTAssertThrowsError(try store.importData(Data(repeating: 0, count: 5_000_001), apps: [alpha]))
        XCTAssertThrowsError(try store.importData(JSONEncoder().encode(original), apps: []))
        XCTAssertEqual(store.layout, original)
        XCTAssertEqual(LauncherLayoutStore(fileURL: storageURL).layout, original)
    }

    func testCorruptPersistedLayoutIsIsolatedAndWarningSurvivesSynchronizationAndRelaunch() throws {
        let original = Data("unreadable original layout".utf8)
        try original.write(to: storageURL)
        let store = LauncherLayoutStore(fileURL: storageURL)
        XCTAssertNotNil(store.errorMessage)
        let isolated = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("launcher-layout.corrupt-") }
        XCTAssertEqual(isolated.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(isolated.first)), original)
        store.synchronize(with: [alpha, beta])
        XCTAssertEqual(store.layout.orderedAppPaths, [alpha.id, beta.id])
        XCTAssertNotNil(store.errorMessage, "Automatic reconciliation must not swallow recovery warning")
        let restored = LauncherLayoutStore(fileURL: storageURL)
        XCTAssertNotNil(restored.errorMessage, "Recovery remains visible until acknowledged")
        restored.acknowledgeError()
        XCTAssertNil(LauncherLayoutStore(fileURL: storageURL).errorMessage)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(isolated.first)), original)
    }

    func testLegacyCommandHasDeadlineAndOutputLimit() throws {
        XCTAssertThrowsError(try LegacyLaunchpadImporter.run(executable: "/bin/sleep", arguments: ["2"], timeout: 0.05)) { error in
            XCTAssertEqual(error.localizedDescription, LauncherLayoutError.legacyImportTimedOut.localizedDescription)
        }
        XCTAssertThrowsError(try LegacyLaunchpadImporter.run(executable: "/usr/bin/sqlite3", arguments: ["-safe", "-init", "/dev/null", ":memory:", "SELECT printf('%10000s', 'x');"], maximumOutputBytes: 1024)) { error in
            XCTAssertEqual(error.localizedDescription, LauncherLayoutError.legacyImportTooLarge.localizedDescription)
        }
    }

    func testPersistenceFailureDoesNotPretendToApply() throws {
        let blocked = directory.appendingPathComponent("file")
        try Data().write(to: blocked)
        let store = LauncherLayoutStore(fileURL: blocked.appendingPathComponent("layout.json"))
        store.synchronize(with: [alpha])
        XCTAssertTrue(store.layout.root.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    func testNavigationWrapsRowsColumnsAndPartialLastRow() {
        XCTAssertNil(GridNavigation.move(from: nil, direction: .down, count: 0, columns: 7))
        XCTAssertEqual(GridNavigation.move(from: nil, direction: .down, count: 10, columns: 3), 0)
        XCTAssertEqual(GridNavigation.move(from: 0, direction: .left, count: 10, columns: 3), 9)
        XCTAssertEqual(GridNavigation.move(from: 9, direction: .right, count: 10, columns: 3), 0)
        XCTAssertEqual(GridNavigation.move(from: 1, direction: .up, count: 10, columns: 3), 7)
        XCTAssertEqual(GridNavigation.move(from: 0, direction: .up, count: 10, columns: 3), 9)
        XCTAssertEqual(GridNavigation.move(from: 8, direction: .down, count: 10, columns: 3), 2)
        XCTAssertEqual(GridNavigation.move(from: 9, direction: .down, count: 10, columns: 3), 0)
    }

    func testNavigationCrossesPageBoundaryWithoutLosingSelection() {
        let next = GridNavigation.move(from: 34, direction: .right, count: 72, columns: 7)
        XCTAssertEqual(next, 35)
        XCTAssertEqual(next.map { $0 / 35 }, 1)
        XCTAssertEqual(GridNavigation.move(from: 35, direction: .left, count: 72, columns: 7), 34)
        XCTAssertEqual(GridNavigation.move(from: 500, direction: .down, count: 1, columns: 0), 0)
    }

    func testLegacyRowsPreservePageFolderAndChildOrder() throws {
        typealias Row = LegacyLaunchpadImporter.Row
        let rows = [
            Row(id: 1, parent: 0, position: 0, title: "", bundleID: "", kind: "container"),
            Row(id: 2, parent: 1, position: 0, title: "", bundleID: "", kind: "container"),
            Row(id: 3, parent: 2, position: 0, title: "Alpha", bundleID: "", kind: "app"),
            Row(id: 4, parent: 2, position: 1, title: "Work", bundleID: "", kind: "group"),
            Row(id: 5, parent: 4, position: 1, title: "Beta", bundleID: "", kind: "app"),
            Row(id: 6, parent: 4, position: 0, title: "Gamma", bundleID: "", kind: "app"),
            Row(id: 7, parent: 2, position: 2, title: "Not Installed", bundleID: "", kind: "app")
        ]
        let imported = try LegacyLaunchpadImporter.makeLayout(rows: Array(rows.reversed()), apps: [alpha, beta, gamma])
        XCTAssertEqual(imported.root, [.app(alpha.id), .folder("launchpad-4")])
        XCTAssertEqual(imported.folders.first?.appPaths, [gamma.id, beta.id])
        try imported.validate()
    }

    func testLegacyImportUsesReadOnlySQLiteAndNeverCreatesMissingDatabase() throws {
        let missing = directory.appendingPathComponent("missing.db")
        XCTAssertThrowsError(try LegacyLaunchpadImporter.read(url: missing, apps: [alpha]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let database = directory.appendingPathComponent("launchpad.db")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, """
            CREATE TABLE items(item_id INTEGER PRIMARY KEY, parent_id INTEGER, ordering INTEGER);
            CREATE TABLE apps(item_id INTEGER PRIMARY KEY, title TEXT, bundleid TEXT);
            CREATE TABLE groups(item_id INTEGER PRIMARY KEY, title TEXT);
            INSERT INTO items VALUES(1,0,0),(2,1,0),(3,2,0);
            INSERT INTO groups VALUES(2,'Work');
            INSERT INTO apps VALUES(3,'Alpha','');
            """]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let before = try Data(contentsOf: database)
        let imported = try LegacyLaunchpadImporter.read(url: database, apps: [alpha, beta])
        XCTAssertEqual(imported.folders.first?.name, "Work")
        XCTAssertEqual(imported.orderedAppPaths, [alpha.id])
        XCTAssertEqual(try Data(contentsOf: database), before)
        let invalid = directory.appendingPathComponent("invalid.db")
        try Data("not a database".utf8).write(to: invalid)
        XCTAssertThrowsError(try LegacyLaunchpadImporter.read(url: invalid, apps: [alpha]))
        XCTAssertEqual(try Data(contentsOf: invalid), Data("not a database".utf8))
        let disguisedView = directory.appendingPathComponent("view.db")
        let viewProcess = Process()
        viewProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        viewProcess.arguments = [disguisedView.path, "CREATE VIEW items AS SELECT 1 AS item_id; CREATE TABLE apps(item_id INTEGER); CREATE TABLE groups(item_id INTEGER);"]
        try viewProcess.run()
        viewProcess.waitUntilExit()
        XCTAssertEqual(viewProcess.terminationStatus, 0)
        XCTAssertThrowsError(try LegacyLaunchpadImporter.read(url: disguisedView, apps: [alpha]))
    }

    func testLegacyImportRejectsAmbiguousNamesAndEmptyMatches() {
        let duplicate = AppItem(url: URL(fileURLWithPath: "/Users/Test/Applications/Alpha.app"), name: "Alpha")
        let row = LegacyLaunchpadImporter.Row(id: 1, parent: 0, position: 0, title: "Alpha", bundleID: "", kind: "app")
        XCTAssertThrowsError(try LegacyLaunchpadImporter.makeLayout(rows: [row], apps: [alpha, duplicate]))
        XCTAssertThrowsError(try LegacyLaunchpadImporter.makeLayout(rows: [row, row], apps: [alpha]))
    }

    func testDirectoryWatcherDiscoversInstallAndUninstallAutomatically() throws {
        let vendor = directory.appendingPathComponent("Vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        let store = AppStore(searchPaths: [directory])
        store.reload()
        let installed = expectation(description: "directory event discovers new application")
        let removed = expectation(description: "directory event removes deleted application")
        var sawInstall = false
        let subscription = store.$apps.sink { apps in
            if apps.contains(where: { $0.name == "Watched" }) {
                if !sawInstall { sawInstall = true; installed.fulfill() }
            } else if sawInstall { removed.fulfill() }
        }
        let appURL = vendor.appendingPathComponent("Watched.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        wait(for: [installed], timeout: 5)
        try FileManager.default.removeItem(at: appURL)
        wait(for: [removed], timeout: 5)
        withExtendedLifetime(subscription) {}
    }

    func testAppScanFindsNestedAppsAndDeduplicatesSymlinksByPath() throws {
        let nested = directory.appendingPathComponent("Vendor/Tool.app")
        let inner = nested.appendingPathComponent("Contents/Helpers/Inner.app")
        let sameName = directory.appendingPathComponent("Another/Tool.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sameName, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("Alias.app"), withDestinationURL: nested)
        let inventory = AppLibrary.scan(paths: [directory])
        XCTAssertEqual(Set(inventory.apps.map(\.id)), [nested.path, sameName.path])
        XCTAssertFalse(inventory.apps.contains { $0.id == inner.path })
        XCTAssertTrue(inventory.directories.contains(directory.appendingPathComponent("Vendor", isDirectory: true)))
        let withMissingDirectory = AppLibrary.scan(paths: [directory, directory.appendingPathComponent("Missing")])
        XCTAssertEqual(Set(withMissingDirectory.directories.map(\.path)).count, withMissingDirectory.directories.count)
        XCTAssertEqual(inventory.directories, withMissingDirectory.directories)
    }
}
