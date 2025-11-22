import SwiftUI
import PDFKit
import Combine
import UniformTypeIdentifiers

struct PrintPreviewSheet: View {
    @ObservedObject var pdfManager: PDFManager
    @Environment(\.dismiss) private var dismiss

    // State Management - Split into groups for clarity
    @StateObject private var viewModel = PrintOptionsViewModel()
    @StateObject private var pageState = PageSelectionState()
    @StateObject private var printState = PrintOptionsState()
    @StateObject private var previewState = PreviewState()
    @StateObject private var shareState = ShareExportState()
    @StateObject private var zoomState = ZoomState()

    // UI State
    @State private var printerButtonHost: UIView?
    @FocusState private var customFieldFocused: Bool
    
    private var pageCount: Int { pdfManager.pdfDocument?.pageCount ?? 0 }
    private var jobName: String { pdfManager.fileURL?.lastPathComponent ?? "Untitled.pdf" }

    var body: some View {
        content
    }
    
    // Split body into minimal pieces
    private var content: some View {
        baseView
            .modifier(ShareSheetModifier(shareState: shareState))
            .modifier(FileExporterModifier(shareState: shareState, jobName: jobName))
    }
    
    private var baseView: some View {
        NavigationStack {
            innerContent
        }
    }
    
    private var innerContent: some View {
        mainLayout
            .modifier(NavigationSetupModifier())
            .modifier(ToolbarModifier(
                pdfManager: pdfManager,
                printerButtonHost: $printerButtonHost,
                shareAction: { shareSelection() },
                saveAction: { handleSaveAsPDF() },
                printAction: { startPrint() },
                printDisabled: printDisabled
            ))
            .modifier(LifecycleModifier(
                onAppear: { setupOnAppear() }
            ))
            .modifier(ChangeObserverModifier(
                viewModel: viewModel,
                pageState: pageState,
                printState: printState,
                previewState: previewState,
                pdfManager: pdfManager,
                rebuildAction: { rebuildPreviewDocument() }
            ))
    }
    
