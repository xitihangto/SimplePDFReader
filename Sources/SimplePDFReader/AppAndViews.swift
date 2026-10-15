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
        pdfView.autoScales = false
        pdfView.scaleFactor = pane.scaleFactor
        pdfView.displayMode = pane.displayMode
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = NSColor.windowBackgroundColor
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 5.0

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

        if let doc = pane.activeDocument(fallback: viewModel.primaryDocument) {
            pdfView.document = doc
            pdfView.autoScales = false
            pdfView.scaleFactor = pane.scaleFactor
            let targetIdx = min(max(pane.currentPageNumber - 1, 0), max(doc.pageCount - 1, 0))
            if let page = doc.page(at: targetIdx) {
                pdfView.go(to: page)
            }
        }

        pane.pdfView = pdfView
        context.coordinator.observe(pdfView: pdfView)

        DispatchQueue.main.async {
            viewModel.syncActivePaneMetrics()
        }
        return pdfView
    }

    func updateNSView(_ pdfView: InteractivePDFView, context: Context) {
        if pane.pdfView !== pdfView {
            pane.pdfView = pdfView
        }
        let targetDoc = pane.activeDocument(fallback: viewModel.primaryDocument)
        if pdfView.document !== targetDoc {
            pdfView.document = targetDoc
            pdfView.autoScales = false
            pdfView.scaleFactor = pane.scaleFactor
            if let doc = targetDoc {
                let targetIdx = min(max(pane.currentPageNumber - 1, 0), max(doc.pageCount - 1, 0))
                if let page = doc.page(at: targetIdx) {
                    pdfView.go(to: page)
                }
            }
            DispatchQueue.main.async {
                viewModel.syncActivePaneMetrics()
            }
        }
        if pdfView.displayMode != pane.displayMode {
            pdfView.displayMode = pane.displayMode
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
                    .help("打开 PDF 文件 (⌘O)")
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

// MARK: - App 代理与主入口
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: PDFReaderViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
        NSApp.activate(ignoringOtherApps: true)

        let args = CommandLine.arguments.dropFirst()
        if let firstPDF = args.first(where: { $0.lowercased().hasSuffix(".pdf") }) {
            let url = URL(fileURLWithPath: firstPDF)
            if FileManager.default.fileExists(atPath: url.path) {
                viewModel?.loadPDF(from: url)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let pdfURL = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            viewModel?.loadPDF(from: pdfURL)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

@main
struct SimplePDFReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = PDFReaderViewModel()

    var body: some Scene {
        WindowGroup(viewModel.primaryDocument == nil ? "SimplePDFReader" : "SimplePDFReader — \(viewModel.primaryFileName)") {
            ContentView(viewModel: viewModel)
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
        }
        .commands {
            // 用自定义「关于」面板替换系统默认的 About 项，展示作者与仓库信息
            CommandGroup(replacing: .appInfo) {
                Button("关于 \(AppMetadata.displayName)") {
                    AboutWindow.show()
                }
            }

            // 在左上角应用主菜单 (SimplePDFReader) 中加入“设为默认 PDF 阅读器…”
            CommandGroup(after: .appInfo) {
                Divider()
                Button("设为默认 PDF 阅读器…") {
                    viewModel.setAsDefaultPDFReader()
                }
            }

            // 在“文件”菜单中也提供“设为默认 PDF 阅读器…”入口
            CommandGroup(replacing: .newItem) {
                Button("打开 PDF 文件…") {
                    viewModel.openDocumentPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("设为默认 PDF 阅读器…") {
                    viewModel.setAsDefaultPDFReader()
                }
            }

            CommandMenu("视图与缩放") {
                Button("放大") {
                    viewModel.zoomIn()
                }
                .keyboardShortcut("=", modifiers: [.command])

                Button("缩小") {
                    viewModel.zoomOut()
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("实际大小 (100%)") {
                    viewModel.resetZoomToActualSize()
                }
                .keyboardShortcut("0", modifiers: [.command])

                Button("自适应宽度") {
                    viewModel.zoomToFit()
                }
                .keyboardShortcut("9", modifiers: [.command])

                Divider()

                Button("显示/隐藏侧边栏") {
                    viewModel.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("单屏模式（默认）") {
                    viewModel.layoutMode = .single
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("双屏模式") {
                    viewModel.layoutMode = .dual
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("三屏模式") {
                    viewModel.layoutMode = .triple
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button("四屏模式") {
                    viewModel.layoutMode = .quad
                }
                .keyboardShortcut("4", modifiers: [.command])

                Button("自适应分屏模式") {
                    viewModel.layoutMode = .autoByZoom
                }
                .keyboardShortcut("5", modifiers: [.command])
            }

            CommandMenu("查找与跳转") {
                Button("搜索全文…") {
                    viewModel.focusSearchTrigger = UUID()
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("查找下一个") {
                    viewModel.selectNextSearchResult()
                }
                .keyboardShortcut("g", modifiers: [.command])

                Button("查找上一个") {
                    viewModel.selectPreviousSearchResult()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button("跳转到页码…") {
                    viewModel.focusPageJumpTrigger = UUID()
                }
                .keyboardShortcut("j", modifiers: [.command])

                Button("上一页") {
                    viewModel.goToPreviousPage()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Button("下一页") {
                    viewModel.goToNextPage()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])
            }
        }
    }
}
