import Foundation
import Darwin

/// Reads Apple's legacy database through the system SQLite client in read-only mode.
/// No database is created, copied, migrated, or written, including when a selected path is invalid.
enum LegacyLaunchpadImporter {
    struct Row: Decodable {
        let id: Int
        let parent: Int
        let position: Int
        let title: String
        let bundleID: String
        let kind: String
    }

    static func candidateDatabases() -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        if let userDirectory = try? run(executable: "/usr/bin/getconf", arguments: ["DARWIN_USER_DIR"]),
           let path = String(data: userDirectory, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let directory = URL(fileURLWithPath: path).appendingPathComponent("com.apple.dock.launchpad")
            result.append(directory.appendingPathComponent("db/db"))
        }
        let dock = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dock")
        if let files = try? fm.contentsOfDirectory(at: dock, includingPropertiesForKeys: nil) {
            result += files.filter { $0.pathExtension == "db" }
        }
        return result.filter { fm.fileExists(atPath: $0.path) }
    }

    static func read(url: URL, apps: [AppItem]) throws -> LauncherLayout {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw LauncherLayoutError.unavailableLegacyDatabase }
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 100_000_000 else {
            throw LauncherLayoutError.invalidLegacyDatabase
        }
        let sql = """
            PRAGMA trusted_schema=OFF;
            PRAGMA query_only=ON;
            SELECT i.item_id AS id, COALESCE(i.parent_id, 0) AS parent,
                   COALESCE(i.ordering, 0) AS position, substr(COALESCE(a.title, g.title, ''), 1, 200) AS title,
                   substr(COALESCE(a.bundleid, ''), 1, 200) AS bundleID,
                   CASE WHEN a.item_id IS NOT NULL THEN 'app'
                        WHEN g.item_id IS NOT NULL THEN 'group' ELSE 'container' END AS kind
            FROM items AS i
            LEFT JOIN apps AS a ON a.item_id = i.item_id
            LEFT JOIN groups AS g ON g.item_id = i.item_id
            ORDER BY i.ordering, i.item_id LIMIT 20000;
            """
        do {
            let options = ["-safe", "-init", "/dev/null", "-readonly", "-json", url.path]
            // Reject views in place of Apple's three ordinary tables before evaluating any joins.
            let schemaSQL = "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; SELECT count(*) AS count FROM sqlite_master WHERE type='table' AND name IN ('items','apps','groups');"
            let schemaData = try run(executable: "/usr/bin/sqlite3", arguments: options + [schemaSQL], maximumOutputBytes: 1024)
            let schema = try JSONSerialization.jsonObject(with: schemaData) as? [[String: Any]]
            guard (schema?.first?["count"] as? NSNumber)?.intValue == 3 else { throw LauncherLayoutError.invalidLegacyDatabase }
            let data = try run(executable: "/usr/bin/sqlite3", arguments: options + [sql])
            let rows = try JSONDecoder().decode([Row].self, from: data)
            return try makeLayout(rows: rows, apps: apps)
        } catch let error as LauncherLayoutError { throw error }
        catch { throw LauncherLayoutError.invalidLegacyDatabase }
    }

    static func makeLayout(rows: [Row], apps: [AppItem]) throws -> LauncherLayout {
        guard Set(rows.map(\.id)).count == rows.count else { throw LauncherLayoutError.invalidLegacyDatabase }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let bundleIDs = Dictionary(grouping: apps, by: { Bundle(url: $0.url)?.bundleIdentifier ?? "" })
        let names = Dictionary(grouping: apps, by: { LauncherSearch.normalized($0.name) })
        var usedApps = Set<String>()
        var addedFolders = Set<String>()
        var layout = LauncherLayout()

        func ancestors(of row: Row) -> [Row] {
            var ancestors: [Row] = []
            var visited: Set<Int> = [row.id]
            var parent = row.parent
            while let node = byID[parent], visited.insert(node.id).inserted, ancestors.count < 100 {
                ancestors.insert(node, at: 0)
                parent = node.parent
            }
            return ancestors
        }

        func orderKey(_ row: Row) -> [Int] {
            (ancestors(of: row) + [row]).flatMap { [$0.position, $0.id] }
        }

        let orderedApps = rows.filter { $0.kind == "app" }.sorted {
            orderKey($0).lexicographicallyPrecedes(orderKey($1))
        }
        for row in orderedApps {
            let bundleMatches = row.bundleID.isEmpty ? [] : bundleIDs[row.bundleID] ?? []
            let nameMatches = names[LauncherSearch.normalized(row.title)] ?? []
            // Ambiguous display names are skipped; a bundle ID is preferable to a guessed application.
            let app = bundleMatches.first ?? (nameMatches.count == 1 ? nameMatches.first : nil)
            guard let app, usedApps.insert(app.id).inserted else { continue }
            let folder = ancestors(of: row).last {
                $0.kind == "group" && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if let folder {
                let id = "launchpad-\(folder.id)"
                if addedFolders.insert(id).inserted {
                    layout.folders.append(LauncherFolder(id: id, name: folder.title, appPaths: []))
                    layout.root.append(.folder(id))
                }
                if let index = layout.folders.firstIndex(where: { $0.id == id }) {
                    layout.folders[index].appPaths.append(app.id)
                }
            } else {
                layout.root.append(.app(app.id))
            }
        }
        guard !usedApps.isEmpty else { throw LauncherLayoutError.noInstalledApps }
        return layout
    }

    /// Bounded temporary output avoids pipe truncation and never loads oversized output into memory.
    /// Production callers invoke this on a background queue; both process lifetime and disk output are capped.
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 3,
                    maximumOutputBytes: Int = 8_000_000) throws -> Data {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("LaunchGrid-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let outputURL = scratch.appendingPathComponent("output")
        guard fm.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = FileHandle(forWritingAtPath: outputURL.path) else { throw LauncherLayoutError.invalidLegacyDatabase }
        defer { try? output.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var failure: LauncherLayoutError?
        while task.isRunning {
            let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > maximumOutputBytes { failure = .legacyImportTooLarge; break }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = .legacyImportTimedOut; break }
            usleep(20_000)
        }
        if let failure {
            task.terminate()
            usleep(10_000)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
            throw failure
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw LauncherLayoutError.invalidLegacyDatabase }
        let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumOutputBytes else { throw LauncherLayoutError.legacyImportTooLarge }
        return try Data(contentsOf: outputURL)
    }
}
