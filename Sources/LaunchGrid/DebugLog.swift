import Foundation

enum DebugLog {
    static let path = "/tmp/launchgrid-debug.log"

    static func log(_ message: String) {
        let line = "\(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: nil)
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
