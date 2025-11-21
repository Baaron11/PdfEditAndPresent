import Foundation
import PDFKit
import PencilKit

// MARK: - PDFManager Extension for Margin and Dual-Layer Drawing Management

extension PDFManager {

    // MARK: - Margin Settings Storage Keys
    private static var marginSettingsKey: UInt8 = 0
    private static var pdfAnchoredDrawingsKey: UInt8 = 1
    private static var marginDrawingsKey: UInt8 = 2

    /// Margin settings array - one entry per page
    var marginSettings: [MarginSettings] {
        get {
            return objc_getAssociatedObject(self, &PDFManager.marginSettingsKey) as? [MarginSettings] ?? []
        }
        set {
            objc_setAssociatedObject(self, &PDFManager.marginSettingsKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

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

    // MARK: - Initialization

    /// Initialize margin settings and drawings when PDF is loaded
    func initializeMarginSettings() {
        marginSettings = Array(repeating: MarginSettings(), count: pageCount)
        pdfAnchoredDrawings = [:]
        marginDrawings = [:]
        print("Margin settings and dual-layer drawings initialized for \(pageCount) pages")
    }

    // MARK: - Margin Settings Access

    /// Get margin settings for a specific page
    func getMarginSettings(for pageIndex: Int) -> MarginSettings {
        guard pageIndex >= 0 && pageIndex < marginSettings.count else {
            print("Invalid page index for margin settings: \(pageIndex)")
            return MarginSettings()
        }
        return marginSettings[pageIndex]
    }

    /// Update margin settings for a specific page
    func updateMarginSettings(for pageIndex: Int, settings: MarginSettings) {
        guard pageIndex >= 0 && pageIndex < marginSettings.count else {
            print("Cannot update margin settings: invalid page index \(pageIndex)")
            return
        }

        marginSettings[pageIndex] = settings
        print("Updated margin settings for page \(pageIndex + 1)")
        print("   - Enabled: \(settings.isEnabled)")
        print("   - Anchor: \(settings.anchorPosition.rawValue)")
        print("   - Scale: \(Int(settings.pdfScale * 100))%")

        // Post notification for observers
        NotificationCenter.default.post(
            name: .marginSettingsDidChange,
            object: self,
            userInfo: ["pageIndex": pageIndex, "settings": settings]
        )
    }

    /// Apply margin settings to all pages at once
    func applyMarginSettingsToAllPages(_ settings: MarginSettings) {
        marginSettings = Array(repeating: settings, count: pageCount)
        print("Applied margin settings to all \(pageCount) pages")
        print("   - Enabled: \(settings.isEnabled)")
        print("   - Anchor: \(settings.anchorPosition.rawValue)")
        print("   - Scale: \(Int(settings.pdfScale * 100))%")

        NotificationCenter.default.post(
            name: .marginSettingsDidChange,
            object: self,
            userInfo: ["allPages": true, "settings": settings]
        )
    }

    /// Apply margin settings to current page only
    func applyMarginSettingsToCurrentPage(_ settings: MarginSettings) {
        updateMarginSettings(for: currentPageIndex, settings: settings)
    }

    /// Apply margin settings with change tracking
    func applyMarginSettingsToCurrentPageWithTracking(_ settings: MarginSettings) {
        applyMarginSettingsToCurrentPage(settings)
    }

    /// Apply margin settings to all pages with change tracking
    func applyMarginSettingsToAllPagesWithTracking(_ settings: MarginSettings) {
        applyMarginSettingsToAllPages(settings)
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

    // MARK: - Helpers

    /// Get helper for calculating margin/PDF positioning
    func getMarginCanvasHelper(for pageIndex: Int) -> MarginCanvasHelper {
        let settings = getMarginSettings(for: pageIndex)
        let pdfSize = getPageSize(for: pageIndex)
        return MarginCanvasHelper(settings: settings, originalPDFSize: pdfSize, canvasSize: pdfSize)
    }

    /// Check if margins are enabled for current page
    var hasMarginEnabled: Bool {
        getMarginSettings(for: currentPageIndex).isEnabled
    }

    /// Get current page's margin settings
    var currentPageMarginSettings: MarginSettings {
        getMarginSettings(for: currentPageIndex)
    }

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
    static let marginSettingsDidChange = Notification.Name("marginSettingsDidChange")
    static let drawingsDidChange = Notification.Name("drawingsDidChange")
}
