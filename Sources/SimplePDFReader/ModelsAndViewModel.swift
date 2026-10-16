import Foundation
import PDFKit
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - 分屏与自适应模式（默认单屏）
enum SplitLayoutMode: String, CaseIterable, Identifiable {
    case single = "单屏"
    case dual = "双屏"
    case triple = "三屏"
    case quad = "四屏"
    case autoByZoom = "自适应分屏"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .single: return "rectangle"
        case .dual: return "rectangle.split.2x1"
        case .triple: return "rectangle.split.3x1"
        case .quad: return "rectangle.split.2x2"
        case .autoByZoom: return "sparkles.rectangle.stack"
        }
    }
}

/// 智能缩放时的具体排布策略
enum SmartZoomStrategy: String, CaseIterable, Identifiable {
    case adaptivePanesAndColumns = "自动切换单页/双页/多屏"
    case adaptiveColumnsOnly = "仅自动切换单页/双页并排"
    case adaptivePanesOnly = "仅自动增减分屏数量"

    var id: String { rawValue }
}

// MARK: - 侧边栏标签页
enum SidebarTab: String, CaseIterable, Identifiable {
    case outline = "大纲"
    case search = "搜索"

    var id: String { rawValue }
}

// MARK: - PDF 大纲目录节点
struct OutlineNode: Identifiable {
    let id = UUID()
    let title: String
    let pageNumber: Int?
    let destination: PDFDestination?
    let children: [OutlineNode]?

    static func buildTree(from root: PDFOutline?, in document: PDFDocument) -> [OutlineNode] {
        guard let root = root else { return [] }
        var nodes: [OutlineNode] = []
        for i in 0..<root.numberOfChildren {
            if let child = root.child(at: i),
               let node = parseOutlineItem(child, in: document) {
                nodes.append(node)
            }
        }
        return nodes
    }

    private static func parseOutlineItem(_ item: PDFOutline, in document: PDFDocument) -> OutlineNode? {
        let rawLabel = item.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawLabel.isEmpty ? "未命名章节" : rawLabel

        var resolvedDestination = item.destination
        if resolvedDestination == nil, let actionGoTo = item.action as? PDFActionGoTo {
            resolvedDestination = actionGoTo.destination
        }

        var pageNum: Int? = nil
        if let page = resolvedDestination?.page {
            let idx = document.index(for: page)
            if idx != NSNotFound && idx >= 0 {
                pageNum = idx + 1
            }
        }

        var childNodes: [OutlineNode] = []
        for i in 0..<item.numberOfChildren {
            if let child = item.child(at: i),
               let childNode = parseOutlineItem(child, in: document) {
                childNodes.append(childNode)
            }
        }

        return OutlineNode(
            title: title,
            pageNumber: pageNum,
            destination: resolvedDestination,
            children: childNodes.isEmpty ? nil : childNodes
        )
    }
}

// MARK: - 搜索结果项
struct SearchResultItem: Identifiable {
    let id = UUID()
    let index: Int
    let selection: PDFSelection
    let pageNumber: Int
    let snippet: String
}

// MARK: - 单个分屏视图状态
@MainActor
final class PaneState: ObservableObject, Identifiable {
    let id: Int
    /// 若在分屏中单独打开了另一份对比 PDF，则保存在此处；若为 nil 则默认共享主文档
    @Published var customDocument: PDFDocument? = nil
    @Published var customFileName: String? = nil
    /// 对比文档的来源路径。用于共享文档缓存的回收判断，以及重新打开同一文件时命中缓存。
    @Published var customFileURL: URL? = nil

    @Published var currentPageNumber: Int = 1
    @Published var pageInputText: String = "1"
    @Published var scaleFactor: CGFloat = 1.0
    @Published var displayMode: PDFDisplayMode = .singlePageContinuous

