import AppKit
import Combine
import Foundation
import SystemConfiguration

/// 周期（今日 / 本周 / 本月）
enum TrafficPeriod: String, CaseIterable, Identifiable {
    case day = "今日"
    case week = "本周"
    case month = "本月"

    var id: String { rawValue }
}

/// 单个进程的实时流量
struct ProcessTraffic: Identifiable, Equatable {
    let pid: Int32
    let name: String
    /// 每秒下行字节
    let bytesIn: UInt64
    /// 每秒上行字节
    let bytesOut: UInt64

    var id: Int32 { pid }
    var totalBytes: UInt64 { bytesIn + bytesOut }

    var rateText: String {
        ByteFormat.string(totalBytes) + "/s"
    }
}

/// 一条网络连接
struct NetworkConnection: Identifiable, Equatable {
    let id: String
    let protocolName: String
    let localAddress: String
    let localPort: UInt16
    let remoteAddress: String
    let remotePort: UInt16
    let state: String
    let pid: Int32
    let processName: String
    let isIPv6: Bool

    /// IPv6 的地址要加方括号，否则和端口连在一起看不清
    func endpointText(address: String, port: UInt16) -> String {
        guard port != 0 else { return address }
        return isIPv6 ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    var localText: String { endpointText(address: localAddress, port: localPort) }
    var remoteText: String { endpointText(address: remoteAddress, port: remotePort) }
}

/// 累计流量
struct CumulativeTraffic: Equatable {
    var downloadBytes: UInt64 = 0
    var uploadBytes: UInt64 = 0

    var totalBytes: UInt64 { downloadBytes + uploadBytes }
}

/// 字节数格式化
enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var index = 0
        var scaled = value
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        return index == 0
            ? String(format: "%.0f %@", scaled, units[index])
            : String(format: "%.1f %@", scaled, units[index])
    }
}

/// 网络采样与统计
///
/// 整机速率走 `netstat -b` 的网卡字节计数器做差分（不是 nettop 求和——
/// nettop 只能看到本机进程的视角，且列布局随系统版本变）。
/// 按进程归因走 nettop，连接明细走 `netstat -an` + `lsof -i -n -P` 合并。
///
/// 历史按 5 秒增量追加写 JSONL，避免每天重写整个 JSON 的大文件。
final class NetworkMonitor: ObservableObject {
    @Published private(set) var downloadBPS: Double = 0
    @Published private(set) var uploadBPS: Double = 0
    @Published private(set) var processTraffic: [ProcessTraffic] = []
    @Published private(set) var connections: [NetworkConnection] = []
    @Published private(set) var cumulative: CumulativeTraffic = CumulativeTraffic()
    @Published private(set) var samples: [TrafficSample] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var lastError: String?
    /// 系统路由视角的连通性（只读标志位，不发包），状态栏绿点用
    @Published private(set) var isReachable = true

    /// 历史采样间隔
    private let historyInterval: TimeInterval = 5
    /// 历史保留天数
    private static let retentionDays = 45
    /// 实时刷新间隔
    private let liveInterval: TimeInterval = 2

    private var liveTimer: Timer?
    private var historyTimer: Timer?
    private var isRefreshing = false
    private var isRecording = false

    // 速率差分的状态（上次计数 + 上次单调时钟）
    //
    // 实时速率和历史采样各用一套基线：两者轮询周期不同（2s / 5s），
    // 共用一套会互相抢基线，导致速率恒为 0。
    private var rateBaseline: (rx: UInt64, tx: UInt64, uptime: UInt64)?
    private var sampleBaseline: (rx: UInt64, tx: UInt64, uptime: UInt64)?
    private let baselineLock = NSLock()

    // 历史累计的当日缓存
    private var dayTotals: [String: CumulativeTraffic] = [:]

    // MARK: - 模型

    struct TrafficSample: Codable, Identifiable, Equatable {
        let timestamp: Date
        /// 距上次采样的下行增量（字节）
        let downloadBytes: UInt64
        /// 距上次采样的上行增量（字节）
        let uploadBytes: UInt64

        var id: Date { timestamp }
    }

    // MARK: - 轮询

    /// 只有停在网络页时才轮询
    func setActive(_ active: Bool) {
        if active {
            refresh()
            startLiveTimer()
            startHistoryTimer()
        } else {
            liveTimer?.invalidate()
            liveTimer = nil
            historyTimer?.invalidate()
            historyTimer = nil
        }
    }