    private var mainLayout: some View {
        GeometryReader { geo in
            HStack(spacing: 16) {
                leftPanel
                    .frame(width: max(320, geo.size.width * 0.40))
                
                rightPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing)
            }
        }
    }
    
    private var leftPanel: some View {
        PrintOptionsForm(
            viewModel: viewModel,
            pageState: pageState,
            printState: printState,
            customFieldFocused: $customFieldFocused,
            pageCount: pageCount,
            currentEditorPage: pdfManager.editorCurrentPage
        )
    }
    
    private var rightPanel: some View {
        VStack(spacing: 8) {
            PDFPreviewArea(
                previewState: previewState,
                zoomState: zoomState,
                viewModel: viewModel,
                pdfManager: pdfManager
            )

            PageNavigator(
                currentPage: $previewState.displayPage,
                maxPage: previewState.displayPageCount
            )
        }
    }
    
    // MARK: - Computed Properties
    
    private var printDisabled: Bool {
        pdfManager.pdfDocument == nil ||
        (viewModel.selection.isCustom && viewModel.resolvedPages.isEmpty)
    }
    
    private var previewLabels: [String] {
        switch pageState.choice {
        case .all:
            // Show actual page numbers 1..N
            return (1...(previewState.previewDoc?.pageCount ?? 1)).map { "Page \($0)" }
        case .current:
            // Show the actual current page number
            return ["Page \(pdfManager.editorCurrentPage)"]
        case .custom:
            // Show the actual page numbers selected (e.g., "Page 1", "Page 4", "Page 5")
            return pageState.customPages.map { "Page \($0)" }
        }
    }
    
    // MARK: - Actions
    
    private func setupOnAppear() {
        // Initialize viewModel with page count and current page
        viewModel.setPageCount(pageCount)
        viewModel.switchToMode(.all, currentEditorPage: pdfManager.editorCurrentPage)

        // Sync legacy state
        pageState.viewModel = viewModel
        pageState.currentPage = max(1, pdfManager.editorCurrentPage)
        pageState.syncFromViewModel()

        applyQualityPreset(printState.qualityPreset)
        rebuildPreviewDocument()
        pdfManager.restoreLastPrinterIfAvailable()

        // Force a rebuild after a short delay to ensure proper initial layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.rebuildPreviewDocument()
        }
    }
    
    private func rebuildPreviewDocument() {
        // Store previous document for comparison
        let previousDoc = previewState.previewDoc
        
        guard let subset = buildSubsetDocument() else {
            previewState.previewDoc = nil
            return
        }
        
        let composed = PreviewComposer.compose(
            subset: subset,
            paperSize: printState.paperSize,
            pagesPerSheet: printState.pagesPerSheet,
            border: printState.borderStyle,
            orientation: printState.orientation
        )
        
        let newDoc = composed ?? subset
        
        // Only update and trigger fit if document actually changed
        if previousDoc !== newDoc {
            previewState.previewDoc = newDoc
            previewState.displayPage = min(max(1, previewState.displayPage),
                                          newDoc.pageCount ?? 1)
            
            // Trigger a fit after rebuilding with a slight delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.zoomState.fitHandler?()
            }
        }
    }
    
    private func buildSubsetDocument() -> PDFDocument? {
        guard let base = pdfManager.pdfDocument else { return nil }

        // Use viewModel.resolvedPages as the single source of truth
        let pages = viewModel.resolvedPages

        // Return nil if no pages selected
        guard !pages.isEmpty else { return nil }

        // If all pages selected and it's the full document, return as-is
        if pages.count == base.pageCount && pages == IndexSet(1...base.pageCount) {
            return base
        }

        // Build subset document
        let sub = PDFDocument()
        var i = 0
        for p in pages.sorted() {
            if p > 0 && p <= base.pageCount {
                if let pg = base.page(at: p - 1) {
                    sub.insert(pg, at: i)
                    i += 1
                }
            }
        }
        return sub.pageCount > 0 ? sub : nil
    }
    
    private func shareSelection() {
        guard let data = buildSelectionData() else { return }
        processDataForSharing(data)
    }
    
    private func processDataForSharing(_ data: Data) {
        if printState.qualityPreset == .original {
            shareData(data)
        } else {
            let opts = currentOptimizeOptions()
            pdfManager.optimizePDFData(data, options: opts) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let optimized):
                        self.shareData(optimized)
                    case .failure:
                        self.shareData(data)
                    }
                }
            }
        }
    }
    
    private func shareData(_ data: Data) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf")
        try? data.write(to: tmp)
        presentShareSheet(url: tmp)
    }
    
    private func presentShareSheet(url: URL) {
        shareState.shareItems = [url]
        shareState.showShareSheet = true
    }
    
    private func handleSaveAsPDF() {
        buildFinalPDFDataForCurrentSettings { data in
            guard let data else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent((jobName as NSString).deletingPathExtension + "_output.pdf")
            try? data.write(to: url)
            shareState.exportURL = url
            shareState.showExporter = true
        }
    }
    
    private func startPrint() {
        // Implementation remains the same
        guard pdfManager.pdfDocument != nil else { return }
        
        let selectionData = buildPrintSelectionData()
        guard let data = selectionData else { return }
        
        if printState.qualityPreset == .original {
            executePrint(with: data)
        } else {
            let opts = currentOptimizeOptions()
            pdfManager.optimizePDFData(data, options: opts) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let optimized):
                        self.executePrint(with: optimized)
                    case .failure:
                        self.executePrint(with: data)
                    }
                }
            }
        }
    }
    
    private func executePrint(with data: Data) {
        #if os(iOS)
        pdfManager.presentPrintController(
            pdfData: data,
            jobName: jobName,
            copies: printState.copies,
            color: printState.color,
            duplex: printState.duplex,
            orientation: printState.orientation,
            pagesPerSheet: printState.pagesPerSheet,
            paperSize: printState.paperSize,
            borderStyle: printState.borderStyle,
            includeAnnotations: printState.includeAnnotations
        )
        #else
        pdfManager.presentPrintController(macData: data, jobName: jobName)
        #endif
        dismiss()
    }
    
    private func buildSelectionData() -> Data? {
        guard let base = pdfManager.pdfDocument else { return nil }

        let pages = viewModel.resolvedPages
        guard !pages.isEmpty else { return nil }

        // If all pages, return full document
        if pages.count == base.pageCount && pages == IndexSet(1...base.pageCount) {
            return base.dataRepresentation()
        }

        // Build subset
        let sub = PDFDocument()
        var i = 0
        for p in pages.sorted() {
            if p > 0 && p <= base.pageCount {
                if let pg = base.page(at: p - 1) {
                    sub.insert(pg, at: i)
                    i += 1
                }
            }
        }
        return sub.dataRepresentation()
    }
    
    private func buildPrintSelectionData() -> Data? {
        return buildSelectionData()
    }
    
    private func buildFinalPDFDataForCurrentSettings(_ completion: @escaping (Data?) -> Void) {
        guard let subset = buildSubsetDocument() else {
            completion(nil)
            return
        }
        
        let composed = PreviewComposer.compose(
            subset: subset,
            paperSize: printState.paperSize,
            pagesPerSheet: printState.pagesPerSheet,
            border: printState.borderStyle,
            orientation: printState.orientation
        ) ?? subset
        
        guard let baseData = composed.dataRepresentation() else {
            completion(nil)
            return
        }
        
        if printState.qualityPreset == .original {
            completion(baseData)
        } else {
            let opts = currentOptimizeOptions()
            pdfManager.optimizePDFData(baseData, options: opts) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let optimized):
                        completion(optimized)
                    case .failure:
                        completion(baseData)
                    }
                }
            }
        }
    }
    
    private func currentOptimizeOptions() -> PDFOptimizeOptions {
        PDFOptimizeOptions(
            preset: printState.qualityPreset,
            imageQuality: printState.imageQuality,
            maxImageDPI: printState.maxDPI,
            downsampleImages: printState.downsample,
            grayscaleImages: printState.grayscale,
            stripMetadata: printState.stripMetadata,
            flattenAnnotations: printState.flatten,
            recompressStreams: printState.recompress
        )
    }
    
    private func applyQualityPreset(_ p: PDFOptimizeOptions.Preset) {
        switch p {
        case .original:
            break
        case .smaller:
            printState.imageQuality = 0.75
            printState.maxDPI = 144
            printState.downsample = true
            printState.grayscale = false
            printState.stripMetadata = true
            printState.flatten = false
            printState.recompress = true
        case .smallest:
            printState.imageQuality = 0.6
            printState.maxDPI = 96
            printState.downsample = true
            printState.grayscale = false
            printState.stripMetadata = true
            printState.flatten = true
            printState.recompress = true
        case .custom:
            break
        }
    }
}

