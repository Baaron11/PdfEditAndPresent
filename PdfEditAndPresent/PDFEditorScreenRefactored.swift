import SwiftUI
import PDFKit
import PencilKit
import PaperKit
import UniformTypeIdentifiers
import Combine

// MARK: - Size Change Modifier
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension View {
    func onSizeChange(perform action: @escaping (CGSize) -> Void) -> some View {
        self
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: SizePreferenceKey.self, value: geometry.size)
                }
            )
            .onPreferenceChange(SizePreferenceKey.self, perform: action)
    }
}

// MARK: - Refactored PDF Editor Screen (With Unsaved Changes Detection)
struct PDFEditorScreenRefactored: View {
    @Environment(\.dismiss) var dismiss
    var pdfViewModel: PDFViewModel
    @StateObject private var pdfManager = PDFManager()
    @StateObject private var editorData = EditorData()
    
    @State private var canvasMode: CanvasMode = .drawing
    @State private var isSidebarOpen: Bool = true
    @State private var canvasKey: UUID = UUID()
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @State private var showSavePrompt = false
    @State private var showSettings = false
    @State private var showMarginSettings = false
    @State private var isInitialized = false
    @State private var isPanning = false
    @State private var panOffset: CGSize = .zero
    @State private var lastPanValue: CGSize = .zero
    @State private var lastDisplayMode: PDFDisplayMode = .continuousScroll
    
    @State private var isEditingZoom = false
    @State private var zoomInputText = "100"
    
    @State private var isEditingPageNumber = false
    @State private var pageNumberInput = ""
    @FocusState private var isTitleFieldFocused: Bool
    @State private var initialZoomForGesture: CGFloat = 1.0
    @State private var contentSize: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    
    @State private var scrollPosition: CGFloat = 0
    @State private var visiblePageIndex: Int = 0
    
    @State private var showSaveAsCopyDialog = false
    @State private var saveAsCopyFilename = ""
    
