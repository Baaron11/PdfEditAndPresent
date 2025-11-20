import SwiftUI
import PDFKit

struct PrintPreviewSheet: View {
    @ObservedObject var pdfManager: PDFManager
    @Environment(\.dismiss) private var dismiss

    // Pager
    @State private var currentPage: Int = 1

    // Pages selection
    enum PagesChoice: Hashable { case all, custom, current }
    @State private var choice: PagesChoice = .all
    @State private var customInput: String = ""        // e.g. "1-3,5,8-9"
    @State private var customRange: ClosedRange<Int>? = nil
    @State private var customWarning: String? = nil

    // Options
    @State private var copies: Int = 1
    @State private var color: Bool = true
    @State private var duplex: PDFManager.DuplexMode = .none   // label will be "No" in UI
    @State private var orientation: PDFManager.PageOrientation = .auto

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
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 10) {
                        Button("As PDF") {
                            DocumentManager.shared.saveDocumentAs { success, _ in
                                if success { dismiss() }
                            }
                        }
                        Button(isPrinting ? "Printing..." : "Print") {
                            startPrint()
                        }
                        .disabled(pdfManager.pdfDocument == nil || pageCount == 0 || (choice == .custom && customRange == nil))
                    }
                }
            }
            .onAppear {
                currentPage = min(max(1, currentPage), max(1, pageCount))
                // Defaults for quality custom values
                applyQualityPreset(qualityPreset)
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
                            .onChange(of: customInput) { _, _ in validateAndParseCustom() }
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
            if let doc = pdfManager.pdfDocument {
                SinglePagePDFPreview(document: doc, pageIndex: currentPage - 1)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ContentUnavailableView("No Document", systemImage: "doc", description: Text("Open a PDF to print."))
            }
        }
    }

    private var pager: some View {
        HStack(spacing: 12) {
            Button {
                currentPage = max(1, currentPage - 1)
                syncChoiceForCurrentPage()
            } label: { Image(systemName: "chevron.left") }
            .disabled(currentPage <= 1)

            HStack(spacing: 8) {
                Text("Page")
                TextField("", value: $currentPage, format: .number)
                    .frame(width: 56, height: 30)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .onChange(of: currentPage) { _, newValue in
                        currentPage = clamp(newValue, 1, max(1, pageCount))
                        syncChoiceForCurrentPage()
                    }
                Text("of \(max(1, pageCount))")
            }
            .font(.callout)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .fixedSize(horizontal: true, vertical: false)

            Button {
                currentPage = min(max(1, pageCount), currentPage + 1)
                syncChoiceForCurrentPage()
            } label: { Image(systemName: "chevron.right") }
            .disabled(currentPage >= max(1, pageCount))

            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    // MARK: - Actions

    private func startPrint() {
        guard let _ = pdfManager.pdfDocument else { return }
        isPrinting = true

        let selection: PDFManager.PageSelectionMode = {
            switch choice {
            case .all: return .all
            case .current: return .current(currentPage)
            case .custom: return .custom(customRange ?? 1...max(1, pageCount))
            }
        }()

        guard let data = pdfManager.subsetPDFData(for: selection) else {
            isPrinting = false; return
        }

        let finish: (Data) -> Void = { readyData in
            #if os(iOS)
            pdfManager.presentPrintController(pdfData: readyData,
                                              jobName: jobName,
                                              copies: copies,
                                              color: color,
                                              duplex: duplex,
                                              orientation: orientation)
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

private struct RadioRow: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? .accentColor : .secondary)
                Text(title)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

extension PrintPreviewSheet {
    /// Parse "1-5,8,11-13" -> a closed range IF it represents one contiguous range.
    /// For non-contiguous, we compress into the min...max range for simplicity in this UI,
    /// and show a warning that non-contiguous ranges will print the full span.
    private func validateAndParseCustom() {
        customWarning = nil
        guard pageCount > 0 else { customRange = nil; return }

        let tokens = customInput.replacingOccurrences(of: " ", with: "").split(separator: ",")
        var indices: [Int] = []

        func addRange(_ a: Int, _ b: Int) {
            let lo = clamp(min(a, b), 1, pageCount)
            let hi = clamp(max(a, b), 1, pageCount)
            indices.append(contentsOf: Array(lo...hi))
        }

        for tok in tokens where !tok.isEmpty {
            if tok.contains("-") {
                let parts = tok.split(separator: "-")
                if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) {
                    addRange(a, b)
                } else { customWarning = "Invalid range near \"\(tok)\"" }
            } else if let n = Int(tok) {
                addRange(n, n)
            } else {
                customWarning = "Invalid token \"\(tok)\""
            }
        }

        if indices.isEmpty {
            customRange = nil
            if !customInput.isEmpty { customWarning = "Enter a range like 1-3, 5, 8-10" }
            return
        }

        let lo = indices.min()!
        let hi = indices.max()!
        if Set(indices) != Set(lo...hi) {
            customWarning = "Non-contiguous pages will be printed as \(lo)-\(hi)."
        }
        customRange = lo...hi
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
