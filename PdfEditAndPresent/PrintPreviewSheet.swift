import SwiftUI
import PDFKit

struct PrintPreviewSheet: View {
    @ObservedObject var pdfManager: PDFManager
    @Environment(\.dismiss) private var dismiss

    @State private var useRange = false
    @State private var startPage = 1
    @State private var endPage = 1
    @State private var copies = 1
    @State private var color = true
    @State private var duplex: PDFManager.DuplexMode = .none
    @State private var orientation: PDFManager.PageOrientation = .auto

    var pageCount: Int { pdfManager.pdfDocument?.pageCount ?? 0 }
    var jobName: String { pdfManager.pdfDocument?.documentURL?.lastPathComponent ?? "Untitled.pdf" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Live preview
                if let doc = pdfManager.pdfDocument {
                    PDFPreviewView(document: doc)
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal)
                } else {
                    ContentUnavailableView("No Document", systemImage: "doc", description: Text("Open a PDF to print."))
                        .frame(maxHeight: 300)
                }

                Form {
                    Section("Pages") {
                        Toggle("Use Range", isOn: $useRange)
                        if useRange {
                            HStack {
                                Stepper("Start: \(startPage)", value: $startPage, in: 1...(pageCount > 0 ? pageCount : 1))
                                Stepper("End: \(endPage)", value: $endPage, in: 1...(pageCount > 0 ? pageCount : 1))
                            }
                            .onChange(of: startPage) { _, newValue in
                                endPage = max(endPage, newValue)
                            }
                            .onChange(of: endPage) { _, newValue in
                                startPage = min(startPage, newValue)
                            }
                        } else {
                            Text(pageCount > 0 ? "All pages (1-\(pageCount))" : "-")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Options") {
                        Stepper("Copies: \(copies)", value: $copies, in: 1...99)
                        Toggle("Color", isOn: $color)
                        Picker("Duplex", selection: $duplex) {
                            Text("None").tag(PDFManager.DuplexMode.none)
                            Text("Short Edge").tag(PDFManager.DuplexMode.shortEdge)
                            Text("Long Edge").tag(PDFManager.DuplexMode.longEdge)
                        }
                        Picker("Orientation", selection: $orientation) {
                            Text("Auto").tag(PDFManager.PageOrientation.auto)
                            Text("Portrait").tag(PDFManager.PageOrientation.portrait)
                            Text("Landscape").tag(PDFManager.PageOrientation.landscape)
                        }
                    }
                }
            }
            .navigationTitle("Print Preview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Print") {
                        guard pdfManager.pdfDocument != nil else { return }
                        let range: ClosedRange<Int>? = useRange ? (min(startPage, endPage)...max(startPage, endPage)) : nil
                        if let data = pdfManager.makeSubsetPDFData(range: range) {
                            pdfManager.presentPrintController(
                                pdfData: data,
                                jobName: jobName,
                                copies: copies,
                                color: color,
                                duplex: duplex,
                                orientation: orientation
                            )
                            dismiss()
                        }
                    }
                    .disabled(pdfManager.pdfDocument == nil || pageCount == 0)
                }
            }
            .onAppear {
                if pageCount > 0 {
                    startPage = 1
                    endPage = pageCount
                }
            }
        }
    }
}

// MARK: - PDFKit preview wrapper
struct PDFPreviewView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .secondarySystemBackground
        v.document = document
        return v
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
        }
        uiView.autoScales = true
    }
}

#Preview {
    PrintPreviewSheet(pdfManager: PDFManager())
}
