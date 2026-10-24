import SwiftUI

/// 浮层的两种模式
enum LaunchMode: String, CaseIterable, Identifiable {
    case apps = "应用"
    case processes = "进程"

    var id: String { rawValue }
}

/// 浮层根视图：顶部统一切换与搜索，下方按模式渲染
struct RootView: View {
    @ObservedObject var appStore: AppStore
    @ObservedObject var monitor: ProcessMonitor
    @Binding var mode: LaunchMode
    let onLaunch: (AppItem) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

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
        .frame(minWidth: 860, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear { searchFocused = true }
        .onChange(of: mode) { newMode in
            // 只有进程页才需要持续跑 ps
            monitor.setActive(newMode == .processes)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .apps:
            GridContentView(apps: appStore.apps, query: $query, onLaunch: onLaunch)
        case .processes:
            ProcessContentView(monitor: monitor, query: $query)
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
            .frame(width: 170)

            searchField

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(mode == .apps ? "搜索应用" : "搜索进程 / PID", text: $query)
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
