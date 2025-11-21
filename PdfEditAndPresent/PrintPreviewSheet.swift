import SwiftUI
import PDFKit
import Combine
import UniformTypeIdentifiers

struct PrintPreviewSheet: View {
    @ObservedObject var pdfManager: PDFManager
    @Environment(\.dismiss) private var dismiss

    // Pager
    @State private var currentPage: Int = 1

    // Pages selection
    enum PagesChoice: Hashable { case all, custom, current }
    @State private var choice: PagesChoice = .all
    @State private var customInput: String = ""        // e.g. "1-3,5,8-9"
    @State private var customPages: [Int] = []         // exact pages to print (1-based)
    @State private var customWarning: String? = nil
    @State private var customDebounce: DispatchWorkItem?
    @FocusState private var customFieldFocused: Bool

    // Printer button anchor
    @State private var printerButtonHost: UIView?

    // Subset preview
    @State private var previewDoc: PDFDocument? = nil     // subset doc for the preview
    @State private var displayPage: Int = 1               // page within subset
    private var displayPageCount: Int { previewDoc?.pageCount ?? 0 }

    // Options
    @State private var copies: Int = 1
    @State private var color: Bool = true
    @State private var duplex: PDFManager.DuplexMode = .none   // label will be "No" in UI
    @State private var orientation: PDFManager.PageOrientation = .auto
    @State private var paperSize: PDFManager.PaperSize = .systemDefault
    @State private var pagesPerSheet: Int = 1
    @State private var borderStyle: PDFManager.BorderStyle = .none
    @State private var includeAnnotations: Bool = true

    // Quality (reusing Change File Size presets)
    @State private var qualityPreset: PDFOptimizeOptions.Preset = .original
    @State private var imageQuality: Double = 0.75
    @State private var maxDPI: Double = 144
    @State private var downsample = true
    @State private var grayscale = false
    @State private var stripMetadata = true
    @State private var flatten = false
    @State private var recompress = true

    @State private var isPrinting = false

    // Share sheet state
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false

    // Zoom handlers
    @State private var zoomInHandler: (() -> Void)?
    @State private var zoomOutHandler: (() -> Void)?
    @State private var fitHandler: (() -> Void)?

    // Export state
    @State private var exportURL: URL?
    @State private var showExporter = false

    private var pageCount: Int { pdfManager.pdfDocument?.pageCount ?? 0 }
    private var jobName: String { pdfManager.fileURL?.lastPathComponent ?? "Untitled.pdf" }

