import Foundation
import Darwin
import CFNetwork
// getifaddrs / ifaddrs 由 Darwin 模块提供（当前 SDK 未提供独立的 ifaddrs 模块）

// MARK: - 模型

/// 单个 DNS 服务器的探测结果
struct DNSProbeResult: Equatable {
    /// 被探测的服务器地址
    let server: String
    /// 平均解析延迟（毫秒，保留亚毫秒精度）
    let averageLatencyMS: Double
    /// 成功率（0...1）
    let successRate: Double
    /// 总查询次数
    let totalQueries: Int
    /// 失败次数
    let failedQueries: Int
}

/// 本机与公网的地址、地理位置信息
struct IPInfo: Equatable {
    /// 公网 IPv4（外部探测得到）
    var publicIPv4: String?
    /// 局域网 IPv4
    var localIPv4: String?
    /// 本地全局 / ULA IPv6
    var localIPv6: String?
    /// 国家 / 地区名称
    var geoCountry: String?
    /// 省份 / 州名称
    var geoRegion: String?
    /// 城市名称
    var geoCity: String?
    /// 是否同时具备 IPv4 与 IPv6
    var dualStack: Bool
}

/// 网络诊断的三档状态
enum NetworkDiagnostic {
    enum Status: String {
        /// 正常
        case pass
        /// 有瑕疵但不影响使用
        case warning
        /// 异常
        case fail
    }
}

/// 一条诊断结论
struct DiagnosticItem: Equatable {
    /// 结论状态
    let status: NetworkDiagnostic.Status
    /// 面向用户的结论文案
    let message: String
    /// 该项检测耗时（毫秒）
    let durationMS: Double
    /// 一行人类可读的补充说明
    let detail: String
}

/// 可执行的修复动作
enum FixAction: String, CaseIterable {
    /// 清空 DNS 缓存
    case flushDNSCache
    /// 切换 DNS 服务器
    case switchDNS
    /// 重新获取 IP 地址
    case releaseRenewIP
    /// 重置网络适配器
    case resetAdapter
    /// 重置网络协议栈
    case resetNetworkStack
    /// 开关 IPv6
    case toggleIPv6
}

/// 一条修复建议
struct Recommendation: Identifiable, Equatable {
    let id = UUID()
    /// 对应的修复动作
    let action: FixAction
    /// 建议名称
    let name: String
    /// 一句说明
    let detail: String
    /// 建议优先级，数字越小越靠前
    let priority: Int
}

/// 一次完整诊断的报告
struct DiagnosticReport: Equatable {
    /// 总体状态
    var overall: NetworkDiagnostic.Status
    /// 网关 + 公网连通性
    var connectivity: DiagnosticItem
    /// IP 配置
    var ipConfiguration: DiagnosticItem
    /// DNS 解析
    var dnsResolution: DiagnosticItem
    /// 网络质量
    var quality: DiagnosticItem
    /// 修复建议
    var recommendations: [Recommendation]
    /// 生成时间
    var timestamp: Date
}

// MARK: - 修复动作文案

extension FixAction {
    /// 动作在界面上的显示名
    var displayName: String {
        switch self {
        case .flushDNSCache: return "清空 DNS 缓存"
        case .switchDNS: return "切换 DNS 服务器"
        case .releaseRenewIP: return "重新获取 IP 地址"
        case .resetAdapter: return "重置网络适配器"
        case .resetNetworkStack: return "重置网络协议栈"
        case .toggleIPv6: return "开关 IPv6"
        }
    }

    /// 执行前的风险提示
    var warning: String {
        switch self {
        case .flushDNSCache: return "会短暂中断域名解析，通常几秒内自动恢复"
        case .switchDNS: return "会短暂中断网络，需要管理员权限"
        case .releaseRenewIP: return "会短暂中断网络连接，需要管理员权限"
        case .resetAdapter: return "会短暂断开网络连接，需要管理员权限"
        case .resetNetworkStack: return "会重启网络解析链路，可能短暂断网"
        case .toggleIPv6: return "会短暂中断网络，需要管理员权限"
        }
    }
}

// MARK: - 错误

/// 网络工具的错误类型，文案面向最终用户
enum NetworkToolsError: LocalizedError {
    /// DNS 服务器不是合法的 IP 地址
    case invalidDNSServer(String)
    /// DNS 探测失败
    case probeFailed(String)
    /// 找不到默认网络接口
    case interfaceNotFound
    /// 找不到接口对应的网络服务
    case serviceNotFound(String)
    /// 接口名不合法
    case illegalInterfaceName(String)
    /// 网络服务名不合法
    case invalidServiceName(String)
    /// 系统命令执行失败
    case commandFailed(String)
    /// 无法获取任何地址信息
    case noAddressInformation

    var errorDescription: String? {
        switch self {
        case .invalidDNSServer(let detail): return detail
        case .probeFailed(let detail): return detail
        case .interfaceNotFound: return "未找到有效的网络接口"
        case .serviceNotFound(let interface): return "未找到 \(interface) 对应的网络服务"
        case .illegalInterfaceName(let name): return "非法接口名：\(name)"
        case .invalidServiceName(let name): return "网络服务名不合法：\(name)"
        case .commandFailed(let detail): return detail
        case .noAddressInformation: return "无法获取网络地址信息"
        }
    }
}

// MARK: - 网络工具

/// 网络工具层：DNS 读写 / DNS 探测 / IP 与 GeoIP / 网络诊断 / 断网急救修复
///
/// 全部系统命令都走 `Shell`，并且只读检查与需要提权的写操作严格分开：
/// 查询类接口不会修改系统状态，写类接口一律走「先直连、失败再提权」的流程。
enum NetworkTools {

    // MARK: - DNS 服务器读写