// MARK: - State Objects

/// Single source of truth for page selection state
final class PrintOptionsViewModel: ObservableObject {
    enum PageSelection: Equatable {
        case all
        case current(Int) // 1-based
        case custom(String) // raw text as typed

        var isCustom: Bool {
            if case .custom = self { return true }
            return false
        }
    }

    @Published var selection: PageSelection = .all
    @Published var pageCount: Int = 1

    /// The resolved pages to print (1-based), updates whenever selection changes
    @Published private(set) var resolvedPages: IndexSet = []

    /// Warning message for invalid custom input
    @Published private(set) var customWarning: String? = nil

    /// Last successfully applied custom string
    private(set) var lastAppliedCustom: String = ""

    /// Debounce work item for parsing
    private var parseDebounce: DispatchWorkItem?

    init() {
        // Initial resolved pages
        resolvedPages = IndexSet(1...1)
    }

    func setPageCount(_ n: Int) {
        let oldCount = pageCount
        pageCount = max(1, n)

        // Re-resolve if pageCount changed
        if oldCount != pageCount {
            resolveSelection()
        }
    }

    func setCurrentPage(_ page: Int) {
        if case .current = selection {
            selection = .current(page)
            resolveSelection()
        }
    }

    /// Switch to a new selection mode, with appropriate prefill behavior
    func switchToMode(_ newMode: PageSelection, currentEditorPage: Int) {
        let previousSelection = selection

        switch newMode {
        case .all:
            selection = .all
            resolveSelection()

        case .current(let page):
            selection = .current(page > 0 ? page : currentEditorPage)
            resolveSelection()

        case .custom(let explicitText):
            // If explicit text provided, use it
            if !explicitText.isEmpty {
                selection = .custom(explicitText)
            } else {
                // Determine prefill based on previous selection
                let prefill: String
                switch previousSelection {
                case .all:
                    prefill = pageCount > 0 ? "1-\(pageCount)" : ""
                case .current(let page):
                    prefill = "\(page)"
                case .custom(let existingText):
                    prefill = existingText
                }
                selection = .custom(prefill)
            }
            // Immediately parse and apply
            resolveSelection()
        }
    }

    /// Update custom text and trigger debounced parsing
    func updateCustomText(_ text: String) {
        guard case .custom = selection else { return }
        selection = .custom(text)

        // Debounce parsing
        parseDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.resolveSelection()
        }
        parseDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Parse and apply custom text immediately (no debounce)
    func parseAndApplyCustom(_ text: String) {
        selection = .custom(text)
        resolveSelection()
    }

    /// Get current custom text (returns empty string if not in custom mode)
    var customText: String {
        if case .custom(let text) = selection {
            return text
        }
        return ""
    }