    @State private var pendingBackAction: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            toolbarView
            contentAreaView
        }
        .onAppear {
            print("📄 Editor view appeared - initializing PDF")
            pdfManager.setPDFDocument(pdfViewModel.currentDocument)
            pdfViewModel.setupPDFManager(pdfManager)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let pageSize = pdfManager.getCurrentPageSize()
                editorData.initializeController(CGRect(origin: .zero, size: pageSize))
                
                withAnimation {
                    isInitialized = true
                }
                
                print("✅ PDF editor initialized successfully")
            }
        }
        .onChange(of: pdfManager.currentPageIndex) { _, _ in
            resetCanvasForPageChange()
        }
        .onChange(of: pdfManager.displayMode) { oldValue, newValue in
            print("🔄 Display mode changed from \(oldValue.rawValue) to \(newValue.rawValue)")
            panOffset = .zero
            lastPanValue = .zero
            initialZoomForGesture = 1.0
            if newValue == .continuousScroll {
                pdfManager.zoomToFit()
            }
            lastDisplayMode = newValue
        }
        .sheet(isPresented: $showSettings) {
            PDFSettingsSheet(pdfManager: pdfManager)
        }
        .sheet(isPresented: $showMarginSettings) {
            MarginSettingsSheet(pdfManager: pdfManager)
        }
        .alert("Save Changes?", isPresented: $showSavePrompt, actions: {
            Button("Save Changes", action: {
                pdfViewModel.saveCurrentDocument()
                dismiss()
            })
            
            Button("Save as Copy", action: {
                let currentName = pdfViewModel.currentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
                saveAsCopyFilename = "\(currentName)_copy"
                showSaveAsCopyDialog = true
            })
            
            Button("Exit Without Saving", role: .destructive, action: {
                pdfViewModel.hasUnsavedChanges = false
                dismiss()
            })
            
            Button("Cancel", role: .cancel) {
                pendingBackAction = false
            }
        }, message: {
            Text("You have unsaved changes. What would you like to do?")
        })
        .alert("Save as Copy", isPresented: $showSaveAsCopyDialog, actions: {
            TextField("Filename", text: $saveAsCopyFilename)
            
            Button("Save", action: {
                pdfViewModel.saveAsNewDocument(
                    pdfViewModel.currentDocument ?? PDFDocument(),
                    withName: saveAsCopyFilename,
                    pdfManager: pdfManager
                )
                pdfViewModel.hasUnsavedChanges = false
                dismiss()
            })
            
            Button("Cancel", role: .cancel) {
                pendingBackAction = false
                showSavePrompt = true
            }
        }, message: {
            Text("Enter a name for the copy (without .pdf extension):")
        })
        .onTapGesture {
            if isEditingZoom {
                commitZoomChange()
            }
            if isEditingPageNumber {
                if pdfManager.displayMode == .singlePage {
                    commitPageNumberChange()
                } else {
                    commitPageNumberChangeContinuous()
                }
            }
            if isEditingTitle {
                commitTitleChange()
            }
        }
    }
    
    // MARK: - Toolbar View
    private var toolbarView: some View {
        VStack(spacing: ToolbarMetrics.rowSpacing) {
            titleBarView
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

            controlsToolbarView
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.bottom, ToolbarMetrics.rowSpacing)
        }
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .bottom)
    }
    
    // MARK: - Title Bar View
    private var titleBarView: some View {
        HStack(spacing: 10) {
            Button(action: { handleBackButtonTap() }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.blue)
            }
            .frame(height: ToolbarMetrics.button)

            // ✅ IMPROVED: Better text selection on edit
            if isEditingTitle {
                TextField("", text: $editedTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .focused($isTitleFieldFocused)
                    .onAppear {
                        // Set initial value and focus
                        editedTitle = pdfViewModel.currentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
                        isTitleFieldFocused = true
                        
                        // Select all text after a tiny delay to ensure TextField is ready
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if let textField = UIApplication.shared.windows.first?.rootViewController?.view.firstTextField {
                                textField.selectAll(nil)
                            }
                        }
                    }
                    .onSubmit {
                        commitTitleChange()
                    }
            } else {
                Text(pdfViewModel.currentURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        isEditingTitle = true
                    }
            }

            Button(action: { showSettings = true }) {
                Image(systemName: "gear")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: ToolbarMetrics.button, height: ToolbarMetrics.button)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    .foregroundColor(.primary)
            }
        }
    }
    
    // MARK: - Controls Toolbar
    private enum ToolbarMetrics {
        static let rowSpacing: CGFloat = 6
        static let button: CGFloat = 32
        static let divider: CGFloat = 18
    }
    
    private var controlsToolbarView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(action: { isSidebarOpen.toggle() }) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13))
                        .frame(width: ToolbarMetrics.button, height: ToolbarMetrics.button)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .foregroundColor(.primary)
                }

                Divider().frame(height: ToolbarMetrics.divider)

                if pdfManager.displayMode == .singlePage {
                    pageNavigationViewRedesigned
                } else {
                    pageNavigationViewRedesignedContinuous
                }

                Divider().frame(height: ToolbarMetrics.divider)

                zoomControlsView

                Divider().frame(height: ToolbarMetrics.divider)

                marginSettingsButton

                rotateMenuIconOnly

                Divider().frame(height: ToolbarMetrics.divider)

                modeToggleView

                Button(action: { /* TODO */ }) {
                    Text("Elements")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private var pageNavigationViewRedesigned: some View {
        HStack(spacing: 4) {
            Button(action: {
                pdfManager.previousPage()
                resetCanvasForPageChange()
            }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                    .foregroundColor(.blue)
            }
            .disabled(pdfManager.currentPageIndex == 0)
            
            if isEditingPageNumber {
                HStack(spacing: 2) {
                    Text("Page")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    TextField("", text: $pageNumberInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .frame(width: 30)
                        .keyboardType(.numberPad)
                        .onSubmit {
                            commitPageNumberChange()
                        }
                    
                    Text("of \(pdfManager.pageCount)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            } else {
                Button(action: {
                    isEditingPageNumber = true
                    pageNumberInput = "\(pdfManager.currentPageIndex + 1)"
                }) {
                    Text("Page \(pdfManager.currentPageIndex + 1) of \(pdfManager.pageCount)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }
            }
            
            Button(action: {
                pdfManager.nextPage()
                resetCanvasForPageChange()
            }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                    .foregroundColor(.blue)
            }
            .disabled(pdfManager.currentPageIndex >= pdfManager.pageCount - 1)
        }
    }

    private var pageNavigationViewRedesignedContinuous: some View {
        HStack(spacing: 4) {
            Button(action: {
                if visiblePageIndex > 0 {
                    visiblePageIndex -= 1
                }
            }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                    .foregroundColor(.blue)
            }
            .disabled(visiblePageIndex == 0)
            
            if isEditingPageNumber {
                HStack(spacing: 2) {
                    Text("Page")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    TextField("", text: $pageNumberInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .frame(width: 30)
                        .keyboardType(.numberPad)
                        .onSubmit {
                            commitPageNumberChangeContinuous()
                        }
                    
                    Text("of \(pdfManager.pageCount)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            } else {
                Button(action: {
                    isEditingPageNumber = true
                    pageNumberInput = "\(visiblePageIndex + 1)"
                }) {
                    Text("Page \(visiblePageIndex + 1) of \(pdfManager.pageCount)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }
            }
            
            Button(action: {
                if visiblePageIndex < pdfManager.pageCount - 1 {
                    visiblePageIndex += 1
                }
            }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                    .foregroundColor(.blue)
            }
            .disabled(visiblePageIndex >= pdfManager.pageCount - 1)
        }
    }
    
    private var rotateMenuIconOnly: some View {
        Menu {
            Section("Current Page") {
                Button {
                    pdfManager.rotateCurrentPage(by: 90)
                } label: {
                    Label("Rotate Right 90°", systemImage: "rotate.right")
                }
                Button {
                    pdfManager.rotateCurrentPage(by: -90)
                } label: {
                    Label("Rotate Left 90°", systemImage: "rotate.left")
                }
                Button {
                    pdfManager.rotateCurrentPage(by: 180)
                } label: {
                    Label("Rotate 180°", systemImage: "arrow.2.squarepath")
                }
            }
            
            Section("All Pages") {
                Button {
                    pdfManager.rotateAllPages(by: 90)
                } label: {
                    Label("Rotate All Right 90°", systemImage: "rotate.right.fill")
                }
                Button {
                    pdfManager.rotateAllPages(by: -90)
                } label: {
                    Label("Rotate All Left 90°", systemImage: "rotate.left.fill")
                }
                Button {
                    pdfManager.rotateAllPages(by: 180)
                } label: {
                    Label("Rotate All 180°", systemImage: "arrow.2.squarepath")
                }
            }
        } label: {
            Image(systemName: "rotate.right")
                .font(.system(size: 13))
                .frame(width: ToolbarMetrics.button, height: ToolbarMetrics.button)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                .foregroundColor(.primary)
        }
    }
    
    private var zoomControlsView: some View {
        HStack(spacing: 6) {
            Button(action: { pdfManager.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .disabled(pdfManager.zoomLevel <= pdfManager.minZoom)

            Button(action: {
                isEditingZoom = true
                zoomInputText = "\(Int(pdfManager.zoomLevel * 100))"
            }) {
                Text("\(Int(pdfManager.zoomLevel * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 40)
            }

            Button(action: { pdfManager.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .disabled(pdfManager.zoomLevel >= pdfManager.maxZoom)
        }
    }
    
    private var marginSettingsButton: some View {
        Button("Margin") { showMarginSettings = true }
            .buttonStyle(.bordered)
            .tint(pdfManager.hasMarginEnabled ? .blue : .gray)
    }
    
    private var modeToggleView: some View {
        HStack(spacing: 4) {
            Button {
                canvasMode = .drawing
            } label: {
                Image(systemName: "pencil").font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .tint(canvasMode == .drawing ? .blue : .gray)

            Button {
                canvasMode = .selecting
            } label: {
                Image(systemName: "hand.point.up").font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .tint(canvasMode == .selecting ? .blue : .gray)
        }
    }
    
    // MARK: - Content Area View
    private var contentAreaView: some View {
        Group {
            if isInitialized {
                if pdfManager.displayMode == .continuousScroll {
                    continuousScrollView
                } else {
                    singlePageView
                }
            } else {
                ProgressView("Loading PDF...")
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    private var continuousScrollView: some View {
        HStack(spacing: 0) {
            if isSidebarOpen {
                ContinuousScrollThumbnailSidebar(
                    pdfManager: pdfManager,
                    visiblePageIndex: $visiblePageIndex,
                    isOpen: $isSidebarOpen,
                    onPageSelected: { pageIndex in
                        print("📄 Scrolling to page \(pageIndex + 1)")
                        visiblePageIndex = pageIndex
                    }
                )
                .transition(.move(edge: .leading))
            }
            
            ContinuousScrollPDFViewWithTracking(
                pdfManager: pdfManager,
                visiblePageIndex: $visiblePageIndex
            )
            .ignoresSafeArea()
            .gesture(continuousZoomGesture)
        }
    }
    
    private var continuousZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if canvasMode == .selecting {
                    let newZoom = max(pdfManager.minZoom, min(initialZoomForGesture * scale, pdfManager.maxZoom))
                    pdfManager.setZoom(newZoom)
                }
            }
            .onEnded { _ in
                initialZoomForGesture = pdfManager.zoomLevel
            }
    }
    
    private var singlePageView: some View {
        HStack(spacing: 0) {
            if isSidebarOpen {
                PDFThumbnailSidebar(
                    pdfManager: pdfManager,
                    isOpen: $isSidebarOpen
                )
                .transition(.move(edge: .leading))
            }
            
            singlePagePDFContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    private var singlePagePDFContent: some View {
        ZStack {
            Color(UIColor.systemGray6)
                .ignoresSafeArea()
            
            ZStack {
                PDFPageBackground(
                    pdfManager: pdfManager,
                    currentPageIndex: pdfManager.currentPageIndex
                )
                .scaleEffect(pdfManager.zoomLevel, anchor: .topLeading)
                .offset(panOffset)
                
                UnifiedBoardCanvasView(
                    editorData: editorData,
                    canvasMode: $canvasMode,
                    canvasSize: pdfManager.getCurrentPageSize(),
                    onModeChanged: { newMode in
                        print("📍 Canvas mode: \(newMode)")
                    },
                    onPaperKitItemAdded: {
                        print("📌 Item added to canvas - marking as unsaved")
                        pdfViewModel.hasUnsavedChanges = true
                    }
                )
                .id(canvasKey)
                
                if canvasMode == .selecting {
                    panGestureOverlay
                }
            }
        }
        .clipped()
        .onSizeChange { size in
            viewportSize = size
        }
        .gesture(singlePageZoomGesture)
    }
    
    private var panGestureOverlay: some View {
        Color.clear
            .contentShape(Rectangle())
            .highPriorityGesture(panGesture)
    }
    
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if pdfManager.zoomLevel > 1.0 {
                    let newOffset = CGSize(
                        width: lastPanValue.width + value.translation.width,
                        height: lastPanValue.height + value.translation.height
                    )
                    panOffset = constrainPanOffset(newOffset)
                }
            }
            .onEnded { _ in
                lastPanValue = panOffset
            }
    }
    
    private var singlePageZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if canvasMode == .selecting {
                    let newZoom = max(pdfManager.minZoom, min(initialZoomForGesture * scale, pdfManager.maxZoom))
                    pdfManager.setZoom(newZoom)
                }
            }
            .onEnded { _ in
                initialZoomForGesture = pdfManager.zoomLevel
                panOffset = constrainPanOffset(panOffset)
                lastPanValue = panOffset
            }
    }
    
    // MARK: - Helper Methods
    private func constrainPanOffset(_ offset: CGSize) -> CGSize {
        let pageSize = pdfManager.getCurrentPageSize()
        let scaledPageWidth = pageSize.width * pdfManager.zoomLevel
        let scaledPageHeight = pageSize.height * pdfManager.zoomLevel
        
        let maxPanX = max(0, (scaledPageWidth - viewportSize.width) / 2)
        let maxPanY = max(0, (scaledPageHeight - viewportSize.height) / 2)
        
        let constrainedX = max(-maxPanX, min(offset.width, maxPanX))
        let constrainedY = max(-maxPanY, min(offset.height, maxPanY))
        
        return CGSize(width: constrainedX, height: constrainedY)
    }
    
    private func resetCanvasForPageChange() {
        withAnimation(.easeInOut(duration: 0.1)) {
            canvasKey = UUID()
        }
        
        canvasMode = .drawing
        panOffset = .zero
        lastPanValue = .zero
        initialZoomForGesture = 1.0
        
        let pageSize = pdfManager.getCurrentPageSize()
        editorData.clearCanvas()
        editorData.initializeController(CGRect(origin: .zero, size: pageSize))
        
        print("🔄 Reset canvas for new page")
    }
    
    private func commitZoomChange() {
        if let zoomPercentage = Double(zoomInputText) {
            pdfManager.setZoomToValue(zoomPercentage)
            initialZoomForGesture = pdfManager.zoomLevel
        }
        isEditingZoom = false
    }
    
    private func commitPageNumberChange() {
        if let pageNum = Int(pageNumberInput), pageNum > 0 && pageNum <= pdfManager.pageCount {
            pdfManager.goToPage(pageNum - 1)
            resetCanvasForPageChange()
        }
        isEditingPageNumber = false
    }
    
    private func commitPageNumberChangeContinuous() {
        if let pageNum = Int(pageNumberInput), pageNum > 0 && pageNum <= pdfManager.pageCount {
            visiblePageIndex = pageNum - 1
        }
        isEditingPageNumber = false
    }
    
    private func commitTitleChange() {
        isEditingTitle = false
        
        guard !editedTitle.isEmpty else { return }
        
        if let currentURL = pdfViewModel.currentURL {
            let newURL = currentURL.deletingLastPathComponent()
                .appendingPathComponent(editedTitle)
                .appendingPathExtension("pdf")
            
            do {
                try FileManager.default.moveItem(at: currentURL, to: newURL)
                pdfViewModel.currentURL = newURL
                print("✅ File renamed to: \(editedTitle)")
            } catch {
                print("❌ Failed to rename file: \(error)")
            }
        }
    }
    
    private func handleBackButtonTap() {
        if pdfViewModel.hasUnsavedChanges {
            showSavePrompt = true
        } else {
            dismiss()
        }
    }
}

// MARK: - Drop Delegates
struct FixedContinuousPageDropDelegate: DropDelegate {
    let pageIndex: Int
    let position: Int
    @Binding var draggedPageIndex: Int?
    @Binding var dropTargetPosition: Int?
    @Binding var isDraggingOver: Bool
    var pdfManager: PDFManager
    @Binding var visiblePageIndex: Int
    @Binding var moveCounter: Int
    @Binding var pageToDelete: Int?
    
    private let thumbnailHeight: CGFloat = 116
    
    func dropEntered(info: DropInfo) {
        print("📥 Drop entered at position: \(position)")
        guard draggedPageIndex != nil else {
            print("⚠️ No dragged page index")
            return
        }
        
        isDraggingOver = true
        updateDropPosition(with: info)
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggedPageIndex != nil else { return DropProposal(operation: .forbidden) }
        
        updateDropPosition(with: info)
        return DropProposal(operation: .move)
    }
    
    private func updateDropPosition(with info: DropInfo) {
        let yOffset = info.location.y
        let positionInThumbnail = yOffset.truncatingRemainder(dividingBy: thumbnailHeight)
        
        if positionInThumbnail < thumbnailHeight / 2 {
            dropTargetPosition = position
        } else {
            dropTargetPosition = position + 1
        }
        
        print("📍 Drop target set to position: \(dropTargetPosition ?? 0)")
    }
    
    func dropExited() {
        print("📤 Drop exited")
        isDraggingOver = false
    }
    
    func performDrop(info: DropInfo) -> Bool {
        print("🎯 PERFORM DROP CALLED at position: \(position)")
        
        guard let draggedIdx = draggedPageIndex else {
            print("❌ performDrop: No draggedPageIndex")
            return false
        }
        
        guard let insertPosition = dropTargetPosition else {
            print("❌ No drop target position set")
            return false
        }
        
        if draggedIdx == insertPosition || draggedIdx == insertPosition - 1 {
            print("⚠️ Dropped on same page position, ignoring")
            DispatchQueue.main.async {
                draggedPageIndex = nil
                dropTargetPosition = nil
                isDraggingOver = false
                pageToDelete = nil
                self.moveCounter += 1
            }
            return true
        }
        
        print("🔄 REORDERING: Moving page \(draggedIdx + 1) to position \(insertPosition)")
        
        pdfManager.movePage(from: draggedIdx, to: insertPosition)
        
        if visiblePageIndex == draggedIdx {
            visiblePageIndex = insertPosition
            print("   Updated visible page to: \(insertPosition)")
        }
        
        print("✅ Drop operation completed successfully!")
        
        DispatchQueue.main.async {
            print("🧹 Resetting drag state BEFORE view refresh")
            draggedPageIndex = nil
            dropTargetPosition = nil
            isDraggingOver = false
            pageToDelete = nil
            self.moveCounter += 1
            print("📸 Incremented moveCounter to refresh views with clean drag state")
        }
        
        return true
    }
}

struct SinglePageDropDelegate: DropDelegate {
    let pageIndex: Int
    @Binding var draggedPageIndex: Int?
    @Binding var hoveredPageIndex: Int?
    @Binding var dropTargetPosition: Int?
    @Binding var isDraggingOver: Bool
    var pdfManager: PDFManager
    @Binding var moveCounter: Int
    
    private let thumbnailHeight: CGFloat = 116
    
    func dropEntered(info: DropInfo) {
        guard draggedPageIndex != nil else { return }
        
        isDraggingOver = true
        updateDropPosition(with: info)
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggedPageIndex != nil else { return DropProposal(operation: .forbidden) }
        
        updateDropPosition(with: info)
        return DropProposal(operation: .move)
    }
    
    private func updateDropPosition(with info: DropInfo) {
        let yOffset = info.location.y
        let positionInThumbnail = yOffset.truncatingRemainder(dividingBy: thumbnailHeight)
        
        if positionInThumbnail < thumbnailHeight / 2 {
            dropTargetPosition = pageIndex
        } else {
            dropTargetPosition = pageIndex + 1
        }
    }
    
    func dropExited() {
        isDraggingOver = false
        dropTargetPosition = nil
    }
    
    func performDrop(info: DropInfo) -> Bool {
        guard let draggedIndex = draggedPageIndex else { return false }
        
        guard let insertPosition = dropTargetPosition else { return false }
        
        if draggedIndex == insertPosition || draggedIndex == insertPosition - 1 {
            print("⚠️ Dropped on same page position, ignoring")
            DispatchQueue.main.async {
                draggedPageIndex = nil
                hoveredPageIndex = nil
                dropTargetPosition = nil
                isDraggingOver = false
                self.moveCounter += 1
            }
            return true
        }
        
        print("📄 Moved page \(draggedIndex + 1) to position \(insertPosition + 1)")
        pdfManager.movePage(from: draggedIndex, to: insertPosition)
        
        print("✅ Drop operation completed successfully!")
        
        DispatchQueue.main.async {
            print("🧹 Resetting drag state BEFORE view refresh")
            draggedPageIndex = nil
            hoveredPageIndex = nil
            dropTargetPosition = nil
            isDraggingOver = false
            
            self.moveCounter += 1
            print("📸 Incremented moveCounter to refresh views with clean drag state")
        }
        
        return true
    }
}

// MARK: - Thumbnail Sidebar
struct ContinuousScrollThumbnailSidebar: View {
    @ObservedObject var pdfManager: PDFManager
    @Binding var visiblePageIndex: Int
    @Binding var isOpen: Bool
    var onPageSelected: (Int) -> Void
    
    @State private var draggedPageIndex: Int?
    @State private var dropTargetPosition: Int?
    @State private var isDraggingOver: Bool = false
    @State private var pageToDelete: Int?
    @State private var showDeleteConfirmation = false
    @State private var moveCounter = 0
    @State private var isEditMode = false
    @State private var showFilePicker = false
    @State private var showInsertPositionDialog = false
    @State private var showPageNumberInput = false
    @State private var selectedPDFURL: URL?
    @State private var insertPosition: String = ""
    @State private var insertMethod: InsertMethod = .atEnd
    
    enum InsertMethod {
        case atFront
        case atEnd
        case afterPage
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        if let dropTarget = dropTargetPosition, dropTarget == 0 && isDraggingOver {
                            dropIndicatorLine
                        }
                        
                        ForEach(0..<pdfManager.pageCount, id: \.self) { position in
                            thumbnailItem(for: position, position: position)
                            
                            if let dropTarget = dropTargetPosition, dropTarget == position + 1 && isDraggingOver {
                                dropIndicatorLine
                            }
                        }
                        
                        addPageButton
                        addPDFButton
                        removePageButton
                    }
                    .padding(8)
                }
                .background(Color.gray.opacity(0.05))
                .onChange(of: visiblePageIndex) { _, newIndex in
                    guard !isEditMode, draggedPageIndex == nil else { return }
                    
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(visiblePageIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 120)
        .background(Color.white)
        .overlay(
            VStack { }
                .frame(width: 1)
                .background(Color.gray.opacity(0.2))
                .frame(maxWidth: .infinity, alignment: .trailing)
        )
        .alert("Delete Page?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let pageIndex = pageToDelete {
                    deletePage(at: pageIndex)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete page \(pageToDelete.map { $0 + 1 } ?? 0)? This cannot be undone.")
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf],
            onCompletion: { result in
                if case .success(let url) = result {
                    selectedPDFURL = url
                    showInsertPositionDialog = true
                }
            }
        )
        .confirmationDialog("Insert Position", isPresented: $showInsertPositionDialog) {
            Button("At Front") {
                insertMethod = .atFront
                insertPDF()
            }
            Button("At End") {
                insertMethod = .atEnd
                insertPDF()
            }
            Button("After Page...") {
                insertMethod = .afterPage
                showPageNumberInput = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Where would you like to insert the PDF?")
        }
        .alert("After Which Page?", isPresented: $showPageNumberInput) {
            TextField("Page number", text: $insertPosition)
                .keyboardType(.numberPad)
            
            Button("Insert") {
                if !insertPosition.isEmpty {
                    insertPDF()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter the page number after which to insert (1-\(pdfManager.pageCount))")
        }
    }
    
    private var dropIndicatorLine: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.blue)
            .frame(height: 3)
            .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private func thumbnailItem(for pageIndex: Int, position: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if !isEditMode {
                thumbnailButton(for: pageIndex, position: position)
                    .onDrag {
                        draggedPageIndex = pageIndex
                        print("🎯 Started dragging page \(pageIndex + 1)")
                        return NSItemProvider(object: "\(pageIndex)" as NSString)
                    }
                    .onDrop(of: [.text], delegate: FixedContinuousPageDropDelegate(
                        pageIndex: pageIndex,
                        position: position,
                        draggedPageIndex: $draggedPageIndex,
                        dropTargetPosition: $dropTargetPosition,
                        isDraggingOver: $isDraggingOver,
                        pdfManager: pdfManager,
                        visiblePageIndex: $visiblePageIndex,
                        moveCounter: $moveCounter,
                        pageToDelete: $pageToDelete
                    ))
            } else {
                thumbnailButton(for: pageIndex, position: position)
            }
            
            if isEditMode && draggedPageIndex != pageIndex && pageIndex != pageToDelete {
                Button(action: {
                    pageToDelete = pageIndex
                    showDeleteConfirmation = true
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.blue))
                }
                .padding(3)
            }
        }
        .padding(.vertical, 4)
        .id(pageIndex)
    }
    
    @ViewBuilder
    private func thumbnailButton(for pageIndex: Int, position: Int) -> some View {
        Button(action: { onPageSelected(pageIndex) }) {
            thumbnailContent(for: pageIndex)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(visiblePageIndex == pageIndex ? Color.blue.opacity(0.2) : Color.white)
                .border(visiblePageIndex == pageIndex ? Color.blue : Color.gray.opacity(0.3), width: visiblePageIndex == pageIndex ? 2 : 1)
                .cornerRadius(4)
                .opacity(draggedPageIndex == pageIndex ? 0.5 : 1.0)
        }
    }
    
    @ViewBuilder
    private func thumbnailContent(for pageIndex: Int) -> some View {
        VStack(spacing: 4) {
            if pageIndex < pdfManager.thumbnails.count,
               let image = pdfManager.thumbnails[pageIndex] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 100)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 100)
            }
            
            Text("Page \(pageIndex + 1)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary)
        }
    }
    
    @ViewBuilder
    private var addPageButton: some View {
        Button(action: { pdfManager.addBlankPage() }) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .border(Color.gray.opacity(0.3), width: 1)
                    
                    Image(systemName: "plus")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(.blue)
                }
                .frame(height: 100)
                
                Text("Add Page")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color.white)
            .border(Color.gray.opacity(0.3), width: 1)
            .cornerRadius(4)
        }
    }
    
    @ViewBuilder
    private var addPDFButton: some View {
        Button(action: { showFilePicker = true }) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .border(Color.gray.opacity(0.3), width: 1)
                    
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.blue)
                }
                .frame(height: 100)
                
                Text("Add PDF")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color.white)
            .border(Color.gray.opacity(0.3), width: 1)
            .cornerRadius(4)
        }
    }
    
    @ViewBuilder
    private var removePageButton: some View {
        Button(action: {
            isEditMode.toggle()
            if !isEditMode {
                pageToDelete = nil
                draggedPageIndex = nil
            }
        }) {
            HStack {
                Image(systemName: isEditMode ? "checkmark.circle.fill" : "pencil.circle")
                Text(isEditMode ? "Done" : "Remove Pages")
                Spacer()
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.white)
            .border(Color.blue, width: 1)
            .cornerRadius(4)
        }
    }
    
    private func insertPDF() {
        guard let pdfURL = selectedPDFURL else { return }
        
        let targetPosition: Int
        switch insertMethod {
        case .atFront:
            targetPosition = 0
            print("📥 Inserting PDF at front")
        case .atEnd:
            targetPosition = pdfManager.pageCount
            print("📥 Inserting PDF at end")
        case .afterPage:
            if let pageNum = Int(insertPosition), pageNum > 0 && pageNum <= pdfManager.pageCount {
                targetPosition = pageNum
                print("📥 Inserting PDF after page \(pageNum)")
            } else {
                print("❌ Invalid page number: \(insertPosition)")
                return
            }
        }
        
        pdfManager.insertPDF(from: pdfURL, at: targetPosition)
        
        selectedPDFURL = nil
        insertPosition = ""
        insertMethod = .atEnd
        showPageNumberInput = false
    }
    
    private func deletePage(at index: Int) {
        print("🗑️ Deleting page \(index + 1)")
        pdfManager.deletePage(at: index)
        
        draggedPageIndex = nil
        
        if visiblePageIndex >= pdfManager.pageCount {
            visiblePageIndex = max(0, pdfManager.pageCount - 1)
        }
        
        pageToDelete = nil
    }
}

#Preview {
    ContinuousScrollThumbnailSidebar(
        pdfManager: PDFManager(),
        visiblePageIndex: .constant(0),
        isOpen: .constant(true),
        onPageSelected: { _ in }
    )
}

// ✅ ADD THIS EXTENSION
extension UIView {
    var firstTextField: UITextField? {
        if let textField = self as? UITextField {
            return textField
        }
        
        for subview in subviews {
            if let textField = subview.firstTextField {
                return textField
            }
        }
        
        return nil
    }
}
