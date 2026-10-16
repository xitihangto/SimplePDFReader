import SwiftUI
import AppKit
import PDFKit
import Combine
import UniformTypeIdentifiers

// MARK: - 应用级设置（全应用唯一一份）
//
// 多窗口架构下的状态分层原则：
//
//   · 与「某个窗口」相关的状态（文档 / 缩放 / 页码 / 侧栏 / 分屏 / 搜索）
//     → 属于 PDFReaderViewModel，**每个窗口各持一份**，互不影响。
//
//   · 与「整个应用」相关的状态与动作
//     → 放在这里，全应用唯一一份。
//
// 典型反例：把「设为默认 PDF 阅读器」放进 ViewModel。那样多窗口时会出现
// 「每个窗口各设一遍」的荒唐局面，而且窗口一关这个入口就跟着没了。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {}

    /// 把本应用设为系统默认的 PDF 打开程序。
    /// 设置一次即对整个系统生效，因此天然属于「应用级」动作。
    func setAsDefaultPDFReader() {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension.lowercased() == "app" else {
            Self.presentAlert(
                message: "无法直接设置为默认阅读器",
                info: "请直接双击运行打包好的 SimplePDFReader.app 后再执行此操作。",
                style: .warning
            )
            return
        }

        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: .pdf) { error in
            Task { @MainActor in
                if let error = error {
                    Self.presentAlert(
                        message: "设置默认 PDF 阅读器失败",
                        info: error.localizedDescription,
                        style: .warning
                    )
                } else {
                    Self.presentAlert(
                        message: "已设为默认 PDF 阅读器",
                        info: "设置已完成，今后在 Finder 中双击任何 PDF 文件都会默认使用 SimplePDFReader 打开。",
                        style: .informational
                    )
                }
            }
        }
    }

    private static func presentAlert(message: String, info: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = style
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}