    /// Resolve current selection to IndexSet
    private func resolveSelection() {
        customWarning = nil

        switch selection {
        case .all:
            if pageCount > 0 {
                resolvedPages = IndexSet(1...pageCount)
            } else {
                resolvedPages = []
            }

        case .current(let page):
            let validPage = max(1, min(page, pageCount))
            resolvedPages = IndexSet(integer: validPage)

        case .custom(let text):
            let result = Self.parsePageRanges(text, pageCount: pageCount)
            resolvedPages = result.pages
            customWarning = result.warning
            if !result.pages.isEmpty {
                lastAppliedCustom = text
            }
        }
    }

    /// Parse custom page range string into IndexSet
    /// Returns parsed pages and optional warning message
    static func parsePageRanges(_ input: String, pageCount: Int) -> (pages: IndexSet, warning: String?) {
        guard pageCount > 0 else {
            return ([], nil)
        }

        let cleaned = input.replacingOccurrences(of: " ", with: "")
        if cleaned.isEmpty {
            return ([], nil)
        }

        var pages = IndexSet()
        var warning: String? = nil

        for token in cleaned.split(separator: ",") {
            let tokenStr = String(token)

            if tokenStr.contains("-") {
                let parts = tokenStr.split(separator: "-")
                guard parts.count == 2,
                      let a = Int(parts[0]),
                      let b = Int(parts[1]),
                      a > 0, b > 0 else {
                    warning = "Invalid range"
                    continue
                }

                let lo = max(1, min(min(a, b), pageCount))
                let hi = max(1, min(max(a, b), pageCount))

                if lo <= pageCount {
                    pages.insert(integersIn: lo...hi)
                }
            } else if let p = Int(tokenStr) {
                if p > 0 && p <= pageCount {
                    pages.insert(p)
                } else if p <= 0 {
                    // Ignore zeros and negatives
                    continue
                }
                // Out of range pages are silently ignored (clamped)
            } else {
                warning = "Invalid format"
            }
        }

        if pages.isEmpty && !cleaned.isEmpty {
            warning = "Invalid range"
        }

        return (pages, warning)
    }
}

// Legacy compatibility wrapper
class PageSelectionState: ObservableObject {
    enum Choice: Hashable { case all, custom, current }

    @Published var choice: Choice = .all
    @Published var currentPage: Int = 1
    @Published var customInput: String = ""
    @Published var customPages: [Int] = []
    @Published var customWarning: String? = nil
    var customDebounce: DispatchWorkItem?

    /// Reference to the new view model for migration
    weak var viewModel: PrintOptionsViewModel?

    /// Sync from viewModel to legacy state
    func syncFromViewModel() {
        guard let vm = viewModel else { return }

        switch vm.selection {
        case .all:
            choice = .all
        case .current(let page):
            choice = .current
            currentPage = page
        case .custom(let text):
            choice = .custom
            customInput = text
        }

        customPages = Array(vm.resolvedPages).sorted()
        customWarning = vm.customWarning
    }
}

class PrintOptionsState: ObservableObject {
    @Published var copies: Int = 1
    @Published var color: Bool = true
    @Published var duplex: PDFManager.DuplexMode = .none
    @Published var orientation: PDFManager.PageOrientation = .auto
    @Published var paperSize: PDFManager.PaperSize = .systemDefault
    @Published var pagesPerSheet: Int = 1
    @Published var borderStyle: PDFManager.BorderStyle = .none
    @Published var includeAnnotations: Bool = true
    @Published var qualityPreset: PDFOptimizeOptions.Preset = .original
    @Published var imageQuality: Double = 0.75
    @Published var maxDPI: Double = 144
    @Published var downsample = true
    @Published var grayscale = false
    @Published var stripMetadata = true
    @Published var flatten = false
    @Published var recompress = true
}

class PreviewState: ObservableObject {
    @Published var previewDoc: PDFDocument? = nil
    @Published var displayPage: Int = 1
    var displayPageCount: Int { previewDoc?.pageCount ?? 0 }
}

class ShareExportState: ObservableObject {
    @Published var shareItems: [Any] = []
    @Published var showShareSheet = false
    @Published var exportURL: URL?
    @Published var showExporter = false
}

class ZoomState: ObservableObject {
    @Published var zoomInHandler: (() -> Void)?
    @Published var zoomOutHandler: (() -> Void)?
    @Published var fitHandler: (() -> Void)?
}

// MARK: - View Modifiers

struct NavigationSetupModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .navigationTitle("Print Preview")
            .toolbarTitleDisplayMode(.inline)
    }
}

struct ShareSheetModifier: ViewModifier {
    @ObservedObject var shareState: ShareExportState
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $shareState.showShareSheet) {
                ShareSheet(items: shareState.shareItems)
            }
    }
}

