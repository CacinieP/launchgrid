import AppKit
import Combine
import Darwin

/// 单个运行中进程的快照
struct ProcessEntry: Identifiable, Equatable {
    let pid: Int32
    let ppid: Int32
    let user: String
    let cpu: Double
    let memPercent: Double
    let rssKB: Int64
    let state: String
    let command: String
    /// 是否为带 Dock 图标的 GUI 应用（来自 NSWorkspace）
    let isApplication: Bool

    var id: Int32 { pid }

    /// 展示名：取可执行文件名
    var displayName: String {
        let base = (command as NSString).lastPathComponent
        return base.isEmpty ? command : base
    }

    /// 从可执行路径反推 .app 包路径，用于取图标
    var appBundlePath: String? {
        guard let dotApp = command.range(of: ".app/") else { return nil }
        let end = command.index(dotApp.lowerBound, offsetBy: 4) // ".app" 之后
        return String(command[command.startIndex ..< end])
    }

    var memoryText: String {
        let megabytes = Double(rssKB) / 1024
        if megabytes >= 1024 { return String(format: "%.1f GB", megabytes / 1024) }
        return String(format: "%.0f MB", megabytes)
    }

    var cpuText: String { String(format: "%.1f%%", cpu) }

    var memText: String { String(format: "%.1f%%", memPercent) }
}

/// 进程清单的采集与终止
///
/// 取数走 `/bin/ps`（覆盖全部进程，含非 GUI 的 node / python / launchd 等），
/// GUI 判定与图标走 NSWorkspace。面板切到进程页时才轮询，隐藏时立刻停。
final class ProcessMonitor: ObservableObject {
    @Published private(set) var processes: [ProcessEntry] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var lastError: String?

    private var timer: Timer?
    private var isRefreshing = false
    private let refreshInterval: TimeInterval = 2

    // MARK: - 轮询

    /// 面板可见性驱动轮询，避免应用在后台时一直跑 ps
    func setActive(_ active: Bool) {
        if active {
            refresh()
            guard timer == nil else { return }
            let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        // NSWorkspace.runningApplications 在主线程取，交给后台线程做纯字符串解析
        let applicationPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = ProcessMonitor.readSnapshot(applicationPIDs: applicationPIDs)
            DispatchQueue.main.async {
                guard let self else { return }
                self.processes = snapshot
                self.updatedAt = Date()
                self.lastError = snapshot.isEmpty ? "无法读取进程列表" : nil
                self.isRefreshing = false
            }
        }
    }

    // MARK: - 取数

    private static func readSnapshot(applicationPIDs: Set<Int32>) -> [ProcessEntry] {
        // 全量 ps 输出轻松上百 KB，必须走 Shell 的临时文件读取：
        // 管道 readDataToEndOfFile 在 macOS 上会截断大输出（见 Shell.run 注释）
        let result = Shell.run(
            "/bin/ps",
            ["-axww", "-o", "pid=,ppid=,user=,%cpu=,%mem=,rss=,state=,comm="],
            timeout: 10
        )
        guard result.isSuccess, !result.stdout.isEmpty else { return [] }

        var resultEntries: [ProcessEntry] = []
        resultEntries.reserveCapacity(1024)

        for line in result.stdout.split(separator: "\n") {
            // comm 放在最后且路径可能含空格，所以最多切 7 刀，末段保留完整路径
            let fields = line.split(maxSplits: 7,
                                    omittingEmptySubsequences: true,
                                    whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 8 else { continue }

            let pid = Int32(fields[0]) ?? -1
            guard pid > 0 else { continue }

            resultEntries.append(ProcessEntry(
                pid: pid,
                ppid: Int32(fields[1]) ?? 0,
                user: String(fields[2]),
                cpu: Double(fields[3]) ?? 0,
                memPercent: Double(fields[4]) ?? 0,
                rssKB: Int64(fields[5]) ?? 0,
                state: String(fields[6]),
                // ps 的 comm 字段前会带一段对齐空格
                command: String(fields[7]).trimmingCharacters(in: .whitespaces),
                isApplication: applicationPIDs.contains(pid)
            ))
        }
        return resultEntries
    }

    // MARK: - 终止

    enum Action {
        case terminate
        case forceTerminate
    }

    /// 执行终止动作，返回 nil 表示成功，否则是给用户看的失败原因
    func perform(_ action: Action, on entry: ProcessEntry) -> String? {
        switch action {
        case .terminate:
            // GUI 应用优先走 NSRunningApplication，应用能收到退出事件并自行保存状态
            if entry.isApplication,
               let app = NSRunningApplication(processIdentifier: entry.pid),
               app.terminate() {
                return nil
            }
            return ProcessMonitor.signal(entry.pid, SIGTERM)
        case .forceTerminate:
            return ProcessMonitor.signal(entry.pid, SIGKILL)
        }
    }

    private static func signal(_ pid: Int32, _ sig: Int32) -> String? {
        guard kill(pid, sig) == 0 else {
            let code = errno
            switch code {
            case EPERM:
                return "权限不足：无法终止 PID \(pid)（需要管理员权限）"
            case ESRCH:
                return "进程 PID \(pid) 已退出"
            default:
                return "终止 PID \(pid) 失败（errno \(code)）"
            }
        }
        return nil
    }

    /// 只知道 PID 时的终止入口（网络页按流量归因后直接处置用）
    ///
    /// GUI 应用仍优先走 `NSRunningApplication.terminate()`，让它能自行保存并退出。
    func terminate(pid: Int32, force: Bool = false) -> String? {
        if !force,
           let app = NSRunningApplication(processIdentifier: pid),
           app.terminate() {
            return nil
        }
        return ProcessMonitor.signal(pid, force ? SIGKILL : SIGTERM)
    }
}