    /// 读取当前生效的 DNS 服务器列表
    ///
    /// 先解析 `scutil --dns` 的第一个 resolver 块，取不到时回落读 `/etc/resolv.conf`。
    static func currentDNSServers() throws -> [String] {
        let result = Shell.run("/usr/sbin/scutil", ["--dns"], timeout: 10)
        var servers = parseDNSServers(from: result.stdout)
        if servers.isEmpty {
            servers = parseResolvConfServers()
        }
        if servers.isEmpty && result.status == -1 {
            throw NetworkToolsError.commandFailed("无法读取系统 DNS 配置")
        }
        return servers
    }

    /// 写入 DNS 服务器（需要管理员权限，失败会自动走系统提权弹窗）
    ///
    /// - Parameters:
    ///   - primary: 主 DNS 服务器
    ///   - secondary: 备用 DNS 服务器，传 nil 表示只设置一个
    static func setDNSServers(primary: String, secondary: String?) throws {
        guard let interface = defaultInterface(),
              let service = networkServiceName(for: interface) else {
            throw NetworkToolsError.serviceNotFound("默认接口")
        }
        try applyDNSServers(primary: primary, secondary: secondary, service: service)
    }

    /// 解析 `scutil --dns` 输出里的 nameserver
    ///
    /// 遇到第一个 `resolver #` 块就取它里面的 nameserver，取到即停，
    /// 避免把 scoped resolver 的地址混进来。
    private static func parseDNSServers(from text: String) -> [String] {
        var servers: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #") {
                // 已经拿到 nameserver，说明第一个 resolver 块解析完毕
                if !servers.isEmpty { break }
                continue
            }
            guard line.hasPrefix("nameserver[") else { continue }
            guard let address = extractNameserverAddress(from: line) else { continue }
            if !servers.contains(address) { servers.append(address) }
        }
        return servers
    }

    /// 从 `nameserver[0] : fe80::1%en0` 这类行里取出地址
    ///
    /// 不能按 `:` 直接切，否则 IPv6 地址会被截断，这里先定位 `]`，再找它后面的第一个 `:`。
    private static func extractNameserverAddress(from line: String) -> String? {
        guard let closeBracket = line.firstIndex(of: "]") else { return nil }
        let tail = line[line.index(after: closeBracket)...]
        guard let separator = tail.firstIndex(of: ":") else { return nil }
        let address = tail[tail.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return address.isEmpty ? nil : address
    }

    /// 回落读取 `/etc/resolv.conf`
    private static func parseResolvConfServers() -> [String] {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return [] }
        var servers: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("nameserver ") else { continue }
            let address = line.dropFirst("nameserver ".count).trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty, !servers.contains(address) else { continue }
            servers.append(address)
        }
        return servers
    }

    /// 对指定服务写入 DNS 服务器，失败时自动提权重试
    private static func applyDNSServers(primary: String, secondary: String?, service: String) throws {
        try validateServiceName(service)
        // DNS 服务器必须是 IP 字面量，避免非法值进入提权命令串
        guard isIPv4(primary) || isIPv6(primary) else {
            throw NetworkToolsError.invalidDNSServer("DNS 服务器只支持 IP 地址，当前是「\(primary)」")
        }
        if let secondary, !secondary.trimmingCharacters(in: .whitespaces).isEmpty {
            guard isIPv4(secondary) || isIPv6(secondary) else {
                throw NetworkToolsError.invalidDNSServer("DNS 服务器只支持 IP 地址，当前是「\(secondary)」")
            }
        }

        var args = ["-setdnsservers", service, primary]
        if let secondary, !secondary.trimmingCharacters(in: .whitespaces).isEmpty {
            args.append(secondary)
        }
        let command = "networksetup -setdnsservers \(shellQuoted(service)) \(primary)"
            + (args.count > 3 ? " \(args[3])" : "")

        // 先直连一次，既能免掉不必要的授权弹窗，也能拿到原始 stderr 给用户看
        let direct = Shell.run("/usr/sbin/networksetup", args, timeout: 20)
        if direct.isSuccess { return }

        do {
            try Shell.privilegedFallback("/usr/sbin/networksetup", args, asCommand: command)
        } catch {
            let detail = direct.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NetworkToolsError.commandFailed(detail.isEmpty ? error.localizedDescription : detail)
        }
    }

    // MARK: - 网络服务定位

    /// 列出系统里的网络服务
    ///
    /// - Returns: 服务名与是否被禁用（列表里带 `*` 前缀的是禁用项）
    private static func listNetworkServices() -> [(name: String, disabled: Bool)] {
        guard let output = try? Shell.check("/usr/sbin/networksetup", ["-listallnetworkservices"], timeout: 10) else {
            return []
        }
        var services: [(name: String, disabled: Bool)] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("An asterisk") { continue }
            if line.hasPrefix("*") {
                let name = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { services.append((name, true)) }
            } else {
                services.append((line, false))
            }
        }
        return services
    }

    /// 查接口对应的硬件端口名（如 en1 → Wi-Fi）
    private static func hardwarePortName(for interface: String) -> String? {
        guard let output = try? Shell.check("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 10) else {
            return nil
        }
        var currentPort: String?
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                currentPort = String(line.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:") {
                let device = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                if device == interface { return currentPort }
            }
        }
        return nil
    }

    /// 查接口对应的 MAC 地址
    private static func hardwarePortMAC(for interface: String) -> String? {
        guard let output = try? Shell.check("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 10) else {
            return nil
        }
        var currentMAC: String?
        var currentDevice: String?
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Device:") {
                currentDevice = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Ethernet Address:") {
                currentMAC = String(line.dropFirst("Ethernet Address:".count)).trimmingCharacters(in: .whitespaces)
            }
            if currentDevice == interface, let mac = currentMAC { return mac }
        }
        return nil
    }

    /// 查接口对应的网络服务名（如 en1 → Wi-Fi），找不到返回 nil
    ///
    /// 依次尝试三种依据：
    /// 1. `-getinfo` 里的 `Device: <接口>` 行（最权威，但新版 macOS 已经不再输出）；
    /// 2. `-getinfo` 里的 MAC 地址与硬件端口一致（新版 macOS 的可靠依据）；
    /// 3. 硬件端口名与服务名同名。
    static func networkServiceName(for interface: String) -> String? {
        let services = listNetworkServices()
        guard !services.isEmpty else { return nil }

        var infoCache: [String: String] = [:]
        func serviceInfo(_ name: String) -> String? {
            if let cached = infoCache[name] { return cached }
            let info = try? Shell.check("/usr/sbin/networksetup", ["-getinfo", name], timeout: 10)
            infoCache[name] = info
            return info
        }

        // 1. Device 行
        for service in services where !service.disabled {
            guard let info = serviceInfo(service.name) else { continue }
            if containsDeviceLine(info, interface: interface) { return service.name }
        }

        // 2. MAC 地址
        if let mac = hardwarePortMAC(for: interface) {
            for service in services where !service.disabled {
                guard let info = serviceInfo(service.name) else { continue }
                if info.range(of: mac, options: .caseInsensitive) != nil { return service.name }
            }
        }

        // 3. 硬件端口名与服务名同名
        if let port = hardwarePortName(for: interface) {
            if let match = services.first(where: {
                $0.name.compare(port, options: .caseInsensitive) == .orderedSame
            }) {
                return match.name
            }
        }
        return nil
    }

    /// `-getinfo` 输出里是否存在 `Device: <接口>` 行
    private static func containsDeviceLine(_ info: String, interface: String) -> Bool {
        for rawLine in info.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            guard line.hasPrefix("device:") else { continue }
            let value = String(line.dropFirst("device:".count)).trimmingCharacters(in: .whitespaces)
            if value == interface.lowercased() { return true }
        }
        return false
    }

    // MARK: - 默认接口与网关

    /// 默认网络接口（如 en1），失败返回 nil
    static func defaultInterface() -> String? {
        guard let output = try? Shell.check("/sbin/route", ["-n", "get", "default"], timeout: 10) else {
            return nil
        }
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("interface:") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            let name = String(fields[1]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// 默认网关 IP，失败返回 nil
    static func defaultGateway() -> String? {
        guard let output = try? Shell.check("/usr/sbin/netstat", ["-nr"], timeout: 10) else { return nil }
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("default") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            var candidate = String(fields[1]).trimmingCharacters(in: .whitespaces)
            // 去掉 IPv6 的 %zone 后缀
            if let percent = candidate.firstIndex(of: "%") {
                candidate = String(candidate[..<percent])
            }
            if isIPv4(candidate) || isIPv6(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - DNS 探测

    /// 探测指定 DNS 服务器的解析延迟
    ///
    /// 用 UDP 直连 53 端口手工拼 A 记录查询包，收响应后校验事务 ID、QR 位、rcode 与答案条数。
    /// 共发 5 次查询，域名在 google.com / cloudflare.com / example.com 之间轮询，单次超时 3 秒。
    ///
    /// - Note: 这是真实的对外 DNS 查询，被查询的域名会暴露给该 DNS 服务器。
    /// - Parameter server: 只能是 IP 字面量（如 8.8.8.8、1.1.1.1、[::1]），不支持主机名。
    static func probeDNSServer(_ server: String) throws -> DNSProbeResult {
        let normalized = try normalizeDNSServer(server)
        let domains = ["google.com", "cloudflare.com", "example.com"]
        let total = 5

        var latencies: [Double] = []
        var failures = 0
        for index in 0..<total {
            if index > 0 { Thread.sleep(forTimeInterval: 0.1) }
            let domain = domains[index % domains.count]
            do {
                latencies.append(try sendDNSQuery(server: normalized, domain: domain, timeout: 3))
            } catch {
                failures += 1
            }
        }

        guard !latencies.isEmpty else {
            throw NetworkToolsError.probeFailed("无法连接 DNS 服务器 \(server)")
        }
        let average = latencies.reduce(0, +) / Double(latencies.count)
        return DNSProbeResult(
            server: server,
            averageLatencyMS: average,
            successRate: Double(latencies.count) / Double(total),
            totalQueries: total,
            failedQueries: failures
        )
    }

    /// 校验并归一化 DNS 服务器地址
    private static func normalizeDNSServer(_ server: String) throws -> String {
        var value = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        // IPv6 的 %zone 后缀不能用于建 socket
        if let percent = value.firstIndex(of: "%") {
            value = String(value[..<percent])
        }
        guard isIPv4(value) || isIPv6(value) else {
            throw NetworkToolsError.invalidDNSServer("DNS 服务器只支持 IP 地址，当前是「\(server)」")
        }
        return value
    }

    /// 向 DNS 服务器发送一次 A 记录查询，返回往返延迟（毫秒）
    private static func sendDNSQuery(server: String, domain: String, timeout: TimeInterval) throws -> Double {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        // 只接受数字地址，绝不触发系统解析器
        hints.ai_flags = AI_NUMERICHOST

        var infoPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(server, "53", &hints, &infoPointer)
        guard status == 0, let first = infoPointer else {
            throw NetworkToolsError.invalidDNSServer("无法使用 DNS 服务器地址 \(server)")
        }
        defer { freeaddrinfo(infoPointer) }

        var entry: UnsafeMutablePointer<addrinfo>? = first
        var lastError: Error = NetworkToolsError.probeFailed("无法连接 DNS 服务器 \(server)")
        while let current = entry {
            do {
                return try performDNSQuery(entry: current, domain: domain, timeout: timeout)
            } catch {
                lastError = error
            }
            entry = current.pointee.ai_next
        }
        throw lastError
    }

    /// 在已解析好的地址上完成一次 DNS 查询
    private static func performDNSQuery(entry: UnsafeMutablePointer<addrinfo>, domain: String, timeout: TimeInterval) throws -> Double {
        let descriptor = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
        guard descriptor >= 0 else {
            throw NetworkToolsError.probeFailed("无法创建 UDP 套接字")
        }
        defer { close(descriptor) }

        var timeoutValue = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))

        // UDP connect 只是固定收发对端，不会真的建立连接
        guard let destination = entry.pointee.ai_addr else {
            throw NetworkToolsError.probeFailed("DNS 服务器地址无效")
        }
        guard connect(descriptor, destination, entry.pointee.ai_addrlen) == 0 else {
            throw NetworkToolsError.probeFailed("无法连接 DNS 服务器")
        }

        let transactionID = UInt16.random(in: 0...UInt16.max)
        let query = buildDNSQuery(domain: domain, transactionID: transactionID)

        let start = DispatchTime.now().uptimeNanoseconds
        let sent = query.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return send(descriptor, base, buffer.count, 0)
        }
        guard sent > 0 else {
            throw NetworkToolsError.probeFailed("DNS 查询发送失败")
        }

        var buffer = [UInt8](repeating: 0, count: 2048)
        let received = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return recv(descriptor, base, raw.count, 0)
        }
        guard received > 0 else {
            throw NetworkToolsError.probeFailed("DNS 查询超时或没有响应")
        }

        // 亚毫秒精度：纳秒差直接换算成毫秒的小数
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        guard validateDNSResponse(Data(buffer.prefix(received)), transactionID: transactionID) else {
            throw NetworkToolsError.probeFailed("DNS 响应无效")
        }
        return elapsedMS
    }

    /// 手工拼一个 A 记录查询包
    private static func buildDNSQuery(domain: String, transactionID: UInt16) -> Data {
        var data = Data()
        // 头部：事务 ID、RD 标志、QDCOUNT = 1
        data.append(UInt8((transactionID >> 8) & 0xFF))
        data.append(UInt8(transactionID & 0xFF))
        data.append(0x01)
        data.append(0x00)
        data.append(0x00)
        data.append(0x01)
        data.append(0x00)
        data.append(0x00)
        data.append(0x00)
        data.append(0x00)
        data.append(0x00)
        data.append(0x00)

        // 问题段：域名标签 + QTYPE=A(1) + QCLASS=IN(1)
        for label in domain.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard bytes.count <= 63 else { continue }
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0x00)
        data.append(0x00)
        data.append(0x01)
        data.append(0x00)
        data.append(0x01)
        return data
    }

    /// 校验 DNS 响应：长度、事务 ID、QR 位、rcode、答案条数
    private static func validateDNSResponse(_ data: Data, transactionID: UInt16) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data)
        let responseID = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        guard responseID == transactionID else { return false }

        let flags = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        guard flags & 0x8000 != 0 else { return false }   // QR 必须置位
        guard flags & 0x000F == 0 else { return false }   // rcode 必须为 0

        let answerCount = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
        return answerCount > 0
    }

    // MARK: - IP 信息

    /// 取本机 IP 与公网 IP 信息
    ///
    /// - Parameter includeGeoIP: 为 true 时额外查询 GeoIP 地理信息（会发起外部请求）
    static func fetchIPInfo(includeGeoIP: Bool) throws -> IPInfo {
        let local = try localAddresses()
        let publicIPv4 = fetchPublicIPv4()

        guard local.v4 != nil || local.v6 != nil || publicIPv4 != nil else {
            throw NetworkToolsError.noAddressInformation
        }

        var country: String?
        var region: String?
        var city: String?
        if includeGeoIP {
            let target = publicIPv4 ?? local.v4 ?? local.v6
            if let target {
                let geo = geoInfo(for: target)
                country = geo.country
                region = geo.region
                city = geo.city
            }
        }

        return IPInfo(
            publicIPv4: publicIPv4,
            localIPv4: local.v4,
            localIPv6: local.v6,
            geoCountry: country,
            geoRegion: region,
            geoCity: city,
            dualStack: local.v4 != nil && local.v6 != nil
        )
    }

    /// 枚举本机 IPv4 / IPv6
    ///
    /// 只保留 up、非 loopback 的接口地址，并剔除 unspecified / loopback / link-local。
    /// 枚举失败时回落到 UDP connect 取本机地址（不会真的发包）；
    /// 两条路都拿不到地址时抛错。
    private static func localAddresses() throws -> (v4: String?, v6: String?) {
        var v4: String?
        var v6: String?
        let preferred = defaultInterface()

        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let head = pointer else {
            let fallbackV4 = fallbackLocalIPv4()
            let fallbackV6 = fallbackLocalIPv6()
            guard fallbackV4 != nil || fallbackV6 != nil else {
                throw NetworkToolsError.commandFailed("无法读取本机网络接口")
            }
            return (fallbackV4, fallbackV6)
        }
        defer { freeifaddrs(pointer) }

        var candidates: [(name: String, v4: String?, v6: String?)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            let name = String(cString: current.pointee.ifa_name)
            if flags & IFF_UP != 0 && flags & IFF_LOOPBACK == 0,
               let address = current.pointee.ifa_addr {
                switch address.pointee.sa_family {
                case sa_family_t(AF_INET):
                    if let text = hostAddress(address), isUsableIPv4(text) {
                        candidates.append((name: name, v4: text, v6: nil))
                    }
                case sa_family_t(AF_INET6):
                    if let text = hostAddress(address), isUsableIPv6(text) {
                        candidates.append((name: name, v4: nil, v6: text))
                    }
                default:
                    break
                }
            }
            cursor = current.pointee.ifa_next
        }

        // 优先取默认接口上的地址，其次取第一个可用地址
        if let preferred {
            v4 = candidates.first(where: { $0.name == preferred })?.v4
            v6 = candidates.first(where: { $0.name == preferred })?.v6
        }
        if v4 == nil { v4 = candidates.compactMap(\.v4).first }
        if v6 == nil { v6 = candidates.compactMap(\.v6).first }

        if v4 == nil { v4 = fallbackLocalIPv4() }
        if v6 == nil { v6 = fallbackLocalIPv6() }
        return (v4, v6)
    }

    /// `sockaddr` 转数字形式字符串
    private static func hostAddress(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        let family = address.pointee.sa_family
        let length = socklen_t(family == sa_family_t(AF_INET6)
            ? MemoryLayout<sockaddr_in6>.size
            : MemoryLayout<sockaddr_in>.size)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard status == 0 else { return nil }
        return String(cString: host)
    }

    /// 过滤掉 unspecified / loopback / link-local 的 IPv4
    private static func isUsableIPv4(_ address: String) -> Bool {
        if address == "0.0.0.0" { return false }
        if address.hasPrefix("127.") { return false }
        if address.hasPrefix("169.254.") { return false }
        return true
    }

    /// 过滤掉 unspecified / loopback / link-local 的 IPv6
    private static func isUsableIPv6(_ address: String) -> Bool {
        let value = address.lowercased()
        if value == "::" || value == "::1" { return false }
        if value.hasPrefix("fe80:") { return false }
        return true
    }

    /// UDP connect 回落取本机 IPv4（只建立连接状态，不会真的发包）
    private static func fallbackLocalIPv4() -> String? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, "8.8.8.8", &target.sin_addr) == 1 else { return nil }

        let connected = withUnsafePointer(to: &target) { pointer -> Int32 in
            return pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer -> Int32 in
            return pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        guard named == 0 else { return nil }
        return String(cString: inet_ntoa(local.sin_addr))
    }

    /// UDP connect 回落取本机 IPv6
    private static func fallbackLocalIPv6() -> String? {
        let descriptor = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var target = sockaddr_in6()
        target.sin6_family = sa_family_t(AF_INET6)
        target.sin6_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET6, "2001:4860:4860::8888", &target.sin6_addr) == 1 else { return nil }

        let connected = withUnsafePointer(to: &target) { pointer -> Int32 in
            return pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer -> Int32 in
            return pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        guard named == 0 else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &local) { pointer -> Int32 in
            return pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getnameinfo(sockaddrPointer, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard status == 0 else { return nil }
        let text = String(cString: host)
        return isUsableIPv6(text) ? text : nil
    }

    /// 取公网 IPv4，依次尝试三个服务
    private static func fetchPublicIPv4() -> String? {
        let endpoints = [
            "https://api4.ipify.org",
            "https://ipv4.icanhazip.com",
            "https://ifconfig.me/ip"
        ]
        for endpoint in endpoints {
            guard let text = try? fetchText(endpoint, timeout: 5) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isIPv4(trimmed) else { continue }
            return trimmed
        }
        return nil
    }

    // MARK: - GeoIP

    /// 查询 IP 的地理信息
    ///
    /// 私有地址直接返回「本地网络」，不发请求；公网地址依次尝试三个服务。
    private static func geoInfo(for ip: String) -> (country: String?, region: String?, city: String?) {
        if isPrivateIP(ip) {
            return ("本地网络", nil, nil)
        }

        // 1. ipapi.co
        if let json = try? fetchJSON("https://ipapi.co/json/\(ip)", timeout: 10) {
            let hasError: Bool = {
                if let flag = json["error"] as? Bool { return flag }
                if let text = json["error"] as? String { return !text.isEmpty }
                return false
            }()
            if !hasError {
                let country = (json["country_name"] as? String) ?? (json["country"] as? String)
                if let country, !country.isEmpty {
                    let region = (json["region"] as? String) ?? (json["region_name"] as? String)
                    let city = json["city"] as? String
                    return (country, region, city)
                }
            }
        }

        // 2. ipwhois.app
        if let json = try? fetchJSON("https://ipwhois.app/json/\(ip)", timeout: 10) {
            let success = json["success"] as? Bool ?? true
            if success, let country = json["country"] as? String, !country.isEmpty {
                let region = json["region"] as? String
                let city = json["city"] as? String
                return (country, region, city)
            }
        }

        // 3. ip-api.com
        for endpoint in ["https://ip-api.com/json/\(ip)", "http://ip-api.com/json/\(ip)"] {
            guard let json = try? fetchJSON(endpoint, timeout: 10) else { continue }
            guard (json["status"] as? String) == "success" else { continue }
            guard let country = json["country"] as? String, !country.isEmpty else { continue }
            let region = json["regionName"] as? String
            let city = json["city"] as? String
            return (country, region, city)
        }

        return ("未知", nil, nil)
    }

    /// 判断是否属于私有 / 保留地址段
    private static func isPrivateIP(_ address: String) -> Bool {
        if address == "127.0.0.1" || address == "::1" { return true }
        if address.hasPrefix("10.") || address.hasPrefix("192.168.") || address.hasPrefix("169.254.") {
            return true
        }
        if address.hasPrefix("172.") {
            let parts = address.split(separator: ".")
            if parts.count == 4, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        if address.hasPrefix("fe80:") || address.hasPrefix("fc") || address.hasPrefix("fd") { return true }
        return false
    }

    // MARK: - 网络诊断

    /// 跑一次完整诊断（4 项）
    ///
    /// 检测在后台线程串行执行，结果在主线程回调。
    static func runDiagnostics(completion: @escaping (Result<DiagnosticReport, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<DiagnosticReport, Error> = Result {
                try NetworkTools.makeReport()
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// 组装一份诊断报告
    private static func makeReport() throws -> DiagnosticReport {
        let connectivity = diagnoseConnectivity()
        let ipConfiguration = diagnoseIPConfiguration()
        let dnsResolution = diagnoseDNSResolution()
        let quality = diagnoseQuality()

        let items = [connectivity, ipConfiguration, dnsResolution, quality]
        let overall: NetworkDiagnostic.Status
        if items.allSatisfy({ $0.status == .pass }) {
            overall = .pass
        } else if items.contains(where: { $0.status == .fail }) {
            overall = .fail
        } else {
            overall = .warning
        }

        return DiagnosticReport(
            overall: overall,
            connectivity: connectivity,
            ipConfiguration: ipConfiguration,
            dnsResolution: dnsResolution,
            quality: quality,
            recommendations: makeRecommendations(
                connectivity: connectivity,
                ipConfiguration: ipConfiguration,
                dnsResolution: dnsResolution,
                quality: quality
            ),
            timestamp: Date()
        )
    }

    /// 检测网关与公网连通性
    private static func diagnoseConnectivity() -> DiagnosticItem {
        let start = DispatchTime.now().uptimeNanoseconds

        guard let gateway = defaultGateway() else {
            return DiagnosticItem(
                status: .fail,
                message: "无法连接到网关（未找到默认网关）",
                durationMS: elapsedMS(since: start),
                detail: "请检查网线或 Wi-Fi 是否已连接"
            )
        }

        let gatewayPing = ping(host: gateway, count: 1, waitMS: 3000, timeout: 4)
        guard gatewayPing.received > 0 else {
            return DiagnosticItem(
                status: .fail,
                message: "无法连接到网关 \(gateway)",
                durationMS: elapsedMS(since: start),
                detail: gatewayPing.summary.isEmpty ? "网关没有响应" : gatewayPing.summary
            )
        }

        let publicPing = ping(host: "8.8.8.8", count: 1, waitMS: 3000, timeout: 5)
        if publicPing.received > 0 {
            return DiagnosticItem(
                status: .pass,
                message: "网络连接正常",
                durationMS: elapsedMS(since: start),
                detail: "网关 \(gateway) 可达，公网延迟 \(format(publicPing.averageLatencyMS))ms"
            )
        }
        return DiagnosticItem(
            status: .warning,
            message: "网关可达，但无法访问公网",
            durationMS: elapsedMS(since: start),
            detail: "网关 \(gateway) 可达，但公网地址没有响应"
        )
    }

    /// 检测本机 IP 配置，只读不外发
    private static func diagnoseIPConfiguration() -> DiagnosticItem {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let local = try localAddresses()
            guard local.v4 != nil || local.v6 != nil else {
                return DiagnosticItem(
                    status: .fail,
                    message: "未检测到有效的本地IP地址",
                    durationMS: elapsedMS(since: start),
                    detail: "请检查网络接口是否已启用并连上网络"
                )
            }
            let parts = [
                local.v4.map { "IPv4 \($0)" },
                local.v6.map { "IPv6 \($0)" }
            ].compactMap { $0 }
            return DiagnosticItem(
                status: .pass,
                message: "IP地址配置正常",
                durationMS: elapsedMS(since: start),
                detail: parts.joined(separator: " · ")
            )
        } catch {
            return DiagnosticItem(
                status: .warning,
                message: "IP地址配置检测异常",
                durationMS: elapsedMS(since: start),
                detail: error.localizedDescription
            )
        }
    }

    /// 检测 DNS 解析
    private static func diagnoseDNSResolution() -> DiagnosticItem {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let probe = try probeDNSServer("8.8.8.8")
            let successRate = probe.successRate * 100
            if probe.averageLatencyMS > 0 && probe.successRate > 0.5 {
                return DiagnosticItem(
                    status: .pass,
                    message: "DNS解析正常（\(format(probe.averageLatencyMS))ms）",
                    durationMS: elapsedMS(since: start),
                    detail: "服务器 \(probe.server)，成功率 \(format(successRate))%"
                )
            }
            return DiagnosticItem(
                status: .fail,
                message: "DNS解析失败",
                durationMS: elapsedMS(since: start),
                detail: "服务器 \(probe.server)，成功率仅 \(format(successRate))%"
            )
        } catch {
            return DiagnosticItem(
                status: .fail,
                message: "DNS解析失败",
                durationMS: elapsedMS(since: start),
                detail: error.localizedDescription
            )
        }
    }

    /// 检测网络质量
    private static func diagnoseQuality() -> DiagnosticItem {
        let start = DispatchTime.now().uptimeNanoseconds
        let outcome = ping(host: "8.8.8.8", count: 4, waitMS: 2000, timeout: 12)

        let average = outcome.averageLatencyMS
        let loss = outcome.lossPercent
        let status: NetworkDiagnostic.Status
        if average < 50 && loss < 1 {
            status = .pass
        } else if average < 200 && loss < 5 {
            status = .warning
        } else {
            status = .fail
        }

        return DiagnosticItem(
            status: status,
            message: "网络质量: \(format(average))ms, 丢包\(format(loss))%",
            durationMS: elapsedMS(since: start),
            detail: "已发送 \(outcome.sent) 个数据包，接收 \(outcome.received) 个"
        )
    }

    /// 按规则生成修复建议（只给建议，不执行任何修复）
    private static func makeRecommendations(
        connectivity: DiagnosticItem,
        ipConfiguration: DiagnosticItem,
        dnsResolution: DiagnosticItem,
        quality: DiagnosticItem
    ) -> [Recommendation] {
        var recommendations: [Recommendation] = []

        if dnsResolution.status != .pass {
            recommendations.append(Recommendation(
                action: .switchDNS,
                name: FixAction.switchDNS.displayName,
                detail: "当前 DNS 解析异常，切换到 8.8.8.8 / 1.1.1.1 可提升解析成功率",
                priority: 1
            ))
            recommendations.append(Recommendation(
                action: .flushDNSCache,
                name: FixAction.flushDNSCache.displayName,
                detail: "清理系统 DNS 缓存，排除过期记录导致的解析失败",
                priority: 2
            ))
        }

        if ipConfiguration.status != .pass {
            recommendations.append(Recommendation(
                action: .releaseRenewIP,
                name: FixAction.releaseRenewIP.displayName,
                detail: "向 DHCP 服务器重新申请地址，可解决 IP 冲突与租约过期",
                priority: 1
            ))
            recommendations.append(Recommendation(
                action: .resetAdapter,
                name: FixAction.resetAdapter.displayName,
                detail: "关闭再启用网卡，可清除网卡驱动层的异常状态",
                priority: 2
            ))
        }

        if quality.status != .pass || connectivity.status != .pass {
            recommendations.append(Recommendation(
                action: .resetNetworkStack,
                name: FixAction.resetNetworkStack.displayName,
                detail: "重启系统解析与网络链路，可修复连接卡死、时通时断",
                priority: 1
            ))
        }

        return Array(recommendations.sorted { $0.priority < $1.priority }.prefix(3))
    }

    // MARK: - ping 解析

    /// 一次 ping 的结果
    private struct PingOutcome {
        var sent: Int = 0
        var received: Int = 0
        var averageLatencyMS: Double = 0
        var lossPercent: Double = 100
        var summary: String = ""
    }

    /// 执行一次 ping 并解析输出
    private static func ping(host: String, count: Int, waitMS: Int, timeout: TimeInterval) -> PingOutcome {
        let result = Shell.run("/sbin/ping", ["-c", String(count), "-W", String(waitMS), host], timeout: timeout)
        var outcome = parsePingOutput(result.stdout)
        if outcome.sent == 0 { outcome.sent = count }
        outcome.received = min(outcome.received, outcome.sent)
        outcome.lossPercent = outcome.sent > 0
            ? Double(outcome.sent - outcome.received) / Double(outcome.sent) * 100
            : 100
        return outcome
    }

    /// 解析 macOS ping 输出
    private static func parsePingOutput(_ output: String) -> PingOutcome {
        var outcome = PingOutcome()
        var latencies: [Double] = []
        var sent: Int?

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // 重复回复不计入统计
            if line.contains("DUP!") { continue }

            if let value = integerBefore(line, keywords: ["packets transmitted", "个数据包被传输", "个数据包已传输"]) {
                sent = value
            }

            guard line.contains("bytes from") || line.contains("字节来自") else { continue }
            outcome.received += 1
            // 小于 1 毫秒的回复无法取到精确值，按 0 计
            latencies.append(parseLatency(in: line) ?? 0)
        }

        outcome.sent = sent ?? outcome.received
        if !latencies.isEmpty {
            outcome.averageLatencyMS = latencies.reduce(0, +) / Double(latencies.count)
        }
        return outcome
    }

    /// 从行尾的关键字前取整数
    private static func integerBefore(_ line: String, keywords: [String]) -> Int? {
        for keyword in keywords {
            guard let range = line.range(of: keyword, options: .caseInsensitive) else { continue }
            let head = line[line.startIndex..<range.lowerBound]
            let digits = head.reversed().prefix { $0.isNumber || $0 == " " }
            let text = String(digits.reversed()).trimmingCharacters(in: .whitespaces)
            if let value = Int(text) { return value }
        }
        return nil
    }

    /// 解析 ping 回复里的延迟
    private static func parseLatency(in line: String) -> Double? {
        let markers = ["time=", "时间=", "time<", "时间<"]
        for marker in markers {
            guard let range = line.range(of: marker, options: .caseInsensitive) else { continue }
            let tail = line[range.upperBound...]
            // macOS 对 1 毫秒以内的回复输出 time<1ms，取不到精确值
            if marker.hasSuffix("<") { return 0 }
            var number = ""
            for character in tail {
                if character.isNumber || character == "." || character == "-" {
                    number.append(character)
                } else {
                    break
                }
            }
            if let value = Double(number) { return max(0, value) }
        }
        return nil
    }

    // MARK: - 修复动作

    /// 执行一个修复动作
    ///
    /// - Parameters:
    ///   - action: 要执行的动作
    ///   - dnsServers: 切换 DNS 时使用的服务器地址，为 nil 时用 8.8.8.8 / 1.1.1.1
    static func applyFix(_ action: FixAction, dnsServers: (primary: String, secondary: String?)?) throws {
        switch action {
        case .flushDNSCache:
            try flushDNSCache()
        case .switchDNS:
            let primary = dnsServers?.primary ?? "8.8.8.8"
            let secondary = dnsServers?.secondary ?? "1.1.1.1"
            try switchDNS(primary: primary, secondary: secondary)
        case .releaseRenewIP:
            try releaseRenewIP()
        case .resetAdapter:
            try resetAdapter()
        case .resetNetworkStack:
            try resetNetworkStack()
        case .toggleIPv6:
            try toggleIPv6()
        }
    }

    /// 清空 DNS 缓存
    private static func flushDNSCache() throws {
        let flush = Shell.run("/usr/bin/dscacheutil", ["-flushcache"], timeout: 15)
        guard flush.isSuccess else {
            let detail = flush.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NetworkToolsError.commandFailed(detail.isEmpty ? "清空 DNS 缓存失败" : detail)
        }
        try restartMDNSResponder()
    }

    /// 切换 DNS 服务器
    private static func switchDNS(primary: String, secondary: String?) throws {
        guard let interface = defaultInterface() else {
            throw NetworkToolsError.interfaceNotFound
        }
        guard let service = networkServiceName(for: interface) else {
            throw NetworkToolsError.serviceNotFound(interface)
        }
        try applyDNSServers(primary: primary, secondary: secondary, service: service)
    }

    /// 重新获取 IP 地址
    private static func releaseRenewIP() throws {
        guard let interface = defaultInterface() else {
            throw NetworkToolsError.interfaceNotFound
        }
        guard isValidInterfaceName(interface) else {
            throw NetworkToolsError.illegalInterfaceName(interface)
        }
        let result = Shell.run("/usr/sbin/ipconfig", ["set", interface, "DHCP"], timeout: 30)
        if result.isSuccess { return }
        try Shell.privileged("ipconfig set \(interface) DHCP")
    }

    /// 重置网络适配器
    private static func resetAdapter() throws {
        guard let interface = defaultInterface() else {
            throw NetworkToolsError.interfaceNotFound
        }
        guard isValidInterfaceName(interface) else {
            throw NetworkToolsError.illegalInterfaceName(interface)
        }
        // 关闭与开启必须成对执行，直接走提权弹窗，避免中途失败把网卡留在 down 状态
        try Shell.privileged("ifconfig \(interface) down && sleep 1 && ifconfig \(interface) up")
    }

    /// 重置网络协议栈
    private static func resetNetworkStack() throws {
        try restartMDNSResponder()
    }

    /// 重启 mDNSResponder，失败时提权重试
    private static func restartMDNSResponder() throws {
        let result = Shell.run("/usr/bin/killall", ["-HUP", "mDNSResponder"], timeout: 15)
        if result.isSuccess { return }
        try Shell.privileged("killall -HUP mDNSResponder")
    }

    /// 开关 IPv6
    private static func toggleIPv6() throws {
        guard let interface = defaultInterface() else {
            throw NetworkToolsError.interfaceNotFound
        }
        guard let service = networkServiceName(for: interface) else {
            throw NetworkToolsError.serviceNotFound(interface)
        }
        try validateServiceName(service)

        let info = try Shell.check("/usr/sbin/networksetup", ["-getinfo", service], timeout: 10)
        let isOff = info.split(separator: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces).lowercased() == "ipv6: off"
        }
        let flag = isOff ? "-setv6automatic" : "-setv6off"
        let args = [flag, service]
        let command = "networksetup \(flag) \(shellQuoted(service))"

        let direct = Shell.run("/usr/sbin/networksetup", args, timeout: 20)
        if direct.isSuccess { return }
        do {
            try Shell.privilegedFallback("/usr/sbin/networksetup", args, asCommand: command)
        } catch {
            let detail = direct.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NetworkToolsError.commandFailed(detail.isEmpty ? error.localizedDescription : detail)
        }
    }

    /// IPv6 当前是否开启
    static func isIPv6Enabled() throws -> Bool {
        guard let interface = defaultInterface() else {
            throw NetworkToolsError.interfaceNotFound
        }
        guard let service = networkServiceName(for: interface) else {
            throw NetworkToolsError.serviceNotFound(interface)
        }
        let info = try Shell.check("/usr/sbin/networksetup", ["-getinfo", service], timeout: 10)
        for rawLine in info.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            if line == "ipv6: off" { return false }
        }
        return true
    }

    // MARK: - 工具函数

    /// 接口名只允许字母、数字和下划线
    private static func isValidInterfaceName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        for scalar in name.unicodeScalars {
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_":
                continue
            default:
                return false
            }
        }
        return true
    }

    /// 网络服务名不允许包含引号，否则无法安全地交给提权命令
    private static func validateServiceName(_ name: String) throws {
        guard !name.isEmpty else {
            throw NetworkToolsError.invalidServiceName(name)
        }
        if name.contains("'") || name.contains("\"") || name.contains("\\") || name.contains("\n") {
            throw NetworkToolsError.invalidServiceName(name)
        }
    }

    /// 给参数套上单引号，供 `Shell.privileged` 的命令串使用
    private static func shellQuoted(_ value: String) -> String {
        return "'\(value)'"
    }

    /// 从某个时间点算起经过的毫秒数
    private static func elapsedMS(since start: UInt64) -> Double {
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// 保留一位小数的数字文案
    private static func format(_ value: Double) -> String {
        return String(format: "%.1f", value)
    }

    /// 判断字符串是否为 IPv4
    private static func isIPv4(_ address: String) -> Bool {
        var parsed = in_addr()
        return inet_pton(AF_INET, address, &parsed) == 1
    }

    /// 判断字符串是否为 IPv6
    private static func isIPv6(_ address: String) -> Bool {
        var parsed = in6_addr()
        return inet_pton(AF_INET6, address, &parsed) == 1
    }

    // MARK: - HTTP 请求

    /// 发起一次 HTTP 请求并返回文本，显式绕过系统代理
    private static func fetchText(_ urlString: String, timeout: TimeInterval) throws -> String {
        guard let url = URL(string: urlString) else {
            throw NetworkToolsError.commandFailed("无效的请求地址")
        }
        let session = makeSession(timeout: timeout)
        defer { session.finishTasksAndInvalidate() }

        let box = Box<String?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            if error != nil { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            guard let data, let text = String(data: data, encoding: .utf8) else { return }
            box.set(text)
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            throw NetworkToolsError.commandFailed("请求超时")
        }
        guard let text = box.value else {
            throw NetworkToolsError.commandFailed("请求失败")
        }
        return text
    }

    /// 发起一次 HTTP 请求并返回 JSON
    private static func fetchJSON(_ urlString: String, timeout: TimeInterval) throws -> [String: Any] {
        let text = try fetchText(urlString, timeout: timeout)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw NetworkToolsError.commandFailed("返回内容不是有效的 JSON")
        }
        return dictionary
    }

    /// 构造一个不走系统代理的会话
    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 显式禁用系统代理，直连目标服务器
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0
        ]
        return URLSession(configuration: configuration)
    }
}

/// 线程安全的可选值容器，用来跨闭包传递请求结果
private final class Box<T> {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) {
        self.stored = value
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ newValue: T) {
        lock.lock()
        stored = newValue
        lock.unlock()
    }
}
