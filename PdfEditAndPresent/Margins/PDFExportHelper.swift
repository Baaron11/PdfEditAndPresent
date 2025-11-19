import PDFKit
import UIKit
import PencilKit

// MARK: - PDF Export Helper (Dynamic Canvas)
struct PDFExportHelper {
    
    let pdfManager: PDFManager
    let pageIndex: Int
    let marginHelper: MarginCanvasHelper
    
    enum ExportOption { case pdfOnly, marginsOnly, both }
    
    // MARK: - Page Rendering
    
    func renderPageImage(includeMargins: Bool) -> UIImage? {
        guard let pdfPage = pdfManager.pdfDocument?.page(at: pageIndex) else { return nil }
        
        let renderSize: CGSize = {
            if includeMargins {
                return marginHelper.canvasSize  // dynamic canvas
            } else {
                return pdfPage.bounds(for: .mediaBox).size
            }
        }()
        
        let image = UIGraphicsImageRenderer(size: renderSize).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: renderSize))
            
            if includeMargins {
                let pdfFrame = marginHelper.pdfFrameInCanvas
                context.cgContext.saveGState()
                
                // Translate to the top-left of the frame, then scale by pdfScale
                context.cgContext.translateBy(x: pdfFrame.origin.x, y: pdfFrame.origin.y)
                context.cgContext.scaleBy(x: marginHelper.settings.pdfScale, y: marginHelper.settings.pdfScale)
                
                pdfPage.draw(with: .mediaBox, to: context.cgContext)
                context.cgContext.restoreGState()
            } else {
                pdfPage.draw(with: .mediaBox, to: context.cgContext)
            }
        }
        
        return image
    }
    
    func renderPageWithMarginDrawing(_ marginDrawing: PKDrawing) -> UIImage? {
        guard let pageImage = renderPageImage(includeMargins: true) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: marginHelper.canvasSize)
        
        let composited = renderer.image { context in
            pageImage.draw(at: .zero)
            let drawingImage = marginDrawing.image(from: CGRect(origin: .zero, size: marginHelper.canvasSize), scale: 1.0)
            drawingImage.draw(at: .zero)
        }
        return composited
    }
    
    // MARK: - PDF Creation
    
    func createPDFWithoutMargins() -> PDFDocument? {
        guard let originalPage = pdfManager.pdfDocument?.page(at: pageIndex) else { return nil }
        let newDocument = PDFDocument()
        
        if !marginHelper.settings.isEnabled {
            newDocument.insert(originalPage, at: 0)
        } else {
            // Re-render the original page (no margin transform)
            let originalBounds = originalPage.bounds(for: .mediaBox)
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: originalBounds.size))
            let pdfData = renderer.pdfData { ctx in
                originalPage.draw(with: .mediaBox, to: ctx.cgContext)
            }
            if let doc = PDFDocument(data: pdfData), let page = doc.page(at: 0) {
                newDocument.insert(page, at: 0)
            }
        }
        return newDocument
    }
    
    func createPDFWithMargins(_ marginDrawing: PKDrawing) -> PDFDocument? {
        guard let composited = renderPageWithMarginDrawing(marginDrawing) else { return nil }
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: marginHelper.canvasSize))
        let pdfData = pdfRenderer.pdfData { _ in
            composited.draw(at: .zero)
        }
        return PDFDocument(data: pdfData)
    }
    
    // MARK: - Save
    
    func savePage(
        to url: URL,
        option: ExportOption,
        marginDrawing: PKDrawing? = nil
    ) -> Bool {
        let document: PDFDocument?
        
        switch option {
        case .pdfOnly:
            document = createPDFWithoutMargins()
        case .marginsOnly:
            guard let marginDrawing = marginDrawing else { return false }
            let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: marginHelper.canvasSize))
            let pdfData = pdfRenderer.pdfData { _ in
                UIColor.white.setFill()
                UIBezierPath(rect: CGRect(origin: .zero, size: marginHelper.canvasSize)).fill()
                
                let drawingImage = marginDrawing.image(from: CGRect(origin: .zero, size: marginHelper.canvasSize), scale: 1.0)
                drawingImage.draw(at: .zero)
            }
            document = PDFDocument(data: pdfData)
        case .both:
            if let marginDrawing = marginDrawing {
                document = createPDFWithMargins(marginDrawing)
            } else {
                document = createPDFWithoutMargins()
            }
        }
        
        guard let document = document else { return false }
        return document.write(to: url)
    }
    
    func saveDocument(
        to url: URL,
        option: ExportOption,
        marginDrawings: [Int: PKDrawing] = [:]
    ) -> Bool {
        guard let originalDocument = pdfManager.pdfDocument else { return false }
        let newDocument = PDFDocument()
        
        for pageIndex in 0..<originalDocument.pageCount {
            let helper = MarginCanvasHelper(
                settings: pdfManager.getMarginSettings(for: pageIndex),
                originalPDFSize: pdfManager.getCurrentPageSize()
            )
            let exporter = PDFExportHelper(pdfManager: pdfManager, pageIndex: pageIndex, marginHelper: helper)
            
            var pageToAdd: PDFPage?
            switch option {
            case .pdfOnly:
                pageToAdd = originalDocument.page(at: pageIndex)
            case .marginsOnly, .both:
                let marginDrawing = marginDrawings[pageIndex]
                
                if let pageImage = exporter.renderPageImage(includeMargins: true) {
                    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: helper.canvasSize))
                    let pdfData = renderer.pdfData { _ in
                        pageImage.draw(at: .zero)
                        if let drawing = marginDrawing {
                            let drawingImage = drawing.image(from: CGRect(origin: .zero, size: helper.canvasSize), scale: 1.0)
                            drawingImage.draw(at: .zero)
                        }
                    }
                    if let tempDoc = PDFDocument(data: pdfData), let page = tempDoc.page(at: 0) {
                        pageToAdd = page
                    }
                }
            }
            if let page = pageToAdd {
                newDocument.insert(page, at: newDocument.pageCount)
            }
        }
        return newDocument.write(to: url)
    }
}
