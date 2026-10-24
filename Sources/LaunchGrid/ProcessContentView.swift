import SwiftUI

/// 进程管理面板：列出全部进程，带 CPU / 内存占用，可搜索、排序、终止
struct ProcessContentView: View {
    @ObservedObject var monitor: ProcessMonitor
    @Binding var query: String

    @State private var sort: SortKey = .cpu
    @State private var descending = true
    @State private var selectedPID: Int32?
    @State private var notice: String?

    enum SortKey: String, CaseIterable {
        case name = "名称"
        case pid = "PID"
        case cpu = "CPU"
        case memory = "内存"
        case user = "用户"
    }

    private let nameWidth: CGFloat = 340
    private let pidWidth: CGFloat = 62
    private let cpuWidth: CGFloat = 68
    private let memWidth: CGFloat = 92
    private let userWidth: CGFloat = 104

    // MARK: - 数据

    private var filtered: [ProcessEntry] {
        var list = monitor.processes
        if !query.isEmpty {
            list = list.filter { entry in
                entry.displayName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || entry.command.range(of: query, options: [.caseInsensitive]) != nil
                    || String(entry.pid) == query
            }
        }
        switch sort {
        case .name:
            list.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .pid:
            list.sort { $0.pid < $1.pid }
        case .cpu:
            list.sort { $0.cpu < $1.cpu }
        case .memory:
            list.sort { $0.rssKB < $1.rssKB }
        case .user:
            list.sort { $0.user.localizedCaseInsensitiveCompare($1.user) == .orderedAscending }
        }
        // 统一按升序排好，再按需要整体反转
        if descending { list.reverse() }
        return list
    }

    private var selected: ProcessEntry? {
        guard let selectedPID else { return nil }
        return monitor.processes.first { $0.pid == selectedPID }
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
                    Text(monitor.processes.isEmpty ? "正在读取进程列表…" : "没有匹配的进程")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    if let error = monitor.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { entry in
                            ProcessRow(
                                entry: entry,
                                isSelected: entry.pid == selectedPID,
                                nameWidth: nameWidth,
                                pidWidth: pidWidth,
                                cpuWidth: cpuWidth,
                                memWidth: memWidth,
                                userWidth: userWidth
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedPID = entry.pid
                                notice = nil
                            }
                            .contextMenu {
                                Button("终止（SIGTERM）") { perform(.terminate, on: entry) }
                                Button("强制终止（SIGKILL）") { perform(.forceTerminate, on: entry) }
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
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            header("进程名", width: nameWidth, key: .name, alignment: .leading)
            header("PID", width: pidWidth, key: .pid, alignment: .trailing)
            header("CPU", width: cpuWidth, key: .cpu, alignment: .trailing)
            header("内存", width: memWidth, key: .memory, alignment: .trailing)
            header("用户", width: userWidth, key: .user, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func header(_ title: String, width: CGFloat, key: SortKey, alignment: Alignment) -> some View {
        Text(sort == key ? "\(title) \(descending ? "↓" : "↑")" : title)
            .frame(width: width, alignment: alignment)
            .contentShape(Rectangle())
            .onTapGesture {
                if sort == key {
                    descending.toggle()
                } else {
                    sort = key
                    // 数值列默认从高到低，文本列默认从 A 到 Z
                    descending = (key == .cpu || key == .memory)
                }
                notice = nil
            }
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            if let entry = selected {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已选：\(entry.displayName) · PID \(entry.pid)")
                        .font(.callout)
                        .lineLimit(1)
                    Text(entry.command)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("点击列表中的进程以选择")
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
                if let entry = selected { perform(.terminate, on: entry) }
            } label: {
                Text("终止")
            }
            // 不要绑 .defaultAction：搜索框里按回车会误触发终止
            .disabled(selected == nil)

            Button {
                if let entry = selected { perform(.forceTerminate, on: entry) }
            } label: {
                Text("强制终止")
            }
            .disabled(selected == nil)

            statusText
        }
    }

    private var statusText: some View {
        Group {
            if let updatedAt = monitor.updatedAt {
                Text("\(filtered.count)/\(monitor.processes.count) 个进程 · \(updatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(filtered.count)/\(monitor.processes.count) 个进程")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 190, alignment: .trailing)
    }

    // MARK: - 动作

    private func perform(_ action: ProcessMonitor.Action, on entry: ProcessEntry) {
        if let error = monitor.perform(action, on: entry) {
            notice = error
        } else {
            notice = action == .terminate
                ? "已请求退出 \(entry.displayName)"
                : "已强制终止 \(entry.displayName)"
            // 进程消失后清掉选中态
            selectedPID = nil
            monitor.refresh()
        }
    }
}

/// 单行进程
private struct ProcessRow: View {
    let entry: ProcessEntry
    let isSelected: Bool
    let nameWidth: CGFloat
    let pidWidth: CGFloat
    let cpuWidth: CGFloat
    let memWidth: CGFloat
    let userWidth: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.callout)
                    .lineLimit(1)
                Text(entry.command)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: nameWidth, alignment: .leading)

            Text(String(entry.pid))
                .frame(width: pidWidth, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(entry.cpuText)
                .frame(width: cpuWidth, alignment: .trailing)
                .monospacedDigit()

            Text(entry.memoryText)
                .frame(width: memWidth, alignment: .trailing)
                .monospacedDigit()

            Text(entry.user)
                .frame(width: userWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
    }

    @ViewBuilder
    private var icon: some View {
        if let bundlePath = entry.appBundlePath {
            Image(nsImage: AppIconCache.shared.icon(for: URL(fileURLWithPath: bundlePath)))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "gearshape.2")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(2)
        }
    }
}