    private var previewLabels: [String] {
        switch choice {
        case .all:
            // Show 1..N (sheet pages after composition)
            return (1...(previewDoc?.pageCount ?? 1)).map { "Page \($0)" }
        case .current:
            return ["Page \(pdfManager.editorCurrentPage)"]
        case .custom:
            // Use original page numbers for user clarity
            return customPages.map { "Page \($0)" }
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                HStack(spacing: 16) {
                    // LEFT: Controls
                    controls
                        .frame(width: max(320, geo.size.width * 0.40))
                        .padding(.leading)

                    // RIGHT: Single-page preview + pager
                    VStack(spacing: 8) {
                        preview
                        pager
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing)
                }
            }
            .navigationTitle("Print Preview")
            .toolbarTitleDisplayMode(.inline)  // saves horizontal space
            .toolbar {
                // Back button (replaces the old .cancellationAction "Cancel")
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)   // text + chevron
                    }
                    .buttonStyle(.bordered)             // neutral, like old Cancel
                    .controlSize(.regular)
                }

                // Center: printer selector (unchanged)
                ToolbarItem(placement: .principal) {
                    ZStack(alignment: .center) {
                        Button {
                            guard let host = printerButtonHost else { return }
                            let rect = host.bounds.insetBy(dx: 0, dy: -4)
                            pdfManager.presentPrinterPicker(from: host, sourceRect: rect)
                        } label: {
                            Label(pdfManager.selectedPrinterName, systemImage: "printer")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        ViewAnchor(view: $printerButtonHost).allowsHitTesting(false)
                    }
                }

                // Right side: Share / As PDF / Print (neutral bordered; no blue fill)
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    HStack(spacing: 8) {
                        // Share
                        Button {
                            shareSelection()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .imageScale(.medium)
                                .accessibilityLabel("Share")
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .controlSize(.regular)

                        // Save As PDF (folder icon)
                        Button {
                            buildFinalPDFDataForCurrentSettings { data in
                                guard let data else { return }
                                let url = FileManager.default.temporaryDirectory
                                    .appendingPathComponent((jobName as NSString).deletingPathExtension + "_output.pdf")
                                try? data.write(to: url)
                                self.exportURL = url
                                self.showExporter = true
                            }
                        } label: {
                            Image(systemName: "folder")
                                .imageScale(.medium)
                                .accessibilityLabel("Save as PDF")
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .controlSize(.regular)

                        // Print
                        Button("Print") {
                            startPrint()
                        }
                        .disabled(pdfManager.pdfDocument == nil
                                  || (choice == .custom && customPages.isEmpty))
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .controlSize(.regular)
                    }
                }
            }
            .onAppear {
                currentPage = max(1, pdfManager.editorCurrentPage)
                applyQualityPreset(qualityPreset)
                rebuildPreviewDocument()
                pdfManager.restoreLastPrinterIfAvailable()
            }
            .onChange(of: choice) { _, _ in rebuildPreviewDocument() }
            .onChange(of: customPages) { _, _ in if choice == .custom { rebuildPreviewDocument() } }
            .onChange(of: pdfManager.editorCurrentPage) { _, _ in if choice == .current { rebuildPreviewDocument() } }
            .onChange(of: paperSize) { _, _ in rebuildPreviewDocument() }
            .onChange(of: pagesPerSheet) { _, _ in rebuildPreviewDocument() }
            .onChange(of: borderStyle) { _, _ in rebuildPreviewDocument() }
            .onChange(of: orientation) { _, _ in rebuildPreviewDocument() }
            .onChange(of: previewDoc) { _, _ in
                // Ensure correct fit the moment a new doc is composed
                DispatchQueue.main.async { fitHandler?() }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareItems)
            }
            .fileExporter(
                isPresented: $showExporter,
                document: (exportURL != nil ? ExportablePDF(url: exportURL!) : nil),
                contentType: .pdf,
                defaultFilename: (jobName as NSString).deletingPathExtension + "_output"
            ) { result in
                // Optional: handle success/failure; don't dismiss automatically
            }
        }
    }

    // MARK: - Views

    private var controls: some View {
        Form {
            Section("Pages") {
                RadioRow(title: "All Pages", isOn: choice == .all) { choice = .all }
                RadioRow(title: "Custom", isOn: choice == .custom) { choice = .custom }
                RadioRow(title: "Current Page Only", isOn: choice == .current) { choice = .current }

                if choice == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("ex 1-3 or 1,2,3 or 1-2,4", text: $customInput)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($customFieldFocused)
                            .onChange(of: customInput) { _, _ in
                                // Debounce parsing so the field keeps focus while typing
                                customDebounce?.cancel()
                                let work = DispatchWorkItem { parseCustomPages(keepFocus: true) }
                                customDebounce = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
                            }
                            .onAppear { DispatchQueue.main.async { customFieldFocused = true } }

                        if let warning = customWarning {
                            Text(warning).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Section("Options") {
                Stepper("Copies: \(copies)", value: $copies, in: 1...99)
                Toggle("Color", isOn: $color)
                Picker("Double Sided", selection: $duplex) {
                    Text("No").tag(PDFManager.DuplexMode.none)
                    Text("Short Edge").tag(PDFManager.DuplexMode.shortEdge)
                    Text("Long Edge").tag(PDFManager.DuplexMode.longEdge)
                }
                Picker("Orientation", selection: $orientation) {
                    Text("Auto").tag(PDFManager.PageOrientation.auto)
                    Text("Portrait").tag(PDFManager.PageOrientation.portrait)
                    Text("Landscape").tag(PDFManager.PageOrientation.landscape)
                }
                Toggle("Annotations", isOn: $includeAnnotations)
                    .tint(.accentColor)
            }

            Section("Layout") {
                Picker("Paper Size", selection: $paperSize) {
                    Text("System Default").tag(PDFManager.PaperSize.systemDefault)
                    Text("Letter").tag(PDFManager.PaperSize.letter)
                    Text("Legal").tag(PDFManager.PaperSize.legal)
                    Text("A4").tag(PDFManager.PaperSize.a4)
                }
                Picker("Pages per Sheet", selection: $pagesPerSheet) {
                    Text("1").tag(1); Text("2").tag(2); Text("4").tag(4); Text("6").tag(6); Text("8").tag(8)
                }
                Picker("Border", selection: $borderStyle) {
                    Text("None").tag(PDFManager.BorderStyle.none)
                    Text("Single HairLine").tag(PDFManager.BorderStyle.singleHair)
                    Text("Single Thin Line").tag(PDFManager.BorderStyle.singleThin)
                    Text("Double HairLine").tag(PDFManager.BorderStyle.doubleHair)
                    Text("Double Thin Line").tag(PDFManager.BorderStyle.doubleThin)
                }
                Picker("Quality", selection: $qualityPreset) {
                    Text("Original").tag(PDFOptimizeOptions.Preset.original)
                    Text("Smaller").tag(PDFOptimizeOptions.Preset.smaller)
                    Text("Smallest").tag(PDFOptimizeOptions.Preset.smallest)
                    Text("Custom").tag(PDFOptimizeOptions.Preset.custom)
                }
                .onChange(of: qualityPreset) { _, newValue in
                    applyQualityPreset(newValue)
                }

                if qualityPreset == .custom {
                    HStack {
                        Text("Image Quality")
                        Slider(value: $imageQuality, in: 0.4...1.0, step: 0.05)
                        Text("\(Int(imageQuality * 100))%")
                    }
                    HStack {
                        Text("Max Image DPI")
                        Slider(value: $maxDPI, in: 72...600, step: 12)
                        Text("\(Int(maxDPI))")
                    }
                    Toggle("Downsample Images", isOn: $downsample)
                    Toggle("Grayscale Images", isOn: $grayscale)
                    Toggle("Strip Metadata", isOn: $stripMetadata)
                    Toggle("Flatten Annotations", isOn: $flatten)
                    Toggle("Recompress Streams", isOn: $recompress)
                }
            }
        }
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            if let doc = previewDoc {
                LabeledContinuousPDFPreview(
                    document: doc,
                    labels: previewLabels,
                    currentPage: $displayPage,
                    onRegisterZoomHandlers: { zin, zout, fit in
                        self.zoomInHandler = zin
                        self.zoomOutHandler = zout
                        self.fitHandler = fit
                    }
                )
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // translucent zoom controls
                HStack(spacing: 8) {
                    Button { fitHandler?() }    label: { Image(systemName: "rectangle.arrowtriangle.2.outward") }
                    Button { zoomOutHandler?() } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { zoomInHandler?() }  label: { Image(systemName: "plus.magnifyingglass") }
                }
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
            } else {
                ContentUnavailableView("No Pages Selected", systemImage: "doc", description: Text("Choose pages to print."))
            }
        }
    }

    private var pager: some View {
        HStack(spacing: 12) {
            Button { displayPage = max(1, displayPage - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(displayPage <= 1)

            HStack(spacing: 8) {
                Text("Page")
                TextField("", value: $displayPage, format: .number)
                    .frame(width: 56, height: 30)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .onChange(of: displayPage) { _, newValue in
                        displayPage = clamp(newValue, 1, max(1, displayPageCount))
                    }
                Text("of \(max(1, displayPageCount))")
            }
            .font(.callout)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .fixedSize(horizontal: true, vertical: false)

            Button { displayPage = min(max(1, displayPageCount), displayPage + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(displayPage >= max(1, displayPageCount))

            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    // MARK: - Build Final PDF for Export

    private func buildFinalPDFDataForCurrentSettings(_ completion: @escaping (Data?) -> Void) {
        guard let subset = buildSubsetDocument() else { completion(nil); return }

        // Compose with layout/orientation so the file matches preview/print
        let composed = PreviewComposer.compose(
            subset: subset,
            paperSize: paperSize,
            pagesPerSheet: pagesPerSheet,
            border: borderStyle,
            orientation: orientation
        ) ?? subset

        guard let baseData = composed.dataRepresentation() else { completion(nil); return }

        if qualityPreset == .original {
            completion(baseData)
        } else {
            let opts = currentOptimizeOptions()
            pdfManager.optimizePDFData(baseData, options: opts) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let optimized): completion(optimized)
                    case .failure: completion(baseData)
                    }
                }
            }
        }
    }

    // MARK: - Preview Document Builder

    private func rebuildPreviewDocument() {
        guard let subset = buildSubsetDocument() else { previewDoc = nil; return }
        // Compose with layout so the user sees the true print layout
        let composed = PreviewComposer.compose(subset: subset,
                                               paperSize: paperSize,
                                               pagesPerSheet: pagesPerSheet,
                                               border: borderStyle,
                                               orientation: orientation)
        previewDoc = composed ?? subset
        displayPage = min(max(1, displayPage), previewDoc?.pageCount ?? 1)
    }

    private func buildSubsetDocument() -> PDFDocument? {
        guard let base = pdfManager.pdfDocument else { return nil }
        switch choice {
        case .all:
            return base
        case .current:
            let idx = max(0, min(pdfManager.editorCurrentPage-1, base.pageCount-1))
            let one = PDFDocument()
            if let p = base.page(at: idx) { one.insert(p, at: 0) }
            return one
        case .custom:
            guard !customPages.isEmpty else { return nil }
            let sub = PDFDocument()
            var i = 0
            for p in customPages.sorted() {
                if let pg = base.page(at: p-1) { sub.insert(pg, at: i); i += 1 }
            }
            return sub
        }
    }

    // MARK: - Actions

    private func shareSelection() {
        guard let base = buildSelectionData() else { return }

        let present: (URL) -> Void = { url in
            DispatchQueue.main.async {
                let act = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                   let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController,
                   root.presentedViewController == nil {
                    if let pop = act.popoverPresentationController {
                        pop.sourceView = root.view
                        pop.sourceRect = CGRect(x: root.view.bounds.midX, y: 10, width: 1, height: 1)
                        pop.permittedArrowDirections = []
                    }
                    root.present(act, animated: true)
                }
            }
        }

        let proceed: (Data) -> Void = { data in
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".pdf")
            try? data.write(to: tmp)
            present(tmp)
        }

        if qualityPreset == .original {
            proceed(base)
        } else {
            let opts = currentOptimizeOptions()
            pdfManager.optimizePDFData(base, options: opts) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let optimized): proceed(optimized)
                    case .failure: proceed(base)
                    }
                }
            }
        }
    }

    private func buildSelectionData() -> Data? {
        switch choice {
        case .all:     return pdfManager.pdfDocument?.dataRepresentation()
        case .current: return pdfManager.subsetPDFData(for: .current(pdfManager.editorCurrentPage))
        case .custom:
            guard !customPages.isEmpty else { return nil }
            let sub = PDFDocument()
            var i = 0
            for p in customPages.sorted() {
                if let pg = pdfManager.pdfDocument?.page(at: p-1) { sub.insert(pg, at: i); i += 1 }
            }
            return sub.dataRepresentation()
        }
    }

    private func startPrint() {
        guard let _ = pdfManager.pdfDocument else { return }
        isPrinting = true

        let selectionData: Data?
        switch choice {
        case .all:
            selectionData = pdfManager.pdfDocument?.dataRepresentation()

        case .current:
            selectionData = pdfManager.subsetPDFData(for: .current(pdfManager.editorCurrentPage))

        case .custom:
            if customPages.isEmpty { selectionData = nil }
            else {
                let sub = PDFDocument()
                var insert = 0
                for p in customPages.sorted() {
                    if let page = pdfManager.pdfDocument?.page(at: p - 1) {
                        sub.insert(page, at: insert); insert += 1
                    }
                }
                selectionData = sub.dataRepresentation()
            }
        }

        guard let data = selectionData else {
            isPrinting = false; return
        }

        let finish: (Data) -> Void = { readyData in
            #if os(iOS)
            pdfManager.presentPrintController(pdfData: readyData,
                                              jobName: jobName,
                                              copies: copies,
                                              color: color,
                                              duplex: duplex,
                                              orientation: orientation,
                                              pagesPerSheet: pagesPerSheet,
                                              paperSize: paperSize,
                                              borderStyle: borderStyle,
                                              includeAnnotations: includeAnnotations)
            #else
            pdfManager.presentPrintController(macData: readyData, jobName: jobName)
            #endif
            isPrinting = false
            dismiss()
        }

        if qualityPreset == .original {
            finish(data)
        } else {
            let opts = currentOptimizeOptions()
            pdfManager.optimizePDFData(data, options: opts) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let optimized): finish(optimized)
                    case .failure: finish(data) // fall back to original
                    }
                }
            }
        }
    }

    private func currentOptimizeOptions() -> PDFOptimizeOptions {
        PDFOptimizeOptions(
            preset: qualityPreset,
            imageQuality: imageQuality,
            maxImageDPI: maxDPI,
            downsampleImages: downsample,
            grayscaleImages: grayscale,
            stripMetadata: stripMetadata,
            flattenAnnotations: flatten,
            recompressStreams: recompress
        )
    }

    private func applyQualityPreset(_ p: PDFOptimizeOptions.Preset) {
        switch p {
        case .original:
            // no fields needed
            break
        case .smaller:
            imageQuality = 0.75; maxDPI = 144; downsample = true; grayscale = false; stripMetadata = true; flatten = false; recompress = true
        case .smallest:
            imageQuality = 0.6;  maxDPI = 96;  downsample = true; grayscale = false; stripMetadata = true; flatten = true;  recompress = true
        case .custom:
            // keep whatever user last used
            break
        }
    }

    private func syncChoiceForCurrentPage() {
        if choice == .current {
            // keep selection consistent with the pager
        }
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(hi, max(lo, v)) }
}

