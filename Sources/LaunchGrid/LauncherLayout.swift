import Foundation
import Combine

struct LauncherItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case app, folder }
    let kind: Kind
    let value: String
    var id: String { "\(kind.rawValue):\(value)" }
    static func app(_ path: String) -> Self { Self(kind: .app, value: path) }
    static func folder(_ id: String) -> Self { Self(kind: .folder, value: id) }
}

struct LauncherFolder: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var appPaths: [String]
}

struct LauncherLayout: Codable, Equatable {
    var version = 1
    var root: [LauncherItem] = []
    var folders: [LauncherFolder] = []
    var aliases: [String: [String]] = [:]

    /// A backup is deliberately a small, versioned document containing app paths, never executable data.
    func validate() throws {
        guard version == 1 else { throw LauncherLayoutError.unsupportedVersion }
        let folderIDs = folders.map(\.id)
        guard Set(folderIDs).count == folderIDs.count,
              folders.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw LauncherLayoutError.invalidDocument }
        let references = root.filter { $0.kind == .folder }.map(\.value)
        guard Set(references).count == references.count, Set(references) == Set(folderIDs) else {
            throw LauncherLayoutError.invalidDocument
        }
        let paths = root.filter { $0.kind == .app }.map(\.value) + folders.flatMap(\.appPaths)
        guard Set(paths).count == paths.count,
              paths.allSatisfy({ $0.hasPrefix("/") && URL(fileURLWithPath: $0).pathExtension.lowercased() == "app" }),
              aliases.values.flatMap({ $0 }).allSatisfy({ $0.count <= 200 }) else {
            throw LauncherLayoutError.invalidDocument
        }
    }

    /// Reconcile a saved layout against the installed inventory, preserving every surviving position.
    mutating func synchronize(with apps: [AppItem]) {
        let installed = Set(apps.map(\.id))
        var used = Set<String>()
        var nextFolders: [LauncherFolder] = []
        var nextRoot: [LauncherItem] = []
        for item in root {
            switch item.kind {
            case .app:
                if installed.contains(item.value), used.insert(item.value).inserted { nextRoot.append(item) }
            case .folder:
                guard var folder = folders.first(where: { $0.id == item.value }),
                      !nextFolders.contains(where: { $0.id == folder.id }) else { continue }
                folder.appPaths = folder.appPaths.filter { installed.contains($0) && used.insert($0).inserted }
                nextFolders.append(folder)
                nextRoot.append(item)
            }
        }
        for app in apps where used.insert(app.id).inserted { nextRoot.append(.app(app.id)) }
        root = nextRoot
        folders = nextFolders
        aliases = aliases.filter { installed.contains($0.key) }
    }

    var orderedAppPaths: [String] {
        root.flatMap { item in
            item.kind == .app ? [item.value] : (folders.first { $0.id == item.value }?.appPaths ?? [])
        }
    }
}

enum LauncherLayoutError: LocalizedError {
    case unsupportedVersion, invalidDocument, oversizedDocument, noInstalledApps, unavailableLegacyDatabase, invalidLegacyDatabase, legacyImportTimedOut, legacyImportTooLarge, recoveryBlocked

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "这个布局备份的版本暂不支持。"
        case .invalidDocument: return "布局文件无效，应用或文件夹记录不完整、重复，或路径格式错误。"
        case .oversizedDocument: return "布局文件超过 5 MB，无法导入。"
        case .noInstalledApps: return "布局中没有找到已安装的应用，当前布局未更改。"
        case .unavailableLegacyDatabase: return "未找到旧 Launchpad 数据库。系统升级后可能已删除它；可手动选择保留的数据库文件。"
        case .invalidLegacyDatabase: return "无法读取这个 Launchpad 数据库，或其中没有可识别的应用布局。当前布局未更改。"
        case .legacyImportTimedOut: return "读取旧 Launchpad 数据库超时，导入已停止。当前布局未更改。"
        case .legacyImportTooLarge: return "旧 Launchpad 数据库的输出超出安全大小限制，导入已停止。当前布局未更改。"
        case .recoveryBlocked: return "无法隔离损坏的布局文件，已停止保存以保留原文件。请先在 Finder 中移走该文件，再重新启动 LaunchGrid。"
        }
    }
}

