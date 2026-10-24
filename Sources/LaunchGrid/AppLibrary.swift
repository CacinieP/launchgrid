import AppKit
import Combine
import Darwin

struct AppItem: Identifiable, Equatable {
    let url: URL
    let name: String

    var id: String { url.path }
    var icon: NSImage { AppIconCache.shared.icon(for: url) }
}

/// Reused by every grid redraw; the cache is cleared when the installed inventory changes.
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

    func invalidate() { cache.removeAll() }
}

/// Watches application directories, including category subdirectories and missing-directory parents.
/// File-system events are debounced; no polling or application launches are required.
final class AppStore: ObservableObject {
    @Published private(set) var apps: [AppItem] = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingReload: DispatchWorkItem?
    private var workspaceObserver: NSObjectProtocol?
    private let searchPaths: [URL]

    init(searchPaths: [URL] = AppLibrary.searchPaths) {
        self.searchPaths = searchPaths
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleReload() }
    }

    func reload() {
        precondition(Thread.isMainThread)
        let inventory = AppLibrary.scan(paths: searchPaths)
        AppIconCache.shared.invalidate()
        apps = inventory.apps
        watch(inventory.directories)
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func watch(_ directories: [URL]) {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for url in directories {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib, .extend, .link, .revoke], queue: .main
            )
            source.setEventHandler { [weak self] in self?.scheduleReload() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        pendingReload?.cancel()
        sources.forEach { $0.cancel() }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }
}

enum AppLibrary {
    static var searchPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                home.appendingPathComponent("Applications")]
    }

    static func apps() -> [AppItem] { scan().apps }

    static func scan(paths: [URL] = searchPaths) -> (apps: [AppItem], directories: [URL]) {
        let fm = FileManager.default
        var seen = Set<String>()
        var visited = Set<String>()
        var directories: [URL] = []
        var result: [AppItem] = []

        func visit(_ directory: URL, depth: Int) {
            let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
            guard depth <= 12, visited.insert(canonical.path).inserted else { return }
            guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                // A newly created ~/Applications should trigger another scan as well.
                let parent = directory.deletingLastPathComponent()
                if fm.fileExists(atPath: parent.path) { directories.append(parent) }
                return
            }
            directories.append(directory)
            for url in children where !url.lastPathComponent.hasPrefix(".") {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if url.pathExtension.lowercased() == "app", values?.isDirectory == true {
                    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                    guard seen.insert(resolved.path).inserted else { continue }
                    let bundle = Bundle(url: url)
                    let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    result.append(AppItem(url: resolved, name: name))
                } else if values?.isDirectory == true, values?.isSymbolicLink != true {
                    visit(url, depth: depth + 1)
                }
            }
        }
        paths.forEach { visit($0, depth: 0) }
        let sorted = result.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        // Directory URLs from contentsOfDirectory carry a trailing slash; root/missing-parent
        // URLs may not. Deduplicate by canonical filesystem path rather than URL spelling.
        let watchPaths = Set(directories.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        return (sorted, watchPaths.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) })
    }
}
