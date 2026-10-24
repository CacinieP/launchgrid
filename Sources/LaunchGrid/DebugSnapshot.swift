import AppKit

/// 调试用：把浮层内容渲染成 PNG 写到磁盘
///
/// 在没有录屏权限（screencapture 报 "could not create image from display"）的环境里，
/// 用这个开关可以直接从应用内部拿到真实渲染结果：
///
///     LAUNCHGRID_SNAPSHOT_PATH=/tmp/lg.png LAUNCHGRID_SHOW_ON_LAUNCH=processes open -a LaunchGrid
enum DebugSnapshot {
    static var outputPath: String? {
        ProcessInfo.processInfo.environment["LAUNCHGRID_SNAPSHOT_PATH"]
    }

    static func capture(_ view: NSView) {
        guard let path = outputPath else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            DebugLog.log("snapshot written \(path)")
        } catch {
            DebugLog.log("snapshot failed \(error)")
        }
    }
}
