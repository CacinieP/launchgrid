import AppKit
import Combine
import Foundation

/// 剪贴板历史条目
struct ClipboardEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
    /// 复制来源的 bundle id（可空）
    let sourceBundleID: String?
    /// 复制来源的显示名（可空）
    let sourceName: String?

    /// 列表里显示的摘要：压缩空白并截断
    var preview: String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\t", with: " ")
        let trimmed = flat.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 160 { return trimmed }
        return String(trimmed.prefix(160)) + "…"
    }

    var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: createdAt)
    }
}

/// 剪贴板历史。仅在用户启用且未暂停时监听；内容以本地 JSON 明文保存 7 天。
/// 通过注入独立偏好、pasteboard 和路径，测试不会接触真实剪贴板或历史。
final class ClipboardStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isPaused = false
    @Published private(set) var isCapturing = false

    private let maxEntries = 200
    private let maxEntryBytes = 256 * 1024
    private let retentionDays = 7
    private let pollInterval: TimeInterval = 0.6
    private let pasteboard: NSPasteboard
    private let storeURL: URL
    private let sourceProvider: () -> (bundleID: String?, name: String?)
    private let now: () -> Date
    /// A single queue preserves mutation order: an earlier save cannot restore deleted history.
    private let persistenceQueue = DispatchQueue(label: "com.launchgrid.clipboard.persistence", qos: .utility)
    private var subscriptions = Set<AnyCancellable>()
    private var isEnabled: Bool
    private var ignoredBundleIDs: Set<String>
    private var isStarted = false
    private var didLoad = false
    private var lastChangeCount: Int
    private var timer: Timer?
    private var saveWorkItem: DispatchWorkItem?
    private var cleanupDate: Date?

    private struct Payload: Codable {
        var version: Int = 1
        var savedAt: Date
        var entries: [ClipboardEntry]
    }

    static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LaunchGrid", isDirectory: true)
            .appendingPathComponent("clipboard.json")
    }

    init(
        preferences: AppPreferences = .shared,
        pasteboard: NSPasteboard = .general,
        storeURL: URL? = nil,
        sourceProvider: @escaping () -> (bundleID: String?, name: String?) = {
            let front = NSWorkspace.shared.frontmostApplication
            return (front?.bundleIdentifier, front?.localizedName)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.storeURL = storeURL ?? Self.defaultStoreURL
        self.sourceProvider = sourceProvider
        self.now = now
        self.isEnabled = preferences.clipboardEnabled
        self.ignoredBundleIDs = Set(preferences.ignoredClipboardBundleIDs)
        self.lastChangeCount = pasteboard.changeCount
        preferences.$clipboardEnabled.dropFirst().sink { [weak self] enabled in
            self?.isEnabled = enabled
            self?.updateCaptureState()
        }.store(in: &subscriptions)
        preferences.$ignoredClipboardBundleIDs.dropFirst().sink { [weak self] identifiers in
            guard let self else { return }
            self.ignoredBundleIDs = Set(identifiers)
            self.lastChangeCount = self.pasteboard.changeCount
            let before = self.entries.count
            self.entries.removeAll { entry in
                entry.sourceBundleID.map { self.ignoredBundleIDs.contains($0) } ?? false
            }
            if self.entries.count != before { self.saveNow() }
        }.store(in: &subscriptions)
    }

    deinit {
        timer?.invalidate()
        saveWorkItem?.cancel()
    }

    // MARK: - 生命周期与隐私控制

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if !didLoad {
            didLoad = true
            load()
        }
        updateCaptureState()
    }

    func stop() {
        isStarted = false
        updateCaptureState()
        saveNow()
        // The app's termination callback must finish writing before the process exits.
        flushPendingWrites()
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        updateCaptureState()
    }

    private func updateCaptureState() {
        let shouldCapture = isStarted && isEnabled && !isPaused
        guard shouldCapture != isCapturing else { return }
        timer?.invalidate()
        timer = nil
        // Never import the current clipboard on start/resume. It may have been copied
        // while collection was off, paused, or before the user opted in.
        lastChangeCount = pasteboard.changeCount
        isCapturing = shouldCapture
        guard shouldCapture else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.captureCurrent()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - 采集

    func captureCurrent() {
        guard isCapturing else { return }
        runDailyCleanupIfNeeded()
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        let hiddenTypes = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        ]
        if let types = pasteboard.types, hiddenTypes.contains(where: { types.contains($0) }) {
            return
        }
        // NSPasteboard does not expose a trustworthy source owner; use the foreground
        // application as a best-effort approximation, just as the UI discloses.
        let source = sourceProvider()
        if let bundleID = source.bundleID, ignoredBundleIDs.contains(bundleID) { return }
        guard let text = pasteboard.string(forType: .string) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text.utf8.count <= maxEntryBytes else { return }

        entries.removeAll { $0.text == text }
        entries.insert(
            ClipboardEntry(
                id: UUID(), text: text, createdAt: now(),
                sourceBundleID: source.bundleID, sourceName: source.name
            ),
            at: 0
        )
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        scheduleSave()
    }

    // MARK: - 增删

    func remove(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        saveNow()
    }

    func clearAll() {
        entries.removeAll()
        // Also skip the current pasteboard so clearing cannot immediately recapture it.
        lastChangeCount = pasteboard.changeCount
        saveNow()
    }

    // MARK: - 落盘

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let payload = Payload(savedAt: now(), entries: entries)
        let url = storeURL
        persistenceQueue.async { [weak self] in
            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                let data = try encoder.encode(payload)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path
                )
                DispatchQueue.main.async { self?.lastError = nil }
            } catch {
                let message = "剪贴板历史写入失败：\(error.localizedDescription)"
                DispatchQueue.main.async { self?.lastError = message }
            }
        }
    }

    /// Internal synchronization point for shutdown and isolated persistence tests.
    func flushPendingWrites() {
        persistenceQueue.sync {}
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            lastError = "剪贴板历史文件损坏，已忽略"
            return
        }
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86400)
        entries = payload.entries
            .filter { entry in
                entry.createdAt >= cutoff
                    && !(entry.sourceBundleID.map { ignoredBundleIDs.contains($0) } ?? false)
            }
            .sorted { $0.createdAt > $1.createdAt }
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        if payload.entries.count != entries.count { scheduleSave() }
    }

    func runDailyCleanupIfNeeded() {
        let today = Calendar.current.startOfDay(for: now())
        if let cleanupDate, Calendar.current.isDate(cleanupDate, inSameDayAs: today) { return }
        cleanupDate = today
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86400)
        let before = entries.count
        entries.removeAll { $0.createdAt < cutoff }
        if entries.count != before { scheduleSave() }
    }
}
