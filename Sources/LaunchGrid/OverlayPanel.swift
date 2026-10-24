import AppKit
import Quartz
import SwiftUI

/// 全屏浮层：无边框、非激活、盖住 Dock 与菜单栏，行为对齐旧 Launchpad
final class OverlayPanel: NSPanel {
    /// 浮层收起时的回调，用于停掉进程轮询
    var onHide: (() -> Void)?

    init(rootView: some View) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        contentViewController = NSHostingController(rootView: rootView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show(on screen: NSScreen) {
        DebugLog.log("panel.show frame=\(screen.frame)")
        setFrame(screen.frame, display: true)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DebugLog.log("panel shown isVisible=\(isVisible) frame=\(frame)")
    }

    func hide() {
        orderOut(nil)
        onHide?()
    }

    deinit {}
}