// MARK: - 选择 PDF 的系统面板
@MainActor
enum PDFOpenPanel {
    static func choose(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - 窗口会话登记表
//
// 每个窗口对应一个 Session：窗口对象 + 该窗口私有的 ViewModel。
// 登记表解决四件事：
//   1. 外部打开文件时，判断「该放进已有空白窗口，还是新开一个窗口」；
//   2. 点 Dock 图标重新激活时，把已有窗口提到最前（而不是新建）；
//   3. 计算「当前还有哪些 PDFDocument 在被使用」，用于回收共享缓存；
//   4. 菜单命令据此找到「当前 key window 对应的 ViewModel」。
@MainActor
final class WindowRegistry {
    /// 嵌套类型不会自动继承外层的 actor 隔离，因此这里显式标注。
    @MainActor
    final class Session {
        let id: UUID
        let viewModel: PDFReaderViewModel
        weak var window: NSWindow?
        /// 最近一次成为 key window 的时间，用于「提到最前」与挑选目标窗口
        var lastActive: Date = .distantPast

        init(id: UUID, viewModel: PDFReaderViewModel) {
            self.id = id
            self.viewModel = viewModel
        }

        var hasDocument: Bool { viewModel.primaryDocument != nil }

        /// 本窗口是否正在显示指定文件。
        /// 主文档与各分屏单独打开的对比文档都算 —— 一个文件只要在某个窗口里露着脸，
        /// 就算「已经打开了」，再次打开时应当聚焦那个窗口而不是重复开一份。
        func isDisplaying(_ key: URL) -> Bool {
            if viewModel.primaryFileURL?.standardizedFileURL == key { return true }
            return viewModel.panes.contains { $0.customFileURL?.standardizedFileURL == key }
        }
    }

    static let shared = WindowRegistry()

    private var sessions: [UUID: Session] = [:]
    private var observers: [UUID: [NSObjectProtocol]] = [:]

    private init() {}

    // MARK: 登记 / 注销

    func attach(window: NSWindow, sessionID: UUID, viewModel: PDFReaderViewModel) {
        let session: Session
        if let existing = sessions[sessionID] {
            existing.window = window
            session = existing
        } else {
            session = Session(id: sessionID, viewModel: viewModel)
            session.window = window
            sessions[sessionID] = session
        }
        session.lastActive = Date()
        observe(window: window, sessionID: sessionID)

        // 新窗口就绪：立刻看看有没有「等窗口出现才能打开」的文件
        (NSApp.delegate as? AppDelegate)?.windowDidBecomeReady()

        sweepDocuments()
    }

    func detach(sessionID: UUID) {
        sessions.removeValue(forKey: sessionID)
        for token in observers.removeValue(forKey: sessionID) ?? [] {
            NotificationCenter.default.removeObserver(token)
        }
        sweepDocuments()
    }

    // MARK: 查询

    /// 窗口对象仍然存在的会话
    var liveSessions: [Session] {
        sessions.values.filter { $0.window != nil }
    }

    var isEmpty: Bool { liveSessions.isEmpty }

    var mostRecentSession: Session? {
        liveSessions.max { $0.lastActive < $1.lastActive }
    }

    func session(for window: NSWindow?) -> Session? {
        guard let window = window else { return nil }
        return liveSessions.first { $0.window === window }
    }

    /// 当前应当接收菜单命令的窗口 —— 即 key window 对应的那个。
    /// 这是「菜单只作用于当前激活窗口」的兜底实现：不依赖 SwiftUI 的场景树，
    /// 手动创建的窗口同样适用。
    var activeSession: Session? {
        session(for: NSApp.keyWindow)
    }

    /// 找到正在显示指定文件的窗口（多个时取最近活跃的那个）。
    func session(displaying url: URL) -> Session? {
        let key = url.standardizedFileURL
        return liveSessions
            .filter { $0.isDisplaying(key) }
            .max { $0.lastActive < $1.lastActive }
    }

    /// 找到某个 ViewModel 所属的会话。
    /// 供 ViewModel 反查「自己在哪个窗口里」——它不该直接持有窗口引用。
    func session(owning viewModel: PDFReaderViewModel) -> Session? {
        liveSessions.first { $0.viewModel === viewModel }
    }

    /// 取走一个「窗口已就绪、但还没有打开任何文档」的会话。
    ///
    /// 典型用途：双击 PDF 启动应用时，应用会先建出一个空白窗口，
    /// 随后才把文件交给我们。此时应当把文件装进这个空白窗口，
    /// 而不是再开一个 —— 否则每次双击都会多出一个空窗口。
    func claimEmptySession() -> Session? {
        return liveSessions
            .filter { !$0.hasDocument && $0.window?.isMiniaturized != true }
            .max { $0.lastActive < $1.lastActive }
    }

    /// 把窗口提到最前（点 Dock 图标时使用），绝不新建窗口。
    func bringMostRecentToFront() {
        let live = liveSessions
        guard !live.isEmpty else { return }
        for session in live {
            if let window = session.window, window.isMiniaturized {
                window.deminiaturize(nil)
            }
        }
        mostRecentSession?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: 文档回收

    /// 当前所有窗口正在使用的 PDF 文件集合
    func documentURLsInUse() -> Set<URL> {
        var urls: Set<URL> = []
        for session in liveSessions {
            let viewModel = session.viewModel
            if let url = viewModel.primaryFileURL {
                urls.insert(url.standardizedFileURL)
            }
            for pane in viewModel.panes {
                if let url = pane.customFileURL {
                    urls.insert(url.standardizedFileURL)
                }
            }
        }
        return urls
    }

    /// - Parameter alsoKeeping: 额外要保留下来的文件。
    ///   用于「窗口刚建好、登记表里还没有它」的时刻：此时它自己正在加载的文档
    ///   会被误判为「没人用」而被清出缓存，加上这个参数就能避免。
    func sweepDocuments(alsoKeeping extra: Set<URL> = []) {
        var keep = documentURLsInUse()
        keep.formUnion(extra.map { $0.standardizedFileURL })
        DocumentStore.shared.sweep(keeping: keep)
    }

    // MARK: 内部

    private func observe(window: NSWindow, sessionID: UUID) {
        guard observers[sessionID] == nil else { return }
        let center = NotificationCenter.default
        let becameKey = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sessions[sessionID]?.lastActive = Date()
            }
        }
        let willClose = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // 不能一收到 willClose 就注销会话。
                // 实测发现：SwiftUI 在处理「打开文件」事件时，会对仍然活着的窗口发出
                // willClose（窗口并未真的关闭）。若照单全收地注销，登记表会被清空，
                // 后续逻辑就会误判「一个窗口都没有」，进而凭空多建窗口或长时间空等。
                //
                // 因此推迟一拍再确认：窗口真的不可见了才注销。
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self = self, let session = self.sessions[sessionID] else { return }
                if let window = session.window, window.isVisible || window.isMiniaturized {
                    return
                }
                self.detach(sessionID: sessionID)
            }
        }
        observers[sessionID] = [becameKey, willClose]
    }
}