struct FileExporterModifier: ViewModifier {
    @ObservedObject var shareState: ShareExportState
    let jobName: String
    
    func body(content: Content) -> some View {
        content
            .fileExporter(
                isPresented: $shareState.showExporter,
                document: shareState.exportURL != nil ? ExportablePDF(url: shareState.exportURL!) : nil,
                contentType: .pdf,
                defaultFilename: (jobName as NSString).deletingPathExtension + "_output"
            ) { _ in }
    }
}

struct LifecycleModifier: ViewModifier {
    let onAppear: () -> Void
    
    func body(content: Content) -> some View {
        content.onAppear(perform: onAppear)
    }
}

struct ChangeObserverModifier: ViewModifier {
    @ObservedObject var viewModel: PrintOptionsViewModel
    @ObservedObject var pageState: PageSelectionState
    @ObservedObject var printState: PrintOptionsState
    @ObservedObject var previewState: PreviewState
    let pdfManager: PDFManager
    let rebuildAction: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.selection) { _, _ in
                pageState.syncFromViewModel()
                rebuildAction()
            }
            .onChange(of: viewModel.resolvedPages) { _, _ in
                pageState.syncFromViewModel()
                rebuildAction()
            }
            .onChange(of: pdfManager.editorCurrentPage) { _, newPage in
                viewModel.setCurrentPage(newPage)
            }
            .onChange(of: printState.paperSize) { _, _ in rebuildAction() }
            .onChange(of: printState.pagesPerSheet) { _, _ in rebuildAction() }
            .onChange(of: printState.borderStyle) { _, _ in rebuildAction() }
            .onChange(of: printState.orientation) { _, _ in rebuildAction() }
    }
}

// MARK: - Toolbar Modifier

struct ToolbarModifier: ViewModifier {
    @ObservedObject var pdfManager: PDFManager
    @Binding var printerButtonHost: UIView?
    let shareAction: () -> Void
    let saveAction: () -> Void
    let printAction: () -> Void
    let printDisabled: Bool
    
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                BackToolbarButton()
            }
            
            ToolbarItem(placement: .principal) {
                PrinterSelectorButton(
                    pdfManager: pdfManager,
                    printerButtonHost: $printerButtonHost
                )
            }
            
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                HStack(spacing: 8) {
                    ShareToolbarButton(action: shareAction)
                    SaveToolbarButton(action: saveAction)
                    PrintToolbarButton(action: printAction, disabled: printDisabled)
                }
            }
        }
    }
}

// Individual Toolbar Buttons
struct BackToolbarButton: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Button {
            dismiss()
        } label: {
            Label("Back", systemImage: "chevron.left")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

struct PrinterSelectorButton: View {
    @ObservedObject var pdfManager: PDFManager
    @Binding var printerButtonHost: UIView?
    
    var body: some View {
        ZStack(alignment: .center) {
            Button {
                guard let host = printerButtonHost else { return }
                let rect = host.bounds.insetBy(dx: 0, dy: -4)
                pdfManager.presentPrinterPicker(from: host, sourceRect: rect)
            } label: {
                Label(
                    pdfManager.selectedPrinterName.isEmpty ? "Select Printer" : pdfManager.selectedPrinterName,
                    systemImage: "printer"
                )
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            ViewAnchor(view: $printerButtonHost)
                .allowsHitTesting(false)
        }
    }
}

struct ShareToolbarButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.arrow.up")
                .imageScale(.medium)
                .accessibilityLabel("Share")
        }
        .buttonStyle(.bordered)
        .tint(.blue)
        .controlSize(.regular)
    }
}

struct SaveToolbarButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "folder")
                .imageScale(.medium)
                .accessibilityLabel("Save as PDF")
        }
        .buttonStyle(.bordered)
        .tint(.blue)
        .controlSize(.regular)
    }
}

struct PrintToolbarButton: View {
    let action: () -> Void
    let disabled: Bool
    
    var body: some View {
        Button("Print", action: action)
            .disabled(disabled)
            .buttonStyle(.bordered)
            .tint(.blue)
            .controlSize(.regular)
    }
}

// MARK: - Supporting Views (keep existing implementations)

struct PrintOptionsForm: View {
    @ObservedObject var viewModel: PrintOptionsViewModel
    @ObservedObject var pageState: PageSelectionState
    @ObservedObject var printState: PrintOptionsState
    @FocusState.Binding var customFieldFocused: Bool
    let pageCount: Int
    let currentEditorPage: Int

