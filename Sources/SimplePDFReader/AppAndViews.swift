import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - 侧栏尺寸（唯一来源）
//
// 侧栏宽度与 HSplitView 分隔线宽度在这里各定义一次：
//   · SidebarView 用它设置固定宽度；
//   · 开/关侧栏时窗口按 `occupancy` 增减，保证「阅读区宽度不变」。
// 两边同源，所以开→关必然回到原宽度，不会差 1pt 挤出横向滚动条。
enum SidebarMetrics {
    /// 侧栏内容宽度
    static let width: CGFloat = 250
    /// HSplitView 分隔线宽度（实测 1pt）
    static let divider: CGFloat = 1
    /// 侧栏展开时占用的总宽度
    static var occupancy: CGFloat { width + divider }
}

// MARK: - 自定义 PDFView（支持点击激活分屏、实时监听缩放与拖拽打开 PDF）
final class InteractivePDFView: PDFView {
    var onActivatePane: (() -> Void)?
    var onScaleChanged: ((CGFloat) -> Void)?
    var onDropPDF: ((URL) -> Void)?

    override var scaleFactor: CGFloat {
        didSet {
            if scaleFactor > 0 {
                onScaleChanged?(scaleFactor)
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        InteractivePDFView.installScrollZoomMonitorIfNeeded()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        InteractivePDFView.installScrollZoomMonitorIfNeeded()
    }

    // MARK: - ⌘ + 滚轮缩放
    //
    // 为什么不能只重写 scrollWheel：滚动事件由命中测试命中的**最深层视图**接收
    // （PDFView 内部的 PDFDocumentView / 内部 NSScrollView），PDFView 自己的
    // scrollWheel 根本不会被调用 —— 于是 ⌘+滚轮 只会被内部滚动视图当成普通翻页。
    // 因此改用「本地事件监视器」：在事件分发前拦截，再按光标位置找回对应的 PDFView。
    private static var didInstallScrollZoomMonitor = false

    static func installScrollZoomMonitorIfNeeded() {
        guard !didInstallScrollZoomMonitor else { return }
        didInstallScrollZoomMonitor = true
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            InteractivePDFView.handleCommandScrollZoomEvent(event) ? nil : event
        }
    }

    private static func handleCommandScrollZoomEvent(_ event: NSEvent) -> Bool {
        let commandHeld = event.modifierFlags.contains(.command)
            || NSEvent.modifierFlags.contains(.command)
        guard commandHeld,
              let window = event.window,
              let content = window.contentView else { return false }

        let point = content.convert(event.locationInWindow, from: nil)
        guard let hit = content.hitTest(point) else { return false }

        var node: NSView? = hit
        while let current = node {
            if let pdfView = current as? InteractivePDFView {
                // 惯性滑行不再缩放，但同样要吃掉，避免缩放刚结束就接着翻页
                if event.momentumPhase.isEmpty {
                    pdfView.applyCommandScrollZoom(event)
                }
                return true
            }
            node = current.superview
        }
        return false
    }

    func applyCommandScrollZoom(_ event: NSEvent) {
        guard document != nil else { return }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.0001 else { return }
        onActivatePane?()
        // 精确设备（触控板）按点、非精确设备（鼠标滚轮）按格，两套底数让手感接近
        let factor = event.hasPreciseScrollingDeltas
            ? pow(1.0018, delta)
            : pow(1.12, delta)
        guard factor > 0, abs(factor - 1) > 0.00001 else { return }
        zoomKeepingPointUnderCursor(by: factor,
                                    at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        onActivatePane?()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onActivatePane?()

        // ⌘ + 滚轮 / ⌘ + 双指滑动 = 以光标为中心缩放。
        // 不调用 super：否则同一串事件会既缩放又翻页。
        //
        // 判定同时看事件自带修饰键与「当前键盘状态」：部分输入设备/驱动合成的滚动事件
        // 不会带上 modifiers，只看 event.modifierFlags 会漏判成普通翻页。
        let commandHeld = event.modifierFlags.contains(.command)
            || NSEvent.modifierFlags.contains(.command)
        if commandHeld {
            applyCommandScrollZoom(event)
            return
        }

        super.scrollWheel(with: event)
    }

    /// 缩放并保持 `anchorInView` 处的内容不动（光标锚定）。
    ///
    /// 做法：缩放前记下锚点对应的页面坐标 → 改缩放 → 重新算出该页面坐标落在视图里的
    /// 新位置 → 把内部滚动视图的偏移量反向补偿回去。
    private func zoomKeepingPointUnderCursor(by factor: CGFloat, at anchorInView: NSPoint) {
        guard let page = currentPage else { return }
        let oldScale = scaleFactor
        guard oldScale > 0 else { return }
        let newScale = min(max(oldScale * factor, minScaleFactor), maxScaleFactor)
        guard abs(newScale - oldScale) > 0.0001 else { return }

        let anchorInPage = convert(anchorInView, to: page)

        autoScales = false
        scaleFactor = newScale
        layoutDocumentView()

        // 内部滚动视图拿不到时退化为「以中心缩放」（scaleFactor 已经生效，只是不锚定光标）
        guard let clipView = documentView?.enclosingScrollView?.contentView else {
            if scaleFactor > 0 { onScaleChanged?(scaleFactor) }
            return
        }

        let newAnchorInView = convert(anchorInPage, from: page)
        let dx = newAnchorInView.x - anchorInView.x
        let dy = newAnchorInView.y - anchorInView.y
        if abs(dx) > 0.5 || abs(dy) > 0.5 {
            var origin = clipView.bounds.origin
            origin.x += dx
            origin.y += dy
            clipView.scroll(to: origin)
            documentView?.enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        if scaleFactor > 0 { onScaleChanged?(scaleFactor) }
    }

    override func magnify(with event: NSEvent) {
        onActivatePane?()
        super.magnify(with: event)
        if scaleFactor > 0 {
            onScaleChanged?(scaleFactor)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if extractPDFURL(from: sender) != nil {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let url = extractPDFURL(from: sender) {
            onDropPDF?(url)
            return true
        }
        return super.performDragOperation(sender)
    }

    private func extractPDFURL(from sender: NSDraggingInfo) -> URL? {
        let pboard = sender.draggingPasteboard
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] else {
            return nil
        }
        return urls.first { $0.pathExtension.lowercased() == "pdf" }
    }
}

// MARK: - PDFKit NSViewRepresentable 桥接
struct PDFKitRepresentedView: NSViewRepresentable {
    let paneIndex: Int
    @ObservedObject var pane: PaneState
    @ObservedObject var viewModel: PDFReaderViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(paneIndex: paneIndex, pane: pane, viewModel: viewModel)
    }

    func makeNSView(context: Context) -> InteractivePDFView {
        let pdfView = InteractivePDFView()
        // 顺序很重要：先把 min/max 与 displayMode 定好，再给文档，最后设缩放。
        // 否则 PDFKit 会在设置文档/改动画模式时按自己的规则「取整」当前比例，
        // 表现为「切一次分屏，缩放比例自己变了一点」。
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        // 分页留白只保留「底部 8pt」作为页间间隙：
        //   · 上边距归零 —— 否则第一页顶部会多出一条白边，视口就不再「正好等于一页」；
        //   · 左/右边距归零 —— 否则内容宽度 = 页宽 + 16pt，视口只有页宽时必然出现横向滚动条。
        pdfView.pageBreakMargins = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        pdfView.backgroundColor = NSColor.windowBackgroundColor
        pdfView.minScaleFactor = PDFReaderViewModel.minZoomScale
        pdfView.maxScaleFactor = PDFReaderViewModel.maxZoomScale
        pdfView.autoScales = false
        pdfView.displayMode = pane.displayMode

        let activeIndex = paneIndex
        pdfView.onActivatePane = { [weak viewModel] in
            Task { @MainActor in
                if viewModel?.activePaneIndex != activeIndex {
                    viewModel?.activePaneIndex = activeIndex
                }
            }
        }
        pdfView.onScaleChanged = { [weak viewModel] newScale in
            Task { @MainActor in
                viewModel?.handleScaleChanged(paneIndex: activeIndex, scale: newScale)
            }
        }
        pdfView.onDropPDF = { [weak viewModel] url in
            Task { @MainActor in
                viewModel?.loadPDF(from: url, intoPane: nil)
            }
        }

        // 关键：先把视图登记到 PaneState，再同步状态。
        // 这样即便同步过程中触发了回调，操作也已经指向正确的视图。
        pane.pdfView = pdfView
        context.coordinator.observe(pdfView: pdfView)
        applyModelState(to: pdfView, forcePage: true)

        DispatchQueue.main.async {
            viewModel.syncActivePaneMetrics()
        }
        return pdfView
    }

    func updateNSView(_ pdfView: InteractivePDFView, context: Context) {
        if pane.pdfView !== pdfView {
            pane.pdfView = pdfView
        }
        let documentChanged = pdfView.document !== pane.activeDocument(fallback: viewModel.primaryDocument)
        applyModelState(to: pdfView, forcePage: documentChanged)
        if pdfView.displayMode != pane.displayMode {
            pdfView.displayMode = pane.displayMode
        }
        if documentChanged {
            DispatchQueue.main.async {
                viewModel.syncActivePaneMetrics()
            }
        }
    }

    /// SwiftUI 移除该视图时调用：只有当登记的仍是本视图时才清空，
    /// 避免「新视图已登记、旧视图随后被销毁」时把新引用误清掉。
    static func dismantleNSView(_ pdfView: InteractivePDFView, coordinator: Coordinator) {
        if coordinator.pane.pdfView === pdfView {
            coordinator.pane.pdfView = nil
        }
    }

    /// 把模型状态（文档 / 缩放 / 页码）同步到视图。
    ///
    /// 设计原则：**模型是唯一权威，视图只负责跟随**。这样无论 SwiftUI 何时重建视图
    /// （切换分屏、开关侧栏、窗口缩放都可能触发），状态都会自动纠正回来，
    /// 不会出现「操作无效」。
    private func applyModelState(to pdfView: InteractivePDFView, forcePage: Bool) {
        let targetDoc = pane.activeDocument(fallback: viewModel.primaryDocument)
        if pdfView.document !== targetDoc {
            pdfView.document = targetDoc
        }
        pdfView.autoScales = false

        // 缩放：以模型为准。程序化设置期间抑制 PDFKit 的回声，
        // 否则它会把「自己取整后的值」写回模型，造成比例漂移。
        if abs(pdfView.scaleFactor - pane.scaleFactor) > 0.005 {
            pane.isApplyingProgrammaticScale = true
            pdfView.scaleFactor = pane.scaleFactor
            let target = pane
            DispatchQueue.main.async { target.isApplyingProgrammaticScale = false }
        }

        // 页码：仅在「视图新建」或「换了文档」时强制对齐。
        // 不能每次更新都对齐 —— 用户滚动引起的页码变化是异步回写模型的，
        // 每次都强制对齐会把用户的滚动「拽回去」。
        guard forcePage, let doc = targetDoc, doc.pageCount > 0 else { return }
        let targetIdx = min(max(pane.currentPageNumber - 1, 0), max(doc.pageCount - 1, 0))
        if let currentPage = pdfView.currentPage, doc.index(for: currentPage) == targetIdx {
            return
        }
        if let page = doc.page(at: targetIdx) {
            pdfView.go(to: page)
        }
    }

    final class Coordinator: NSObject {
        let paneIndex: Int
        let pane: PaneState
        let viewModel: PDFReaderViewModel
        private var pageObserver: NSObjectProtocol?
        private var scaleObserver: NSObjectProtocol?

        init(paneIndex: Int, pane: PaneState, viewModel: PDFReaderViewModel) {
            self.paneIndex = paneIndex
            self.pane = pane
            self.viewModel = viewModel
        }

        func observe(pdfView: PDFView) {
            let center = NotificationCenter.default
            pageObserver = center.addObserver(
                forName: Notification.Name.PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self, weak pdfView] _ in
                guard let self = self,
                      let pdfView = pdfView,
                      let doc = pdfView.document,
                      let currentPage = pdfView.currentPage else { return }
                let idx = doc.index(for: currentPage)
                if idx != NSNotFound && idx >= 0 {
                    Task { @MainActor in
                        self.viewModel.handlePageChanged(paneIndex: self.paneIndex, newPageNumber: idx + 1)
                    }
                }
            }

            scaleObserver = center.addObserver(
                forName: Notification.Name.PDFViewScaleChanged,
                object: pdfView,
                queue: .main
            ) { [weak self, weak pdfView] _ in
                guard let self = self, let pdfView = pdfView else { return }
                let scale = pdfView.scaleFactor
                Task { @MainActor in
                    self.viewModel.handleScaleChanged(paneIndex: self.paneIndex, scale: scale)
                }
            }
        }

        deinit {
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
        }
    }
}

// MARK: - 单个分屏容器视图
struct PaneContainerView: View {
    let paneIndex: Int
    @ObservedObject var pane: PaneState
    @ObservedObject var viewModel: PDFReaderViewModel

    private var isActive: Bool {
        viewModel.activePaneIndex == paneIndex
    }

    var body: some View {
        VStack(spacing: 0) {
            // 当处于双屏/多屏模式或打开了独立对比文档时，显示自适应分屏状态栏
            if viewModel.visiblePaneCount > 1 || pane.customDocument != nil {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)

                    Text("屏\(paneIndex + 1)")
                        .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? .primary : .secondary)
                        .fixedSize()

                    if let customName = pane.customFileName {
                        Text(customName)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 90)
                    }

                    Spacer(minLength: 2)

                    // 单页 / 双页紧凑切换按钮
                    Button(action: {
                        let nextMode: PDFDisplayMode = (pane.displayMode == .twoUpContinuous) ? .singlePageContinuous : .twoUpContinuous
                        pane.displayMode = nextMode
                        pane.pdfView?.displayMode = nextMode
                    }) {
                        Text(pane.displayMode == .twoUpContinuous ? "双页" : "单页")
                            .font(.system(size: 10.5))
                    }
                    .controlSize(.mini)
                    .help("切换当前分屏单页/双页并排显示")

                    // 当前分屏页码快速跳转
                    HStack(spacing: 2) {
                        Button(action: { viewModel.goToPreviousPage(inPane: paneIndex) }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9.5))
                        }
                        .buttonStyle(.borderless)

                        TextField("", text: $pane.pageInputText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 36)
                            .controlSize(.mini)
                            .multilineTextAlignment(.center)
                            .onSubmit {
                                if let num = Int(pane.pageInputText.trimmingCharacters(in: .whitespaces)) {
                                    viewModel.jumpToPage(number: num, inPane: paneIndex)
                                } else {
                                    pane.pageInputText = "\(pane.currentPageNumber)"
                                }
                            }

                        Text("/\(pane.totalPages(fallback: viewModel.primaryDocument))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .fixedSize()

                        Button(action: { viewModel.goToNextPage(inPane: paneIndex) }) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9.5))
                        }
                        .buttonStyle(.borderless)
                    }

                    Text("\(Int(round(pane.scaleFactor * 100)))%")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize()

                    if paneIndex > 0 {
                        if pane.customDocument != nil {
                            Button("同主档") {
                                viewModel.clearCustomDocument(inPane: paneIndex)
                            }
                            .controlSize(.mini)
                            .help("恢复显示主窗口 PDF")
                        } else {
                            Button("换文件") {
                                viewModel.openDocumentPanel(forPaneIndex: paneIndex)
                            }
                            .controlSize(.mini)
                            .help("在此分屏单独打开另一份对比 PDF")
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor))
                .onTapGesture {
                    viewModel.activePaneIndex = paneIndex
                }

                Divider()
            }

            PDFKitRepresentedView(paneIndex: paneIndex, pane: pane, viewModel: viewModel)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(
                    viewModel.visiblePaneCount > 1 && isActive ? Color.accentColor.opacity(0.6) : Color.clear,
                    lineWidth: 1.5
                )
        )
    }
}

