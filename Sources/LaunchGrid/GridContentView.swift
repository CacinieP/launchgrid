import SwiftUI
import UniformTypeIdentifiers

/// Persistent launcher grid, folders, search, keyboard selection, and portable layout backups.
struct GridContentView: View {
    let apps: [AppItem]
    @Binding var query: String
    let onLaunch: (AppItem) -> Void
    var onInspect: ((AppItem) -> Void)? = nil

    @StateObject private var store = LauncherLayoutStore.shared
    @State private var page = 0
    @State private var columnsCount = 7
    @State private var selectedIndex: Int?
    @State private var openFolderID: String?
    @State private var editing: GridEditor?
    @State private var editText = ""
    @State private var notice: String?
    @State private var focusToken = 0
    @State private var importingLegacy = false
    @State private var installedInventory: [AppItem] = []

    private let rowsPerPage = 5
    private let gridSpacing: CGFloat = 28
    private var perPage: Int { columnsCount * rowsPerPage }
    private var appByID: [String: AppItem] { Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) }) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var currentFolder: LauncherFolder? { store.layout.folders.first { $0.id == openFolderID } }
    private var items: [LauncherItem] {
        if isSearching {
            let byID = appByID
            return store.layout.orderedAppPaths.compactMap { path in
                guard let app = byID[path], LauncherSearch.matches(app, query: query, aliases: store.layout.aliases[path] ?? []) else { return nil }
                return .app(path)
            }
        }
        if let folder = currentFolder { return folder.appPaths.map(LauncherItem.app) }
        return store.layout.root
    }
    private var pageCount: Int { max(1, (items.count + perPage - 1) / perPage) }
    private var currentPage: [LauncherItem] {
        let first = min(max(page, 0), pageCount - 1) * perPage
        return Array(items.dropFirst(first).prefix(perPage))
    }

    var body: some View {
        GeometryReader { geo in
            content
                .onAppear {
                    updateColumns(geo.size.width)
                    installedInventory = apps
                    store.synchronize(with: apps)
                    if let error = store.errorMessage { notice = error }
                }
                .onChange(of: geo.size.width) { updateColumns($0) }
        }
        .background(GridKeyboardCapture(focusToken: focusToken, onKey: handleKey).frame(width: 0, height: 0))
        .onChange(of: apps) { installedInventory = $0; store.synchronize(with: $0) }
        .onChange(of: query) { _ in resetSelection() }
        .onChange(of: store.layout) { _ in
            if let id = openFolderID, !store.layout.folders.contains(where: { $0.id == id }) { openFolderID = nil }
            if let selectedIndex, selectedIndex >= items.count { self.selectedIndex = items.isEmpty ? nil : items.count - 1 }
            page = min(page, pageCount - 1)
        }
        .onChange(of: store.errorMessage) { message in if let message { notice = message } }
        .sheet(item: $editing) { editor in editorSheet(editor) }
        .alert("LaunchGrid 布局", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil; store.acknowledgeError() } })) {
            Button("好", role: .cancel) { notice = nil; store.acknowledgeError() }
        } message: { Text(notice ?? "") }
    }

    private var content: some View {
        VStack(spacing: 14) {
            toolbar
            if currentPage.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: currentFolder == nil ? "magnifyingglass" : "folder").font(.largeTitle)
                    Text(isSearching ? "没有找到应用" : "文件夹为空")
                    if currentFolder != nil && !isSearching { Text("返回应用网格，在应用右键菜单中移入这个文件夹。这里也可以接收拖入的应用。 ").font(.caption) }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: [UTType.text], isTargeted: nil) { drop($0, before: nil) }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnsCount), spacing: 20) {
                            ForEach(currentPage) { item in
                                tile(item)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 48)
                        if !isSearching {
                            Text("拖到这里移至末尾")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .contentShape(Rectangle())
                                .onDrop(of: [UTType.text], isTargeted: nil) { drop($0, before: nil) }
                        }
                    }
                    .onChange(of: selectedIndex) { index in
                        if let index, items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            if pageCount > 1 { pageIndicator }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if let folder = currentFolder, !isSearching {
                Button { openFolderID = nil; resetSelection(); focusToken += 1 } label: { Label("全部应用", systemImage: "chevron.left") }
                Text(folder.name).font(.headline).lineLimit(1)
            } else {
                Text(isSearching ? "搜索结果 · \(items.count)" : "\(apps.count) 个应用").foregroundStyle(.secondary)
            }
            Spacer()
            if importingLegacy { ProgressView().controlSize(.small); Text("正在读取旧布局…").font(.caption) }
            Text("↓ 选择 · ↵ 打开 · 拖动排序").font(.caption).foregroundStyle(.secondary)
            Menu {
                Button("新建文件夹…") { beginEditing(.newFolder([]), text: "新文件夹") }
                Divider()
                Button("导出布局…", action: exportLayout)
                Button("导入布局备份…", action: importLayout)
                Button("导入旧 Launchpad 布局", action: importDetectedLegacy)
                Button("选择旧 Launchpad 数据库…", action: chooseLegacyDatabase)
                Divider()
                Button("恢复按名称排序…") { confirmRestore() }
            } label: { Label("布局", systemImage: "slider.horizontal.3") }
            .fixedSize().disabled(importingLegacy)
        }
        .padding(.horizontal, 48)
    }

    private func tile(_ item: LauncherItem) -> some View {
        VStack(spacing: 8) {
            if item.kind == .app, let app = appByID[item.value] {
                Image(nsImage: app.icon).resizable().scaledToFit().frame(width: 76, height: 76)
                Text(app.name).font(.caption).lineLimit(1).truncationMode(.tail).frame(maxWidth: 110)
            } else if let folder = store.layout.folders.first(where: { $0.id == item.value }) {
                folderIcon(folder)
                Text(folder.name).font(.caption).lineLimit(1).truncationMode(.tail).frame(maxWidth: 110)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(selectedItem == item ? Color.accentColor.opacity(0.26) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .onTapGesture { activate(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(itemName(item))
        .contextMenu { contextMenu(item) }
        .onDrag { isSearching ? NSItemProvider() : NSItemProvider(object: item.id as NSString) }
        .onDrop(of: [UTType.text], delegate: GridTileDropDelegate(isFolder: item.kind == .folder, enabled: !isSearching) { providers, intoFolder in
            drop(providers, before: item, intoFolder: intoFolder)
        })
        .help(item.kind == .folder ? "拖到中心移入文件夹；拖到顶部边缘在文件夹前排序。" : "拖动调整顺序；右键可编辑别名或移入文件夹。")
    }

    private var selectedItem: LauncherItem? {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    private func folderIcon(_ folder: LauncherFolder) -> some View {
        LazyVGrid(columns: [GridItem(.fixed(27), spacing: 5), GridItem(.fixed(27), spacing: 5)], spacing: 5) {
            ForEach(Array(folder.appPaths.prefix(4)), id: \.self) { path in
                if let app = appByID[path] { Image(nsImage: app.icon).resizable().scaledToFit().frame(width: 27, height: 27) }
            }
            if folder.appPaths.isEmpty { Image(systemName: "folder").font(.title2).frame(width: 27, height: 27).foregroundStyle(.secondary) }
        }
        .frame(width: 76, height: 76).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private func contextMenu(_ item: LauncherItem) -> some View {
        if item.kind == .app, let app = appByID[item.value] {
            Button("打开") { onLaunch(app) }
            if let onInspect { Button("查看运行与联网状态…") { onInspect(app) } }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            Divider()
            Button("编辑搜索别名…") { beginEditing(.aliases(app.id), text: (store.layout.aliases[app.id] ?? []).joined(separator: ", ")) }
            Button("为此应用新建文件夹…") { beginEditing(.newFolder([app.id]), text: "新文件夹") }
            if !store.layout.folders.isEmpty {
                Menu("移入文件夹") {
                    ForEach(store.layout.folders) { folder in
                        Button(folder.name) { store.moveApp(app.id, toFolder: folder.id) }
                            .disabled(folder.appPaths.contains(app.id))
                    }
                }
            }
            if store.layout.folders.contains(where: { $0.appPaths.contains(app.id) }) {
                Button("移出文件夹") { store.moveApp(app.id, toFolder: nil) }
            }
        } else if let folder = store.layout.folders.first(where: { $0.id == item.value }) {
            Button("打开文件夹") { activate(item) }
            Button("重命名…") { beginEditing(.renameFolder(folder.id), text: folder.name) }
            Button("解散文件夹（保留应用）") { store.dissolveFolder(folder.id) }
        }
        if !isSearching && pageCount > 1 {
            Divider()
            Menu("移动到页面") {
                ForEach(0..<pageCount, id: \.self) { destination in
                    Button("第 \(destination + 1) 页") { move(item, toPage: destination) }
                        .disabled((items.firstIndex(of: item) ?? 0) / perPage == destination)
                }
            }
        }
    }

    private func move(_ item: LauncherItem, toPage destination: Int) {
        let index = min(max(0, destination * perPage), max(0, items.count - 1))
        store.move(item, toIndex: index, inFolder: openFolderID)
        selectedIndex = items.firstIndex(of: item)
        page = (selectedIndex ?? 0) / perPage
        focusToken += 1
    }

    private func itemName(_ item: LauncherItem) -> String {
        item.kind == .app ? (appByID[item.value]?.name ?? "应用") : (store.layout.folders.first { $0.id == item.value }?.name ?? "文件夹")
    }

    private func activate(_ item: LauncherItem) {
        if item.kind == .app, let app = appByID[item.value] { onLaunch(app) }
        else { query = ""; openFolderID = item.value; resetSelection(); focusToken += 1 }
    }

    private func handleKey(_ code: UInt16) -> Bool {
        if code == 36 || code == 76 {
            if let item = selectedItem ?? items.first { activate(item); return true }
            return false
        }
        let direction: GridDirection
        switch code {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        default: return false
        }
        selectedIndex = GridNavigation.move(from: selectedIndex, direction: direction, count: items.count, columns: columnsCount)
        if let selectedIndex { page = selectedIndex / perPage }
        return selectedIndex != nil
    }

    private func resetSelection() { page = 0; selectedIndex = nil }

    private func updateColumns(_ width: CGFloat) {
        let columns = max(3, min(7, Int((max(width - 96, 1) + gridSpacing) / (76 + gridSpacing))))
        if columns != columnsCount {
            columnsCount = columns
            page = (selectedIndex ?? 0) / perPage
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 10) {
            ForEach(0..<pageCount, id: \.self) { index in
                Button { page = index; selectedIndex = index * perPage; focusToken += 1 } label: {
                    Circle().fill(index == page ? Color.primary : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                }
                .buttonStyle(.plain).accessibilityLabel("第 \(index + 1) 页，共 \(pageCount) 页")
            }
        }
    }

    private func drop(_ providers: [NSItemProvider], before target: LauncherItem?, intoFolder: Bool = true) -> Bool {
        guard !isSearching, let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            DispatchQueue.main.async {
                let all = store.layout.root + store.layout.folders.flatMap { $0.appPaths.map(LauncherItem.app) }
                guard let source = all.first(where: { $0.id == id }), source != target else { return }
                if let target {
                    if intoFolder && target.kind == .folder && source.kind == .app {
                        store.moveApp(source.value, toFolder: target.value)
                    } else {
                        store.reorder(source, before: target, inFolder: openFolderID)
                    }
                } else { store.move(source, toEndOfFolder: openFolderID) }
            }
        }
        return true
    }

    private func beginEditing(_ kind: GridEditor.Kind, text: String) { editText = text; editing = GridEditor(kind: kind) }

    private func editorSheet(_ editor: GridEditor) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editor.title).font(.headline)
            TextField(editor.isAliases ? "多个别名用逗号分隔" : "文件夹名称", text: $editText)
                .textFieldStyle(.roundedBorder).onSubmit { saveEditor(editor) }
            if editor.isAliases { Text("支持中文、拼音及自定义简称；留空可移除别名。").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("取消") { editing = nil }.keyboardShortcut(.cancelAction)
                Button("保存") { saveEditor(editor) }.keyboardShortcut(.defaultAction)
                    .disabled(!editor.isAliases && editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 380)
    }

    private func saveEditor(_ editor: GridEditor) {
        switch editor.kind {
        case .newFolder(let paths): _ = store.createFolder(named: editText, appPaths: paths)
        case .renameFolder(let id): store.renameFolder(id, to: editText)
        case .aliases(let path): store.setAliases(editText.components(separatedBy: CharacterSet(charactersIn: ",，\n")), for: path)
        }
        editing = nil
    }

    private func exportLayout() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LaunchGrid-layout.json"
        present(panel) { url in
            do { try store.exportData().write(to: url, options: .atomic) }
            catch { notice = "导出失败：\(error.localizedDescription)" }
        }
    }

    private func importLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        present(panel) { url in
            do {
                let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard size <= 5_000_000 else { throw LauncherLayoutError.oversizedDocument }
                let count = try store.importData(Data(contentsOf: url), apps: apps)
                openFolderID = nil; query = ""; resetSelection()
                notice = "已恢复 \(count) 个应用的位置。未安装的应用已跳过，其他已安装应用追加在末尾。"
            } catch { notice = "导入失败：\(error.localizedDescription)" }
        }
    }

    private func importDetectedLegacy() { beginLegacyImport(url: nil) }

    private func chooseLegacyDatabase() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = "选择旧 Launchpad 的 SQLite 数据库（通常名为 db 或以 .db 结尾）。只读导入，不会改动源文件。"
        present(panel) { beginLegacyImport(url: $0) }
    }

    private func beginLegacyImport(url: URL?) {
        guard !importingLegacy else { return }
        importingLegacy = true
        let installed = apps
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<LauncherLayout, Error> {
                let candidates = url.map { [$0] } ?? LegacyLaunchpadImporter.candidateDatabases()
                guard !candidates.isEmpty else { throw LauncherLayoutError.unavailableLegacyDatabase }
                var lastError: Error = LauncherLayoutError.invalidLegacyDatabase
                for candidate in candidates {
                    do { return try LegacyLaunchpadImporter.read(url: candidate, apps: installed) }
                    catch { lastError = error }
                }
                throw lastError
            }
            DispatchQueue.main.async {
                importingLegacy = false
                do {
                    let imported = try result.get()
                    let count = try store.importLegacyLayout(imported, apps: installedInventory)
                    openFolderID = nil; query = ""; resetSelection()
                    notice = "已导入 \(count) 个已安装应用的顺序和文件夹。其他应用追加在末尾；旧数据库未改动。"
                } catch { notice = "导入失败：\(error.localizedDescription)" }
            }
        }
    }

    private func confirmRestore() {
        let alert = NSAlert()
        alert.messageText = "恢复按应用名称排序？"
        alert.informativeText = "将解散所有文件夹并重置顺序，保留搜索别名。建议先导出布局备份。"
        alert.addButton(withTitle: "恢复排序")
        alert.addButton(withTitle: "取消")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { store.restoreAlphabetical(apps: apps); openFolderID = nil; resetSelection() }
            }
        }
    }

    private func present(_ panel: NSSavePanel, completion: @escaping (URL) -> Void) {
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { completion(url) }
        }
    }
}