    var body: some View {
        Form {
            PagesFormSection(
                viewModel: viewModel,
                customFieldFocused: $customFieldFocused,
                pageCount: pageCount,
                currentEditorPage: currentEditorPage
            )

            OptionsFormSection(printState: printState)

            LayoutFormSection(printState: printState)
        }
    }
}

struct PagesFormSection: View {
    @ObservedObject var viewModel: PrintOptionsViewModel
    @FocusState.Binding var customFieldFocused: Bool
    let pageCount: Int
    let currentEditorPage: Int

    // Local state for custom text field
    @State private var customText: String = ""

    // Check if current selection is each mode
    private var isAll: Bool {
        if case .all = viewModel.selection { return true }
        return false
    }

    private var isCurrent: Bool {
        if case .current = viewModel.selection { return true }
        return false
    }

    private var isCustom: Bool {
        viewModel.selection.isCustom
    }

    // Text shown in field when disabled (non-custom modes)
    private var displayText: String {
        switch viewModel.selection {
        case .all:
            return pageCount > 0 ? "1-\(pageCount)" : ""
        case .current(let page):
            return "\(page)"
        case .custom:
            return customText
        }
    }

    var body: some View {
        Section("Pages") {
            VStack(alignment: .leading, spacing: 12) {
                // 1) All Pages
                RadioRow(title: "All Pages", isOn: isAll) {
                    viewModel.switchToMode(.all, currentEditorPage: currentEditorPage)
                }

                // 2) Current Page
                RadioRow(title: "Current Page", isOn: isCurrent) {
                    viewModel.switchToMode(.current(currentEditorPage), currentEditorPage: currentEditorPage)
                }

                // 3) Custom + always-visible text field
                HStack(alignment: .center, spacing: 8) {
                    RadioRow(title: "Custom", isOn: isCustom) {
                        // Switch to custom mode - viewModel handles prefill
                        viewModel.switchToMode(.custom(""), currentEditorPage: currentEditorPage)
                        // Update local text from viewModel
                        customText = viewModel.customText
                        // Focus the field for immediate editing
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            customFieldFocused = true
                        }
                    }
                    .frame(minWidth: 100, alignment: .leading)

                    // Text field is ALWAYS visible
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("e.g. 1-3, 5, 7-9",
                                  text: Binding(
                                    get: { isCustom ? customText : displayText },
                                    set: { newValue in
                                        if isCustom {
                                            customText = newValue
                                            viewModel.updateCustomText(newValue)
                                        }
                                    }
                                  )
                        )
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($customFieldFocused)
                        .frame(maxWidth: 200)
                        .disabled(!isCustom)
                        .accessibilityLabel("Page range")
                        .accessibilityValue(isCustom ? customText : displayText)
                        .accessibilityHint(isCustom ? "Editable" : "Select Custom to edit")

                        if let warning = viewModel.customWarning, isCustom {
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Spacer()
                }
            }
        }
        // Sync local customText when viewModel's selection changes
        .onChange(of: viewModel.selection) { _, newSelection in
            if case .custom(let text) = newSelection {
                customText = text
            }
        }
        // Initialize on appear
        .onAppear {
            viewModel.setPageCount(pageCount)
            if case .custom(let text) = viewModel.selection {
                customText = text
            }
        }
    }
}


struct OptionsFormSection: View {
    @ObservedObject var printState: PrintOptionsState
    
    var body: some View {
        Section("Options") {
            Stepper("Copies: \(printState.copies)", value: $printState.copies, in: 1...99)
            
            Toggle("Color", isOn: $printState.color)
                .tint(.blue)
            
            DuplexPicker(duplex: $printState.duplex)
            
            OrientationPicker(orientation: $printState.orientation)
            
            Toggle("Annotations", isOn: $printState.includeAnnotations)
                .tint(.accentColor)
        }
    }
}

struct DuplexPicker: View {
    @Binding var duplex: PDFManager.DuplexMode
    
    var body: some View {
        Picker("Double Sided", selection: $duplex) {
            Text("No").tag(PDFManager.DuplexMode.none)
            Text("Short Edge").tag(PDFManager.DuplexMode.shortEdge)
            Text("Long Edge").tag(PDFManager.DuplexMode.longEdge)
        }
    }
}

struct OrientationPicker: View {
    @Binding var orientation: PDFManager.PageOrientation
    
    var body: some View {
        Picker("Orientation", selection: $orientation) {
            Text("Auto").tag(PDFManager.PageOrientation.auto)
            Text("Portrait").tag(PDFManager.PageOrientation.portrait)
            Text("Landscape").tag(PDFManager.PageOrientation.landscape)
        }
    }
}

