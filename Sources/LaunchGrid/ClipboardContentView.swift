import SwiftUI

/// 剪贴板历史面板：列出复制过的文本，可搜索，并直接回贴回原 app
struct ClipboardContentView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var pasteContext: PasteContext
    @Binding var query: String
    /// 收起浮层（回贴前要让出前台）
    let onHide: () -> Void

    @State private var selectedID: UUID?
    @State private var notice: String?
    @State private var trusted = PasteBack.isTrusted

    private let timeWidth: CGFloat = 76
    private let sourceWidth: CGFloat = 150

    // MARK: - 数据

    private var filtered: [ClipboardEntry] {
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            entry.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (entry.sourceName?.range(of: query, options: [.caseInsensitive]) != nil)
        }
    }

    private var selected: ClipboardEntry? {
        guard let selectedID else { return nil }
        return store.entries.first { $0.id == selectedID }
    }

    // MARK: - 视图

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.bottom, 8)
            Divider().opacity(0.25)

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Text(store.entries.isEmpty ? "剪贴板还是空的" : "没有匹配的内容")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    if store.entries.isEmpty {
                        Text("复制点东西就会出现在这里")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            ClipboardRow(
                                entry: entry,
                                isSelected: entry.id == selectedID,
                                timeWidth: timeWidth,
                                sourceWidth: sourceWidth
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedID = entry.id
                                notice = nil
                            }
                            .onTapGesture(count: 2) {
                                pasteBack(entry)
                            }
                            .contextMenu {
                                Button("直接回贴") { pasteBack(entry) }
                                Button("仅复制到剪贴板") { copyOnly(entry) }
                                if let url = URL(string: entry.text), url.scheme != nil {
                                    Button("打开链接") { openURL(entry) }
                                }
                                Divider()
                                Button("删除这条") { remove(entry) }
                            }
                            .padding(.horizontal, 40)
                            Divider().opacity(0.12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().opacity(0.25)
            actionBar
                .padding(.horizontal, 40)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            trusted = PasteBack.isTrusted
            store.runDailyCleanupIfNeeded()
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Text("时间")
                .frame(width: timeWidth, alignment: .leading)
            Text("内容")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("来源")
                .frame(width: sourceWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if !trusted {
                permissionBanner
            }

            HStack(spacing: 14) {
                if let entry = selected {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已选：\(entry.preview)")
                            .font(.callout)
                            .lineLimit(1)
                        Text(entry.sourceName ?? "未知来源")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("点击一条内容以选择，双击可直接回贴")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                Button {
                    if let entry = selected { pasteBack(entry) }
                } label: {
                    Text("直接回贴")
                }
                .disabled(selected == nil || !trusted)

                Button {
                    if let entry = selected { copyOnly(entry) }
                } label: {
                    Text("仅复制")
                }
                .disabled(selected == nil)

                Button {
                    if let entry = selected { remove(entry) }
                } label: {
                    Text("删除")
                }
                .disabled(selected == nil)

                statusText
            }
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            Text("直接回贴需要「辅助功能」权限")
                .font(.caption)
            Button("去授权") {
                PasteBack.requestTrust()
                PasteBack.openAccessibilitySettings()
            }
            .controlSize(.small)
            Button("仅复制模式已可用") {
                trusted = true
            }
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusText: some View {
        Text("\(filtered.count)/\(store.entries.count) 条 · 保留 7 天")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 160, alignment: .trailing)
    }

    // MARK: - 动作

    private func pasteBack(_ entry: ClipboardEntry) {
        do {
            try PasteBack.paste(entry.text, into: pasteContext.target) {
                onHide()
            }
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    private func copyOnly(_ entry: ClipboardEntry) {
        if PasteBack.copyToPasteboard(entry.text) {
            notice = "已复制到剪贴板，请手动粘贴"
        } else {
            notice = "写入剪贴板失败"
        }
    }

    private func openURL(_ entry: ClipboardEntry) {
        guard let url = URL(string: entry.text), url.scheme != nil else { return }
        NSWorkspace.shared.open(url)
    }

    private func remove(_ entry: ClipboardEntry) {
        store.remove(entry)
        if selectedID == entry.id { selectedID = nil }
    }
}

/// 单条剪贴板记录
private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let timeWidth: CGFloat
    let sourceWidth: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.timeText)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: timeWidth, alignment: .leading)

            Text(entry.preview)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.sourceName ?? "—")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: sourceWidth, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
    }
}
