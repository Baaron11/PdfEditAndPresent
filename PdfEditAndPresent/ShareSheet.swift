//import SwiftUI
//
//struct ShareSheet: UIViewControllerRepresentable {
//    let items: [Any]
//
//    func makeUIViewController(context: Context) -> UIActivityViewController {
//        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
//        return vc
//    }
//    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
//}
// MARK: - Supporting Views for PrintPreviewSheet

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Labeled Continuous PDF Preview
//struct LabeledContinuousPDFPreview: View {
//    let document: PDFDocument
//    let labels: [String]
//    @Binding var currentPage: Int
//    let onRegisterZoomHandlers: (
//        _ zoomIn: @escaping () -> Void,
//        _ zoomOut: @escaping () -> Void,
//        _ fit: @escaping () -> Void
//    ) -> Void
//    
//    var body: some View {
//        ContinuousPDFPreview(
//            document: document,
//            currentPage: $currentPage,
//            onRegisterZoomHandlers: onRegisterZoomHandlers
//        )
//    }
//}

// MARK: - Continuous PDFKit wrapper
struct ContinuousPDFPreview: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int
    var onRegisterZoomHandlers: ((
        _ zoomIn: @escaping () -> Void,
        _ zoomOut: @escaping () -> Void,
        _ fit: @escaping () -> Void
    ) -> Void)?
    
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .secondarySystemBackground
        v.document = document
        v.delegate = context.coordinator
        
        if let p = document.page(at: max(0, min(currentPage - 1, document.pageCount - 1))) {
            v.go(to: p)
        }
        
        // Register zoom handlers
        onRegisterZoomHandlers?(
            { v.scaleFactor = v.scaleFactor * 1.25 },
            { v.scaleFactor = v.scaleFactor / 1.25 },
            { v.autoScales = false; v.autoScales = true }
        )
        
        return v
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
        }
        
        uiView.displayMode = .singlePageContinuous
        uiView.displayDirection = .vertical
        uiView.autoScales = true
        
        if let p = document.page(at: max(0, min(currentPage - 1, document.pageCount - 1))) {
            uiView.go(to: p)
        }
    }
    
    func makeCoordinator() -> Coord {
        Coord(self)
    }
    
    final class Coord: NSObject, PDFViewDelegate {
        var parent: ContinuousPDFPreview
        
        init(_ p: ContinuousPDFPreview) {
            self.parent = p
        }
        
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
        
        if let page = document.page(at: max(0, min(pageIndex, document.pageCount - 1))) {
            v.go(to: page)
        }
        
        return v
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
        }
        
        if let page = document.page(at: max(0, min(pageIndex, document.pageCount - 1))) {
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
    
    init(url: URL) {
        self.url = url
    }
    
    init(configuration: ReadConfiguration) throws {
        self.url = FileManager.default.temporaryDirectory
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return try FileWrapper(url: url, options: .immediate)
    }
}

// MARK: - Preview Composer (Placeholder)
// Note: This is a placeholder - you'll need to implement your actual PreviewComposer logic
//struct PreviewComposer {
//    static func compose(
//        subset: PDFDocument,
//        paperSize: PDFManager.PaperSize,
//        pagesPerSheet: Int,
//        border: PDFManager.BorderStyle,
//        orientation: PDFManager.PageOrientation
//    ) -> PDFDocument? {
//        // Your implementation here
//        return subset
//    }
//}

#Preview {
    PrintPreviewSheet(pdfManager: PDFManager())
}
