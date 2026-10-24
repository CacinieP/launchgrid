import Foundation

/// 命令执行结果
struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var isSuccess: Bool { status == 0 }

    /// 去掉首尾空白的标准输出
    var output: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Shell 命令执行
///
/// 所有对系统工具的调用都走这里，方便统一处理超时、退出码和错误文案。
/// 全部用数组传参，不拼 shell 字符串，从根上避免引号转义类漏洞。
enum Shell {
    enum ShellError: LocalizedError {
        case launchFailed(String)
        case nonZeroExit(String)
        case timedOut(String)
        case userCancelled
        case unsafeCommand

        var errorDescription: String? {
            switch self {
            case .launchFailed(let cmd): return "无法执行 \(cmd)"
            case .nonZeroExit(let msg): return msg
            case .timedOut(let cmd): return "\(cmd) 执行超时"
            case .userCancelled: return "用户取消了管理员授权"
            case .unsafeCommand: return "拒绝执行不安全的命令"
            }
        }
    }

    /// 执行命令并返回结果（不抛错）
    ///
    /// 输出走临时文件而不是 Pipe：Foundation 的 `readDataToEndOfFile()`
    /// 在 macOS 上会截断大输出（实测 155KB 只拿到 101KB，裸写也一样），
    /// 而这些命令的输出轻松上百 KB（netstat -an 就 150KB+）。
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval? = 15) -> ShellResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        task.standardInput = FileHandle.nullDevice

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let outURL = temporaryDirectory.appendingPathComponent("lgtmp-\(UUID().uuidString).out")
        let errURL = temporaryDirectory.appendingPathComponent("lgtmp-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        guard let outHandle = FileHandle(forWritingAtPath: outURL.path),
              let errHandle = FileHandle(forWritingAtPath: errURL.path) else {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
            return ShellResult(status: -1, stdout: "", stderr: "无法创建输出文件")
        }
        task.standardOutput = outHandle
        task.standardError = errHandle

        defer {
            try? outHandle.close()
            try? errHandle.close()
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        do {
            try task.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        var timedOut = false
        if let timeout {
            let watchdog = DispatchWorkItem {
                if task.isRunning {
                    timedOut = true
                    task.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            task.waitUntilExit()
            watchdog.cancel()
        } else {
            task.waitUntilExit()
        }

        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""

        if timedOut {
            return ShellResult(status: -1, stdout: stdout, stderr: "执行超时")
        }
        return ShellResult(status: task.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// 执行命令，非零退出抛错，返回标准输出
    @discardableResult
    static func check(_ launchPath: String, _ args: [String], timeout: TimeInterval? = 15) throws -> String {
        let result = run(launchPath, args, timeout: timeout)
        if result.status == -1 {
            throw ShellError.launchFailed(launchPath)
        }
        guard result.isSuccess else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError.nonZeroExit(message.isEmpty ? "命令执行失败（退出码 \(result.status)）" : message)
        }
        return result.output
    }

    /// 通过系统原生授权弹窗以管理员身份执行 shell 命令
    ///
    /// - Parameter command: 交给 root 执行的命令串。不能含引号或反斜杠。
    static func privileged(_ command: String) throws {
        guard !command.contains("\""), !command.contains("\\") else {
            throw ShellError.unsafeCommand
        }
        let script = "do shell script \"\(command)\" with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", script], timeout: 120)
        guard result.status == 0 else {
            let message = result.stderr.lowercased()
            if result.stderr.contains("-128") || message.contains("cancel") || message.contains("cancelled") {
                throw ShellError.userCancelled
            }
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError.nonZeroExit(detail.isEmpty ? "特权命令执行失败（需要管理员权限）" : detail)
        }
    }

    /// 先直接执行，失败（多为权限不足）再走管理员授权弹窗重试
    static func privilegedFallback(_ launchPath: String, _ args: [String], asCommand: String) throws {
        let direct = run(launchPath, args, timeout: 20)
        if direct.isSuccess { return }
        try privileged(asCommand)
    }
}
