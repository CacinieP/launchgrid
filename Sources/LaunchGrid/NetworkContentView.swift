import SwiftUI

/// 网络面板：实时速率、按进程流量归因、连接明细、DNS 与断网诊断
struct NetworkContentView: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var processMonitor: ProcessMonitor
    @Binding var query: String

    @State private var tab: NetworkTab = .traffic
    @State private var notice: String?

    enum NetworkTab: String, CaseIterable, Identifiable {
        case traffic = "流量"
        case connections = "连接"
        case dns = "DNS"
        case diagnostics = "诊断"

        var id: String { rawValue }

        /// 调试环境变量用的英文标识，避免和界面显示名耦合
        var debugKey: String {
            switch self {
            case .traffic: return "traffic"
            case .connections: return "connections"
            case .dns: return "dns"
            case .diagnostics: return "diagnostics"
            }
        }

        init?(debugKey: String) {
            let key = debugKey.lowercased()
            guard let match = NetworkTab.allCases.first(where: { $0.debugKey == key }) else { return nil }
            self = match
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
                .padding(.horizontal, 40)
                .padding(.bottom, 10)

            Picker("", selection: $tab) {
                ForEach(NetworkTab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            .padding(.bottom, 10)

            Divider().opacity(0.25)

            Group {
                switch tab {
                case .traffic:
                    trafficTab
                case .connections:
                    connectionsTab
                case .dns:
                    DNSTab(notice: $notice)
                case .diagnostics:
                    DiagnosticsTab(notice: $notice)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.25)

            bottomBar
                .padding(.horizontal, 40)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // 调试用：LAUNCHGRID_NETWORK_TAB=traffic|connections|dns|diagnostics 直接落到某个子页
            if let raw = ProcessInfo.processInfo.environment["LAUNCHGRID_NETWORK_TAB"],
               let selected = NetworkTab(debugKey: raw) {
                tab = selected
                DebugLog.log("env LAUNCHGRID_NETWORK_TAB=\(raw) -> tab=\(selected.rawValue)")
            } else if let raw = ProcessInfo.processInfo.environment["LAUNCHGRID_NETWORK_TAB"] {
                DebugLog.log("env LAUNCHGRID_NETWORK_TAB=\(raw) 无法识别")
            }
            monitor.loadTodaySamples()
            monitor.pruneHistory()
        }
    }

    // MARK: - 顶部状态条

    private var statusBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.isReachable ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(monitor.isReachable ? "网络正常" : "网络不可达")
                    .font(.callout)
            }

            ratePill(down: monitor.downloadBPS, up: monitor.uploadBPS)

            HStack(spacing: 6) {
                Text("今日")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("↓\(ByteFormat.string(monitor.cumulative.downloadBytes))")
                    .font(.callout.monospacedDigit())
                Text("↑\(ByteFormat.string(monitor.cumulative.uploadBytes))")
                    .font(.callout.monospacedDigit())
            }

            Spacer(minLength: 0)

            if let error = monitor.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func ratePill(down: Double, up: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down")
                .font(.caption2)
                .foregroundStyle(.cyan)
            Text(ByteFormat.string(UInt64(max(down, 0))) + "/s")
                .font(.callout.monospacedDigit())
            Image(systemName: "arrow.up")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(ByteFormat.string(UInt64(max(up, 0))) + "/s")
                .font(.callout.monospacedDigit())
        }
    }

    // MARK: - 流量子页

    private var trafficTab: some View {
        VStack(spacing: 0) {
            TrafficChart(samples: monitor.samples)
                .frame(height: 150)
                .padding(.horizontal, 40)
                .padding(.vertical, 12)

            Divider().opacity(0.2)

            HStack(spacing: 12) {
                Text("进程")
                    .frame(width: 260, alignment: .leading)
                Text("PID")
                    .frame(width: 62, alignment: .trailing)
                Text("下行")
                    .frame(width: 92, alignment: .trailing)
                Text("上行")
                    .frame(width: 92, alignment: .trailing)
                Text("合计")
                    .frame(width: 92, alignment: .trailing)
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 40)
            .padding(.bottom, 6)

            Divider().opacity(0.25)

            if filteredTraffic.isEmpty {
                Text("没有匹配的网络进程")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredTraffic) { item in
                            HStack(spacing: 12) {
                                Text(item.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .frame(width: 260, alignment: .leading)
                                Text(String(item.pid))
                                    .frame(width: 62, alignment: .trailing)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(ByteFormat.string(item.bytesIn) + "/s")
                                    .frame(width: 92, alignment: .trailing)
                                    .monospacedDigit()
                                Text(ByteFormat.string(item.bytesOut) + "/s")
                                    .frame(width: 92, alignment: .trailing)
                                    .monospacedDigit()
                                Text(item.rateText)
                                    .frame(width: 92, alignment: .trailing)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 40)
                            .contentShape(Rectangle())
                            // 不做单击终止：列表每 2 秒刷新重排，误点代价太高，终止走右键菜单
                            .contextMenu {
                                Button("终止该进程") { terminate(item) }
                            }
                            Divider().opacity(0.12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var filteredTraffic: [ProcessTraffic] {
        guard !query.isEmpty else { return monitor.processTraffic }
        return monitor.processTraffic.filter {
            $0.name.range(of: query, options: [.caseInsensitive]) != nil
                || String($0.pid) == query
        }
    }

    // MARK: - 连接子页

    private var connectionsTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("进程")
                    .frame(width: 170, alignment: .leading)
                Text("PID")
                    .frame(width: 60, alignment: .trailing)
                Text("协议")
                    .frame(width: 58, alignment: .leading)
                Text("本地")
                    .frame(width: 220, alignment: .leading)
                Text("远端")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("状态")
                    .frame(width: 108, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 40)
            .padding(.bottom, 8)

            Divider().opacity(0.25)

            if filteredConnections.isEmpty {
                Text("没有匹配的连接")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredConnections) { conn in
                            HStack(spacing: 12) {
                                Text(conn.processName)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .frame(width: 170, alignment: .leading)
                                Text(String(conn.pid))
                                    .frame(width: 60, alignment: .trailing)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(conn.protocolName)
                                    .frame(width: 58, alignment: .leading)
                                    .foregroundStyle(.secondary)
                                Text(conn.localText)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: 220, alignment: .leading)
                                Text(conn.remoteText)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(conn.state.isEmpty ? "—" : conn.state)
                                    .font(.caption)
                                    .frame(width: 108, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 40)
                            Divider().opacity(0.12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var filteredConnections: [NetworkConnection] {
        guard !query.isEmpty else { return monitor.connections }
        return monitor.connections.filter {
            $0.processName.range(of: query, options: [.caseInsensitive]) != nil
                || $0.remoteAddress.contains(query)
                || String($0.pid) == query
        }
    }

    // MARK: - 底部状态栏

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Text("右键流量行可终止该进程")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Button {
                monitor.refresh()
            } label: {
                Text("刷新")
            }

            if let updatedAt = monitor.updatedAt {
                Text(updatedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
            }
        }
    }

    // MARK: - 动作

    private func terminate(_ item: ProcessTraffic) {
        if let error = processMonitor.terminate(pid: item.pid) {
            notice = error
        } else {
            notice = "已请求终止 \(item.name)"
            monitor.refresh()
        }
    }
}

/// 今日上下行曲线
private struct TrafficChart: View {
    let samples: [NetworkMonitor.TrafficSample]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))

                if samples.count >= 2 {
                    let peak = max(samples.map { max($0.downloadBytes, $0.uploadBytes) }.max() ?? 1, 1)
                    let step = size.width / CGFloat(max(samples.count - 1, 1))

                    // 下行
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for (index, sample) in samples.enumerated() {
                            let x = CGFloat(index) * step
                            let y = size.height - (CGFloat(sample.downloadBytes) / CGFloat(peak)) * size.height
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.55), Color.cyan.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    // 上行
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for (index, sample) in samples.enumerated() {
                            let x = CGFloat(index) * step
                            let y = size.height - (CGFloat(sample.uploadBytes) / CGFloat(peak)) * size.height
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.45), Color.orange.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    HStack(spacing: 14) {
                        legend("下行", Color.cyan)
                        legend("上行", Color.orange)
                        Spacer()
                        Text("峰值 \(ByteFormat.string(peak))/s · 每 5 秒采样")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                } else {
                    Text("正在采集流量样本…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