// MARK: - View Anchor for UIKit Presentation
private struct ViewAnchor: UIViewRepresentable {
    @Binding var view: UIView?
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        DispatchQueue.main.async { self.view = v }
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

extension PrintPreviewSheet {
    /// Parse "1-5,8,11-13" into an exact list of pages (non-contiguous supported)
    private func parseCustomPages(keepFocus: Bool = false) {
        customWarning = nil
        guard pageCount > 0 else { customPages = []; previewDoc = nil; return }

        let cleaned = customInput.replacingOccurrences(of: " ", with: "")
        if cleaned.isEmpty { customPages = []; previewDoc = nil; return }

        var pages = Set<Int>()

        for token in cleaned.split(separator: ",") {
            if token.contains("-") {
                let parts = token.split(separator: "-")
                guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else {
                    customWarning = "Invalid range near \"\(token)\""; continue
                }
                let lo = clamp(min(a, b), 1, pageCount)
                let hi = clamp(max(a, b), 1, pageCount)
                for p in lo...hi { pages.insert(p) }
            } else if let p = Int(token) {
                pages.insert(clamp(p, 1, pageCount))
            } else {
                customWarning = "Invalid token \"\(token)\""
            }
        }

        customPages = pages.sorted()
        rebuildPreviewDocument()                     // update preview
        if keepFocus { DispatchQueue.main.async { self.customFieldFocused = true } } // keep cursor
    }
}

// MARK: - Continuous PDFKit wrapper
struct ContinuousPDFPreview: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .secondarySystemBackground
        v.document = document
        v.delegate = context.coordinator
        if let p = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) { v.go(to: p) }
        return v
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document { uiView.document = document }
        uiView.displayMode = .singlePageContinuous
        uiView.displayDirection = .vertical
        uiView.autoScales = true
        if let p = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) { uiView.go(to: p) }
    }

    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, PDFViewDelegate {
        var parent: ContinuousPDFPreview
        init(_ p: ContinuousPDFPreview) { self.parent = p }
        func pdfViewPageChanged(_ sender: Notification) {
            guard let v = sender.object as? PDFView,
                  let page = v.currentPage,
                  let idx = v.document?.index(for: page) else { return }
            parent.currentPage = idx + 1
        }
    }
}

// MARK: - Single-page PDFKit wrapper
struct SinglePagePDFPreview: UIViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePage
        v.displayDirection = .horizontal
        v.backgroundColor = .secondarySystemBackground
        v.document = document
        if let page = document.page(at: max(0, min(pageIndex, document.pageCount-1))) {
            v.go(to: page)
        }
        return v
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
        }
        if let page = document.page(at: max(0, min(pageIndex, document.pageCount-1))) {
            uiView.go(to: page)
        }
        uiView.displayMode = .singlePage
        uiView.displayDirection = .horizontal
        uiView.autoScales = true
    }
}

// MARK: - Exportable PDF Document

struct ExportablePDF: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var url: URL
    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { self.url = FileManager.default.temporaryDirectory }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return try FileWrapper(url: url, options: .immediate)
    }
}

#Preview {
    PrintPreviewSheet(pdfManager: PDFManager())
}
