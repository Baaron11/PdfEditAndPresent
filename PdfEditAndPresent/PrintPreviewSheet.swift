import SwiftUI
import PDFKit
import Combine
import UniformTypeIdentifiers

struct PrintPreviewSheet: View {
    @ObservedObject var pdfManager: PDFManager
    @Environment(\.dismiss) private var dismiss

    // State Management - Split into groups for clarity
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
                pageState: pageState,
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
        (pageState.choice == .custom && pageState.customPages.isEmpty)
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
        pageState.currentPage = max(1, pdfManager.editorCurrentPage)
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
        
        switch pageState.choice {
        case .all:
            return base
            
        case .current:
            let idx = max(0, min(pdfManager.editorCurrentPage - 1, base.pageCount - 1))
            let one = PDFDocument()
            if let p = base.page(at: idx) {
                one.insert(p, at: 0)
            }
            return one.pageCount > 0 ? one : nil
            
        case .custom:
            // Return nil if no pages are selected to show "No Pages Selected"
            guard !pageState.customPages.isEmpty else { return nil }
            
            let sub = PDFDocument()
            var i = 0
            for p in pageState.customPages.sorted() {
                if p > 0 && p <= base.pageCount {
                    if let pg = base.page(at: p - 1) {
                        sub.insert(pg, at: i)
                        i += 1
                    }
                }
            }
            return sub.pageCount > 0 ? sub : nil
        }
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
        switch pageState.choice {
        case .all:
            return pdfManager.pdfDocument?.dataRepresentation()
        case .current:
            return pdfManager.subsetPDFData(for: .current(pdfManager.editorCurrentPage))
        case .custom:
            guard !pageState.customPages.isEmpty else { return nil }
            let sub = PDFDocument()
            var i = 0
            for p in pageState.customPages.sorted() {
                if let pg = pdfManager.pdfDocument?.page(at: p - 1) {
                    sub.insert(pg, at: i)
                    i += 1
                }
            }
            return sub.dataRepresentation()
        }
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

class PageSelectionState: ObservableObject {
    enum Choice: Hashable { case all, custom, current }
    @Published var choice: Choice = .all
    @Published var currentPage: Int = 1
    @Published var customInput: String = ""
    @Published var customPages: [Int] = []
    @Published var customWarning: String? = nil
    var customDebounce: DispatchWorkItem?
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
    @ObservedObject var pageState: PageSelectionState
    @ObservedObject var printState: PrintOptionsState
    @ObservedObject var previewState: PreviewState
    let pdfManager: PDFManager
    let rebuildAction: () -> Void
    