// MARK: - 窗口创建与管理
//
// 为什么不用 WindowGroup 管理这些窗口：
// SwiftUI 的 WindowGroup 会在每次收到「打开文件」事件时**额外**凭空创建一个窗口，
// 于是「双击一个 PDF」会得到两个窗口（一个装着文件，一个是空的）。
// 实测确认：这正是历史上「莫名其妙多出一个窗口」的机制。
//
// 因此这里采取完全可控的方案：
//   · 应用启动时那一个窗口由 SwiftUI 的 Window 场景提供（它不会凭空新建）；
//   · 其余窗口全部由本类用 NSWindow + NSHostingController 显式创建。
// 这样「什么时候该新建窗口、什么时候该复用已有窗口」完全由我们决定，可预测、可测试。
@MainActor
final class ReaderWindowManager {
    static let shared = ReaderWindowManager()

    private var windows: [UUID: NSWindow] = [:]
    private var titleObservers: [UUID: AnyCancellable] = [:]
    private var closeObservers: [UUID: NSObjectProtocol] = [:]

    private init() {}

    /// 新建一个阅读器窗口（菜单「文件 → 新建窗口」⌘N）。
    ///
    /// 用户明确要的是「一个新窗口」，所以即便此刻已经有一个空白窗口，也照样再开一个，
    /// 不做复用 —— 复用会让 ⌘N 看起来「没反应」。
    @discardableResult
    func openNewWindow(fileURL: URL? = nil) -> UUID {
        create(fileURL: fileURL)
    }

    /// 统一的「打开文件」入口 —— 双击 PDF、拖到 Dock、工具栏「打开」按钮、
    /// 菜单「打开 PDF…」全部走这里，因此行为完全一致。
    ///
    /// 规则（按优先级）：
    ///   1. 该文件已在某个窗口打开 → 聚焦那个窗口，**绝不重复打开同一份文件**；
    ///   2. 发起操作的那个窗口本身是空的 → 就地填入（这是「填入」而不是「顶掉」，
    ///      所以不会出现「点开一个文件，原来那个空窗口还空着」的浪费）；
    ///   3. 还有别的空白窗口 → 装进最近用过的那个；
    ///   4. 否则 → 新开一个窗口承载它。
    ///
    /// 关键在于第 4 条：**已经开着的内容永远不会被顶掉**，需要时自动多开一个窗口。
    /// 这正是「多窗口对比阅读」的用法。
    func openDocument(at url: URL, preferring window: NSWindow? = nil) {
        let key = url.standardizedFileURL

        // 1) 已经打开 → 聚焦，不重复打开
        if let existing = WindowRegistry.shared.session(displaying: key) {
            focus(existing.window)
            return
        }

        // 2) 发起操作的窗口是空的 → 就地填入
        if let origin = WindowRegistry.shared.session(for: window), !origin.hasDocument {
            origin.viewModel.loadPDF(from: key, silently: true)
            focus(origin.window)
            return
        }

        // 3) 任意一个空白窗口
        if let empty = WindowRegistry.shared.claimEmptySession() {
            empty.viewModel.loadPDF(from: key, silently: true)
            focus(empty.window)
            return
        }

        // 4) 新开一个窗口
        create(fileURL: key)
    }

    /// 当前所有窗口正在查看的文件（用于退出时保存、下次启动恢复）
    var openFileURLs: [URL] {
        WindowRegistry.shared.liveSessions.compactMap { $0.viewModel.primaryFileURL }
    }

    // MARK: 内部

