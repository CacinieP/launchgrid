import SwiftUI

/// 浮层的四种模式
enum LaunchMode: String, CaseIterable, Identifiable {
    case apps = "应用"
    case processes = "进程"
    case clipboard = "剪贴板"
    case network = "网络"

    var id: String { rawValue }
}

/// 浮层根视图：顶部统一切换与搜索，下方按模式渲染
struct RootView: View {
    @ObservedObject var appStore: AppStore
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var clipboardStore: ClipboardStore
    @ObservedObject var pasteContext: PasteContext
    @ObservedObject var networkMonitor: NetworkMonitor
    @ObservedObject var navigation: LauncherNavigation
    @ObservedObject private var preferences = AppPreferences.shared
    @Binding var mode: LaunchMode
    let onLaunch: (AppItem) -> Void
    /// 收起浮层（回贴前要把前台让给目标 app）
    let onHidePanel: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var inspectedApp: AppItem?

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .underWindowBackground)

            VStack(spacing: 20) {
                topBar
                content
                    .frame(maxHeight: .infinity)
            }
            .padding(.vertical, 28)
        }
        .frame(minWidth: 660, minHeight: 400)
        .preferredColorScheme(.dark)
        .onAppear { searchFocused = true }
        .onChange(of: mode) { _ in
            query = ""
            inspectedApp = nil
            searchFocused = true
        }
        .onChange(of: navigation.inspectionRevision) { _ in inspectedApp = nil }
        .sheet(item: $inspectedApp) { app in
            AppDetailView(app: app, monitor: monitor, networkMonitor: networkMonitor,
                          onLaunch: { onLaunch(app) })
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .apps:
            GridContentView(apps: appStore.apps, query: $query, onLaunch: onLaunch,
                            onInspect: { inspectedApp = $0 })
        case .processes:
            ProcessContentView(monitor: monitor, query: $query)
        case .clipboard:
            ClipboardContentView(
                store: clipboardStore,
                pasteContext: pasteContext,
                query: $query,
                onHide: onHidePanel
            )
        case .network:
            if preferences.networkEnabled {
                NetworkContentView(monitor: networkMonitor, processMonitor: monitor, query: $query)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "network.slash").font(.largeTitle)
                    Text("网络模块已关闭").font(.title2)
                    Text("开启后，仅在网络面板或应用详情显示时采样。").foregroundStyle(.secondary)
                    Button("开启网络模块") { preferences.networkEnabled = true }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var searchPlaceholder: String {
        switch mode {
        case .apps: return "搜索应用"
        case .processes: return "搜索进程 / PID"
        case .clipboard: return "搜索剪贴板"
        case .network: return "搜索进程 / 地址"
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)

            Picker("", selection: $mode) {
                ForEach(LaunchMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 290)

            searchField

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(searchPlaceholder, text: $query)
                .accessibilityIdentifier("launcher-search")
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 340)
        .background(.regularMaterial, in: Capsule())
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.blendingMode = .behindWindow
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