    /// 当前分屏对应的 PDFView。
    ///
    /// 这里刻意使用**强引用**：早期版本用的是 weak，一旦 SwiftUI 因视图结构变化
    /// 重建/释放了 NSView，该引用会静默变成 nil，于是缩放、跳页等操作全部无声失效，
    /// 而界面上的百分比却照常变化（因为模型被改了），表现为「操作完全无效」。
    /// 生命周期由 NSViewRepresentable 负责：makeNSView / updateNSView 赋值，
    /// dismantleNSView 置空。
    var pdfView: PDFView?

    /// 仅当 PDFView 确实挂在某个窗口上时才算「可操作」。
    /// 用来挡住「引用还在、但视图已脱离窗口层级」的僵尸对象。
    var livePDFView: PDFView? {
        guard let view = pdfView, view.window != nil else { return nil }
        return view
    }

    /// 程序化设置缩放期间置位，用于抑制 PDFKit 回调回声，
    /// 保证 pane.scaleFactor（模型）始终是权威值。
    var isApplyingProgrammaticScale = false

    init(id: Int) {
        self.id = id
    }

    func activeDocument(fallback: PDFDocument?) -> PDFDocument? {
        customDocument ?? fallback
    }

    func totalPages(fallback: PDFDocument?) -> Int {
        activeDocument(fallback: fallback)?.pageCount ?? 0
    }
}

// MARK: - 阅读器核心状态管理
@MainActor
final class PDFReaderViewModel: ObservableObject {
    // 主文档状态
    @Published var primaryDocument: PDFDocument? = nil
    @Published var primaryFileName: String = "未打开文件"
    @Published var primaryFileURL: URL? = nil

    // 顶栏直接绑定的实时响应式状态（解决嵌套 ObservableObject 不触发顶栏刷新的问题）
    @Published var activeScalePercentage: Int = 100
    @Published var activePageNumber: Int = 1
    @Published var activePageInputText: String = "1"
    @Published var activeTotalPages: Int = 0

    // 侧边栏状态（默认关闭，仅在点击左侧大纲/侧边栏按钮时开启）
    @Published var showSidebar: Bool = false
    @Published var sidebarTab: SidebarTab = .outline
    @Published var outlineNodes: [OutlineNode] = []

    // 搜索状态（支持输入实时更新搜索结果）
    @Published var searchQuery: String = "" {
        didSet {
            handleSearchQueryChanged(oldValue: oldValue)
        }
    }
    @Published var searchResults: [SearchResultItem] = []
    @Published var currentSearchIndex: Int = -1
    @Published var isCompactSearchExpanded: Bool = false
    @Published var focusSearchTrigger: UUID = UUID()
    @Published var focusPageJumpTrigger: UUID = UUID()

    // 分屏与智能缩放状态（默认单屏模式）
    @Published var layoutMode: SplitLayoutMode = .single {
        didSet {
            handleLayoutModeChanged()
        }
    }
    @Published var smartZoomStrategy: SmartZoomStrategy = .adaptivePanesAndColumns {
        didSet {
            if layoutMode == .autoByZoom {
                let scale = activePane.livePDFView?.scaleFactor ?? activePane.scaleFactor
                applySmartZoomLayout(forScale: scale, force: true)
            }
        }
    }
    /// 当前实际显示的分屏数量 (1 ~ 4)
    @Published var visiblePaneCount: Int = 1
    /// 智能模式下的状态说明
    @Published var smartStatusLabel: String = "自适应: 单屏单页"
    /// 是否开启多屏联动翻页
    @Published var syncPanesScrolling: Bool = false

    // 当前激活的分屏索引 (0 ~ 3)
    @Published var activePaneIndex: Int = 0 {
        didSet {
            syncActivePaneMetrics()
        }
    }

    // 4 个分屏容器状态
    let panes: [PaneState] = [
        PaneState(id: 0),
        PaneState(id: 1),
        PaneState(id: 2),
        PaneState(id: 3)
    ]

    private var paneCancellables: [AnyCancellable] = []
    private var smartZoomWorkItem: DispatchWorkItem?
    private var searchDebounceWorkItem: DispatchWorkItem?
    private var lastSearchedQuery: String = ""
    private var isPerformingProgrammaticLayoutChange = false