struct LayoutFormSection: View {
    @ObservedObject var printState: PrintOptionsState
    
    var body: some View {
        Section("Layout") {
            BasicLayoutOptions(printState: printState)
            QualityOptions(printState: printState)
        }
    }
}

struct BasicLayoutOptions: View {
    @ObservedObject var printState: PrintOptionsState
    
    var body: some View {
        Group {
            PaperSizePicker(paperSize: $printState.paperSize)
            PagesPerSheetPicker(pagesPerSheet: $printState.pagesPerSheet)
            BorderStylePicker(borderStyle: $printState.borderStyle)
        }
    }
}

struct PaperSizePicker: View {
    @Binding var paperSize: PDFManager.PaperSize
    
    var body: some View {
        Picker("Paper Size", selection: $paperSize) {
            Text("System Default").tag(PDFManager.PaperSize.systemDefault)
            Text("Letter").tag(PDFManager.PaperSize.letter)
            Text("Legal").tag(PDFManager.PaperSize.legal)
            Text("A4").tag(PDFManager.PaperSize.a4)
        }
    }
}

struct PagesPerSheetPicker: View {
    @Binding var pagesPerSheet: Int
    
    var body: some View {
        Picker("Pages per Sheet", selection: $pagesPerSheet) {
            Text("1").tag(1)
            Text("2").tag(2)
            Text("4").tag(4)
            Text("6").tag(6)
            Text("8").tag(8)
        }
    }
}

struct BorderStylePicker: View {
    @Binding var borderStyle: PDFManager.BorderStyle
    
    var body: some View {
        Picker("Border", selection: $borderStyle) {
            Text("None").tag(PDFManager.BorderStyle.none)
            Text("Single HairLine").tag(PDFManager.BorderStyle.singleHair)
            Text("Single Thin Line").tag(PDFManager.BorderStyle.singleThin)
            Text("Double HairLine").tag(PDFManager.BorderStyle.doubleHair)
            Text("Double Thin Line").tag(PDFManager.BorderStyle.doubleThin)
        }
    }
}

struct QualityOptions: View {
    @ObservedObject var printState: PrintOptionsState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            QualityPresetPicker(
                preset: $printState.qualityPreset,
                onPresetChange: applyPreset
            )
            
            if printState.qualityPreset == .custom {
                CustomQualitySettings(printState: printState)
            }
        }
    }
    
    private func applyPreset(_ p: PDFOptimizeOptions.Preset) {
        switch p {
        case .original:
            break
        case .smaller:
            printState.imageQuality = 0.75
            printState.maxDPI = 144
            printState.downsample = true
            printState.grayscale = false
            printState.stripMetadata = true
            printState.flatten = false
            printState.recompress = true
        case .smallest:
            printState.imageQuality = 0.6
            printState.maxDPI = 96
            printState.downsample = true
            printState.grayscale = false
            printState.stripMetadata = true
            printState.flatten = true
            printState.recompress = true
        case .custom:
            break
        }
    }
}

struct QualityPresetPicker: View {
    @Binding var preset: PDFOptimizeOptions.Preset
    let onPresetChange: (PDFOptimizeOptions.Preset) -> Void
    
    var body: some View {
        Picker("Quality", selection: $preset) {
            Text("Original").tag(PDFOptimizeOptions.Preset.original)
            Text("Smaller").tag(PDFOptimizeOptions.Preset.smaller)
            Text("Smallest").tag(PDFOptimizeOptions.Preset.smallest)
            Text("Custom").tag(PDFOptimizeOptions.Preset.custom)
        }
        .onChange(of: preset) { _, newValue in
            onPresetChange(newValue)
        }
    }
}

struct CustomQualitySettings: View {
    @ObservedObject var printState: PrintOptionsState
    
    var body: some View {
        Group {
            ImageQualitySlider(quality: $printState.imageQuality)
            MaxDPISlider(dpi: $printState.maxDPI)
            
            Toggle("Downsample Images", isOn: $printState.downsample)
            Toggle("Grayscale Images", isOn: $printState.grayscale)
            Toggle("Strip Metadata", isOn: $printState.stripMetadata)
            Toggle("Flatten Annotations", isOn: $printState.flatten)
            Toggle("Recompress Streams", isOn: $printState.recompress)
        }
    }
}

struct ImageQualitySlider: View {
    @Binding var quality: Double
    
    var body: some View {
        HStack {
            Text("Image Quality")
            Slider(value: $quality, in: 0.4...1.0, step: 0.05)
            Text("\(Int(quality * 100))%")
        }
    }
}

