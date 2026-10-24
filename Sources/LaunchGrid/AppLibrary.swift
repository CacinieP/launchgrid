import AppKit
import Combine

struct AppItem: Identifiable, Equatable {
    let url: URL
    let name: String

    var id: String { url.path }
    var icon: NSImage { AppIconCache.shared.icon(for: url) }
}

/// 应用图标缓存
///
/// 网格每次重绘都会取图标，不缓存的话每一帧都要从磁盘重新读 .app。
final class AppIconCache {
    static let shared = AppIconCache()

    private var cache: [String: NSImage] = [:]

    func icon(for url: URL) -> NSImage {
        let key = url.path
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(forFile: key)
        cache[key] = image
        return image
    }
}

/// 应用清单的可观察包装
///
/// 之前刷新清单靠丢弃并重建浮层实现，导致刷新时必须重新 show 一次。
final class AppStore: ObservableObject {
    @Published private(set) var apps: [AppItem] = []

    func reload() {
        apps = AppLibrary.apps()
    }
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