    init(initialFileURL: URL? = nil) {
        // 将所有子分屏 PaneState 的变更转发至顶层 ViewModel，确保 SwiftUI 视图实时刷新
        for pane in panes {
            let c = pane.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            paneCancellables.append(c)
        }

        // 窗口创建时若已指定文件（来自 Finder 打开 / 新建窗口时带文件），
        // 直接加载。此刻 PDFView 还不存在，但模型是权威的 ——
        // makeNSView 会按模型把文档、缩放、页码应用上去。
        if let url = initialFileURL {
            loadPDF(from: url, silently: true)
        }
    }

    var activePane: PaneState {
        panes[min(max(activePaneIndex, 0), panes.count - 1)]
    }

    /// 同步当前激活分屏的缩放百分比、当前页码与总页数到顶层属性
    func syncActivePaneMetrics() {
        let pane = activePane
        // 刻意不在这里从视图回读 scaleFactor：模型是唯一权威来源。
        // 视图侧的缩放变化会经 PDFViewScaleChanged / scaleFactor didSet 进入
        // handleScaleChanged，不需要（也不应该）在这里覆盖模型，
        // 否则 PDFKit 的内部取整会污染模型，造成比例漂移。
        let pct = max(10, min(1000, Int(round(pane.scaleFactor * 100))))
        if activeScalePercentage != pct {
            activeScalePercentage = pct
        }
        if activePageNumber != pane.currentPageNumber {
            activePageNumber = pane.currentPageNumber
        }
        if activePageInputText != pane.pageInputText {
            activePageInputText = pane.pageInputText
        }
        let total = pane.totalPages(fallback: primaryDocument)
        if activeTotalPages != total {
            activeTotalPages = total
        }
    }

    // MARK: - 侧边栏按需开启控制
    func toggleSidebar() {
        showSidebar.toggle()
    }

    func openSidebar(for tab: SidebarTab) {
        sidebarTab = tab
        if !showSidebar {
            showSidebar = true
        }
    }

    // MARK: - 打开 PDF 文件
    func openDocumentPanel(forPaneIndex paneIndex: Int? = nil) {
        let title = paneIndex == nil
            ? "选择要打开的 PDF 文件"
            : "为分屏 #\((paneIndex ?? 0) + 1) 选择 PDF 文件"
        guard let url = PDFOpenPanel.choose(title: title) else { return }
        loadPDF(from: url, intoPane: paneIndex)
    }

    /// 加载 PDF。
    ///
    /// - Parameters:
    ///   - paneIndex: 指定则加载到该分屏（作为对比文档）；nil 则作为本窗口的主文档。
    ///   - silently: 失败时不弹模态框。用于「窗口创建时自动恢复文件」这类场景 ——
    ///     此时弹框会打断启动流程，而且用户并没有主动发起这次打开。
    func loadPDF(from url: URL, intoPane paneIndex: Int? = nil, silently: Bool = false) {
        // 同一份文件被多个窗口打开时复用同一个 PDFDocument 实例
        guard let doc = DocumentStore.shared.document(at: url) else {
            guard !silently else { return }
            let alert = NSAlert()
            alert.messageText = "无法打开 PDF 文件"
            alert.informativeText = "文件可能已损坏或受密码保护：\(url.lastPathComponent)"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        if let targetPaneIdx = paneIndex, targetPaneIdx > 0 {
            let pane = panes[targetPaneIdx]
            pane.customDocument = doc
            pane.customFileName = url.lastPathComponent
            pane.customFileURL = url
            pane.currentPageNumber = 1
            pane.pageInputText = "1"
            pane.scaleFactor = 1.0
            pane.livePDFView?.document = doc
            pane.livePDFView?.autoScales = false
            pane.livePDFView?.scaleFactor = 1.0
            activePaneIndex = targetPaneIdx
            syncActivePaneMetrics()
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                performSearch(animateSelection: false)
            }
            WindowRegistry.shared.sweepDocuments(alsoKeeping: [url])
            return
        }

        // 加载为主文档
        primaryDocument = doc
        primaryFileURL = url
        primaryFileName = url.lastPathComponent
        outlineNodes = OutlineNode.buildTree(from: doc.outlineRoot, in: doc)

        // 重置搜索
        clearSearch()

        // 更新所有未绑定独立文档的分屏，默认以 100% (scaleFactor = 1.0) 清晰展示并支持平滑加减缩放
        for (idx, pane) in panes.enumerated() {
            if pane.customDocument == nil {
                pane.livePDFView?.document = doc
                let initialPageIdx = min(idx, max(doc.pageCount - 1, 0))
                if let page = doc.page(at: initialPageIdx) {
                    pane.livePDFView?.go(to: page)
                }
                pane.currentPageNumber = initialPageIdx + 1
                pane.pageInputText = "\(initialPageIdx + 1)"
                pane.scaleFactor = 1.0
                pane.livePDFView?.autoScales = false
                pane.livePDFView?.scaleFactor = 1.0
            }
        }

        syncActivePaneMetrics()

        if layoutMode == .autoByZoom {
            let currentScale = activePane.livePDFView?.scaleFactor ?? 1.0
            applySmartZoomLayout(forScale: currentScale, force: true)
        }

        // 换文档后，旧文档若已无人使用则从共享缓存中回收。
        // 注意要把刚装上的这份也标为「在用」——此刻本窗口可能还没登记进登记表。
        WindowRegistry.shared.sweepDocuments(alsoKeeping: [url])
    }