struct MaxDPISlider: View {
    @Binding var dpi: Double
    
    var body: some View {
        HStack {
            Text("Max Image DPI")
            Slider(value: $dpi, in: 72...600, step: 12)
            Text("\(Int(dpi))")
        }
    }
}

// MARK: - PDF Preview Components

struct PDFPreviewArea: View {
    @ObservedObject var previewState: PreviewState
    @ObservedObject var zoomState: ZoomState
    @ObservedObject var viewModel: PrintOptionsViewModel
    let pdfManager: PDFManager
    @State private var hasInitializedFit = false
    @State private var lastSelection: PrintOptionsViewModel.PageSelection? = nil

    var body: some View {
        ZStack {
            if let doc = previewState.previewDoc {
                LabeledContinuousPDFPreview(
                    document: doc,
                    labels: buildLabels(),
                    currentPage: $previewState.displayPage,
                    onRegisterZoomHandlers: { zin, zout, fit in
                        registerHandlers(zin: zin, zout: zout, fit: fit)
                    }
                )
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onAppear {
                    performInitialFit()
                }
                .onChange(of: doc) { oldDoc, newDoc in
                    // Only perform fit if document actually changed
                    if oldDoc !== newDoc {
                        hasInitializedFit = false
                        performInitialFit()
                    }
                }
                .onChange(of: viewModel.selection) { _, newSelection in
                    // Force a fit when switching modes
                    if lastSelection != newSelection {
                        lastSelection = newSelection
                        hasInitializedFit = false
                        // Delay slightly to let the view update
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.performInitialFit()
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Pages Selected",
                    systemImage: "doc",
                    description: Text("Choose pages to print.")
                )
            }
        }
        .overlay(alignment: .top) {
            if previewState.previewDoc != nil {
                ZoomControls(zoomState: zoomState)
            }
        }
    }

    private func buildLabels() -> [String] {
        // Use resolvedPages as single source of truth for labels
        let pages = viewModel.resolvedPages.sorted()
        return pages.map { "Page \($0)" }
    }

    private func registerHandlers(zin: @escaping () -> Void,
                                 zout: @escaping () -> Void,
                                 fit: @escaping () -> Void) {
        DispatchQueue.main.async {
            zoomState.zoomInHandler = zin
            zoomState.zoomOutHandler = zout
            zoomState.fitHandler = fit

            // Trigger initial fit after handlers are registered
            if !self.hasInitializedFit {
                self.performInitialFit()
            }
        }
    }

    private func performInitialFit() {
        // Reset the flag
        hasInitializedFit = false

        // Try multiple times with delays to ensure view is laid out
        let delays: [Double] = [0.05, 0.15, 0.25, 0.35, 0.5]

        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // Check if we still need to fit
                if !self.hasInitializedFit, let fitHandler = self.zoomState.fitHandler {
                    fitHandler()
                    // Mark as done on last iteration
                    if index == delays.count - 1 {
                        self.hasInitializedFit = true
                    }
                }
            }
        }
    }
}

struct ZoomControls: View {
    @ObservedObject var zoomState: ZoomState
    
    var body: some View {
        HStack(spacing: 8) {
            Button { zoomState.zoomOutHandler?() } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            
            Button { zoomState.fitHandler?() } label: {
                Text("Fit")
            }
            
            Button { zoomState.zoomInHandler?() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 10)
    }
}

struct PageNavigator: View {
    @Binding var currentPage: Int
    let maxPage: Int
    
    var body: some View {
        HStack(spacing: 12) {
            Button {
                currentPage = max(1, currentPage - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(currentPage <= 1)
            
            PageNumberField(currentPage: $currentPage, maxPage: maxPage)
            
            Button {
                currentPage = min(max(1, maxPage), currentPage + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(currentPage >= max(1, maxPage))
            
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }
}

struct PageNumberField: View {
    @Binding var currentPage: Int
    let maxPage: Int
    
    var body: some View {
        HStack(spacing: 8) {
            Text("Page")
            
            TextField("", value: $currentPage, format: .number)
                .frame(width: 56, height: 30)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad)
                .onChange(of: currentPage) { _, newValue in
                    currentPage = min(max(1, newValue), max(1, maxPage))
                }
            
            Text("of \(max(1, maxPage))")
        }
        .font(.callout)
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Supporting Views

private struct ViewAnchor: UIViewRepresentable {
    @Binding var view: UIView?
    
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        DispatchQueue.main.async {
            self.view = v
        }
        return v
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct RadioRow: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(title)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

#Preview {
    PrintPreviewSheet(pdfManager: PDFManager())
}
