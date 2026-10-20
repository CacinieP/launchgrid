import SwiftUI

struct GridContentView: View {
    let apps: [AppItem]
    let onLaunch: (AppItem) -> Void

    @State private var query = ""
    @State private var page = 0
    @FocusState private var searchFocused: Bool

    private let columnsCount = 7
    private let perPage = 35

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 28), count: columnsCount)
    }

    private var filtered: [AppItem] {
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private var pages: [[AppItem]] {
        guard !filtered.isEmpty else { return [] }
        return stride(from: 0, to: filtered.count, by: perPage).map {
            Array(filtered[$0 ..< min($0 + perPage, filtered.count)])
        }
    }

    private var currentPage: [AppItem] {
        guard !pages.isEmpty else { return [] }
        return pages[min(max(page, 0), pages.count - 1)]
    }

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .underWindowBackground)

            VStack(spacing: 28) {
                searchField

                if currentPage.isEmpty {
                    Text("没有找到应用")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(currentPage) { app in
                                AppIconView(app: app) { onLaunch(app) }
                            }
                        }
                        .padding(.horizontal, 48)
                    }
                    .frame(maxHeight: .infinity)
                }

                if pages.count > 1 {
                    pageIndicator
                }
            }
            .padding(.vertical, 36)
        }
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(.dark)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _ in page = 0 }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索应用", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 340)
        .background(.regularMaterial, in: Capsule())
    }

    private var pageIndicator: some View {
        HStack(spacing: 10) {
            ForEach(pages.indices, id: \.self) { index in
                Circle()
                    .fill(index == min(max(page, 0), pages.count - 1) ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .onTapGesture { page = index }
            }
        }
    }
}

private struct AppIconView: View {
    let app: AppItem
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
            Text(app.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 110)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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