final class LauncherLayoutStore: ObservableObject {
    static let shared = LauncherLayoutStore()
    @Published private(set) var layout: LauncherLayout
    @Published var errorMessage: String?
    private let fileURL: URL
    private let recoveryBlocked: Bool
    private var unacknowledgedLoadError: String?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchGrid/launcher-layout.json")
        var loaded = LauncherLayout()
        let recoveryNoticeURL = self.fileURL.appendingPathExtension("recovery-notice.txt")
        var loadError = try? String(contentsOf: recoveryNoticeURL, encoding: .utf8)
        var blocked = false
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let size = try self.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 5_000_000 else { throw LauncherLayoutError.oversizedDocument }
                let data = try Data(contentsOf: self.fileURL)
                loaded = try JSONDecoder().decode(LauncherLayout.self, from: data)
                try loaded.validate()
            } catch {
                loaded = LauncherLayout()
                let originalError = error.localizedDescription
                let backup = self.fileURL.deletingLastPathComponent().appendingPathComponent("launcher-layout.corrupt-\(UUID().uuidString).json")
                do {
                    try FileManager.default.moveItem(at: self.fileURL, to: backup)
                    loadError = "读取布局失败：\(originalError)\n原文件已隔离保留在：\(backup.path)\n已创建新的应用布局；隔离文件不会被自动覆盖。"
                } catch {
                    blocked = true
                    loadError = "读取布局失败：\(originalError)\n\(LauncherLayoutError.recoveryBlocked.localizedDescription)\n原文件：\(self.fileURL.path)"
                }
                if let loadError { try? Data(loadError.utf8).write(to: recoveryNoticeURL, options: .atomic) }
            }
        }
        self.layout = loaded
        self.errorMessage = loadError
        self.unacknowledgedLoadError = loadError
        self.recoveryBlocked = blocked
    }

    func acknowledgeError() {
        unacknowledgedLoadError = nil
        errorMessage = nil
        try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("recovery-notice.txt"))
    }

    func synchronize(with apps: [AppItem]) {
        var updated = layout
        updated.synchronize(with: apps)
        if updated != layout { apply(updated) }
    }

    @discardableResult
    func createFolder(named name: String, appPaths: [String] = []) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var next = layout
        let known = Set(layout.orderedAppPaths)
        var seen = Set<String>()
        let members = appPaths.filter { known.contains($0) && seen.insert($0).inserted }
        for path in members { removeApp(path, from: &next) }
        let id = UUID().uuidString
        next.folders.append(LauncherFolder(id: id, name: String(name.prefix(80)), appPaths: members))
        next.root.append(.folder(id))
        apply(next)
        return id
    }

    func renameFolder(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = layout.folders.firstIndex(where: { $0.id == id }) else { return }
        var next = layout
        next.folders[index].name = String(name.prefix(80))
        apply(next)
    }

    /// Dissolving a folder places its apps at the folder's previous root position.
    func dissolveFolder(_ id: String) {
        guard let folder = layout.folders.first(where: { $0.id == id }),
              let index = layout.root.firstIndex(of: .folder(id)) else { return }
        var next = layout
        next.root.replaceSubrange(index...index, with: folder.appPaths.map(LauncherItem.app))
        next.folders.removeAll { $0.id == id }
        apply(next)
    }

    func moveApp(_ path: String, toFolder folderID: String?) {
        guard layout.orderedAppPaths.contains(path) else { return }
        if let folderID, !layout.folders.contains(where: { $0.id == folderID }) { return }
        var next = layout
        removeApp(path, from: &next)
        if let folderID, let index = next.folders.firstIndex(where: { $0.id == folderID }) {
            next.folders[index].appPaths.append(path)
        } else {
            next.root.append(.app(path))
        }
        apply(next)
    }

    func reorder(_ item: LauncherItem, before target: LauncherItem, inFolder folderID: String?) {
        guard item != target else { return }
        var next = layout
        if let folderID, item.kind == .app, target.kind == .app,
           let index = next.folders.firstIndex(where: { $0.id == folderID }),
           next.folders[index].appPaths.contains(item.value), next.folders[index].appPaths.contains(target.value) {
            next.folders[index].appPaths.removeAll { $0 == item.value }
            if let position = next.folders[index].appPaths.firstIndex(of: target.value) {
                next.folders[index].appPaths.insert(item.value, at: position)
            }
        } else if folderID == nil, next.root.contains(item), next.root.contains(target) {
            next.root.removeAll { $0 == item }
            if let index = next.root.firstIndex(of: target) { next.root.insert(item, at: index) }
        } else { return }
        apply(next)
    }

    /// Move to a final index after removal, so page-boundary moves work in either direction.
    func move(_ item: LauncherItem, toIndex destination: Int, inFolder folderID: String?) {
        var next = layout
        if let folderID, item.kind == .app,
           let folderIndex = next.folders.firstIndex(where: { $0.id == folderID }),
           next.folders[folderIndex].appPaths.contains(item.value) {
            next.folders[folderIndex].appPaths.removeAll { $0 == item.value }
            let index = min(max(0, destination), next.folders[folderIndex].appPaths.count)
            next.folders[folderIndex].appPaths.insert(item.value, at: index)
        } else if folderID == nil, next.root.contains(item) {
            next.root.removeAll { $0 == item }
            next.root.insert(item, at: min(max(0, destination), next.root.count))
        } else { return }
        apply(next)
    }

    func move(_ item: LauncherItem, toEndOfFolder folderID: String?) {
        if item.kind == .app { moveApp(item.value, toFolder: folderID) }
        else if folderID == nil, layout.root.contains(item) {
            var next = layout
            next.root.removeAll { $0 == item }
            next.root.append(item)
            apply(next)
        }
    }

    func setAliases(_ aliases: [String], for appPath: String) {
        var next = layout
        let trimmed = aliases.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        next.aliases[appPath] = trimmed.filter { seen.insert($0).inserted }
        apply(next)
    }

    func restoreAlphabetical(apps: [AppItem]) {
        var next = LauncherLayout()
        next.aliases = layout.aliases
        let sorted = apps.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        next.synchronize(with: sorted)
        apply(next)
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(layout)
    }

    @discardableResult
    func importData(_ data: Data, apps: [AppItem]) throws -> Int {
        guard data.count <= 5_000_000 else { throw LauncherLayoutError.oversizedDocument }
        var imported = try JSONDecoder().decode(LauncherLayout.self, from: data)
        try imported.validate()
        let known = Set(apps.map(\.id))
        let importedCount = imported.orderedAppPaths.filter { known.contains($0) }.count
        guard importedCount > 0 else { throw LauncherLayoutError.noInstalledApps }
        imported.synchronize(with: apps)
        try persist(imported)
        layout = imported
        return importedCount
    }

    func importLegacy(at url: URL, apps: [AppItem]) throws -> Int {
        try importLegacyLayout(LegacyLaunchpadImporter.read(url: url, apps: apps), apps: apps)
    }

    func importLegacyLayout(_ imported: LauncherLayout, apps: [AppItem]) throws -> Int {
        try imported.validate()
        let installed = Set(apps.map(\.id))
        let count = imported.orderedAppPaths.filter { installed.contains($0) }.count
        guard count > 0 else { throw LauncherLayoutError.noInstalledApps }
        var reconciled = imported
        reconciled.aliases = layout.aliases
        reconciled.synchronize(with: apps)
        try persist(reconciled)
        layout = reconciled
        return count
    }

    private func removeApp(_ path: String, from layout: inout LauncherLayout) {
        layout.root.removeAll { $0 == .app(path) }
        for index in layout.folders.indices { layout.folders[index].appPaths.removeAll { $0 == path } }
    }

    private func apply(_ updated: LauncherLayout) {
        if recoveryBlocked {
            layout = updated // Session-only layout; the unreadable original must stay untouched.
            errorMessage = unacknowledgedLoadError ?? LauncherLayoutError.recoveryBlocked.localizedDescription
            return
        }
        do {
            try persist(updated)
            layout = updated
            errorMessage = unacknowledgedLoadError
        } catch {
            errorMessage = [unacknowledgedLoadError, "保存布局失败：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func persist(_ updated: LauncherLayout) throws {
        guard !recoveryBlocked else { throw LauncherLayoutError.recoveryBlocked }
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

private final class LauncherSearchTerms: NSObject {
    let values: [String]
    init(_ values: [String]) { self.values = values }
}

enum LauncherSearch {
    private static let cache: NSCache<NSString, LauncherSearchTerms> = {
        let cache = NSCache<NSString, LauncherSearchTerms>()
        cache.countLimit = 4096
        return cache
    }()

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func terms(for candidate: String) -> [String] {
        if let cached = cache.object(forKey: candidate as NSString) { return cached.values }
        let direct = normalized(candidate)
        let latin = normalized(candidate.applyingTransform(.toLatin, reverse: false) ?? candidate)
        let words = latin.split { !$0.isLetter && !$0.isNumber }
        let values = [direct, latin, words.joined(), String(words.compactMap(\.first))]
        cache.setObject(LauncherSearchTerms(values), forKey: candidate as NSString)
        return values
    }

    static func matches(_ app: AppItem, query: String, aliases: [String] = []) -> Bool {
        let needle = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return true }
        let compactNeedle = needle.filter { !$0.isWhitespace }
        return ([app.name] + aliases).contains { candidate in
            let values = terms(for: candidate)
            return values[0].contains(needle) || values[1].contains(needle)
                || values[2].contains(compactNeedle) || values[3].contains(compactNeedle)
        }
    }
}

enum GridDirection { case left, right, up, down }

enum GridNavigation {
    static func move(from current: Int?, direction: GridDirection, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        let columns = max(1, columns)
        guard let current, (0..<count).contains(current) else {
            return direction == .left || direction == .up ? count - 1 : 0
        }
        switch direction {
        case .left: return (current + count - 1) % count
        case .right: return (current + 1) % count
        case .up:
            if current >= columns { return current - columns }
            return ((count - 1 - current) / columns) * columns + current
        case .down:
            return current + columns < count ? current + columns : current % columns
        }
    }
}