    func body(content: Content) -> some View {
        content
            .onChange(of: pageState.choice) { _, _ in rebuildAction() }
            .onChange(of: pageState.customPages) { _, _ in
                if pageState.choice == .custom { rebuildAction() }
            }
            .onChange(of: pdfManager.editorCurrentPage) { _, _ in
                if pageState.choice == .current { rebuildAction() }
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
    @ObservedObject var pageState: PageSelectionState
    @ObservedObject var printState: PrintOptionsState
    @FocusState.Binding var customFieldFocused: Bool
    let pageCount: Int
    let currentEditorPage: Int

    var body: some View {
        Form {
            PagesFormSection(
                pageState: pageState,
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
    @ObservedObject var pageState: PageSelectionState
    @FocusState.Binding var customFieldFocused: Bool
    let pageCount: Int
    let currentEditorPage: Int

    // Text shown in field when disabled (non-custom modes)
    private var autoFillTextForNonCustom: String {
        switch pageState.choice {
        case .all:
            return pageCount > 0 ? "1-\(pageCount)" : ""
        case .current:
            return "\(max(1, currentEditorPage))"
        case .custom:
            return pageState.customInput
        }
    }

    var body: some View {
        Section("Pages") {
            VStack(alignment: .leading, spacing: 12) {
                // 1) All Pages
                RadioRow(title: "All Pages", isOn: pageState.choice == .all) {
                    pageState.choice = .all
                    pageState.customInput = pageCount > 0 ? "1-\(pageCount)" : ""
                }

                // 2) Current Page (renamed from "Current Page Only")
                RadioRow(title: "Current Page", isOn: pageState.choice == .current) {
                    pageState.choice = .current
                    pageState.customInput = "\(max(1, currentEditorPage))"
                }

                // 3) Custom + always-visible text field
                HStack(alignment: .center, spacing: 8) {
                    RadioRow(title: "Custom", isOn: pageState.choice == .custom) {
                        // Seed with current value so user can extend it
                        if pageState.choice != .custom {
                            switch pageState.choice {
                            case .current:
                                pageState.customInput = "\(max(1, currentEditorPage))"
                            case .all:
                                pageState.customInput = pageCount > 0 ? "1-\(pageCount)" : ""
                            case .custom:
                                break
                            }
                        }
                        pageState.choice = .custom
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
                                    get: {
                                        pageState.choice == .custom ? pageState.customInput : autoFillTextForNonCustom
                                    },
                                    set: { newValue in
                                        if pageState.choice == .custom {
                                            pageState.customInput = newValue
                                        }
                                    }
                                  )
                        )
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($customFieldFocused)
                        .frame(maxWidth: 200)
                        .disabled(pageState.choice != .custom)
                        .accessibilityLabel("Page range")
                        .accessibilityValue(pageState.choice == .custom ? pageState.customInput : autoFillTextForNonCustom)
                        .accessibilityHint(pageState.choice == .custom ? "Editable" : "Select Custom to edit")

                        if let warning = pageState.customWarning, pageState.choice == .custom {
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Spacer()
                }
            }
        }
        // Initialize field on appear
        .onAppear {
            if pageState.customInput.isEmpty {
                pageState.customInput = pageCount > 0 ? "1-\(pageCount)" : ""
            }
        }
        // Parse when user edits in Custom mode
        .onChange(of: pageState.customInput) { _, _ in
            if pageState.choice == .custom {
                handleCustomInputChange()
            }
        }
    }

    private func handleCustomInputChange() {
        pageState.customDebounce?.cancel()
        let work = DispatchWorkItem {
            parseCustomPages(keepFocus: true)
            DispatchQueue.main.async {
                pageState.customPages = pageState.customPages
            }
        }
        pageState.customDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    private func parseCustomPages(keepFocus: Bool = false) {
        pageState.customWarning = nil
        guard pageCount > 0 else {
            pageState.customPages = []
            return
        }

        let cleaned = pageState.customInput.replacingOccurrences(of: " ", with: "")
        if cleaned.isEmpty {
            pageState.customPages = []
            return
        }

        var pages = Set<Int>()

        for token in cleaned.split(separator: ",") {
            if token.contains("-") {
                let parts = token.split(separator: "-")
                guard parts.count == 2,
                      let a = Int(parts[0]),
                      let b = Int(parts[1]) else {
                    pageState.customWarning = "Invalid range"
                    continue
                }
                let lo = min(max(min(a, b), 1), pageCount)
                let hi = min(max(max(a, b), 1), pageCount)
                for p in lo...hi {
                    pages.insert(p)
                }
            } else if let p = Int(token) {
                pages.insert(min(max(p, 1), pageCount))
            } else {
                pageState.customWarning = "Invalid format"
            }
        }

        pageState.customPages = pages.sorted()

        if keepFocus {
            DispatchQueue.main.async {
                customFieldFocused = true
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
    @ObservedObject var pageState: PageSelectionState
    let pdfManager: PDFManager
    @State private var hasInitializedFit = false
    @State private var lastChoice: PageSelectionState.Choice? = nil
    
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
                .onChange(of: pageState.choice) { _, newChoice in
                    // Force a fit when switching away from custom or to a new choice
                    if lastChoice != newChoice {
                        lastChoice = newChoice
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