// MARK: - 侧边栏：目录大纲与搜索结果（按需开启，带一键关闭）
struct SidebarView: View {
    @ObservedObject var viewModel: PDFReaderViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("", selection: $viewModel.sidebarTab) {
                    ForEach(SidebarTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                Button(action: {
                    viewModel.showSidebar = false
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭侧边栏 (⌘⇧S)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            Divider()

            if viewModel.sidebarTab == .outline {
                outlineContent
            } else {
                searchContent
            }
        }
        // 固定宽度（不用 min/ideal/max 区间）：
        // HSplitView 根本不采用 idealWidth，只在 [min, max] 内按分栏逻辑分配 ——
        // 首次插入第二个 pane 时按平分算（627/2≈313，被 max 截到 300），
        // 之后插入时已存在 NSSplitView 会保留阅读区原宽，侧栏只拿到剩余 1pt（被 min 抬到 185）。
        // 于是首轮窗口 = 页宽+300，次轮 = 页宽+185，看起来「第一次特别宽」。
        // 钉成单一宽度后两个分支没有可分配的余地，首轮/次轮必然一致；代价是不能拖分隔线。
        .frame(width: SidebarMetrics.width)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var outlineContent: some View {
        if viewModel.primaryDocument == nil {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                Text("打开 PDF 后在此查看目录大纲")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if !viewModel.outlineNodes.isEmpty {
            List(viewModel.outlineNodes, children: \.children) { node in
                Button(action: {
                    viewModel.jumpToOutline(node)
                }) {
                    HStack {
                        Text(node.title)
                            .font(.system(size: 12.5))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        if let page = node.pageNumber {
                            Text("\(page)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
        } else if let doc = viewModel.primaryDocument {
            VStack(alignment: .leading, spacing: 0) {
                Text("该文档无内置大纲，已生成快速页码导航：")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
                List(1...max(doc.pageCount, 1), id: \.self) { pageNum in
                    Button(action: {
                        viewModel.jumpToPage(number: pageNum)
                    }) {
                        HStack {
                            Text("第 \(pageNum) 页")
                                .font(.system(size: 12.5))
                            Spacer()
                            if viewModel.activePageNumber == pageNum {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                Text("在顶部搜索框输入关键词\n即可实时检索全文")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if viewModel.searchResults.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("未找到与“\(viewModel.searchQuery)”匹配的内容")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("共找到 \(viewModel.searchResults.count) 处匹配")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider()

                List(viewModel.searchResults) { item in
                    Button(action: {
                        viewModel.selectSearchResult(at: item.index)
                    }) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("第 \(item.pageNumber) 页")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(viewModel.currentSearchIndex == item.index ? .accentColor : .secondary)
                                Spacer()
                                Text("#\(item.index + 1)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Text(item.snippet)
                                .font(.system(size: 12))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        viewModel.currentSearchIndex == item.index
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear
                    )
                }
                .listStyle(.sidebar)
            }
        }
    }
}

// MARK: - 主窗口内容视图（统一弹出式分屏菜单 + 响应式工具栏）
struct ContentView: View {
    @ObservedObject var viewModel: PDFReaderViewModel
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isPageJumpFocused: Bool
    @State private var windowWidth: CGFloat = 860
    @State private var hostWindow: NSWindow?

    /// 缩放菜单里的固定档位（百分比）
    private static let zoomPresetPercents = [25, 50, 75, 100, 125, 150, 175, 200]

    // 窗口宽度断点：
    // - 宽屏 (>= 590pt)：显示按钮文字，搜索框收进右侧按钮（点开为第二行抽屉）
    // - 中屏 (540 ~ 589pt)：按钮图标化，搜索框同样是按钮
    // - 小窗 (< 540pt)：整体收紧
    //
    // 断点下移的原因：打开 PDF 后视口宽度现在严格等于页宽（A4 ≈ 595pt），
    // 若沿用 760pt 的宽屏断点，页大小窗口里的工具栏会退化成一排纯图标。
    // 但 595pt 放不下「文字 + 175pt 内联搜索框」，所以把两者拆成两个独立断点。
    private var isWideToolbar: Bool { windowWidth >= 590 }
    private var isCompactToolbar: Bool { windowWidth < 540 }
    /// 内联搜索框（约 175pt）只在真正够宽的窗口里显示
    private var showsInlineSearch: Bool { windowWidth >= 760 }
    /// 宽屏用舒展间距，其余收紧，保证 595pt 下按钮文字不被裁切
    private var toolbarSpacing: CGFloat { windowWidth >= 760 ? 10 : 6 }

    var body: some View {
        VStack(spacing: 0) {
            responsiveTopToolbar

            Divider()

            HSplitView {
                if viewModel.showSidebar {
                    SidebarView(viewModel: viewModel)
                }

                mainReadingArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 内容区右上角的「关闭本文档」按钮（详见 closeDocumentButton）
                    .overlay(alignment: .topTrailing) {
                        if viewModel.primaryDocument != nil {
                            closeDocumentButton
                        }
                    }
            }
        }
        .frame(minWidth: 400, minHeight: 360)
        .background(WindowWidthObserver { width in
            if abs(windowWidth - width) > 1 {
                windowWidth = width
            }
        })
        .background(WindowAccessor { window in
            hostWindow = window
        })
        .onChange(of: viewModel.showSidebar) { _ in
            adjustWindowWidthForSidebar()
        }
        .onChange(of: viewModel.focusSearchTrigger) { _ in
            if !showsInlineSearch {
                viewModel.isCompactSearchExpanded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
        .onChange(of: viewModel.focusPageJumpTrigger) { _ in
            isPageJumpFocused = true
        }
    }

    // MARK: - 响应式顶部功能栏
    private var responsiveTopToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: toolbarSpacing) {
                // 1. 左侧：唯一的侧边栏（大纲/搜索）开关按钮 + 打开文件按钮
                HStack(spacing: 5) {
                    Button(action: {
                        viewModel.toggleSidebar()
                    }) {
                        if isWideToolbar {
                            Label("侧栏", systemImage: "sidebar.left")
                        } else {
                            Image(systemName: "sidebar.left")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.showSidebar ? .accentColor : nil)
                    .help("显示/隐藏目录大纲与搜索侧边栏 (⌘⇧S)")

                    Button(action: {
                        viewModel.openDocumentPanel()
                    }) {
                        if isWideToolbar {
                            Label("打开", systemImage: "folder")
                        } else {
                            Image(systemName: "folder")
                        }
                    }
                    .help("打开 PDF 文件 (⌘O) · 未打开则在新窗口打开，已打开则切到那个窗口")
                }
                .fixedSize()

                Divider().frame(height: 16)

                // 2. 缩放控制组（缩小 / 缩放比例菜单 / 放大）
                HStack(spacing: 3) {
                    Button(action: { viewModel.zoomOut() }) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("缩小 15% (⌘-)")
                    .disabled(viewModel.primaryDocument == nil)

                    zoomPopupMenu

                    Button(action: { viewModel.zoomIn() }) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("放大 15% (⌘+)")
                    .disabled(viewModel.primaryDocument == nil)
                }
                .fixedSize()

                Divider().frame(height: 16)

                // 3. 一级分屏菜单（单屏 / 双屏 / 三屏 / 四屏 / 自适应分屏）
                layoutPopupMenu
                    .fixedSize()

                Divider().frame(height: 16)

                // 4. 页码跳转组
                pageJumpGroup
                    .fixedSize()

                Spacer(minLength: 2)

                // 5. 右侧实时搜索框（窗口不够宽时收成按钮 + 第二行抽屉）
                if showsInlineSearch {
                    inlineSearchBar(maxFieldWidth: 175)
                } else {
                    compactSearchToggleButton
                }
            }
            .padding(.horizontal, windowWidth >= 760 ? 12 : 8)
            .padding(.vertical, 7)

            // 窗口放不下内联搜索框时，按需展开的第二行搜索栏
            if !showsInlineSearch && (viewModel.isCompactSearchExpanded || !viewModel.searchQuery.isEmpty) {
                Divider()
                HStack(spacing: 6) {
                    inlineSearchBar(maxFieldWidth: .infinity)

                    Button(action: {
                        viewModel.isCompactSearchExpanded = false
                    }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("收起搜索栏")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 缩放比例菜单（预设档位 + 自适应 + 自定义）
    //
    // 标签仍实时显示当前百分比：捏合缩放 / ⌘滚轮 / ⌘= 之后用户依然能一眼看到比例，
    // 只是点击行为从「恢复 100%」变成了「展开菜单」。
    private var zoomPopupMenu: some View {
        Menu {
            ForEach(Self.zoomPresetPercents, id: \.self) { percent in
                Toggle("\(percent)%", isOn: zoomPresetBinding(percent))
                    .disabled(viewModel.primaryDocument == nil)
            }

            Divider()

            Button(action: { viewModel.zoomToFit() }) {
                Label("自适应（窗口宽度）", systemImage: "arrow.left.and.right.square")
            }
            .disabled(viewModel.primaryDocument == nil)

            Divider()

            Button(action: presentCustomZoomPanel) {
                Label("自定义…", systemImage: "slider.horizontal.3")
            }
            .disabled(viewModel.primaryDocument == nil)
        } label: {
            // 注意：Menu 的 label 里「文字之后的独立 Image 视图」会被系统当成菜单图标
            // 挪到最前面，所以箭头必须用 Text(Image(...)) 内联进同一段 Text：
            // 它参与文字基线布局，既不会跑位，也能跟着字号缩放、与文字垂直居中。
            (
                Text("\(viewModel.activeScalePercentage)% ")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                + Text(Image(systemName: "chevron.down"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            )
        }
        // 用 .menuStyle(.button) + .buttonStyle(.bordered)：系统默认的 Menu 样式
        // 在窗口激活时会把胶囊填充成蓝色，而 .bordered 按钮是中性灰，与 v1.9.1 一致。
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .help("当前缩放比例 \(viewModel.activeScalePercentage)% · 点击选择档位、自适应或自定义 (⌘0 恢复 100%)")
    }

    /// 菜单里勾选状态与缩放档位一一对应；当前比例不是预设值时（如 115%）则都不打勾
    private func zoomPresetBinding(_ percent: Int) -> Binding<Bool> {
        Binding(
            get: { viewModel.activeScalePercentage == percent },
            set: { isOn in
                if isOn { viewModel.zoom(toPercent: percent) }
            }
        )
    }

    private func presentCustomZoomPanel() {
        let parent = WindowPlacement.frontWindow(owning: viewModel)
        guard let percent = ZoomInputPanel.present(currentPercent: viewModel.activeScalePercentage,
                                                   parent: parent) else { return }
        viewModel.zoom(toPercent: percent)
    }

    // MARK: - 一级分屏菜单（单屏 / 双屏 / 三屏 / 四屏 / 自适应分屏）
    //
    // 刻意保持「一级」：不再有「分屏模式 >」这样的子菜单，也没有 Section 标题，
    // 全部是平级项。缩放相关的「自适应宽度 / 恢复 100%」已移到缩放比例菜单里。
    private var layoutPopupMenu: some View {
        Menu {
            ForEach(SplitLayoutMode.allCases) { mode in
                Toggle(isOn: layoutModeBinding(mode)) {
                    Label(mode.rawValue, systemImage: mode.symbolName)
                }
            }

            // 自适应分屏策略与多屏联动目前只有这一个入口，
            // 因此仍然放在同一级菜单里（不设子菜单），仅在对应场景下出现。
            if viewModel.layoutMode == .autoByZoom {
                Divider()
                ForEach(SmartZoomStrategy.allCases) { strategy in
                    Toggle("策略：\(strategy.rawValue)", isOn: smartStrategyBinding(strategy))
                }
            }

            if viewModel.visiblePaneCount > 1 {
                Divider()
                Toggle("多屏联动顺延翻页", isOn: $viewModel.syncPanesScrolling)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.layoutMode.symbolName)
                // 同缩放菜单：箭头用 Text(Image(...)) 内联拼接，避免被当成菜单图标挪到最左侧
                (
                    Text(viewModel.layoutMode.rawValue + " ")
                        .font(.system(size: 11.5))
                    + Text(Image(systemName: "chevron.down"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                )
            }
        }
        // 同上：中性灰胶囊，避免系统默认样式在窗口激活时变蓝
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .help("点击弹出菜单：切换单屏/双屏/三屏/四屏/自适应模式")
    }

    private func layoutModeBinding(_ mode: SplitLayoutMode) -> Binding<Bool> {
        Binding(
            get: { viewModel.layoutMode == mode },
            set: { isOn in
                if isOn { viewModel.layoutMode = mode }
            }
        )
    }

    private func smartStrategyBinding(_ strategy: SmartZoomStrategy) -> Binding<Bool> {
        Binding(
            get: { viewModel.smartZoomStrategy == strategy },
            set: { isOn in
                if isOn { viewModel.smartZoomStrategy = strategy }
            }
        )
    }

    // MARK: - 侧边栏展开 / 收起时窗口同步加宽 / 收窄
    //
    // 语义：**在用户当前的窗口宽度上增减侧栏占位**，不重新计算「第一页 100%」。
    // 用户把窗口拖到任意宽度后开侧栏，页面显示区宽度应当保持不变；关掉再原样退回。
    // 若改成调 PageFitSizer，就会把窗口强行改回「页宽 + 侧栏」，用户手动调过的宽度被覆盖。
    //
    // 实现：展开时窗口 + `SidebarMetrics.occupancy`，收起时 - 同一个值。
    // 因为侧栏是固定宽度、分隔线也是固定 1pt，这个值就是侧栏真实占用的宽度，
    // 加多少减多少完全对称 —— 用户拖到任意宽度后开合，都会精确回到原宽度。
    private func adjustWindowWidthForSidebar() {
        guard let window = hostWindow ?? WindowPlacement.frontWindow(owning: viewModel) else { return }
        let expanding = viewModel.showSidebar
        // 等 HSplitView 完成一次布局再动窗口，避免和插入/移除抢同一帧
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            var frame = window.frame
            let delta = expanding ? SidebarMetrics.occupancy : -SidebarMetrics.occupancy
            let newWidth = max(frame.width + delta, window.minSize.width)
            guard abs(newWidth - frame.width) > 0.5 else { return }
            // 只改宽度、保持左上角不动
            frame.size.width = newWidth
            window.setFrame(frame, display: true)
        }
    }

    // MARK: - 页码跳转组
    private var pageJumpGroup: some View {
        HStack(spacing: 3) {
            Button(action: { viewModel.goToPreviousPage() }) {
                Image(systemName: "chevron.up")
            }
            .help("上一页 (⌘↑)")
            .disabled(viewModel.primaryDocument == nil)

            TextField("页", text: Binding(
                get: { viewModel.activePageInputText },
                set: { newVal in
                    viewModel.activePageInputText = newVal
                    viewModel.activePane.pageInputText = newVal
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: isCompactToolbar ? 38 : 44)
            .multilineTextAlignment(.center)
            .focused($isPageJumpFocused)
            .onSubmit {
                let raw = viewModel.activePageInputText.trimmingCharacters(in: .whitespaces)
                if let pageNum = Int(raw) {
                    viewModel.jumpToPage(number: pageNum)
                } else {
                    viewModel.activePageInputText = "\(viewModel.activePageNumber)"
                }
            }
            .disabled(viewModel.primaryDocument == nil)

            Text(isWideToolbar
                 ? "/ \(viewModel.activeTotalPages) 页"
                 : "/\(viewModel.activeTotalPages)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(.secondary)

            Button(action: { viewModel.goToNextPage() }) {
                Image(systemName: "chevron.down")
            }
            .help("下一页 (⌘↓)")
            .disabled(viewModel.primaryDocument == nil)
        }
    }

    // MARK: - 搜索栏组件（实时搜索，回车跳下一个匹配项）
    private var compactSearchToggleButton: some View {
        Button(action: {
            viewModel.isCompactSearchExpanded.toggle()
            if viewModel.isCompactSearchExpanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isSearchFocused = true
                }
            }
        }) {
            HStack(spacing: 3) {
                Image(systemName: "magnifyingglass")
                if !viewModel.searchResults.isEmpty {
                    Text("\(viewModel.currentSearchIndex + 1)/\(viewModel.searchResults.count)")
                        .font(.system(size: 10, design: .monospaced))
                }
            }
        }
        .buttonStyle(.bordered)
        .tint((viewModel.isCompactSearchExpanded || !viewModel.searchQuery.isEmpty) ? .accentColor : nil)
        .help("展开/收起全文搜索栏 (⌘F)")
    }

    private func inlineSearchBar(maxFieldWidth: CGFloat) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11.5))

                TextField("搜索 (⌘F)…", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(minWidth: 70, maxWidth: maxFieldWidth)
                    .focused($isSearchFocused)
                    .onSubmit {
                        viewModel.handleSearchSubmit()
                    }

                if !viewModel.searchResults.isEmpty {
                    Text("\(viewModel.currentSearchIndex + 1)/\(viewModel.searchResults.count)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize()
                } else if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("0/0")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize()
                }

                if !viewModel.searchQuery.isEmpty {
                    Button(action: { viewModel.clearSearch() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )

            Button(action: { viewModel.selectPreviousSearchResult() }) {
                Image(systemName: "chevron.left")
            }
            .help("上一个匹配项 (⇧⌘G)")
            .disabled(viewModel.searchResults.isEmpty)

            Button(action: { viewModel.selectNextSearchResult() }) {
                Image(systemName: "chevron.right")
            }
            .help("下一个匹配项 (⌘G 或回车)")
            .disabled(viewModel.searchResults.isEmpty)
        }
    }

    // MARK: - 内容区右上角「关闭本文档」按钮
    //
    // 与窗口左上角的系统关闭按钮（红点）不是一回事：
    //   · 系统红点 → 关闭整个窗口（本窗口最后一个窗口时应用随之退出）；
    //   · 本按钮   → 只关掉本窗口里打开的文档，窗口留着并回到空白状态，
    //                随时可以再拖一份 PDF 进来；其他窗口完全不受影响。
    private var closeDocumentButton: some View {
        Button(action: { viewModel.closeDocument() }) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 19, height: 19)
                .background(
                    Circle().fill(Color(NSColor.controlBackgroundColor).opacity(0.9))
                )
                .overlay(
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("关闭本文档（不关闭窗口，也不影响其他窗口）⌥⌘W")
        // 与右侧垂直滚动条保持距离：PDFView 的垂直滚动条占据阅读区右缘约 11~15pt
        // （叠加式 / 经典式宽度不同），按钮从前只留 10pt，圆边正好压在滚动条上。
        // 现留出 30pt，按钮右缘与滚动条左缘之间至少还有 15pt 净距，两种样式都不会再碰。
        // 多屏模式下每个分屏顶部有一条状态栏，按钮还要落在它下面，避免压住「换文件」等按钮
        .padding(.top, viewModel.visiblePaneCount > 1 ? 34 : 8)
        .padding(.trailing, 30)
    }

    // MARK: - 主阅读区（支持 1 / 2 / 3 / 4 分屏与空状态）
    @ViewBuilder
    private var mainReadingArea: some View {
        if viewModel.primaryDocument == nil {
            emptyStateView
        } else {
            switch viewModel.visiblePaneCount {
            case 1:
                PaneContainerView(paneIndex: 0, pane: viewModel.panes[0], viewModel: viewModel)
            case 2:
                HSplitView {
                    PaneContainerView(paneIndex: 0, pane: viewModel.panes[0], viewModel: viewModel)
                        .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                    PaneContainerView(paneIndex: 1, pane: viewModel.panes[1], viewModel: viewModel)
                        .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                }
            case 3:
                HSplitView {
                    PaneContainerView(paneIndex: 0, pane: viewModel.panes[0], viewModel: viewModel)
                        .frame(minWidth: 130, maxWidth: .infinity, maxHeight: .infinity)
                    PaneContainerView(paneIndex: 1, pane: viewModel.panes[1], viewModel: viewModel)
                        .frame(minWidth: 130, maxWidth: .infinity, maxHeight: .infinity)
                    PaneContainerView(paneIndex: 2, pane: viewModel.panes[2], viewModel: viewModel)
                        .frame(minWidth: 130, maxWidth: .infinity, maxHeight: .infinity)
                }
            default:
                VSplitView {
                    HSplitView {
                        PaneContainerView(paneIndex: 0, pane: viewModel.panes[0], viewModel: viewModel)
                            .frame(minWidth: 150, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                        PaneContainerView(paneIndex: 1, pane: viewModel.panes[1], viewModel: viewModel)
                            .frame(minWidth: 150, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                    }
                    HSplitView {
                        PaneContainerView(paneIndex: 2, pane: viewModel.panes[2], viewModel: viewModel)
                            .frame(minWidth: 150, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                        PaneContainerView(paneIndex: 3, pane: viewModel.panes[3], viewModel: viewModel)
                            .frame(minWidth: 150, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)

            Text("极简 PDF 阅读器")
                .font(.system(size: 17, weight: .semibold))

            Text("默认纯净单屏无侧栏阅读 · 支持多屏对照、智能缩放、目录大纲、实时搜索与跳页\n直接将 PDF 文件拖拽到此窗口，或点击下方按钮打开")
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 16)

            Button(action: {
                viewModel.openDocumentPanel()
            }) {
                Label("选择 PDF 文件打开 (⌘O)", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, url.pathExtension.lowercased() == "pdf" {
                    Task { @MainActor in
                        viewModel.loadPDF(from: url)
                    }
                }
            }
            return true
        }
    }
}

// MARK: - 关于面板

/// 应用元信息：集中定义作者与仓库信息，便于统一维护
enum AppMetadata {
    static let displayName = "SimplePDFReader"
    static let tagline = "macOS 原生极简 PDF 阅读器"
    static let authorName = "xitihangto"
    static let repositoryName = "xitihangto/SimplePDFReader"
    static let repositoryURLString = "https://github.com/xitihangto/SimplePDFReader"

    /// 形如 "1.1.0"，来自 Info.plist（由 build_app.sh 依据 git tag 注入）
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var repositoryURL: URL? {
        URL(string: repositoryURLString)
    }
}

/// 自定义「关于」窗口的内容视图
private struct AboutView: View {
    let icon: NSImage
    var onClose: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 92, height: 92)
                .padding(.top, 26)

            Text(AppMetadata.displayName)
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 14)

            Text(AppMetadata.tagline)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Text("版本 \(AppMetadata.version)（构建 \(AppMetadata.build)）")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)

            Divider()
                .padding(.horizontal, 30)
                .padding(.vertical, 16)

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("作者")
                        .foregroundStyle(.secondary)
                    Text(AppMetadata.authorName)
                        .textSelection(.enabled)
                }

                HStack(spacing: 6) {
                    Text("仓库")
                        .foregroundStyle(.secondary)
                    if let repositoryURL = AppMetadata.repositoryURL {
                        Link(AppMetadata.repositoryName, destination: repositoryURL)
                    } else {
                        Text(AppMetadata.repositoryName)
                    }
                }
            }
            .font(.system(size: 12))

            HStack(spacing: 10) {
                Button(didCopy ? "已复制" : "复制仓库地址") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(AppMetadata.repositoryURLString, forType: .string)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        didCopy = false
                    }
                }

                Button("在 GitHub 上查看") {
                    if let repositoryURL = AppMetadata.repositoryURL {
                        NSWorkspace.shared.open(repositoryURL)
                    }
                }

                Button("好") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .frame(width: 360)
    }
}

/// 「关于」窗口的创建与复用
@MainActor
enum AboutWindow {
    private static var panel: NSWindow?

    static func show() {
        let parent = WindowPlacement.frontWindow()
        if panel == nil {
            let hosting = NSHostingController(rootView: AboutView(
                icon: NSApp.applicationIconImage ?? NSImage(),
                onClose: { panel?.close() }
            ))
            let newPanel = NSWindow(contentViewController: hosting)
            newPanel.title = "关于 \(AppMetadata.displayName)"
            newPanel.styleMask = [.titled, .closable]
            newPanel.isReleasedWhenClosed = false
            panel = newPanel
        }
        guard let aboutPanel = panel else { return }
        if let parent {
            WindowPlacement.centerOnParent(aboutPanel, parent: parent)
        } else {
            aboutPanel.center()
        }
        aboutPanel.makeKeyAndOrderFront(nil)
        if let parent {
            DispatchQueue.main.async {
                WindowPlacement.centerOnParent(aboutPanel, parent: parent)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - App 代理
//
// 多窗口下的打开文件规则（本文件里最重要的一段逻辑）：
//
//   1. 「应用已在运行 + 双击 PDF」 → 该文件没开着就新开一个窗口放它
//      （单窗口模式下则就地填入那唯一的窗口）；
//      已经开着（含作为某个分屏的对比文档）则聚焦那个窗口，不重复打开。
//   2. 「双击 PDF 启动应用」 → 文件放进应用启动时建出的那个空白窗口，
//      而不是再开一个（否则每次双击都会多出一个空窗口）。
//   3. 「点 Dock 图标重新激活」 → 只把已有窗口提到最前，绝不新建。
//
// 具体怎么分配交给 ReaderWindowManager.openDocument 统一决策，
// 这样「双击 PDF」「拖到 Dock」「工具栏打开按钮」「菜单打开」四处行为完全一致。
//
// 启动时不恢复上次的窗口：应用启动后永远只呈现一个空白主窗口，
// 打开哪个文件由用户自己决定（这是用户明确要求的行为）。
//
// 第 2 条存在时序竞态：application(_:open:) 可能在第一个窗口出现之前就被调用。
// 因此这里用「待打开队列 + 短时重试 + 窗口就绪回调」三重保险兜住它。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 全局唯一的 AppDelegate 引用。
    ///
    /// 为什么需要它：SwiftUI 的 `@NSApplicationDelegateAdaptor` 并不会把本对象挂到
    /// `NSApp.delegate`（那里是 SwiftUI 的内部代理，委托方法虽会被转发，但
    /// `NSApp.delegate as? AppDelegate` 永远得到 nil）。`WindowRegistry` 要在
    /// 「新窗口就绪」时回调本对象，因此这里自存一份引用。
    static var current: AppDelegate?

    override init() {
        super.init()
        Self.current = self
    }

    /// 已收到、但还没能分配到窗口的文件
    private var pendingURLs: [URL] = []
    private var pendingRetries = 0
    private let maxPendingRetries = 60

    /// Combine 订阅（如「窗口模式」菜单勾选同步）
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
        NSApp.activate(ignoringOtherApps: true)

        // 「窗口模式」菜单勾选显式同步：模式在菜单之外被改变时（如首启动 sheet 作答），
        // SwiftUI 的 Toggle 菜单项不保证及时刷新 NSMenuItem.state，这里兜底。
        AppSettings.shared.$windowMode
            .receive(on: RunLoop.main)
            .sink { _ in WindowModeMenuSync.refresh() }
            .store(in: &cancellables)

        // 命令行参数（开发调试：SimplePDFReader /path/to.pdf）
        let argumentURLs = CommandLine.arguments.dropFirst()
            .filter { $0.lowercased().hasSuffix(".pdf") }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        // 无参启动 → 一个空白主窗口（由 SwiftUI 的 Window 场景提供），
        // 刻意不恢复上次打开的文档：打开什么由用户自行选择。
        if !argumentURLs.isEmpty {
            enqueue(argumentURLs)
        }
    }

    /// 系统要求本应用打开若干文件（Finder 双击、拖到 Dock 图标、open -a 等）
    func application(_ application: NSApplication, open urls: [URL]) {
        enqueue(urls)
    }

    /// 应用已在运行时被再次激活（点 Dock 图标、在 Finder 里双击应用本身）。
    /// 返回 false：明确告诉 AppKit「已由我们自己处理，不要走默认的建窗行为」。
    /// 这里只把已有窗口提到最前 —— 绝不新建窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowRegistry.shared.bringMostRecentToFront()
        sender.activate(ignoringOtherApps: false)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// 由 WindowRegistry 在某个窗口就绪时回调，用来把「等窗口」的文件补上，
    /// 并承担「首次运行初始化面板」的触发点。
    func windowDidBecomeReady(for window: NSWindow) {
        presentFirstLaunchOnboardingIfNeeded(on: window)
        drainPending()
    }

    /// 首次运行：弹「初始化面板」（默认阅读器 + 窗口模式，各两张选项卡 + 一个确认按钮）。
    /// 面板本体见 FirstLaunchController；这里只负责「等窗口可见再弹」与重试。
    private var onboardingRetries = 0
    private static let maxOnboardingRetries = 20   // 20 × 0.3s ≈ 6s

    private func presentFirstLaunchOnboardingIfNeeded(on window: NSWindow) {
        guard !UserDefaults.standard.bool(forKey: FirstLaunchController.hasPromptedDefaultReaderKey) else { return }
        scheduleOnboarding(on: window)
    }

    private func scheduleOnboarding(on window: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (onboardingRetries == 0 ? 0.6 : 0.3)) { [weak self] in
            guard let self else { return }
            guard window.isVisible else {
                // SwiftUI Window 场景的窗口负载高时约 2~3s 才上屏；
                // 等不到可见就隔 0.3s 再试，绝不静默放弃。
                if onboardingRetries < Self.maxOnboardingRetries {
                    onboardingRetries += 1
                    scheduleOnboarding(on: window)
                }
                return
            }
            FirstLaunchController.shared.present(on: window)
        }
    }

    // MARK: 待打开文件的分配

    private func enqueue(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return }
        pendingURLs.append(contentsOf: pdfs)
        pendingRetries = 0
        drainPending()
    }

    private func drainPending() {
        guard !pendingURLs.isEmpty else {
            pendingRetries = 0
            return
        }

        // 一个窗口都还没出现（「双击文件启动应用」时的时序竞态）→ 稍等它出现。
        // 这一步必须等：否则这里先新开一个窗口，SwiftUI 稍后又建出主窗口，
        // 用户就会看到两个窗口。
        if WindowRegistry.shared.isEmpty && pendingRetries < maxPendingRetries {
            pendingRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.drainPending()
            }
            return
        }

        // 交给统一的打开入口逐份处理。它会自己决定「填入空白窗口 / 聚焦已打开的窗口 /
        // 新开窗口」（或单窗口模式下的「就地填充」），因此双击 PDF、拖到 Dock、
        // 命令行传参的行为完全一致。
        let urls = pendingURLs
        pendingURLs.removeAll()
        pendingRetries = 0
        for url in urls {
            ReaderWindowManager.shared.openDocument(at: url)
        }
    }
}

// MARK: - 首次运行初始化面板
//
// v1.7.x 的「两个 NSAlert sheet 依次问」被用户反馈「有点麻烦、感受偏复杂」，
// v1.8.0 改为**一个**自定义面板：左右并列两个问题框，各含两张选项卡
// （不是按钮 —— 未选中时两张样式一致，选中后带一圈主题色描边），
// 底部一个「我选好了，确认」按钮：两框都未选完前灰色禁用，选定后才可按。
// 用户明确要求「无出口，必须选完两项」，因此面板是 app 模态窗口。
// v1.8.1 起改为两个出口：①确认按钮（应用两项选择）；②右上角系统标准
// 关闭按钮（标题栏用 fullSizeContentView 融入内容，无细灰线）——
// 点关闭 = 两项都不选、按程序默认值执行（不设为默认、多窗口模式），
// 同样写「已问过」标记，以后不再弹出。
// 「已问过」标记只在**做出选择后**写入（确认或关闭）—— 中途强杀应用不算问过，
// 下次启动重新问。
@MainActor
final class FirstLaunchController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = FirstLaunchController()

    /// 「是否设为默认 PDF 阅读器」是否已经问过（整个面板算一问）。
    static let hasPromptedDefaultReaderKey = "SimplePDFReader.hasPromptedDefaultReader"
    /// 「习惯哪种窗口模式」是否已经问过（与上一项同生共死：一个面板两问）。
    static let hasPromptedWindowModeKey = "SimplePDFReader.hasPromptedWindowMode"

    enum DefaultReaderChoice {
        case setDefault
        case later
    }

    /// 左框当前选择（nil = 未选）
    @Published var defaultChoice: DefaultReaderChoice?
    /// 右框当前选择（nil = 未选）
    @Published var modeChoice: WindowMode?

    /// 两框都选定后才能确认
    var canConfirm: Bool { defaultChoice != nil && modeChoice != nil }

    /// 面板是否正在展示（测试与排查用）
    var isPresenting: Bool { modalWindow != nil }

    private var modalWindow: NSWindow?

    override private init() {}

    /// 弹出面板。调用方应确保窗口已可见；弹出后本方法会阻塞在模态会话里，
    /// 直到用户点「我选好了，确认」或右上角关闭按钮（两个出口）。
    func present(on parent: NSWindow) {
        guard modalWindow == nil else { return }

        let hosting = NSHostingController(rootView: FirstLaunchView(controller: self))
        let window = NSWindow(contentViewController: hosting)
        // .titled + .closable：右上角保留系统标准关闭按钮（离上/右边缘自带少许内缩）。
        // .fullSizeContentView + titlebarAppearsTransparent：标题栏融入内容，
        // 顺手去掉标题栏与内容之间那条细灰线。
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = ""
        window.delegate = self
        modalWindow = window
        WindowPlacement.centerOnParent(window, parent: parent)
        window.makeKeyAndOrderFront(nil)
        WindowPlacement.scheduleModalCentering(window, parent: parent)

        NSApp.runModal(for: window)
    }

    /// 用户点右上角关闭按钮：两项都不选，按程序默认值执行
    /// （不设为默认 PDF 阅读器、窗口模式保持默认的多窗口模式），
    /// 写「已问过」标记，以后不再弹出。
    private func dismissWithDefaults() {
        UserDefaults.standard.set(true, forKey: Self.hasPromptedDefaultReaderKey)
        UserDefaults.standard.set(true, forKey: Self.hasPromptedWindowModeKey)
        modalWindow = nil
        NSApp.stopModal()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 用户主动关闭（右上角按钮）：按默认值收场。
        // confirm() 走的是 orderOut 不是 close，不会触发这里。
        guard modalWindow != nil else { return }
        dismissWithDefaults()
    }

    /// 用户点「我选好了，确认」：静默应用两项选择、写标记、收面板。
    func confirm() {
        if defaultChoice == .setDefault {
            // 静默设置：面板里已经明确选了「设为默认」，不再弹结果提示框
            AppSettings.shared.setAsDefaultPDFReader(showResultAlert: false)
        }
        if let modeChoice {
            AppSettings.shared.windowMode = modeChoice
        }
        UserDefaults.standard.set(true, forKey: Self.hasPromptedDefaultReaderKey)
        UserDefaults.standard.set(true, forKey: Self.hasPromptedWindowModeKey)

        if let window = modalWindow {
            NSApp.stopModal()
            window.orderOut(nil)
        }
        modalWindow = nil
    }
}

/// 初始化面板的 SwiftUI 内容：标题 + 左右两个问题框 + 底部确认按钮。
struct FirstLaunchView: View {
    @ObservedObject var controller: FirstLaunchController

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                }
                Text("首次运行 app 初始化")
                    .font(.system(size: 17, weight: .medium))
                Text("完成下面两项选择即可开始使用")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                questionPanel(title: "是否设为默认 PDF 阅读器？") {
                    optionCard(
                        title: "设为默认",
                        badge: "推荐",
                        desc: "在 Finder 中双击 PDF 时用本应用打开",
                        selected: controller.defaultChoice == .setDefault
                    ) { controller.defaultChoice = .setDefault }

                    optionCard(
                        title: "以后再说",
                        desc: "暂不更改",
                        selected: controller.defaultChoice == .later
                    ) { controller.defaultChoice = .later }
                }

                questionPanel(title: "习惯使用哪种窗口模式？") {
                    optionCard(
                        title: "多窗口模式",
                        badge: "推荐",
                        desc: "可同时持有多个窗口实例",
                        selected: controller.modeChoice == .multi
                    ) { controller.modeChoice = .multi }

                    optionCard(
                        title: "单窗口模式",
                        desc: "全局仅保留一个窗口实例",
                        selected: controller.modeChoice == .single
                    ) { controller.modeChoice = .single }
                }
            }

            Button {
                controller.confirm()
            } label: {
                Text("我选好了，确认")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(controller.canConfirm ? Color.white : Color.secondary)
                    .frame(width: 160)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(controller.canConfirm
                                  ? Color.accentColor
                                  : Color(NSColor.controlBackgroundColor))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!controller.canConfirm)
        }
        // 标题栏已融入内容（fullSizeContentView），顶部多留一点，
        // 避免与右上角关闭按钮竖向贴太近
        .padding(EdgeInsets(top: 28, leading: 24, bottom: 24, trailing: 24))
        .frame(width: 560)
    }

    /// 一个问题框：标题 + 两张选项卡
    private func questionPanel<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 选项卡：不是按钮，是一张圆角矩形卡片 —— 未选中时与同类项样式一致，
    /// 选中后多一圈主题色描边与浅色底纹。整张卡片可点。
    /// `badge` 是标题旁的小徽章（如「推荐」）。
    private func optionCard(
        title: String,
        badge: String? = nil,
        desc: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.accentColor))
                }
                Spacer(minLength: 0)
            }
            Text(desc)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.08) : Color(NSColor.textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? Color.accentColor : Color(NSColor.separatorColor),
                        lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: action)
    }
}

@main
struct SimplePDFReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 这里用 Window 而不是 WindowGroup，是有实测依据的：
        // SwiftUI 的 WindowGroup 会在每次收到「打开文件」事件时额外凭空创建一个窗口，
        // 导致「双击一个 PDF」变成两个窗口。Window 不会。
        //
        // 多窗口本身完全支持 —— 除这一个之外的窗口全部由 ReaderWindowManager
        // 用 NSWindow 显式创建，新建/复用的时机由我们自己掌握，可预测、可测试。
        Window(AppMetadata.displayName, id: "main") {
            PrimaryReaderWindow()
        }
        .commands {
            ReaderCommands()
        }
    }
}

// MARK: - 应用启动时的第一个阅读器窗口
struct PrimaryReaderWindow: View {
    @StateObject private var viewModel = PDFReaderViewModel()
    @State private var sessionID = UUID()
    /// 标题要带当前窗口模式，而模式是应用级设置，故直接观察 AppSettings
    @ObservedObject private var appSettings = AppSettings.shared

    var body: some View {
        ReaderWindowView(viewModel: viewModel, sessionID: sessionID)
            .navigationTitle(
                WindowTitles.title(
                    primaryFileName: viewModel.primaryFileName,
                    hasDocument: viewModel.primaryDocument != nil,
                    mode: appSettings.windowMode
                )
            )
    }
}

// MARK: - 阅读器窗口内容
//
// 每个窗口各持有一份 PDFReaderViewModel —— 这就是「多窗口互不干扰」的根本。
// 文档、缩放、页码、侧栏、分屏、搜索全部是窗口私有状态。
// 唯一被所有窗口共享的只有 AppSettings（应用级设置）与 DocumentStore（文档缓存）。
//
// 本视图同时被两种宿主使用：SwiftUI 的 Window 场景（主窗口）与
// NSHostingController + NSWindow（ReaderWindowManager 创建的额外窗口）。
// 因此这里只放内容，标题由各自的宿主设置。
struct ReaderWindowView: View {
    @ObservedObject var viewModel: PDFReaderViewModel
    let sessionID: UUID

    var body: some View {
        ContentView(viewModel: viewModel)
            .background(WindowAccessor { window in
                Task { @MainActor in
                    WindowRegistry.shared.attach(
                        window: window,
                        sessionID: sessionID,
                        viewModel: viewModel
                    )
                }
            })
            // 打开文档后让窗口贴合「第一页 100%」（详见 PageFitSizer）。
            // 窗口创建时就带着文档的情况不会有 onChange，因此 onAppear 也要试一次。
            .onAppear {
                PageFitSizer.shared.scheduleFit(viewModel: viewModel)
            }
            .onChange(of: viewModel.primaryFileURL) { newValue in
                guard newValue != nil else { return }
                PageFitSizer.shared.scheduleFit(viewModel: viewModel)
            }
    }
}

// MARK: - 菜单命令
//
// 所有与阅读相关的命令都在**触发时**通过 WindowRegistry.shared.activeSession
// 解析出「当前激活窗口」的 ViewModel，因此天然只作用于当前窗口。
struct ReaderCommands: Commands {
    /// 当前激活窗口的 ViewModel（触发时解析，不缓存）
    private var reader: PDFReaderViewModel? {
        WindowRegistry.shared.activeSession?.viewModel
    }

    /// 窗口模式是应用级设置，菜单里的勾选要实时跟随它（任何窗口切换模式后
    /// 勾选都要立即搬家），因此这里直接观察 AppSettings.shared。
    @ObservedObject private var appSettings = AppSettings.shared

    var body: some Commands {
        // 用自定义「关于」面板替换系统默认的 About 项，展示作者与仓库信息
        CommandGroup(replacing: .appInfo) {
            Button("关于 \(AppMetadata.displayName)") {
                AboutWindow.show()
            }
        }

        // 应用级动作：与具体窗口无关
        CommandGroup(after: .appInfo) {
            Divider()
            Button("设为默认 PDF 阅读器…") {
                AppSettings.shared.setAsDefaultPDFReader()
            }

            Divider()

            // 重置为首次运行状态：下次启动重新询问初始化、恢复默认窗口模式。
            // 开着任何多个 PDF 都能执行；只动本地设置，当前会话不受影响。
            Button("重置应用…") {
                AppSettings.shared.confirmResetToFirstRun()
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("新建窗口") {
                ReaderWindowManager.shared.openNewWindow()
            }
            .keyboardShortcut("n", modifiers: [.command])

            // 与「在 Finder 里双击 PDF」完全同一条路径：
            // 没开着就新开窗口，已经开着就聚焦已有窗口，本窗口空着就地填入。
            // 因此绝不会顶掉当前窗口正在看的内容。
            Button("打开 PDF…") {
                let parent = WindowPlacement.frontWindow()
                if let url = PDFOpenPanel.choose(title: "选择要打开的 PDF 文件", parent: parent) {
                    ReaderWindowManager.shared.openDocument(at: url, preferring: parent)
                }
            }
            .keyboardShortcut("o", modifiers: [.command])

            Divider()

            // 只关掉本窗口的文档（回到空白状态），窗口与其他窗口都不受影响。
            // 想关窗口请用窗口左上角的系统按钮或 ⌘W。
            Button("关闭本文档") {
                reader?.closeDocument()
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
        }

        // 顶级「窗口模式」菜单：多窗口 / 单窗口，当前生效者带勾。
        // 勾选状态来自 appSettings.windowMode（应用级设置），因此无论是
        // 在哪里切的模式，打开这个菜单看到的勾都永远在实际生效的那一项上。
        CommandMenu("窗口模式") {
            Toggle("多窗口", isOn: Binding(
                get: { appSettings.windowMode == .multi },
                // 点已勾选项会传入 false，忽略即可（不允许「两个都不勾」）
                set: {
                    if $0 {
                        AppSettings.shared.windowMode = .multi
                    }
                    WindowModeMenuSync.refresh()
                }
            ))

            Toggle("单窗口模式", isOn: Binding(
                get: { appSettings.windowMode == .single },
                set: {
                    if $0 {
                        WindowModeController.shared.requestSingleMode()
                    } else {
                        WindowModeMenuSync.refresh()
                    }
                }
            ))
        }

        CommandMenu("视图与缩放") {
            Button("放大") {
                reader?.zoomIn()
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button("缩小") {
                reader?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: [.command])

            Button("实际大小 (100%)") {
                reader?.resetZoomToActualSize()
            }
            .keyboardShortcut("0", modifiers: [.command])

            Button("自适应宽度") {
                reader?.zoomToFit()
            }
            .keyboardShortcut("9", modifiers: [.command])

            Divider()

            Button("显示/隐藏侧边栏") {
                reader?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Button("单屏模式（默认）") {
                reader?.layoutMode = .single
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("双屏模式") {
                reader?.layoutMode = .dual
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button("三屏模式") {
                reader?.layoutMode = .triple
            }
            .keyboardShortcut("3", modifiers: [.command])

            Button("四屏模式") {
                reader?.layoutMode = .quad
            }
            .keyboardShortcut("4", modifiers: [.command])

            Button("自适应分屏模式") {
                reader?.layoutMode = .autoByZoom
            }
            .keyboardShortcut("5", modifiers: [.command])
        }

        CommandMenu("查找与跳转") {
            Button("搜索全文…") {
                reader?.focusSearchTrigger = UUID()
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("查找下一个") {
                reader?.selectNextSearchResult()
            }
            .keyboardShortcut("g", modifiers: [.command])

            Button("查找上一个") {
                reader?.selectPreviousSearchResult()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Divider()

            Button("跳转到页码…") {
                reader?.focusPageJumpTrigger = UUID()
            }
            .keyboardShortcut("j", modifiers: [.command])

            Button("上一页") {
                reader?.goToPreviousPage()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])

            Button("下一页") {
                reader?.goToNextPage()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
        }
    }
}
