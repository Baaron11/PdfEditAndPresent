import SwiftUI
import PDFKit
import Combine

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
    @State private var customInputCancellable: AnyCancellable?
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

    private var pageCount: Int { pdfManager.pdfDocument?.pageCount ?? 0 }
    private var jobName: String { pdfManager.fileURL?.lastPathComponent ?? "Untitled.pdf" }

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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                // Printer dropdown between Cancel and right controls
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
                        ViewAnchor(view: $printerButtonHost).allowsHitTesting(false)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 8) {
                        // Share button
                        Button {
                            shareSelection()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)

                        // As PDF
                        Button("As PDF") {
                            pdfManager.saveDocumentAs { success, _ in
                                if success { dismiss() }
                            }
                        }
                        .buttonStyle(.bordered)

                        // Print
                        Button(isPrinting ? "Printing..." : "Print") {
                            startPrint()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pdfManager.pdfDocument == nil || pageCount == 0 || (choice == .custom && customPages.isEmpty))
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
                            .onAppear {
                                // Debounce parsing so the field keeps focus while typing
                                customInputCancellable = Just(customInput)
                                    .merge(with: $customInput.dropFirst().eraseToAnyPublisher())
                                    .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                                    .sink { _ in
                                        parseCustomPages(keepFocus: true)
                                    }
                                // Ensure we keep focus when the user enters Custom
                                DispatchQueue.main.async { customFieldFocused = true }
                            }
                            .onDisappear { customInputCancellable?.cancel() }

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
                Picker("Double Sided", selection: $duplex) {      // renamed; default shown as "No"
                    Text("No").tag(PDFManager.DuplexMode.none)
                    Text("Short Edge").tag(PDFManager.DuplexMode.shortEdge)
                    Text("Long Edge").tag(PDFManager.DuplexMode.longEdge)
                }
                Picker("Orientation", selection: $orientation) {
                    Text("Auto").tag(PDFManager.PageOrientation.auto)
                    Text("Portrait").tag(PDFManager.PageOrientation.portrait)
                    Text("Landscape").tag(PDFManager.PageOrientation.landscape)
                }
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
                Toggle("Annotations", isOn: $includeAnnotations)
                    .tint(.accentColor)
                // QUALITY
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
                    Section {
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
    }

    private var preview: some View {
        ZStack {
            if let doc = previewDoc {
                ContinuousPDFPreview(document: doc, currentPage: $displayPage)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    // MARK: - Preview Document Builder

    private func rebuildPreviewDocument() {
        guard let base = pdfManager.pdfDocument else { previewDoc = nil; return }

        switch choice {
        case .all:
            previewDoc = base
            displayPage = min(max(1, displayPage), base.pageCount)

        case .current:
            let idx = clamp(pdfManager.editorCurrentPage, 1, max(1, base.pageCount)) - 1
            let one = PDFDocument()
            if let p = base.page(at: idx) { one.insert(p, at: 0) }
            previewDoc = one
            displayPage = 1

        case .custom:
            guard !customPages.isEmpty else { previewDoc = nil; displayPage = 1; return }
            let sub = PDFDocument()
            var insert = 0
            for p in customPages {
                if let page = base.page(at: p - 1) { sub.insert(page, at: insert); insert += 1 }
            }
            previewDoc = sub
            displayPage = min(max(1, displayPage), sub.pageCount)
        }
    }

    // MARK: - Actions

    private func shareSelection() {
        let baseData: Data?
        switch choice {
        case .all:
            baseData = pdfManager.pdfDocument?.dataRepresentation()
        case .current:
            baseData = pdfManager.subsetPDFData(for: .current(pdfManager.editorCurrentPage))
        case .custom:
            if customPages.isEmpty { baseData = nil }
            else {
                let sub = PDFDocument()
                var insert = 0
                for p in customPages.sorted() {
                    if let page = pdfManager.pdfDocument?.page(at: p - 1) {
                        sub.insert(page, at: insert); insert += 1
                    }
                }
                baseData = sub.dataRepresentation()
            }
        }

        guard let baseData = baseData else { return }

        let presentActivity: (Data) -> Void = { data in
            let activityVC = UIActivityViewController(activityItems: [data], applicationActivities: nil)
            activityVC.excludedActivityTypes = []
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
               let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                if let pop = activityVC.popoverPresentationController {
                    pop.sourceView = root.view
                    pop.sourceRect = CGRect(x: root.view.bounds.midX, y: 10, width: 1, height: 1)
                    pop.permittedArrowDirections = []
                }
                root.present(activityVC, animated: true)
            }
        }

        if qualityPreset == .original {
            presentActivity(baseData)
        } else {
            let opts = currentOptimizeOptions()
            pdfManager.optimizePDFData(baseData, options: opts) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let optimized): presentActivity(optimized)
                    case .failure: presentActivity(baseData)
                    }
                }
            }
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
                    customWarning = "Invalid range near "\(token)""; continue
                }
                let lo = clamp(min(a, b), 1, pageCount)
                let hi = clamp(max(a, b), 1, pageCount)
                for p in lo...hi { pages.insert(p) }
            } else if let p = Int(token) {
                pages.insert(clamp(p, 1, pageCount))
            } else {
                customWarning = "Invalid token "\(token)""
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

#Preview {
    PrintPreviewSheet(pdfManager: PDFManager())
}