    func clearCustomDocument(inPane paneIndex: Int) {
        guard paneIndex >= 0 && paneIndex < panes.count else { return }
        let pane = panes[paneIndex]
        pane.customDocument = nil
        pane.customFileName = nil
        pane.customFileURL = nil
        pane.livePDFView?.document = primaryDocument
        if let doc = primaryDocument {
            let pageIdx = min(max(panes[0].currentPageNumber - 1 + paneIndex, 0), max(doc.pageCount - 1, 0))
            if let page = doc.page(at: pageIdx) {
                pane.livePDFView?.go(to: page)
            }
            pane.currentPageNumber = pageIdx + 1
            pane.pageInputText = "\(pageIdx + 1)"
        }
        syncActivePaneMetrics()
    }

    // MARK: - 缩放控制 (放大 / 缩小 / 自适应宽度 / 实际大小)
    /// PDFView 允许的缩放区间，与 PDFKitRepresentedView 中设置的 min/max 保持一致
    static let minZoomScale: CGFloat = 0.25
    static let maxZoomScale: CGFloat = 5.0

    func zoomIn() {
        stepZoom(by: 1.15)
    }

    func zoomOut() {
        stepZoom(by: 1 / 1.15)
    }

    /// 统一的步进缩放：读取**当前真正可见**视图的比例作为基准，
    /// 避免读到已脱钩视图（或模型与视图不一致）导致的「点了没反应」。
    private func stepZoom(by factor: CGFloat) {
        let pane = activePane
        let current = pane.livePDFView?.scaleFactor ?? pane.scaleFactor
        guard current > 0 else { return }
        let stepped = factor > 1
            ? round((current + 0.15) * 20) / 20
            : round((current - 0.15) * 20) / 20
        let target = factor > 1
            ? min(max(stepped, current * 1.12), Self.maxZoomScale)
            : max(min(stepped, current / 1.12), Self.minZoomScale)
        applyZoomScale(target, toPaneIndex: activePaneIndex)
    }

    func resetZoomToActualSize() {
        applyZoomScale(1.0, toPaneIndex: activePaneIndex)
    }

    func zoomToFit() {
        let pane = activePane
        guard let pdfView = pane.livePDFView else {
            // 视图尚未就绪时不要静默失败：至少把模型对齐到 100%，
            // 视图创建时（makeNSView）会按模型重新应用。
            applyZoomScale(1.0, toPaneIndex: activePaneIndex)
            return
        }
        pdfView.autoScales = true
        pdfView.layoutDocumentView()
        let fittedScale = pdfView.scaleFactor > 0 ? pdfView.scaleFactor : 1.0
        pdfView.autoScales = false
        applyZoomScale(fittedScale, toPaneIndex: activePaneIndex)
    }