    private func startLiveTimer() {
        guard liveTimer == nil else { return }
        let timer = Timer(timeInterval: liveInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func startHistoryTimer() {
        guard historyTimer == nil else { return }
        let timer = Timer(timeInterval: historyInterval, repeats: true) { [weak self] _ in
            self?.recordSample()
        }
        RunLoop.main.add(timer, forMode: .common)
        historyTimer = timer
    }

    // MARK: - 实时刷新

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let rate = self.currentRate()
            DebugLog.log("net refresh down=" + String(Int(rate.down))
                        + " up=" + String(Int(rate.up)))
            let traffic = NetworkMonitor.readProcessTraffic()
            let conns = NetworkMonitor.readConnections()
            let online = NetworkMonitor.readReachability()

            DispatchQueue.main.async {
                self.downloadBPS = rate.down
                self.uploadBPS = rate.up
                self.processTraffic = traffic
                self.connections = conns
                self.isReachable = online
                self.updatedAt = Date()
                self.lastError = nil
                self.isRefreshing = false
            }
        }
    }

    // MARK: - 历史采样

    /// 记一次增量并落盘
    func recordSample() {
        guard !isRecording else { return }
        isRecording = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let delta = self.consumeCounterDelta()
            guard delta != nil else {
                DispatchQueue.main.async { self.isRecording = false }
                return
            }
            let sample = TrafficSample(
                timestamp: Date(),
                downloadBytes: delta!.downloadBytes,
                uploadBytes: delta!.uploadBytes
            )
            NetworkMonitor.appendSample(sample)

            DispatchQueue.main.async {
                self.samples.append(sample)
                if self.samples.count > 2000 { self.samples.removeFirst(self.samples.count - 2000) }
                self.updateCumulative()
                self.isRecording = false
            }
        }
    }

    /// 切换统计周期
    func cumulative(for period: TrafficPeriod) -> CumulativeTraffic {
        let calendar = Calendar.current
        let now = Date()
        let start: Date
        switch period {
        case .day:
            start = calendar.startOfDay(for: now)
        case .week:
            let weekday = calendar.component(.weekday, from: now)
            // Swift 的 weekday 从周日=1 开始，ISO 周一为一周之始
            let daysFromMonday = (weekday + 5) % 7
            let startOfToday = calendar.startOfDay(for: now)
            start = calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfToday) ?? startOfToday
        case .month:
            start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        }

        var total = CumulativeTraffic()
        var day = start
        while day <= now {
            let key = NetworkMonitor.dayKey(day)
            let value = dayTotals[key] ?? NetworkMonitor.loadDayTotal(day)
            total.downloadBytes += value.downloadBytes
            total.uploadBytes += value.uploadBytes
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return total
    }

    private func updateCumulative() {
        cumulative = cumulative(for: .day)
    }

    // MARK: - 速率计算

    /// 读网卡计数器并做差分
    private func currentRate() -> (down: Double, up: Double) {
        let (rx, tx) = NetworkMonitor.readInterfaceBytes()
        let now = DispatchTime.now().uptimeNanoseconds

        baselineLock.lock()
        defer { baselineLock.unlock() }

        // 没有基线时返回 0：避免「开机累计字节 ÷ 开机时长」造成 GB/s 尖峰
        guard let base = rateBaseline, now > base.uptime else {
            rateBaseline = (rx, tx, now)
            return (0, 0)
        }

        // 计数器回退（接口 flap / 换网）时只重新锚定，不产生负速率
        let downBytes = rx >= base.rx ? rx - base.rx : 0
        let upBytes = tx >= base.tx ? tx - base.tx : 0
        let elapsed = Double(now - base.uptime) / 1_000_000_000
        rateBaseline = (rx, tx, now)

        guard elapsed > 0 else { return (0, 0) }
        return (Double(downBytes) / elapsed, Double(upBytes) / elapsed)
    }

    /// 取走一次计数器增量（用于历史采样），并推进基线
    private func consumeCounterDelta() -> CumulativeTraffic? {
        let (rx, tx) = NetworkMonitor.readInterfaceBytes()
        let now = DispatchTime.now().uptimeNanoseconds

        baselineLock.lock()
        defer { baselineLock.unlock() }

        guard let base = sampleBaseline, now > base.uptime else {
            sampleBaseline = (rx, tx, now)
            return nil
        }

        let down = rx >= base.rx ? rx - base.rx : 0
        let up = tx >= base.tx ? tx - base.tx : 0
        sampleBaseline = (rx, tx, now)
        return CumulativeTraffic(downloadBytes: down, uploadBytes: up)
    }

    /// 读默认网卡的累计字节数
    private static func readInterfaceBytes() -> (rx: UInt64, tx: UInt64) {
        guard let interface = NetworkTools.defaultInterface() else { return (0, 0) }
        guard let output = try? Shell.check("/usr/sbin/netstat", ["-b", "-I", interface], timeout: 5) else {
            return (0, 0)
        }
        return parseInterfaceBytes(output) ?? (0, 0)
    }

    /// 解析 `netstat -b -I <iface>` 的 Ibytes / Obytes
    ///
    /// 列位置不能写死：utun 之类的虚拟接口没有 MAC 地址列，后续列会整体左移。
    /// 所以从表头定位 Ibytes / Obytes 的列下标，再取第一条能解析的数据行。
    static func parseInterfaceBytes(_ output: String) -> (rx: UInt64, tx: UInt64)? {
        let lines = output.split(separator: "\n").map(String.init)
        guard let header = lines.first else { return nil }
        let headerCols = header
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.lowercased() }
        guard let inIndex = headerCols.firstIndex(of: "ibytes"),
              let outIndex = headerCols.firstIndex(of: "obytes") else { return nil }

        for line in lines.dropFirst() {
            let cols = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard cols.count > max(inIndex, outIndex) else { continue }
            guard let rx = UInt64(cols[inIndex]), let tx = UInt64(cols[outIndex]) else { continue }
            return (rx, tx)
        }
        return nil
    }

    // MARK: - 按进程流量归因（nettop）

    /// 读按进程的实时流量
    ///
    /// `nettop -P -d -j bytes_in,bytes_out -x -L 2 -s 1`：
    /// -P 只看进程、-d 增量模式、-j 追加指定列（小写）、-x 原始数字、
    /// -L 2 -s 1 采两次间隔 1 秒 → 第二个采样块就是 1 秒增量。
    /// 不加 -d 的话两个块都是「进程启动至今」的累计值，会被误当速率。
    static func readProcessTraffic() -> [ProcessTraffic] {
        let result = Shell.run(
            "/usr/bin/nettop",
            ["-P", "-d", "-j", "bytes_in,bytes_out", "-x", "-L", "2", "-s", "1"],
            timeout: 12
        )
        guard result.isSuccess, !result.stdout.isEmpty else { return [] }

        // 按 "time," 表头切块，取最后一块（那一块是 1 秒增量）
        var blocks: [[String]] = []
        var current: [String] = []
        for line in result.stdout.split(separator: "\n").map(String.init) {
            if line.hasPrefix("time,") {
                if !current.isEmpty { blocks.append(current) }
                current = []
                continue
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }
        guard let sample = blocks.last else { return [] }

        // nettop 的进程名被截断到 15 个字符，用 ps 的真实名字补全
        let nameMap = readProcessNames()

        var traffic: [ProcessTraffic] = []
        for line in sample {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 6 else { continue }

            // 列布局：[0]=time [1]="name.pid" [2]=interface [3]=state [4]=bytes_in [5]=bytes_out
            let namePID = cols[1].trimmingCharacters(in: .whitespaces)
            // 进程名本身可能带点（如 python3.13），所以从右边按最后一个点切
            guard let dot = namePID.lastIndex(of: ".") else { continue }
            let name = String(namePID[namePID.startIndex ..< dot])
            guard let pid = Int32(namePID[namePID.index(after: dot)...]), pid > 0 else { continue }

            let bytesIn = UInt64(cols[4].trimmingCharacters(in: .whitespaces)) ?? 0
            let bytesOut = UInt64(cols[5].trimmingCharacters(in: .whitespaces)) ?? 0
            traffic.append(ProcessTraffic(
                pid: pid,
                name: nameMap[pid] ?? name,
                bytesIn: bytesIn,
                bytesOut: bytesOut
            ))
        }
        return traffic.sorted { $0.totalBytes > $1.totalBytes }
    }

    // MARK: - 连接明细

    /// 读连接明细
    ///
    /// 只用 `lsof -i -n -P`：它一条就带齐了进程名、PID、协议、两端地址和状态。
    /// 原先用 `netstat -an` 拿连接本体再和 lsof 合并，但 `netstat` 的
    /// "Active Internet connections" 段在非 shell 启动时整个不打印
    /// （经 Process 只有 104KB / 946 行，经 shell 是 155KB / 1642 行），
    /// 合并反而更脆。
    ///
    /// 代价：看不到其它用户进程的连接（那需要完全磁盘访问权限）。
    static func readConnections() -> [NetworkConnection] {
        let result = Shell.run("/usr/sbin/lsof", ["-i", "-n", "-P"], timeout: 10)
        guard result.isSuccess else { return [] }

        // lsof 的 COMMAND 列被截断到 9 个字符，真实名字靠 ps 补
        let nameMap = readProcessNames()

        var connections: [NetworkConnection] = []
        for line in result.stdout.split(separator: "\n").map(String.init).dropFirst() {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 9 else { continue }

            // 列布局：0=COMMAND 1=PID 2=USER 3=FD 4=TYPE 5=DEVICE 6=SIZE/OFF 7=NODE 8+=NAME
            let protocolName = cols[7]
            guard protocolName == "TCP" || protocolName == "UDP" else { continue }
            guard let pid = Int32(cols[1]), pid > 0 else { continue }

            let isIPv6 = cols[4] == "IPv6"
            let endpointField = cols[8]

            // 状态在末尾的括号里：TCP ... (ESTABLISHED)
            var state = ""
            if cols.count >= 10, cols[9].hasPrefix("("), cols[9].hasSuffix(")") {
                state = String(cols[9].dropFirst().dropLast())
            }

            let halves = endpointField.split(separator: "->", omittingEmptySubsequences: false)
            guard let local = parseLsofEndpoint(String(halves[0])) else { continue }
            let remote: (address: String, port: UInt16) = halves.count > 1
                ? (parseLsofEndpoint(String(halves[1])) ?? ("*", 0))
                : ("*", 0)

            // UDP 的通配 socket（*:*）没有信息量
            if protocolName == "UDP", local.address == "*", local.port == 0 { continue }

            let name = nameMap[pid] ?? unescapeLsofCommand(cols[0])
            let key = connectionKey(local: local, remote: remote, isIPv6: isIPv6)

            connections.append(NetworkConnection(
                id: key,
                protocolName: protocolName,
                localAddress: local.address,
                localPort: local.port,
                remoteAddress: remote.address,
                remotePort: remote.port,
                state: state,
                pid: pid,
                processName: name,
                isIPv6: isIPv6
            ))
        }
        // lsof 可能把同一个 socket 列出多次（不同 FD），按 key 去重
        var seen = Set<String>()
        return connections.filter { seen.insert($0.id).inserted }
    }

    /// 解析 lsof 的端点
    ///
    /// lsof 用冒号分隔，且 IPv6 带方括号：`[::1]:53`、`1.2.3.4:443`、`*:49152`。
    static func parseLsofEndpoint(_ token: String) -> (address: String, port: UInt16)? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let close = trimmed.firstIndex(of: "]"),
           let colon = trimmed[trimmed.index(after: close)...].firstIndex(of: ":") {
            var address = String(trimmed[trimmed.startIndex ..< close])
            if address.hasPrefix("[") { address.removeFirst() }
            let portText = String(trimmed[trimmed.index(after: colon)...])
            return (address, UInt16(portText) ?? 0)
        }
        if let colon = trimmed.lastIndex(of: ":") {
            let address = String(trimmed[trimmed.startIndex ..< colon])
            let portText = String(trimmed[trimmed.index(after: colon)...])
            let port = portText == "*" ? 0 : (UInt16(portText) ?? 0)
            return (address, port)
        }
        return (trimmed, 0)
    }

    /// 归一化通配地址：`*` 按地址族变成 unspecified，这样 netstat 与 lsof 才能对上
    static func normalizeAddress(_ address: String, isIPv6: Bool) -> String {
        guard address == "*" else { return address }
        return isIPv6 ? "::" : "0.0.0.0"
    }

    static func connectionKey(
        local: (address: String, port: UInt16),
        remote: (address: String, port: UInt16),
        isIPv6: Bool
    ) -> String {
        let l = "\(normalizeAddress(local.address, isIPv6: isIPv6)):\(local.port)"
        let r = "\(normalizeAddress(remote.address, isIPv6: isIPv6)):\(remote.port)"
        return "\(l)->\(r)"
    }

    /// lsof 的 COMMAND 列会把空白和控制字节转义成 `\xNN`
    static func unescapeLsofCommand(_ raw: String) -> String {
        var out = ""
        let bytes = Array(raw.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x5C, index + 3 < bytes.count, bytes[index + 1] == 0x78 {
                let hex = String(format: "%c%c", bytes[index + 2], bytes[index + 3])
                if let value = UInt8(hex, radix: 16) {
                    out.append(Character(UnicodeScalar(value)))
                    index += 4
                    continue
                }
            }
            out.append(Character(UnicodeScalar(bytes[index])))
            index += 1
        }
        return out
    }

    /// 真实进程名（lsof 的 COMMAND 列只有 9 个字符）
    private static func readProcessNames() -> [Int32: String] {
        guard let output = try? Shell.check(
            "/bin/ps", ["-axo", "pid=,comm="], timeout: 5
        ) else { return [:] }

        var names: [Int32: String] = [:]
        for line in output.split(separator: "\n").map(String.init) {
            let cols = line.split(maxSplits: 1,
                                  omittingEmptySubsequences: true,
                                  whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count == 2, let pid = Int32(cols[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let path = cols[1].trimmingCharacters(in: .whitespaces)
            names[pid] = (path as NSString).lastPathComponent
        }
        return names
    }

    /// 读系统路由表对 8.8.8.8 的可达标志位（查询本地状态，不产生网络流量）
    private static func readReachability() -> Bool {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "8.8.8.8", &address.sin_addr) == 1 else { return true }
        var addr = sockaddr()
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                addr = rebound.pointee
            }
        }
        guard let reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, &addr) else { return true }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reachability, &flags) else { return true }
        return flags.contains(.reachable) && !flags.contains(.interventionRequired)
    }

    // MARK: - 历史落盘

    private static var historyDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("LaunchGrid", isDirectory: true)
            .appendingPathComponent("network", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func historyFile(for date: Date) -> URL {
        historyDirectory.appendingPathComponent("traffic-\(dayKey(date)).jsonl")
    }

    /// 追加一条采样
    private static func appendSample(_ sample: TrafficSample) {
        let url = historyFile(for: sample.timestamp)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let line: [String: Any] = [
            "t": formatter.string(from: sample.timestamp),
            "d": sample.downloadBytes,
            "u": sample.uploadBytes,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        var text = String(data: data, encoding: .utf8) ?? ""
        text.append("\n")
        guard let handle = try? FileHandle(forWritingTo: url) else {
            // 文件不存在时先建一个
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8) ?? Data())
            try? handle.close()
            return
        }
        handle.seekToEndOfFile()
        handle.write(text.data(using: .utf8) ?? Data())
        try? handle.close()
    }

    /// 读某天的累计
    private static func loadDayTotal(_ date: Date) -> CumulativeTraffic {
        let url = historyFile(for: date)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return CumulativeTraffic()
        }
        var total = CumulativeTraffic()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let down = object["d"] as? UInt64,
                  let up = object["u"] as? UInt64 else { continue }
            total.downloadBytes += down
            total.uploadBytes += up
        }
        return total
    }

    /// 读今天的采样点（用于曲线）
    func loadTodaySamples() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let url = NetworkMonitor.historyFile(for: Date())
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            var loaded: [NetworkMonitor.TrafficSample] = []
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timeText = object["t"] as? String,
                      let date = formatter.date(from: timeText),
                      let down = object["d"] as? UInt64,
                      let up = object["u"] as? UInt64 else { continue }
                loaded.append(NetworkMonitor.TrafficSample(
                    timestamp: date, downloadBytes: down, uploadBytes: up
                ))
            }
            DispatchQueue.main.async {
                self?.samples = loaded.sorted { $0.timestamp < $1.timestamp }
                self?.updateCumulative()
            }
        }
    }

    /// 清理超过保留期的历史文件
    func pruneHistory() {
        DispatchQueue.global(qos: .utility).async {
            let dir = NetworkMonitor.historyDirectory
            let cutoff = Calendar.current.startOfDay(for: Date())
                .addingTimeInterval(-Double(NetworkMonitor.retentionDays) * 86400)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { return }
            for file in files where file.lastPathComponent.hasPrefix("traffic-") {
                guard let date = NetworkMonitor.parseDayKey(file.lastPathComponent) else { continue }
                if date < cutoff {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    private static func parseDayKey(_ filename: String) -> Date? {
        let raw = filename.replacingOccurrences(of: "traffic-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}