private struct GridTileDropDelegate: DropDelegate {
    let isFolder: Bool
    let enabled: Bool
    let onDrop: ([NSItemProvider], Bool) -> Bool
    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [UTType.text]) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard enabled else { return false }
        return onDrop(info.itemProviders(for: [UTType.text]), isFolder && info.location.y >= 18)
    }
}

private struct GridEditor: Identifiable {
    enum Kind { case newFolder([String]), renameFolder(String), aliases(String) }
    let id = UUID()
    let kind: Kind
    var isAliases: Bool { if case .aliases = kind { return true }; return false }
    var title: String {
        switch kind {
        case .newFolder: return "新建文件夹"
        case .renameFolder: return "重命名文件夹"
        case .aliases: return "搜索别名"
        }
    }
}

/// A local event monitor accepts grid keys only in this window. Search keeps caret/selection keys;
/// marked text, modifiers, other text fields, controls, and sheets retain their native behavior.
private struct GridKeyboardCapture: NSViewRepresentable {
    let focusToken: Int
    let onKey: (UInt16) -> Bool

    func makeNSView(context: Context) -> GridKeyboardView {
        let view = GridKeyboardView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }
    func updateNSView(_ view: GridKeyboardView, context: Context) {
        context.coordinator.onKey = onKey
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { if view.window?.attachedSheet == nil { view.window?.makeFirstResponder(view) } }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onKey: onKey, focusToken: focusToken) }
    static func dismantleNSView(_ nsView: GridKeyboardView, coordinator: Coordinator) { coordinator.uninstall() }

    final class Coordinator {
        weak var view: GridKeyboardView?
        var onKey: (UInt16) -> Bool
        var focusToken: Int
        private var monitor: Any?
        init(onKey: @escaping (UInt16) -> Bool, focusToken: Int) { self.onKey = onKey; self.focusToken = focusToken }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let view = self.view, let window = view.window,
                      window.isKeyWindow, event.window === window, window.attachedSheet == nil,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
                let responder = window.firstResponder
                if let editor = responder as? NSTextView {
                    guard !editor.hasMarkedText(), let field = editor.delegate as? NSTextField,
                          field.placeholderString == "搜索应用",
                          [UInt16(125), 36, 76].contains(event.keyCode) else { return event }
                } else if responder !== view {
                    // Respect controls such as the mode picker rather than taking their arrow keys.
                    guard let responder, NSStringFromClass(type(of: responder)).contains("Hosting") else { return event }
                }
                if self.onKey(event.keyCode) {
                    if [UInt16(123), 124, 125, 126].contains(event.keyCode) { window.makeFirstResponder(view) }
                    return nil
                }
                // After navigating the grid, typing resumes the existing search field naturally.
                if responder === view, ![UInt16(123), 124, 125, 126, 36, 76, 53, 48].contains(event.keyCode),
                   let characters = event.characters, characters.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }),
                   let search = self.searchField(in: window.contentView) {
                    window.makeFirstResponder(search)
                    window.sendEvent(event)
                    return nil
                }
                return event
            }
        }
        private func searchField(in view: NSView?) -> NSTextField? {
            guard let view else { return nil }
            if let field = view as? NSTextField, field.placeholderString == "搜索应用" { return field }
            for child in view.subviews { if let field = searchField(in: child) { return field } }
            return nil
        }
        func uninstall() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
        deinit { uninstall() }
    }
}

private final class GridKeyboardView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