    func applyZoomScale(_ newScale: CGFloat, toPaneIndex paneIndex: Int) {
        guard paneIndex >= 0 && paneIndex < panes.count, newScale > 0 else { return }
        let clamped = min(max(newScale, Self.minZoomScale), Self.maxZoomScale)
        let pane = panes[paneIndex]

        // 1) 模型先行：即使此刻视图不可用，状态也是正确的，
        //    后续 makeNSView / updateNSView 会据此把视图纠正回来。
        pane.scaleFactor = clamped

        // 2) 再作用于当前真正可见的视图
        if let pdfView = pane.livePDFView {
            pane.isApplyingProgrammaticScale = true
            pdfView.autoScales = false
            pdfView.scaleFactor = clamped
            pdfView.layoutDocumentView()
            let target = pane
            DispatchQueue.main.async { target.isApplyingProgrammaticScale = false }
        }

        // 3) 顶栏百分比等派生状态必须立即跟上（这里不走 handleScaleChanged，
        //    否则会被上面的抑制标志挡掉）
        applyScaleMetrics(paneIndex: paneIndex, scale: clamped)
    }

    // MARK: - 分屏与智能缩放判断
    private func handleLayoutModeChanged() {
        switch layoutMode {
        case .autoByZoom:
            let scale = activePane.livePDFView?.scaleFactor ?? activePane.scaleFactor
            applySmartZoomLayout(forScale: scale, force: true)
        case .single:
            setVisiblePanes(1)
            setDisplayModeForAllPanes(.singlePageContinuous)
        case .dual:
            setVisiblePanes(2)
        case .triple:
            setVisiblePanes(3)
        case .quad:
            setVisiblePanes(4)
        }
        syncActivePaneMetrics()
    }

