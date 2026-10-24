import AppKit

/// 进程入口。用 `@main` 而不是 main.swift 顶层代码：
/// 带 main.swift 的 target 无法被测试 target `@testable import`。
@main
struct LaunchGridMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