    @discardableResult
    private func create(fileURL: URL?) -> UUID {
        let sessionID = UUID()
        let viewModel = PDFReaderViewModel(initialFileURL: fileURL)

        let hosting = NSHostingController(
            rootView: ReaderWindowView(viewModel: viewModel, sessionID: sessionID)
        )
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1020, height: 660))
        window.minSize = NSSize(width: 420, height: 380)
        // 由本类负责释放时机，避免 AppKit 在关闭时自动释放造成悬垂引用
        window.isReleasedWhenClosed = false
        window.title = Self.title(for: viewModel)
        window.center()

        windows[sessionID] = window

        // 标题跟随本窗口的文档。macOS 惯例是「窗口标题 = 文档名」，
        // 多窗口时用户正是靠它区分哪个窗口是哪份文件。
        titleObservers[sessionID] = viewModel.$primaryFileName
            .combineLatest(viewModel.$primaryDocument)
            .receive(on: RunLoop.main)
            .sink { [weak window] name, document in
                window?.title = document == nil ? AppMetadata.displayName : name
            }

        closeObservers[sessionID] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.forget(sessionID) }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
        return sessionID
    }

    private func forget(_ sessionID: UUID) {
        windows.removeValue(forKey: sessionID)
        titleObservers.removeValue(forKey: sessionID)
        if let token = closeObservers.removeValue(forKey: sessionID) {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func focus(_ window: NSWindow?) {
        guard let window = window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    static func title(for viewModel: PDFReaderViewModel) -> String {
        viewModel.primaryDocument == nil ? AppMetadata.displayName : viewModel.primaryFileName
    }
}

// MARK: - PDFDocument 共享缓存
//
// 同一份 PDF 被多个窗口打开时（例如对照阅读同一份文档的两个不同章节），
// 共享同一个 PDFDocument 实例，避免在内存里放多份。
// PDFDocument 的页面内容是不可变的，多个 PDFView 同时显示同一个实例是安全的：
// 视图侧的当前页、缩放、高亮选区都挂在各自 PDFView 上，不共享。
@MainActor
final class DocumentStore {
    static let shared = DocumentStore()

    private var cache: [URL: PDFDocument] = [:]
    private var order: [URL] = []
    /// 缓存上限：超出后按最近最少使用淘汰。被淘汰的文档若仍显示在某个窗口里，
    /// 会由该 PDFView 自己持有，不会出错，只是下次再打开会重新读一遍文件。
    private let capacity = 8

    private init() {}

    func document(at url: URL) -> PDFDocument? {
        let key = url.standardizedFileURL
        if let cached = cache[key] {
            markUsed(key)
            return cached
        }

        let accessed = key.startAccessingSecurityScopedResource()
        defer { if accessed { key.stopAccessingSecurityScopedResource() } }

        guard let document = PDFDocument(url: key) else { return nil }
        cache[key] = document
        markUsed(key)
        evictOverflow()
        return document
    }

    /// 丢弃不再被任何窗口使用的缓存条目
    func sweep(keeping urls: Set<URL>) {
        guard !cache.isEmpty else { return }
        for key in cache.keys where !urls.contains(key) {
            cache.removeValue(forKey: key)
        }
        order.removeAll { !urls.contains($0) }
    }

    func removeAll() {
        cache.removeAll()
        order.removeAll()
    }

    private func markUsed(_ key: URL) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictOverflow() {
        while order.count > capacity {
            let key = order.removeFirst()
            cache.removeValue(forKey: key)
        }
    }
}

// MARK: - 把 SwiftUI 视图所在的原生窗口暴露出来
struct WindowAccessor: NSViewRepresentable {
    let onWindowReady: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowProbeView()
        view.onWindowReady = onWindowReady
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let probe = nsView as? WindowProbeView else { return }
        probe.onWindowReady = onWindowReady
        probe.report(force: false)
    }

    final class WindowProbeView: NSView {
        var onWindowReady: ((NSWindow) -> Void)?
        private weak var reportedWindow: NSWindow?

        /// 只上报「非空」的窗口；刻意不上报 nil —— SwiftUI 更新期间视图可能被短暂
        /// 移出窗口层级，若把那种瞬间当成「窗口没了」处理，会把登记表清空，导致状态丢失。
        /// 真正的窗口关闭由 WindowRegistry 处理。
        ///
        /// `force` 用于「视图重新被放进某个窗口」的场合（viewDidMoveToWindow）：
        /// 那种情况下即便窗口对象没变也要重新上报一次，因为登记表可能已经被注销过，
        /// 需要重新登记回来。
        func report(force: Bool) {
            guard let window = self.window else { return }
            guard force || window !== reportedWindow else { return }
            reportedWindow = window
            let handler = onWindowReady
            DispatchQueue.main.async {
                handler?(window)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report(force: true)
        }
    }
}

// MARK: - 菜单命令如何找到「当前窗口」
//
// 菜单栏全应用只有一份，但每个窗口各有一份 PDFReaderViewModel。
// 命令一律在**触发的那一刻**通过 WindowRegistry.shared.activeSession 解析目标窗口
// （activeSession = NSApp.keyWindow 对应的会话），因此：
//
//   · 菜单与快捷键永远只作用于当前激活的窗口，其他窗口完全不受影响；
//   · 不依赖 SwiftUI 的场景树，由 NSWindow 手动创建的窗口同样适用。
//
// 刻意不给这些菜单项加 .disabled(reader == nil)：那需要在 Commands 的 body 里
// 持有会随焦点变化的响应式状态，容易因为求值时机而「卡」在错误的状态上。
// 没有窗口时应用本就即将退出，菜单项可点但无事发生，是更小的问题。
