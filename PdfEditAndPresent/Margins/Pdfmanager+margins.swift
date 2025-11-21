import Foundation
import PDFKit
import PencilKit

// MARK: - PDFManager Extension for Dual-Layer Drawing Management

extension PDFManager {

    // MARK: - Drawing Storage Keys
    private static var pdfAnchoredDrawingsKey: UInt8 = 1
    private static var marginDrawingsKey: UInt8 = 2

    /// PDF-anchored drawings (normalized to PDF space) - one entry per page
    var pdfAnchoredDrawings: [Int: PKDrawing] {
        get {
            return objc_getAssociatedObject(self, &PDFManager.pdfAnchoredDrawingsKey) as? [Int: PKDrawing] ?? [:]
        }
        set {
            objc_setAssociatedObject(self, &PDFManager.pdfAnchoredDrawingsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Margin drawings (in canvas space) - one entry per page
    var marginDrawings: [Int: PKDrawing] {
        get {
            return objc_getAssociatedObject(self, &PDFManager.marginDrawingsKey) as? [Int: PKDrawing] ?? [:]
        }
        set {
            objc_setAssociatedObject(self, &PDFManager.marginDrawingsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    // MARK: - Dual-Layer Drawing Access

    /// Get PDF-anchored drawing for a specific page (normalized)
    func getPdfAnchoredDrawing(for pageIndex: Int) -> PKDrawing {
        return pdfAnchoredDrawings[pageIndex] ?? PKDrawing()
    }

    /// Set PDF-anchored drawing for a specific page (normalized)
    func setPdfAnchoredDrawing(_ drawing: PKDrawing, for pageIndex: Int) {
        pdfAnchoredDrawings[pageIndex] = drawing
        NotificationCenter.default.post(
            name: .drawingsDidChange,
            object: self,
            userInfo: ["pageIndex": pageIndex, "type": "pdfAnchored"]
        )
    }

    /// Get margin drawing for a specific page (canvas space)
    func getMarginDrawing(for pageIndex: Int) -> PKDrawing {
        return marginDrawings[pageIndex] ?? PKDrawing()
    }

    /// Set margin drawing for a specific page (canvas space)
    func setMarginDrawing(_ drawing: PKDrawing, for pageIndex: Int) {
        marginDrawings[pageIndex] = drawing
        NotificationCenter.default.post(
            name: .drawingsDidChange,
            object: self,
            userInfo: ["pageIndex": pageIndex, "type": "margin"]
        )
    }

    /// Set both drawings for a page at once
    func setDrawings(
        pdfAnchored: PKDrawing,
        margin: PKDrawing,
        for pageIndex: Int
    ) {
        pdfAnchoredDrawings[pageIndex] = pdfAnchored
        marginDrawings[pageIndex] = margin
        NotificationCenter.default.post(
            name: .drawingsDidChange,
            object: self,
            userInfo: ["pageIndex": pageIndex, "type": "both"]
        )
    }

    // MARK: - Migration

    /// Migrate legacy single-drawing to dual-layer format
    func migrateLegacyDrawing(_ drawing: PKDrawing, for pageIndex: Int) {
        // Assume legacy drawing was PDF-anchored
        pdfAnchoredDrawings[pageIndex] = drawing
        marginDrawings[pageIndex] = PKDrawing()
        print("Migrated legacy drawing for page \(pageIndex + 1) to dual-layer format")
    }

    /// Check if page has any drawings
    func hasDrawings(for pageIndex: Int) -> Bool {
        let pdfDrawing = pdfAnchoredDrawings[pageIndex]
        let marginDrawing = marginDrawings[pageIndex]
        return (pdfDrawing != nil && !pdfDrawing!.strokes.isEmpty) ||
               (marginDrawing != nil && !marginDrawing!.strokes.isEmpty)
    }

    // MARK: - Current Page Helpers

    /// Get current page's PDF-anchored drawing
    var currentPagePdfAnchoredDrawing: PKDrawing {
        getPdfAnchoredDrawing(for: currentPageIndex)
    }

    /// Get current page's margin drawing
    var currentPageMarginDrawing: PKDrawing {
        getMarginDrawing(for: currentPageIndex)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let drawingsDidChange = Notification.Name("drawingsDidChange")
}
