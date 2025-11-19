import Foundation
import PDFKit

// MARK: - PDFManager Extension for Margin Management
//extension PDFManager {
//    
//    /// Margin settings array - one entry per page
//    @Published private(set) var marginSettings: [MarginSettings] = []
//    
//    /// Initialize margin settings when PDF is loaded
//    func initializeMarginSettings() {
//        marginSettings = Array(repeating: MarginSettings(), count: pageCount)
//        print("📐 Margin settings initialized for \(pageCount) pages")
//    }
//    
//    /// Get margin settings for a specific page
//    func getMarginSettings(for pageIndex: Int) -> MarginSettings {
//        guard pageIndex >= 0 && pageIndex < marginSettings.count else {
//            print("⚠️ Invalid page index for margin settings: \(pageIndex)")
//            return MarginSettings()
//        }
//        return marginSettings[pageIndex]
//    }
//    
//    /// Update margin settings for a specific page
//    func updateMarginSettings(
//        for pageIndex: Int,
//        settings: MarginSettings
//    ) {
//        guard pageIndex >= 0 && pageIndex < marginSettings.count else {
//            print("⚠️ Cannot update margin settings: invalid page index \(pageIndex)")
//            return
//        }
//        
//        marginSettings[pageIndex] = settings
//        print("✅ Updated margin settings for page \(pageIndex + 1)")
//        print("   - Enabled: \(settings.isEnabled)")
//        print("   - Anchor: \(settings.anchorPosition.rawValue)")
//        print("   - Scale: \(Int(settings.pdfScale * 100))%")
//    }
//    
//    /// Apply margin settings to all pages at once
//    func applyMarginSettingsToAllPages(_ settings: MarginSettings) {
//        marginSettings = Array(repeating: settings, count: pageCount)
//        print("✅ Applied margin settings to all \(pageCount) pages")
//        print("   - Enabled: \(settings.isEnabled)")
//        print("   - Anchor: \(settings.anchorPosition.rawValue)")
//        print("   - Scale: \(Int(settings.pdfScale * 100))%")
//    }
//    
//    /// Apply margin settings to current page only
//    func applyMarginSettingsToCurrentPage(_ settings: MarginSettings) {
//        updateMarginSettings(for: currentPageIndex, settings: settings)
//    }
//    
//    /// Get helper for calculating margin/PDF positioning
//    func getMarginCanvasHelper(for pageIndex: Int) -> MarginCanvasHelper {
//        let settings = getMarginSettings(for: pageIndex)
//        let pdfSize = getCurrentPageSize()
//        return MarginCanvasHelper(settings: settings, originalPDFSize: pdfSize, canvasSize: pdfSize)
//    }
//    
//    /// Check if margins are enabled for current page
//    var hasMarginEnabled: Bool {
//        getMarginSettings(for: currentPageIndex).isEnabled
//    }
//    
//    /// Get current page's margin settings
//    var currentPageMarginSettings: MarginSettings {
//        getMarginSettings(for: currentPageIndex)
//    }
//}
