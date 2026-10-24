// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Combine
import CryptoKit

struct ReleaseVersion: Comparable, Equatable {
    let components: [Int]
    init?(_ raw: String) {
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        components = parts.map { Int($0)! } + Array(repeating: 0, count: 3 - parts.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

struct UpdateRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    func verifiedAsset() -> Asset? {
        guard !draft, !prerelease, ReleaseVersion(tag_name) != nil else { return nil }
        let version = tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
        let name = "LaunchGrid-\(version).dmg"
        let expected = "https://github.com/CacinieP/launchgrid/releases/download/\(tag_name)/\(name)"
        return assets.first {
            $0.name == name && $0.browser_download_url.absoluteString == expected
                && Self.validDigest($0.digest)
        }
    }

    static func validDigest(_ digest: String?) -> Bool {
        guard let digest, digest.hasPrefix("sha256:") else { return false }
        let hash = digest.dropFirst(7)
        return hash.count == 64 && hash.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    static func matchesDigest(_ data: Data, expected: String) -> Bool {
        guard validDigest(expected) else { return false }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return expected.lowercased() == "sha256:" + actual
    }
}

/// Uses official GitHub metadata, a SHA-256 digest, and Apple's signature assessment.
/// Download and replacement always require a separate click after checking for updates.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    @Published private(set) var status = "尚未检查更新"
    @Published private(set) var isBusy = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var updateInstalled = false
    private var release: UpdateRelease?
    private var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    var canInstall: Bool {
        let url = Bundle.main.bundleURL.standardizedFileURL
        let parent = url.deletingLastPathComponent()
        let permitted = [URL(fileURLWithPath: "/Applications"),
                         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return !updateInstalled && release?.verifiedAsset() != nil && url.pathExtension == "app"
            && permitted.contains(parent) && FileManager.default.isWritableFile(atPath: parent.path)
    }

    func checkAutomaticallyIfNeeded() {
        guard AppPreferences.shared.automaticUpdateChecks else { return }
        let previous = UserDefaults.standard.object(forKey: "launchgrid.lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(previous) >= 86400 else { return }
        checkForUpdates()
    }

    func checkForUpdates() {
        guard !isBusy, !updateInstalled else { return }
        isBusy = true
        status = "正在检查 GitHub 正式版本…"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/CacinieP/launchgrid/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LaunchGrid", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<UpdateRelease, Error>
            do {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data, data.count <= 2_000_000 else { throw UpdateError.invalidRelease }
                let release = try JSONDecoder().decode(UpdateRelease.self, from: data)
                guard !release.draft, !release.prerelease, ReleaseVersion(release.tag_name) != nil else {
                    throw UpdateError.invalidRelease
                }
                result = .success(release)
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .failure(let error): self.status = "检查失败：\(error.localizedDescription)"
                case .success(let release):
                    UserDefaults.standard.set(Date(), forKey: "launchgrid.lastUpdateCheck")
                    let currentText = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                    guard let current = ReleaseVersion(currentText), let latest = ReleaseVersion(release.tag_name) else {
                        self.status = "无法读取当前应用版本，请从正式 .app 中检查更新。"
                        return
                    }
                    if latest > current {
                        self.release = release
                        self.availableVersion = release.tag_name
                        self.status = release.verifiedAsset() != nil
                            ? "发现 \(release.tag_name)，可下载并校验安装。"
                            : "发现 \(release.tag_name)，此版本需从发布页手动安装。"
                    } else {
                        self.release = nil
                        self.availableVersion = nil
                        self.status = "已是最新版本（\(currentText)）"
                    }
                }
            }
        }.resume()
    }

    func downloadAndInstall() {
        guard !isBusy, canInstall, let release, let asset = release.verifiedAsset() else {
            status = "请把应用安装到 Applications，或从 GitHub 发布页下载后手动安装。"
            return
        }
        let destination = Bundle.main.bundleURL
        isBusy = true
        status = "正在下载 \(release.tag_name)…"
        session.downloadTask(with: asset.browser_download_url) { [weak self] temporaryURL, response, error in
            do {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let temporaryURL, let digest = asset.digest else { throw UpdateError.invalidRelease }
                let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
                guard UpdateRelease.matchesDigest(data, expected: digest) else { throw UpdateError.digestMismatch }
                DispatchQueue.main.async { self?.status = "下载完成，正在验证签名并安装…" }
                try Self.install(dmg: temporaryURL, destination: destination, version: release.tag_name)
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.updateInstalled = true
                    self?.status = "新版已安装，重新启动后生效。"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.status = "更新失败：\(error.localizedDescription)"
                }
            }
        }.resume()
    }

    func restartToApply() {
        guard updateInstalled else { return }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // App path and PID are positional arguments, never interpolated into executable shell text.
        helper.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                            "launchgrid-restart", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run(); NSApp.terminate(nil) }
        catch { status = "请手动退出并重新打开 LaunchGrid。" }
    }

    static func install(dmg: URL, destination: URL, version: String) throws {
        let fm = FileManager.default
        let working = fm.temporaryDirectory.appendingPathComponent("launchgrid-update-" + UUID().uuidString)
        let mount = working.appendingPathComponent("mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: working) }
        _ = try command("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? command("/usr/bin/hdiutil", ["detach", mount.path]) }
        let candidate = mount.appendingPathComponent("LaunchGrid.app")
        guard let bundle = Bundle(url: candidate), bundle.bundleIdentifier == "app.caciniep.launchgrid",
              let installedVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              ReleaseVersion(installedVersion) == ReleaseVersion(version) else { throw UpdateError.invalidApplication }
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        _ = try command("/usr/bin/codesign", ["--verify", "-R", "anchor apple generic and certificate leaf[subject.OU] = \"5CFSU44B7Q\"", candidate.path])
        _ = try command("/usr/sbin/spctl", ["--assess", "--type", "execute", candidate.path])

        let stage = destination.deletingLastPathComponent().appendingPathComponent(".LaunchGrid-update-" + UUID().uuidString + ".app")
        defer { try? fm.removeItem(at: stage) }
        _ = try command("/usr/bin/ditto", [candidate.path, stage.path])
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", stage.path])
        // Foundation replacement preserves the old app if validation or staging failed.
        _ = try fm.replaceItemAt(destination, withItemAt: stage, backupItemName: nil, options: [])
    }

    @discardableResult
    private static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let result = Shell.run(executable, arguments, timeout: 120)
        guard result.isSuccess else { throw UpdateError.verificationFailed }
        return result.stdout
    }

    private enum UpdateError: LocalizedError {
        case invalidRelease, digestMismatch, invalidApplication, verificationFailed
        var errorDescription: String? {
            switch self {
            case .invalidRelease: return "GitHub 版本信息或安装包无效。"
            case .digestMismatch: return "安装包 SHA-256 不匹配，已停止安装。"
            case .invalidApplication: return "安装包中的应用标识或版本不匹配。"
            case .verificationFailed: return "安装包验证或安装失败，当前应用未主动移除。"
            }
        }
    }
}
