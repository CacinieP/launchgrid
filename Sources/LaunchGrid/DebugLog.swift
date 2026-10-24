import Foundation

enum DebugLog {
    static let path = "/tmp/launchgrid-debug.log"

    /// Debug 构建默认开；Release 默认关（网络页 2 秒一条日志会无限增长），
    /// 需要时可 `defaults write app.caciniep.launchgrid launchgrid.debugLog -bool YES` 打开
    private static let isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "launchgrid.debugLog")
        #endif
    }()

    static func log(_ message: String) {
        guard isEnabled else { return }
        let line = "\(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        // /tmp 世界可写：目标若被换成了符号链接，写入会跟随到任意用户文件，先删掉重建
        if let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType,
           type != .typeRegular {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: nil)
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
