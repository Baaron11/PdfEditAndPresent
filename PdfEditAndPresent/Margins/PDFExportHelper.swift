import PDFKit
import UIKit
import PencilKit

// MARK: - PDF Export Helper (Dual-Layer Dynamic Canvas)
struct PDFExportHelper {

    let pdfManager: PDFManager
    let pageIndex: Int
    let marginHelper: MarginCanvasHelper

    enum ExportOption { case pdfOnly, marginsOnly, both }

    // MARK: - Dual-Layer Page Rendering

    /// Render page with both PDF-anchored and margin drawings
    func renderPageWithDualLayerDrawings(
        pdfAnchoredDrawing: PKDrawing,
        marginDrawing: PKDrawing
    ) -> UIImage? {
        guard let pdfPage = pdfManager.pdfDocument?.page(at: pageIndex) else { return nil }

        let canvasSize = marginHelper.canvasSize
        let pdfFrame = marginHelper.pdfFrameInCanvas

        let renderer = UIGraphicsImageRenderer(size: canvasSize)

        let image = renderer.image { context in
            // Fill background
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: CGPoint.zero, size: canvasSize))

            // Draw PDF at its frame position
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: pdfFrame.origin.x, y: pdfFrame.origin.y)
            context.cgContext.scaleBy(x: marginHelper.settings.pdfScale, y: marginHelper.settings.pdfScale)
            pdfPage.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()

            // Draw PDF-anchored strokes (denormalize from PDF space to canvas space)
            let transformer = DrawingCoordinateTransformer(
                marginHelper: marginHelper,
                canvasViewBounds: CGRect(origin: CGPoint.zero, size: canvasSize)
            )
            let denormalizedPdfDrawing = transformer.denormalizeDrawingFromPDFToCanvas(pdfAnchoredDrawing)
            let pdfDrawingImage = denormalizedPdfDrawing.image(
                from: CGRect(origin: CGPoint.zero, size: canvasSize),
                scale: 1.0
            )
            pdfDrawingImage.draw(at: CGPoint.zero)

            // Draw margin strokes (already in canvas space)
            let marginDrawingImage = marginDrawing.image(
                from: CGRect(origin: CGPoint.zero, size: canvasSize),
                scale: 1.0
            )
            marginDrawingImage.draw(at: CGPoint.zero)
        }

        return image
    }

    // MARK: - Legacy Single-Layer Rendering

    func renderPageImage(includeMargins: Bool) -> UIImage? {
        guard let pdfPage = pdfManager.pdfDocument?.page(at: pageIndex) else { return nil }

        let renderSize: CGSize = {
            if includeMargins {
                return marginHelper.canvasSize
            } else {
                return pdfPage.bounds(for: .mediaBox).size
            }
        }()

        let image = UIGraphicsImageRenderer(size: renderSize).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: CGPoint.zero, size: renderSize))

            if includeMargins {
                let pdfFrame = marginHelper.pdfFrameInCanvas
                context.cgContext.saveGState()

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
            pageImage.draw(at: CGPoint.zero)
            let drawingImage = marginDrawing.image(from: CGRect(origin: CGPoint.zero, size: marginHelper.canvasSize), scale: 1.0)
            drawingImage.draw(at: CGPoint.zero)
        }
        return composited
    }

    // MARK: - PDF Creation with Dual Layers

    func createPDFWithDualLayerDrawings(
        pdfAnchoredDrawing: PKDrawing,
        marginDrawing: PKDrawing
    ) -> PDFDocument? {
        guard let composited = renderPageWithDualLayerDrawings(
            pdfAnchoredDrawing: pdfAnchoredDrawing,
            marginDrawing: marginDrawing
        ) else { return nil }

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: CGPoint.zero, size: marginHelper.canvasSize))
        let pdfData = pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            composited.draw(at: CGPoint.zero)
        }
        return PDFDocument(data: pdfData)
    }

    func createPDFWithoutMargins() -> PDFDocument? {
        guard let originalPage = pdfManager.pdfDocument?.page(at: pageIndex) else { return nil }
        let newDocument = PDFDocument()

        if !marginHelper.settings.isEnabled {
            newDocument.insert(originalPage, at: 0)
        } else {
            let originalBounds = originalPage.bounds(for: .mediaBox)
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: CGPoint.zero, size: originalBounds.size))
            let pdfData = renderer.pdfData { ctx in
                ctx.beginPage()
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
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: CGPoint.zero, size: marginHelper.canvasSize))
        let pdfData = pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            composited.draw(at: CGPoint.zero)
        }
        return PDFDocument(data: pdfData)
    }

    // MARK: - Save Operations

    func savePage(
        to url: URL,
        option: ExportOption,
        pdfAnchoredDrawing: PKDrawing? = nil,
        marginDrawing: PKDrawing? = nil
    ) -> Bool {
        let document: PDFDocument?

        switch option {
        case .pdfOnly:
            document = createPDFWithoutMargins()
        case .marginsOnly:
            guard let marginDrawing = marginDrawing else { return false }
            let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: CGPoint.zero, size: marginHelper.canvasSize))
            let pdfData = pdfRenderer.pdfData { ctx in
                ctx.beginPage()
                UIColor.white.setFill()
                UIBezierPath(rect: CGRect(origin: CGPoint.zero, size: marginHelper.canvasSize)).fill()

                let drawingImage = marginDrawing.image(from: CGRect(origin: CGPoint.zero, size: marginHelper.canvasSize), scale: 1.0)
                drawingImage.draw(at: CGPoint.zero)
            }
            document = PDFDocument(data: pdfData)
        case .both:
            if let pdfAnchoredDrawing = pdfAnchoredDrawing, let marginDrawing = marginDrawing {
                document = createPDFWithDualLayerDrawings(
                    pdfAnchoredDrawing: pdfAnchoredDrawing,
                    marginDrawing: marginDrawing
                )
            } else if let marginDrawing = marginDrawing {
                document = createPDFWithMargins(marginDrawing)
            } else {
                document = createPDFWithoutMargins()
            }
        }

        guard let document = document else { return false }
        return document.write(to: url)
    }

    /// Save entire document with dual-layer drawings
    func saveDocument(
        to url: URL,
        option: ExportOption,
        pdfAnchoredDrawings: [Int: PKDrawing] = [:],
        marginDrawings: [Int: PKDrawing] = [:]
    ) -> Bool {
        guard let originalDocument = pdfManager.pdfDocument else { return false }
        let newDocument = PDFDocument()

        for pageIndex in 0..<originalDocument.pageCount {
            let pageSize = pdfManager.getPageSize(for: pageIndex)
            let settings = pdfManager.getMarginSettings(for: pageIndex)
            let helper = MarginCanvasHelper(
                settings: settings,
                originalPDFSize: pageSize,
                canvasSize: pageSize
            )
            let exporter = PDFExportHelper(pdfManager: pdfManager, pageIndex: pageIndex, marginHelper: helper)

            var pageToAdd: PDFPage?

            switch option {
            case .pdfOnly:
                pageToAdd = originalDocument.page(at: pageIndex)

            case .marginsOnly, .both:
                let pdfAnchoredDrawing = pdfAnchoredDrawings[pageIndex] ?? PKDrawing()
                let marginDrawing = marginDrawings[pageIndex] ?? PKDrawing()

                if let composited = exporter.renderPageWithDualLayerDrawings(
                    pdfAnchoredDrawing: pdfAnchoredDrawing,
                    marginDrawing: marginDrawing
                ) {
                    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: CGPoint.zero, size: helper.canvasSize))
                    let pdfData = renderer.pdfData { ctx in
                        ctx.beginPage()
                        composited.draw(at: CGPoint.zero)
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

    // MARK: - Image Export

    /// Export page as image with dual-layer drawings
    func exportPageAsImage(
        pdfAnchoredDrawing: PKDrawing,
        marginDrawing: PKDrawing,
        scale: CGFloat = 2.0
    ) -> UIImage? {
        guard let pdfPage = pdfManager.pdfDocument?.page(at: pageIndex) else { return nil }

        let canvasSize = marginHelper.canvasSize
        let pdfFrame = marginHelper.pdfFrameInCanvas
        let scaledSize = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)

        let renderer = UIGraphicsImageRenderer(size: scaledSize)

        let image = renderer.image { context in
            // Scale up the context
            context.cgContext.scaleBy(x: scale, y: scale)

            // Fill background
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: CGPoint.zero, size: canvasSize))

            // Draw PDF at its frame position
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: pdfFrame.origin.x, y: pdfFrame.origin.y)
            context.cgContext.scaleBy(x: marginHelper.settings.pdfScale, y: marginHelper.settings.pdfScale)
            pdfPage.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()

            // Draw PDF-anchored strokes
            let transformer = DrawingCoordinateTransformer(
                marginHelper: marginHelper,
                canvasViewBounds: CGRect(origin: CGPoint.zero, size: canvasSize)
            )
            let denormalizedPdfDrawing = transformer.denormalizeDrawingFromPDFToCanvas(pdfAnchoredDrawing)
            let pdfDrawingImage = denormalizedPdfDrawing.image(
                from: CGRect(origin: CGPoint.zero, size: canvasSize),
                scale: 1.0
            )
            pdfDrawingImage.draw(at: CGPoint.zero)

            // Draw margin strokes
            let marginDrawingImage = marginDrawing.image(
                from: CGRect(origin: CGPoint.zero, size: canvasSize),
                scale: 1.0
            )
            marginDrawingImage.draw(at: CGPoint.zero)
        }

        return image
    }
}

// MARK: - PDFManager Extension for Page Size
extension PDFManager {
    /// Get page size for a specific page index
    func getPageSize(for pageIndex: Int) -> CGSize {
        guard let pdfDocument = pdfDocument,
              let page = pdfDocument.page(at: pageIndex) else {
            return getCurrentPageSize()
        }
        return page.bounds(for: .mediaBox).size
    }
}
