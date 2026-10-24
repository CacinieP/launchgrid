import SwiftUI

/// DNS 子页：查看 / 修改 DNS 服务器，探测解析延迟
struct DNSTab: View {
    @Binding var notice: String?

    @State private var servers: [String] = []
    @State private var primary = ""
    @State private var secondary = ""
    @State private var loadError: String?
    @State private var probeTarget = "8.8.8.8"
    @State private var probeResult: DNSProbeResult?
    @State private var probeError: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    currentCard
                    editCard
                    probeCard
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: reload)
    }

    // MARK: - 当前 DNS

    private var currentCard: some View {
        card(title: "当前 DNS 服务器") {
            if let loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if servers.isEmpty {
                Text("没有读到 DNS 服务器")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ForEach(servers, id: \.self) { server in
                        Text(server)
                            .font(.callout.monospaced())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - 修改

    private var editCard: some View {
        card(title: "修改 DNS 服务器") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    field("主 DNS", text: $primary, placeholder: "如 223.5.5.5")
                    field("备用 DNS", text: $secondary, placeholder: "可留空")
                }
                HStack(spacing: 12) {
                    Button {
                        save()
                    } label: {
                        Text("保存（需要管理员授权）")
                    }
                    .disabled(primary.isEmpty || isBusy)

                    Button {
                        reload()
                    } label: {
                        Text("重新读取")
                    }

                    Spacer(minLength: 0)

                    Text("切换 DNS 会短暂影响解析")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 探测

    private var probeCard: some View {
        card(title: "解析延迟探测") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    field("服务器 IP", text: $probeTarget, placeholder: "8.8.8.8")
                    Button {
                        probe()
                    } label: {
                        Text("探测")
                    }
                    .disabled(probeTarget.isEmpty || isBusy)
                    Spacer(minLength: 0)
                }

                if let probeError {
                    Text(probeError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let result = probeResult {
                    HStack(spacing: 18) {
                        Text("平均 \(String(format: "%.1f", result.averageLatencyMS)) ms")
                            .font(.callout.monospacedDigit())
                        Text("成功率 \(Int(result.successRate * 100))%")
                            .font(.callout.monospacedDigit())
                        Text("\(result.totalQueries - result.failedQueries)/\(result.totalQueries) 次成功")
                            .font(.callout.monospacedDigit())
                        Text("共 \(result.server)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("探测会向该 DNS 服务器发起真实的 A 记录查询，查询域名对该服务器可见")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 组件

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - 动作

    private func reload() {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try NetworkTools.currentDNSServers() }
            DispatchQueue.main.async {
                isBusy = false
                switch result {
                case .success(let list):
                    loadError = nil
                    servers = list
                    if primary.isEmpty { primary = list.first ?? "" }
                    if secondary.isEmpty, list.count > 1 { secondary = list[1] }
                case .failure(let error):
                    loadError = error.localizedDescription
                }
            }
        }
    }

    private func save() {
        isBusy = true
        let primaryValue = primary.trimmingCharacters(in: .whitespaces)
        let secondaryValue = secondary.trimmingCharacters(in: .whitespaces)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try NetworkTools.setDNSServers(
                    primary: primaryValue,
                    secondary: secondaryValue.isEmpty ? nil : secondaryValue
                )
            }
            DispatchQueue.main.async {
                isBusy = false
                switch result {
                case .success:
                    notice = "DNS 已更新为 \(primaryValue)"
                    reload()
                case .failure(let error):
                    notice = error.localizedDescription
                }
            }
        }
    }

    private func probe() {
        isBusy = true
        probeError = nil
        let target = probeTarget.trimmingCharacters(in: .whitespaces)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try NetworkTools.probeDNSServer(target) }
            DispatchQueue.main.async {
                isBusy = false
                switch result {
                case .success(let value):
                    probeResult = value
                case .failure(let error):
                    probeError = error.localizedDescription
                }
            }
        }
    }
}

/// 诊断子页：四项网络检查 + 修复建议
struct DiagnosticsTab: View {
    @Binding var notice: String?

    @State private var report: DiagnosticReport?
    @State private var isRunning = false
    @State private var error: String?
    @State private var fixedActions: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Button {
                            run()
                        } label: {
                            Text(isRunning ? "诊断中…" : "开始诊断")
                        }
                        .disabled(isRunning)

                        if let report {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(color(for: report.overall))
                                    .frame(width: 8, height: 8)
                                Text(title(for: report.overall))
                                    .font(.callout)
                            }
                        }
                        Spacer(minLength: 0)
                        Text("诊断只做只读检查，不会改动系统设置")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    if let report {
                        checkCard(title: "网关与公网连通性", item: report.connectivity)
                        checkCard(title: "IP 配置", item: report.ipConfiguration)
                        checkCard(title: "DNS 解析", item: report.dnsResolution)
                        checkCard(title: "网络质量", item: report.quality)

                        if !report.recommendations.isEmpty {
                            fixCard(report.recommendations)
                        }
                    } else if !isRunning {
                        Text("点「开始诊断」检查网络状况")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // 调试用：LAUNCHGRID_AUTORUN_DIAGNOSTICS=1 自动跑一次诊断，方便截图验证报告渲染
            if ProcessInfo.processInfo.environment["LAUNCHGRID_AUTORUN_DIAGNOSTICS"] == "1", report == nil {
                run()
            }
        }
    }

    private func checkCard(title: String, item: DiagnosticItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: item.status))
                .foregroundStyle(color(for: item.status))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(item.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f ms", item.durationMS))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func fixCard(_ recommendations: [Recommendation]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("修复建议")
                .font(.headline)

            ForEach(recommendations) { item in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.callout.weight(.medium))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.action.warning)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Button {
                        apply(item.action)
                    } label: {
                        Text(fixedActions.contains(item.action.rawValue) ? "已执行" : "执行")
                    }
                    .disabled(fixedActions.contains(item.action.rawValue))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func color(for status: NetworkDiagnostic.Status) -> Color {
        switch status {
        case .pass: return .green
        case .warning: return .orange
        case .fail: return .red
        }
    }

    private func icon(for status: NetworkDiagnostic.Status) -> String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    private func title(for status: NetworkDiagnostic.Status) -> String {
        switch status {
        case .pass: return "网络正常"
        case .warning: return "网络有隐患"
        case .fail: return "网络异常"
        }
    }

    private func run() {
        isRunning = true
        error = nil
        NetworkTools.runDiagnostics { result in
            isRunning = false
            switch result {
            case .success(let value):
                report = value
            case .failure(let error):
                self.error = error.localizedDescription
            }
        }
    }

    private func apply(_ action: FixAction) {
        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try NetworkTools.applyFix(action, dnsServers: nil)
            }
            DispatchQueue.main.async {
                isRunning = false
                switch result {
                case .success:
                    fixedActions.append(action.rawValue)
                    notice = "已执行：\(action.displayName)"
                    run()
                case .failure(let error):
                    notice = error.localizedDescription
                }
            }
        }
    }
}
