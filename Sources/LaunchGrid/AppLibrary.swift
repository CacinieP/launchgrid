import AppKit

struct AppItem: Identifiable, Equatable {
    let url: URL
    let name: String

    var id: String { url.path }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

/// 从标准应用目录发现 .app（替代已移除的 Launchpad 数据源）
enum AppLibrary {
    static var searchPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
    }

    static func apps() -> [AppItem] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [AppItem] = []

        for dir in searchPaths {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in files where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                guard seen.insert(name.lowercased()).inserted else { continue }
                result.append(AppItem(url: url, name: name))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
