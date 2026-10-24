// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// Attribute helpers by bundle path and descendants, never by a truncated process name.
enum AppActivity {
    static func processes(for appURL: URL, in entries: [ProcessEntry]) -> [ProcessEntry] {
        let path = appURL.standardizedFileURL.resolvingSymlinksInPath().path
        var included = Set(entries.filter {
            $0.command.hasPrefix(path + "/")
        }.map(\.pid))
        var changed = true
        while changed {
            changed = false
            for entry in entries where !included.contains(entry.pid) && included.contains(entry.ppid) {
                included.insert(entry.pid)
                changed = true
            }
        }
        return entries.filter { included.contains($0.pid) }
            .sorted { $0.cpu > $1.cpu }
    }
}

struct AppDetailView: View {
    let app: AppItem
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var networkMonitor: NetworkMonitor
    @ObservedObject private var preferences = AppPreferences.shared
    let onLaunch: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?

    private var processes: [ProcessEntry] { AppActivity.processes(for: app.url, in: monitor.processes) }
    private var pids: Set<Int32> { Set(processes.map(\.pid)) }
    private var traffic: [ProcessTraffic] { networkMonitor.processTraffic.filter { pids.contains($0.pid) } }
    private var connections: [NetworkConnection] { networkMonitor.connections.filter { pids.contains($0.pid) } }
    private var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    private var memory: UInt64 { UInt64(max(0, processes.reduce(Int64(0)) { $0 + $1.rssKB })) * 1024 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: app.icon).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.title2.bold())
                    Text(app.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 24) {
                metric("CPU", value: monitor.updatedAt == nil ? "等待采样" : String(format: "%.1f%%", cpu))
                metric("内存", value: monitor.updatedAt == nil ? "等待采样" : ByteFormat.string(memory))
                metric("进程", value: "\(processes.count)")
                if preferences.networkEnabled {
                    metric("下载", value: ByteFormat.string(traffic.reduce(0) { $0 + $1.bytesIn }) + "/s")
                    metric("上传", value: ByteFormat.string(traffic.reduce(0) { $0 + $1.bytesOut }) + "/s")
                }
            }
            Text("按应用包路径及其子进程归因；CPU 为系统平均值。仅在面板显示时采样。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = monitor.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            if preferences.networkEnabled, let error = networkMonitor.lastError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("运行进程").font(.headline)
                    if processes.isEmpty {
                        Text(monitor.updatedAt == nil ? "正在读取进程…" : "当前未发现运行进程")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(processes) { process in
                        HStack {
                            Text(process.displayName).lineLimit(1)
                            Spacer()
                            Text("PID \(process.pid) · \(process.cpuText) · \(process.memoryText)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Divider().padding(.vertical, 6)
                    Text("网络连接").font(.headline)
                    if !preferences.networkEnabled {
                        Text("网络模块已关闭，可在设置中开启。").foregroundStyle(.secondary)
                    } else if connections.isEmpty {
                        Text(networkMonitor.updatedAt == nil ? "正在读取连接…" : "当前未发现可见连接；其他用户或受限进程可能不可见。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(connections.prefix(100))) { connection in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(connection.protocolName) · \(connection.remoteText)")
                                    .font(.callout).textSelection(.enabled)
                                Text("\(connection.processName) · PID \(connection.pid) · \(connection.state)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if connections.count > 100 { Text("显示前 100 条，共 \(connections.count) 条").font(.caption) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("打开应用") { dismiss(); onLaunch() }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                Button("退出应用") { terminate() }.disabled(processes.isEmpty)
                Spacer()
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(24).frame(width: 720, height: 570)
        .onAppear { inspectionChanged(true) }
        .onDisappear { inspectionChanged(false) }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit()
        }
    }

    private func inspectionChanged(_ active: Bool) {
        NotificationCenter.default.post(name: Notification.Name("LaunchGridAppInspectionChanged"),
                                        object: nil, userInfo: ["active": active])
    }

    private func terminate() {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL
        }
        guard !applications.isEmpty else { notice = "没有可正常退出的应用进程"; return }
        let accepted = applications.map { $0.terminate() }.allSatisfy { $0 }
        notice = accepted ? "已请求退出；应用可能提示保存内容" : "应用未接受退出请求"
    }
}
