import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

// MARK: - 宽度监听 PreferenceKey（用于工具栏自适应缩放）
private struct ToolbarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 860
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
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
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func mouseDown(with event: NSEvent) {
        onActivatePane?()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onActivatePane?()
        super.scrollWheel(with: event)
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
        .frame(minWidth: 185, idealWidth: 225, maxWidth: 300)
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
    @State private var toolbarWidth: CGFloat = 860

    // 窗口宽度断点：
    // - 宽屏 (>= 760pt)：完整显示按钮文字与内联搜索框
    // - 中屏 (540 ~ 759pt)：图标化按钮 + 紧凑内联搜索框
    // - 小窗 (< 540pt)：主栏精简，搜索框自动转为可展开的第二行抽屉栏
    private var isWideToolbar: Bool { toolbarWidth >= 760 }
    private var isCompactToolbar: Bool { toolbarWidth < 540 }

    var body: some View {
        VStack(spacing: 0) {
            responsiveTopToolbar
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ToolbarWidthPreferenceKey.self, value: geo.size.width)
                    }
                )
                .onPreferenceChange(ToolbarWidthPreferenceKey.self) { newWidth in
                    if abs(toolbarWidth - newWidth) > 1 {
                        toolbarWidth = newWidth
                    }
                }

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
        .onChange(of: viewModel.focusSearchTrigger) { _ in
            if isCompactToolbar {
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
            HStack(spacing: isCompactToolbar ? 6 : 10) {
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

                // 2. 缩放控制组（缩小 / 实时百分比显示与重置 / 放大）
                HStack(spacing: 3) {
                    Button(action: { viewModel.zoomOut() }) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("缩小 15% (⌘-)")
                    .disabled(viewModel.primaryDocument == nil)

                    Button(action: { viewModel.resetZoomToActualSize() }) {
                        Text("\(viewModel.activeScalePercentage)%")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .frame(width: 46)
                    }
                    .help("当前缩放比例 \(viewModel.activeScalePercentage)%，点击恢复 100% (⌘0)")
                    .disabled(viewModel.primaryDocument == nil)

                    Button(action: { viewModel.zoomIn() }) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("放大 15% (⌘+)")
                    .disabled(viewModel.primaryDocument == nil)
                }
                .fixedSize()

                Divider().frame(height: 16)

                // 3. 弹出式分屏与自适应菜单（单屏[默认] / 双屏 / 三屏 / 四屏 / 自适应分屏 / 窗口自适应宽度）
                layoutPopupMenu
                    .fixedSize()

                Divider().frame(height: 16)

                // 4. 页码跳转组
                pageJumpGroup
                    .fixedSize()

                Spacer(minLength: 2)

                // 5. 右侧实时搜索框（已移除右侧重复的侧边栏按钮）
                if isCompactToolbar {
                    compactSearchToggleButton
                } else {
                    inlineSearchBar(maxFieldWidth: isWideToolbar ? 175 : 120)
                }
            }
            .padding(.horizontal, isCompactToolbar ? 8 : 12)
            .padding(.vertical, 7)

            // 小窗口模式下按需展开的第二行搜索栏
            if isCompactToolbar && (viewModel.isCompactSearchExpanded || !viewModel.searchQuery.isEmpty) {
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

    // MARK: - 弹出式菜单（单屏 / 双屏 / 三屏 / 四屏 / 自适应）
    private var layoutPopupMenu: some View {
        Menu {
            Section("分屏视图模式") {
                Picker("分屏模式", selection: $viewModel.layoutMode) {
                    ForEach(SplitLayoutMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.symbolName).tag(mode)
                    }
                }
            }

            Section("页面缩放自适应") {
                Button(action: { viewModel.zoomToFit() }) {
                    Label("自适应当前窗口宽度 (⌘9)", systemImage: "arrow.left.and.right.square")
                }
                .disabled(viewModel.primaryDocument == nil)

                Button(action: { viewModel.resetZoomToActualSize() }) {
                    Label("恢复 100% 原始比例 (⌘0)", systemImage: "1.magnifyingglass")
                }
                .disabled(viewModel.primaryDocument == nil)
            }

            if viewModel.layoutMode == .autoByZoom {
                Section("自适应分屏策略 (\(viewModel.smartStatusLabel))") {
                    Picker("自适应策略", selection: $viewModel.smartZoomStrategy) {
                        ForEach(SmartZoomStrategy.allCases) { strategy in
                            Text(strategy.rawValue).tag(strategy)
                        }
                    }
                }
            }

            if viewModel.visiblePaneCount > 1 {
                Section("多屏协同") {
                    Toggle("多屏联动顺延翻页", isOn: $viewModel.syncPanesScrolling)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.layoutMode.symbolName)
                Text(viewModel.layoutMode.rawValue)
                    .font(.system(size: 11.5))
            }
        }
        .frame(width: isCompactToolbar ? 76 : 94)
        .help("点击弹出菜单：切换单屏/双屏/三屏/四屏/自适应模式")
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
        // 多屏模式下每个分屏顶部有一条状态栏，按钮要落在它下面，避免压住「换文件」等按钮
        .padding(.top, viewModel.visiblePaneCount > 1 ? 34 : 8)
        .padding(.trailing, 10)
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
        if panel == nil {
            let hosting = NSHostingController(rootView: AboutView(
                icon: NSApp.applicationIconImage ?? NSImage(),
                onClose: { panel?.close() }
            ))
            let newPanel = NSWindow(contentViewController: hosting)
            newPanel.title = "关于 \(AppMetadata.displayName)"
            newPanel.styleMask = [.titled, .closable]
            newPanel.isReleasedWhenClosed = false
            newPanel.center()
            panel = newPanel
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - App 代理
//
// 多窗口下的打开文件规则（本文件里最重要的一段逻辑）：
//
//   1. 「应用已在运行 + 双击 PDF」 → 该文件没开着就新开一个窗口放它；
//      已经开着（含作为某个分屏的对比文档）则聚焦那个窗口，不重复打开。
//   2. 「双击 PDF 启动应用」 → 文件放进应用启动时建出的那个空白窗口，
//      而不是再开一个（否则每次双击都会多出一个空窗口）。
//   3. 「点 Dock 图标重新激活」 → 只把已有窗口提到最前，绝不新建。
//
// 具体怎么分配交给 ReaderWindowManager.openDocument 统一决策，
// 这样「双击 PDF」「拖到 Dock」「工具栏打开按钮」「菜单打开」四处行为完全一致。
//
// 第 2 条存在时序竞态：application(_:open:) 可能在第一个窗口出现之前就被调用。
// 因此这里用「待打开队列 + 短时重试 + 窗口就绪回调」三重保险兜住它。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 退出时把「还开着的窗口」记在这里，下次启动恢复
    static let restorationKey = "SimplePDFReader.restorableWindowPaths"

    /// 已收到、但还没能分配到窗口的文件
    private var pendingURLs: [URL] = []
    private var pendingRetries = 0
    private let maxPendingRetries = 60
    private var restoreWorkItem: DispatchWorkItem?
    /// 是否已经收到过「打开文件」事件。
    /// application(_:open:) 与 applicationDidFinishLaunching 的先后顺序并不固定，
    /// 因此不能靠「取消定时器」来互斥，必须用一个与顺序无关的状态来判断。
    private var receivedOpenEvent = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
        NSApp.activate(ignoringOtherApps: true)

        // 命令行参数（开发调试：SimplePDFReader /path/to.pdf）
        let argumentURLs = CommandLine.arguments.dropFirst()
            .filter { $0.lowercased().hasSuffix(".pdf") }
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        if argumentURLs.isEmpty {
            scheduleRestoration()
        } else {
            enqueue(argumentURLs)
        }
    }

    /// 系统要求本应用打开若干文件（Finder 双击、拖到 Dock 图标、open -a 等）
    func application(_ application: NSApplication, open urls: [URL]) {
        // 明确要打开文件时，取消「恢复上次窗口」——
        // 否则会既恢复一堆旧窗口、又打开新文件，用户会看到意料之外的窗口。
        receivedOpenEvent = true
        cancelRestoration()
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

    func applicationWillTerminate(_ notification: Notification) {
        saveRestorationSnapshot()
    }

    /// 由 WindowRegistry 在某个窗口就绪时回调，用来把「等窗口」的文件补上
    func windowDidBecomeReady() {
        drainPending()
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
        // 新开窗口」，因此双击 PDF、拖到 Dock、命令行传参的行为完全一致。
        let urls = pendingURLs
        pendingURLs.removeAll()
        pendingRetries = 0
        for url in urls {
            ReaderWindowManager.shared.openDocument(at: url)
        }
    }

    // MARK: 窗口状态恢复
    //
    // 用自己保存的路径列表恢复，而不是依赖 SwiftUI 的窗口恢复机制 ——
    // 后者会在启动时凭空恢复出一堆窗口，正是历史上那类「莫名其妙多出窗口」的来源。

    private func scheduleRestoration() {
        // 本次启动是「双击文件」触发的 → 用户要的是那个文件，不是上次的一堆窗口
        guard !receivedOpenEvent, pendingURLs.isEmpty else { return }

        let keepsWindows = (UserDefaults.standard.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool) ?? true
        guard keepsWindows else { return }

        let paths = UserDefaults.standard.stringArray(forKey: Self.restorationKey) ?? []
        guard !paths.isEmpty else { return }

        // 留一个很短的宽限期：若这期间收到「打开文件」事件，就放弃恢复
        // （用户双击文件时想要的是那个文件，而不是上次的一堆窗口）。
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // 宽限期内如果收到了打开文件的事件，就放弃恢复
            guard !self.receivedOpenEvent, self.pendingURLs.isEmpty else { return }
            let urls = paths
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return }
            self.enqueue(urls)
        }
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func cancelRestoration() {
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
    }

    private func saveRestorationSnapshot() {
        let keepsWindows = (UserDefaults.standard.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool) ?? true
        let paths = keepsWindows
            ? ReaderWindowManager.shared.openFileURLs.map { $0.path }
            : []
        UserDefaults.standard.set(paths, forKey: Self.restorationKey)
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

    var body: some View {
        ReaderWindowView(viewModel: viewModel, sessionID: sessionID)
            .navigationTitle(
                viewModel.primaryDocument == nil
                    ? AppMetadata.displayName
                    : viewModel.primaryFileName
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
                if let url = PDFOpenPanel.choose(title: "选择要打开的 PDF 文件") {
                    ReaderWindowManager.shared.openDocument(at: url)
                }
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("在当前窗口打开 PDF…") {
                reader?.openDocumentPanelReplacingCurrent()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])

            Divider()

            // 只关掉本窗口的文档（回到空白状态），窗口与其他窗口都不受影响。
            // 想关窗口请用窗口左上角的系统按钮或 ⌘W。
            Button("关闭本文档") {
                reader?.closeDocument()
            }
            .keyboardShortcut("w", modifiers: [.command, .option])

            Divider()

            Button("设为默认 PDF 阅读器…") {
                AppSettings.shared.setAsDefaultPDFReader()
            }
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
