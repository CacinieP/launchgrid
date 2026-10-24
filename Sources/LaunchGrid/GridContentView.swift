import SwiftUI

/// 应用网格：顶部搜索与背景已上移到 RootView，这里只负责网格与分页
struct GridContentView: View {
    let apps: [AppItem]
    @Binding var query: String
    let onLaunch: (AppItem) -> Void

    @State private var page = 0

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
        VStack(spacing: 28) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: query) { _ in page = 0 }
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