    func setVisiblePanes(_ count: Int) {
        let clamped = min(max(count, 1), 4)
        let oldCount = visiblePaneCount
        visiblePaneCount = clamped
        if activePaneIndex >= clamped {
            activePaneIndex = clamped - 1
        }
        if clamped > oldCount, let doc = primaryDocument {
            let basePage = panes[0].currentPageNumber
            for idx in oldCount..<clamped {
                let pane = panes[idx]
                if pane.customDocument == nil {
                    let targetIdx = min(max(basePage - 1 + idx, 0), max(doc.pageCount - 1, 0))
                    pane.currentPageNumber = targetIdx + 1
                    pane.pageInputText = "\(targetIdx + 1)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if let page = doc.page(at: targetIdx) {
                            pane.livePDFView?.go(to: page)
                        }
                    }
                }
            }
        }
    }

    func setDisplayModeForAllPanes(_ mode: PDFDisplayMode) {
        isPerformingProgrammaticLayoutChange = true
        for pane in panes {
            pane.displayMode = mode
            if pane.livePDFView?.displayMode != mode {
                pane.livePDFView?.displayMode = mode
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.isPerformingProgrammaticLayoutChange = false
        }
    }

    func handleScaleChanged(paneIndex: Int, scale: CGFloat) {
        guard paneIndex >= 0 && paneIndex < panes.count, scale > 0 else { return }
        let pane = panes[paneIndex]

        // 由本类自己程序化设置缩放时，PDFKit 会回吐一个被它内部「取整/夹取」过的值。
        // 若照单全收，会出现「切一次分屏，缩放比例就自己变一点」的漂移。
        // 因此程序化设置期间忽略回声，模型保持权威。
        // 注意：本方法只用于处理「来自 PDFKit 的回声」，程序化设置请直接调用
        // applyScaleMetrics，否则会把顶栏百分比一起挡掉。
        if pane.isApplyingProgrammaticScale {
            return
        }

        applyScaleMetrics(paneIndex: paneIndex, scale: scale)
    }

    /// 真正把缩放值落到模型与顶栏显示上
    private func applyScaleMetrics(paneIndex: Int, scale: CGFloat) {
        panes[paneIndex].scaleFactor = scale
        if paneIndex == activePaneIndex {
            let pct = max(10, min(1000, Int(round(scale * 100))))
            if activeScalePercentage != pct {
                activeScalePercentage = pct
            }
        }

        guard layoutMode == .autoByZoom, !isPerformingProgrammaticLayoutChange else { return }

        smartZoomWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.applySmartZoomLayout(forScale: scale, force: false)
            }
        }
        smartZoomWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    /// 根据当前缩放比例智能判断单屏/双屏/多屏与单双页排布
    func applySmartZoomLayout(forScale scale: CGFloat, force: Bool) {
        guard layoutMode == .autoByZoom else { return }

        let highThreshold: CGFloat = 1.15
        let lowThreshold: CGFloat = 0.72

        switch smartZoomStrategy {
        case .adaptivePanesAndColumns:
            if scale >= highThreshold {
                smartStatusLabel = "自适应: 放大单屏精读"
                if visiblePaneCount != 1 || force { setVisiblePanes(1) }
                setDisplayModeForAllPanes(.singlePageContinuous)
            } else if scale >= lowThreshold {
                smartStatusLabel = "自适应: 中等双屏对照"
                if visiblePaneCount != 2 || force { setVisiblePanes(2) }
                setDisplayModeForAllPanes(.singlePageContinuous)
            } else {
                smartStatusLabel = "自适应: 缩小三屏概览"
                if visiblePaneCount != 3 || force { setVisiblePanes(3) }
                setDisplayModeForAllPanes(.twoUpContinuous)
            }

        case .adaptiveColumnsOnly:
            if visiblePaneCount != 1 && force { setVisiblePanes(1) }
            if scale >= 1.05 {
                smartStatusLabel = "自适应: 单页连续"
                setDisplayModeForAllPanes(.singlePageContinuous)
            } else {
                smartStatusLabel = "自适应: 双页并排"
                setDisplayModeForAllPanes(.twoUpContinuous)
            }

        case .adaptivePanesOnly:
            setDisplayModeForAllPanes(.singlePageContinuous)
            if scale >= highThreshold {
                smartStatusLabel = "自适应: 单屏 (1屏)"
                if visiblePaneCount != 1 || force { setVisiblePanes(1) }
            } else if scale >= lowThreshold {
                smartStatusLabel = "自适应: 双屏 (2屏)"
                if visiblePaneCount != 2 || force { setVisiblePanes(2) }
            } else {
                smartStatusLabel = "自适应: 三屏 (3屏)"
                if visiblePaneCount != 3 || force { setVisiblePanes(3) }
            }
        }
    }

    // MARK: - 页面跳转与同步
    func goToPreviousPage(inPane paneIndex: Int? = nil) {
        let idx = paneIndex ?? activePaneIndex
        guard let pdfView = panes[idx].livePDFView, pdfView.canGoToPreviousPage else { return }
        pdfView.goToPreviousPage(nil)
    }

    func goToNextPage(inPane paneIndex: Int? = nil) {
        let idx = paneIndex ?? activePaneIndex
        guard let pdfView = panes[idx].livePDFView, pdfView.canGoToNextPage else { return }
        pdfView.goToNextPage(nil)
    }

    /// 跳转到指定页码。
    /// 注意顺序：**先更新模型，再驱动视图** —— 这样即使此刻视图不可用（正在重建、
    /// 或尚未挂到窗口上），页码状态也是正确的，视图就绪后会自行纠正到该页，
    /// 不会出现「点了页码没反应」。
    func jumpToPage(number: Int, inPane paneIndex: Int? = nil) {
        let idx = paneIndex ?? activePaneIndex
        guard idx >= 0 && idx < panes.count else { return }
        let pane = panes[idx]
        guard let doc = pane.activeDocument(fallback: primaryDocument),
              doc.pageCount > 0 else { return }

        let clampedPage = min(max(number, 1), doc.pageCount)

        pane.currentPageNumber = clampedPage
        pane.pageInputText = "\(clampedPage)"
        if idx == activePaneIndex {
            activePageNumber = clampedPage
            activePageInputText = "\(clampedPage)"
        }

        guard let pdfView = pane.livePDFView,
              let targetPage = doc.page(at: clampedPage - 1) else { return }
        pdfView.go(to: targetPage)
    }

    /// 点击大纲条目跳转。真实大纲与「无大纲时生成的快速页码」共用此逻辑。
    func jumpToOutline(_ node: OutlineNode) {
        let pane = activePane
        guard let pdfView = pane.livePDFView,
              let doc = pane.activeDocument(fallback: primaryDocument) else {
            // 视图不可用：至少把页码模型对齐，视图就绪后自动跳到该页
            if let pageNum = node.pageNumber {
                jumpToPage(number: pageNum)
            }
            return
        }

        if let destination = node.destination {
            pdfView.go(to: destination)
            if let page = destination.page {
                let idx = doc.index(for: page)
                if idx != NSNotFound && idx >= 0 {
                    pane.currentPageNumber = idx + 1
                    pane.pageInputText = "\(idx + 1)"
                    if pane.id == activePaneIndex {
                        activePageNumber = idx + 1
                        activePageInputText = "\(idx + 1)"
                    }
                }
            }
        } else if let pageNum = node.pageNumber,
                  let page = doc.page(at: min(max(pageNum - 1, 0), doc.pageCount - 1)) {
            pdfView.go(to: page)
            pane.currentPageNumber = pageNum
            pane.pageInputText = "\(pageNum)"
            if pane.id == activePaneIndex {
                activePageNumber = pageNum
                activePageInputText = "\(pageNum)"
            }
        }
    }

    func handlePageChanged(paneIndex: Int, newPageNumber: Int) {
        guard paneIndex >= 0 && paneIndex < panes.count else { return }
        let pane = panes[paneIndex]
        if pane.currentPageNumber != newPageNumber {
            pane.currentPageNumber = newPageNumber
        }
        if pane.pageInputText != "\(newPageNumber)" {
            pane.pageInputText = "\(newPageNumber)"
        }
        if paneIndex == activePaneIndex {
            activePageNumber = newPageNumber
            activePageInputText = "\(newPageNumber)"
        }

        if syncPanesScrolling && paneIndex == 0, let doc = primaryDocument {
            for idx in 1..<visiblePaneCount {
                let otherPane = panes[idx]
                if otherPane.customDocument == nil {
                    let targetPage = min(max(newPageNumber + idx, 1), doc.pageCount)
                    if otherPane.currentPageNumber != targetPage,
                       let pageObj = doc.page(at: targetPage - 1) {
                        otherPane.livePDFView?.go(to: pageObj)
                    }
                }
            }
        }
    }

    // MARK: - 实时搜索与结果导航
    private func handleSearchQueryChanged(oldValue: String) {
        guard searchQuery != oldValue else { return }
        searchDebounceWorkItem?.cancel()

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSearchResultsOnly()
            return
        }

        // 80ms 轻量防抖：保证输入变化后立即更新匹配项与高亮
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.performSearch(animateSelection: false)
            }
        }
        searchDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    /// 当在搜索框按回车时：若实时搜索已完成则直接跳转到下一个匹配项；否则立即执行搜索
    func handleSearchSubmit() {
        searchDebounceWorkItem?.cancel()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSearchResultsOnly()
            return
        }
        if trimmed != lastSearchedQuery {
            performSearch(animateSelection: true)
        } else if !searchResults.isEmpty {
            selectNextSearchResult()
        }
    }

    func performSearch(animateSelection: Bool = false) {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let doc = activePane.activeDocument(fallback: primaryDocument) else {
            clearSearchResultsOnly()
            return
        }

        lastSearchedQuery = trimmed
        let selections = doc.findString(trimmed, withOptions: [.caseInsensitive])
        var items: [SearchResultItem] = []

        for (i, sel) in selections.enumerated() {
            sel.color = NSColor.systemYellow.withAlphaComponent(0.55)
            let page = sel.pages.first
            let pageIdx = page.map { doc.index(for: $0) } ?? 0
            let pageNum = (pageIdx != NSNotFound && pageIdx >= 0) ? (pageIdx + 1) : 1

            let snippet = Self.makeSnippet(for: sel, on: page)
            items.append(SearchResultItem(
                index: i,
                selection: sel,
                pageNumber: pageNum,
                snippet: snippet
            ))
        }

        searchResults = items

        // 关键修复：当 selections 为空 (0 匹配) 时，必须先将 highlightedSelections 设为 nil 并强制刷新视图，
        // 不能直接赋空数组 []（PDFKit 中赋 [] 不会清除上一轮残留的高亮图层）
        for pane in panes {
            if pane.activeDocument(fallback: primaryDocument) === doc,
               let pdfView = pane.livePDFView {
                clearPDFViewHighlights(pdfView)
                if !selections.isEmpty {
                    pdfView.highlightedSelections = selections
                }
                forceRedrawPDFView(pdfView)
            }
        }

        if !items.isEmpty {
            selectSearchResult(at: 0, animate: animateSelection)
            if showSidebar {
                sidebarTab = .search
            }
        } else {
            currentSearchIndex = -1
        }
    }

    func selectNextSearchResult() {
        guard !searchResults.isEmpty else {
            performSearch(animateSelection: true)
            return
        }
        let next = (currentSearchIndex + 1) % searchResults.count
        selectSearchResult(at: next, animate: true)
    }

    func selectPreviousSearchResult() {
        guard !searchResults.isEmpty else {
            performSearch(animateSelection: true)
            return
        }
        let prev = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
        selectSearchResult(at: prev, animate: true)
    }

    func selectSearchResult(at index: Int, animate: Bool = true) {
        guard index >= 0 && index < searchResults.count else { return }
        currentSearchIndex = index
        let item = searchResults[index]
        guard let pdfView = activePane.livePDFView else { return }
        pdfView.go(to: item.selection)
        pdfView.setCurrentSelection(item.selection, animate: animate)
    }

    func clearSearch(keepQuery: Bool = false) {
        searchDebounceWorkItem?.cancel()
        if !keepQuery && !searchQuery.isEmpty {
            searchQuery = ""
        }
        clearSearchResultsOnly()
    }

    private func clearSearchResultsOnly() {
        lastSearchedQuery = ""
        searchResults = []
        currentSearchIndex = -1
        for pane in panes {
            if let pdfView = pane.livePDFView {
                clearPDFViewHighlights(pdfView)
                forceRedrawPDFView(pdfView)
            }
        }
    }

    /// 彻底清除 PDFView 的高亮选区与当前选中状态
    private func clearPDFViewHighlights(_ pdfView: PDFView) {
        pdfView.highlightedSelections = nil
        pdfView.setCurrentSelection(nil, animate: false)
        pdfView.clearSelection()
    }

    /// 强制递归刷新 PDFView 及其内部页面图层，避免残留上一次的高亮染色
    private func forceRedrawPDFView(_ pdfView: PDFView) {
        pdfView.needsDisplay = true
        if let docView = pdfView.documentView {
            docView.needsDisplay = true
            Self.invalidateSubviews(of: docView)
        }
    }

    private static func invalidateSubviews(of view: NSView) {
        view.needsDisplay = true
        for sub in view.subviews {
            invalidateSubviews(of: sub)
        }
    }

    private static func makeSnippet(for selection: PDFSelection, on page: PDFPage?) -> String {
        let matchText = selection.string?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pageText = page?.string else { return matchText }
        let singleLinePage = pageText.replacingOccurrences(of: "\n", with: " ")
        if let range = singleLinePage.range(of: matchText, options: .caseInsensitive) {
            let start = singleLinePage.index(range.lowerBound, offsetBy: -24, limitedBy: singleLinePage.startIndex) ?? singleLinePage.startIndex
            let end = singleLinePage.index(range.upperBound, offsetBy: 28, limitedBy: singleLinePage.endIndex) ?? singleLinePage.endIndex
            var snippet = String(singleLinePage[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if start > singleLinePage.startIndex { snippet = "…" + snippet }
            if end < singleLinePage.endIndex { snippet = snippet + "…" }
            return snippet
        }
        return matchText
    }
}
