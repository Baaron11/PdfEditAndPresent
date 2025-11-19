import SwiftUI
import PDFKit
import Combine

// MARK: - Display Mode Enum
enum PDFDisplayMode: String, Codable {
    case singlePage = "Single Page"
    case continuousScroll = "Continuous Scroll"
}

// MARK: - PDF Manager (Complete with Margin Support)
@MainActor
class PDFManager: ObservableObject {
    @Published var pdfDocument: PDFDocument?
    @Published var currentPageIndex: Int = 0
    @Published var pageCount: Int = 0
    @Published var thumbnails: [UIImage?] = []
    @Published var zoomLevel: CGFloat = 1.0
    @Published var displayMode: PDFDisplayMode = .continuousScroll
    
    // ✅ MARGIN SETTINGS: One entry per page
    @Published var marginSettings: [MarginSettings] = []
    
    private var thumbnailCache: [Int: UIImage] = [:]
    
    // Constants
    let minZoom: CGFloat = 0.5
    let maxZoom: CGFloat = 3.0
    let zoomStep: CGFloat = 0.2
    
    // MARK: - Initialize with external document
    func setPDFDocument(_ document: PDFDocument?) {
        self.pdfDocument = document
        self.currentPageIndex = 0
        self.pageCount = document?.pageCount ?? 0
        self.thumbnails = Array(repeating: nil, count: pageCount)
        self.thumbnailCache.removeAll()
        self.zoomLevel = 1.0
        
        // Initialize margin settings for all pages
        self.marginSettings = Array(repeating: MarginSettings(), count: pageCount)
        
        print("📄 PDF Manager: Set document with \(pageCount) pages")
        print("📐 Initialized margin settings for \(pageCount) pages")
        
        // ✅ NEW: Load previously saved margin settings
        loadMarginSettings()
        
        // Generate thumbnails in background
        generateThumbnails()
    }
    
    // MARK: - Create New PDF
    func createNewPDF() {
        let page = PDFPage()
        let document = PDFDocument()
        document.insert(page, at: 0)
        
        setPDFDocument(document)
        print("📄 Created new blank PDF")
    }
    
    // MARK: - Navigation
    func nextPage() {
        if currentPageIndex < pageCount - 1 {
            currentPageIndex += 1
            print("📄 Moved to page \(currentPageIndex + 1)")
        }
    }
    
    func previousPage() {
        if currentPageIndex > 0 {
            currentPageIndex -= 1
            print("📄 Moved to page \(currentPageIndex + 1)")
        }
    }
    
    func goToPage(_ index: Int) {
        if index >= 0 && index < pageCount {
            currentPageIndex = index
            print("📄 Jumped to page \(index + 1)")
        }
    }
    
    // MARK: - Zoom Controls with Snap to 100%
    func zoomIn() {
        let wasBelow100 = zoomLevel < 1.0
        let newZoom = min(zoomLevel + zoomStep, maxZoom)
        
        if wasBelow100 && newZoom >= 1.0 {
            zoomLevel = 1.0
            print("🔍 Zoomed to 100% (snapped)")
        } else if newZoom != zoomLevel {
            zoomLevel = newZoom
            print("🔍 Zoomed in to \(Int(zoomLevel * 100))%")
        }
    }
    
    func zoomOut() {
        let wasAbove100 = zoomLevel > 1.0
        let newZoom = max(zoomLevel - zoomStep, minZoom)
        
        if wasAbove100 && newZoom <= 1.0 {
            zoomLevel = 1.0
            print("🔍 Zoomed to 100% (snapped)")
        } else if newZoom != zoomLevel {
            zoomLevel = newZoom
            print("🔍 Zoomed out to \(Int(zoomLevel * 100))%")
        }
    }
    
    func setZoom(_ level: CGFloat) {
        let clampedZoom = max(minZoom, min(level, maxZoom))
        if clampedZoom != zoomLevel {
            zoomLevel = clampedZoom
            print("🔍 Zoom set to \(Int(zoomLevel * 100))%")
        }
    }
    
    func setZoomToValue(_ percentage: Double) {
        let level = CGFloat(percentage / 100.0)
        let clampedZoom = max(minZoom, min(level, maxZoom))
        if clampedZoom != zoomLevel {
            zoomLevel = clampedZoom
            print("🔍 Custom zoom set to \(Int(zoomLevel * 100))%")
        }
    }
    
    func zoomToFit() {
        zoomLevel = 1.0
        print("🔍 Zoom reset to fit")
    }
    
    // MARK: - Get current page
    func getCurrentPage() -> PDFPage? {
        guard let document = pdfDocument else { return nil }
        return document.page(at: currentPageIndex)
    }
    
    // MARK: - Get page size
    func getCurrentPageSize() -> CGSize {
        guard let page = getCurrentPage() else {
            // Default to A4 if no page exists
            return CGSize(width: 595.28, height: 841.89)
        }
        
        let bounds = page.bounds(for: .mediaBox)
        return bounds.size
    }
    
    // MARK: - Thumbnail Generation
    nonisolated func getThumbnailImage(for pageIndex: Int, from document: PDFDocument?) -> UIImage? {
        guard let page = document?.page(at: pageIndex) else { return nil }
        
        let pageBounds = page.bounds(for: .mediaBox)
        let thumbnailSize = CGSize(width: 100, height: 100 * pageBounds.height / pageBounds.width)
        
        return page.thumbnail(of: thumbnailSize, for: .mediaBox)
    }
    
    private func generateThumbnails() {
        let pageCount = self.pageCount
        let document = self.pdfDocument
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            for index in 0..<pageCount {
                let thumbnail = self.getThumbnailImage(for: index, from: document)
                
                DispatchQueue.main.async {
                    if index < self.thumbnails.count {
                        self.thumbnails[index] = thumbnail
                    }
                }
            }
        }
    }
    
    // MARK: - Load PDF from URL
    func loadPDF(from url: URL) {
        guard let document = PDFDocument(url: url) else {
            print("❌ Failed to load PDF")
            return
        }
        
        setPDFDocument(document)
    }
    
    // MARK: - Document Manipulation
    
    /// Add a blank page at the end of the document
    func addBlankPage() {
        guard var document = pdfDocument else {
            print("❌ No PDF document to add page to")
            return
        }
        
        print("📄 Starting to add blank page...")
        
        // Get the size of the last page for consistency
        var pageSize = CGSize(width: 612, height: 792) // Letter
        if document.pageCount > 0, let lastPage = document.page(at: document.pageCount - 1) {
            let bounds = lastPage.bounds(for: .mediaBox)
            pageSize = bounds.size
            print("📐 Using last page size: \(pageSize)")
        }
        
        let blankPage = PDFPage()
        document.insert(blankPage, at: document.pageCount)
        print("✅ Blank page inserted. Document now has \(document.pageCount) pages")
        
        // Update the document
        self.updateDocument(document)
        
        // ✅ Add default margin settings for new page
        marginSettings.append(MarginSettings())
        
        regenerateThumbnails()
    }
    
    /// Delete a page at the specified index
    func deletePage(at index: Int) {
        guard let document = pdfDocument else {
            print("❌ No document to delete page from")
            return
        }
        
        guard index >= 0 && index < document.pageCount else {
            print("❌ Invalid page index: \(index)")
            return
        }
        
        guard document.pageCount > 1 else {
            print("⚠️ Cannot delete the last page in document")
            return
        }
        
        print("🗑️ Deleting page at index \(index)")
        
        // Create new document without the deleted page
        let newDocument = PDFDocument()
        
        for i in 0..<document.pageCount {
            if i != index {  // Skip the page to delete
                if let page = document.page(at: i) {
                    newDocument.insert(page, at: newDocument.pageCount)
                }
            }
        }
        
        print("✅ Page deleted. New document has \(newDocument.pageCount) pages")
        
        // Update document
        self.updateDocument(newDocument)
        
        // ✅ Remove corresponding margin settings
        if index >= 0 && index < marginSettings.count {
            marginSettings.remove(at: index)
            print("📐 Removed margin settings for deleted page")
        }
        
        // ✅ Update current page index if it's out of bounds
        if currentPageIndex >= pageCount {
            currentPageIndex = max(0, pageCount - 1)
            print("📄 Updated currentPageIndex to \(currentPageIndex)")
        }
        
        regenerateThumbnails()
    }
    
    /// Insert a PDF from a file URL at a specified position
    func insertPDF(from sourceURL: URL, at position: Int) {
        guard let document = pdfDocument else {
            print("❌ No document to insert PDF into")
            return
        }
        
        guard let sourceDocument = PDFDocument(url: sourceURL) else {
            print("❌ Could not load PDF from \(sourceURL)")
            return
        }
        
        guard sourceDocument.pageCount > 0 else {
            print("⚠️ Source PDF has no pages")
            return
        }
        
        let validPosition = min(max(0, position), document.pageCount)
        print("📥 Inserting \(sourceDocument.pageCount) pages from PDF at position \(validPosition)")
        
        // Create new document
        let newDocument = PDFDocument()
        
        // Copy pages up to insertion point
        for i in 0..<validPosition {
            if let page = document.page(at: i) {
                newDocument.insert(page, at: newDocument.pageCount)
            }
        }
        
        // Insert all pages from source PDF
        for i in 0..<sourceDocument.pageCount {
            if let page = sourceDocument.page(at: i) {
                newDocument.insert(page, at: newDocument.pageCount)
            }
        }
        
        // Copy remaining pages from original document
        for i in validPosition..<document.pageCount {
            if let page = document.page(at: i) {
                newDocument.insert(page, at: newDocument.pageCount)
            }
        }
        
        print("✅ PDF inserted. New document has \(newDocument.pageCount) pages")
        
        // Update document
        self.updateDocument(newDocument)
        
        // ✅ Insert corresponding margin settings
        let newMarginSettings = Array(repeating: MarginSettings(), count: sourceDocument.pageCount)
        marginSettings.insert(contentsOf: newMarginSettings, at: validPosition)
        print("📐 Added margin settings for \(sourceDocument.pageCount) new pages")
        
        regenerateThumbnails()
    }
    
    /// Move a page from one position to another
    func movePage(from sourceIndex: Int, to destinationIndex: Int) {
        guard let document = pdfDocument else {
            print("❌ No document to move page in")
            return
        }
        
        guard sourceIndex != destinationIndex else {
            print("⚠️ Source and destination are the same, ignoring")
            return
        }
        
        guard sourceIndex >= 0 && sourceIndex < document.pageCount else {
            print("❌ Invalid source index: \(sourceIndex)")
            return
        }
        
        guard destinationIndex >= 0 && destinationIndex <= document.pageCount else {
            print("❌ Invalid destination index: \(destinationIndex)")
            return
        }
        
        print("🔄 Moving page at index \(sourceIndex) to index \(destinationIndex)")
        
        guard let pageToMove = document.page(at: sourceIndex) else {
            print("❌ Could not get page at \(sourceIndex)")
            return
        }
        
        var pageIndices = Array(0..<document.pageCount)
        
        // Remove from source position
        let removed = pageIndices.remove(at: sourceIndex)
        print("   Removed page at index \(sourceIndex): \(removed)")
        
        // Insert at destination position (accounting for the removal)
        pageIndices.insert(removed, at: min(destinationIndex, pageIndices.count))
        print("   Inserted at index \(destinationIndex): \(removed)")
        print("   New page order: \(pageIndices)")
        
        // Build new document with pages in correct order
        let newDocument = PDFDocument()
        for pageIndex in pageIndices {
            if let page = document.page(at: pageIndex) {
                newDocument.insert(page, at: newDocument.pageCount)
            }
        }
        
        print("✅ Page moved successfully. New document has \(newDocument.pageCount) pages")
        
        // Update document
        self.updateDocument(newDocument)
        
        // Move margin settings using same index logic
        if sourceIndex >= 0 && sourceIndex < marginSettings.count {
            let movedSettings = marginSettings.remove(at: sourceIndex)
            let insertIdx = min(destinationIndex, marginSettings.count)
            marginSettings.insert(movedSettings, at: insertIdx)
            print("📐 Moved margin settings from index \(sourceIndex) to \(insertIdx)")
        }
        
        regenerateThumbnails()
    }
    
    /// Regenerate thumbnails after page changes
    private func regenerateThumbnails() {
        guard let document = pdfDocument else { return }
        
        var newThumbnails: [UIImage?] = []
        
        print("📸 Regenerating \(document.pageCount) thumbnails...")
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                print("⚠️ Could not render thumbnail for page \(pageIndex)")
                newThumbnails.append(nil)
                continue
            }
            
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 1.0
            
            let image = page.thumbnail(of: CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            ), for: .mediaBox)
            
            newThumbnails.append(image)
        }
        
        self.thumbnails = newThumbnails
        
        print("✅ Thumbnails regenerated (\(newThumbnails.count) thumbnails)")
    }
    
    var onDocumentChanged: (() -> Void)? {
        get {
            objc_getAssociatedObject(self, &AssociatedKeys.onDocumentChanged) as? (() -> Void)
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.onDocumentChanged, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }
    
    func updateDocument(_ newDocument: PDFDocument?) {
        self.pdfDocument = newDocument
        self.pageCount = newDocument?.pageCount ?? 0
        print("📊 Updated document: pageCount now = \(self.pageCount)")
        
        onDocumentChanged?()
    }
}

// MARK: - PDFManager Extension - Margin Management with Persistence
extension PDFManager {
    
    // ✅ UPDATED: Send which pages changed (nil = all pages)
    private static let marginSettingsSubject = PassthroughSubject<Set<Int>?, Never>()
    var marginSettingsDidChange: AnyPublisher<Set<Int>?, Never> {
        Self.marginSettingsSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Get Margin Settings
    func getMarginSettings(for pageIndex: Int) -> MarginSettings {
        guard pageIndex >= 0 && pageIndex < marginSettings.count else {
            print("⚠️ Invalid page index for margin settings: \(pageIndex)")
            return MarginSettings()
        }
        return marginSettings[pageIndex]
    }
    
    // MARK: - Update Margin Settings (with persistence)
    func updateMarginSettings(
        for pageIndex: Int,
        settings: MarginSettings
    ) {
        guard pageIndex >= 0 && pageIndex < marginSettings.count else {
            print("⚠️ Cannot update margin settings: invalid page index \(pageIndex)")
            return
        }
        
        marginSettings[pageIndex] = settings
        
        // ✅ NEW: Notify which specific page changed
        Self.marginSettingsSubject.send([pageIndex])
        
        saveMarginSettings()
        
        print("✅ Updated margin settings for page \(pageIndex + 1)")
        print("   - Enabled: \(settings.isEnabled)")
        print("   - Anchor: \(settings.anchorPosition.rawValue)")
        print("   - Scale: \(Int(settings.pdfScale * 100))%")
    }
    
    // MARK: - Apply to Current Page
    func applyMarginSettingsToCurrentPage(_ settings: MarginSettings) {
        updateMarginSettings(for: currentPageIndex, settings: settings)
    }
    
    // MARK: - Apply to All Pages
    func applyMarginSettingsToAllPages(_ settings: MarginSettings) {
        marginSettings = Array(repeating: settings, count: pageCount)
        
        // ✅ NEW: Notify ALL pages changed (nil = all)
        Self.marginSettingsSubject.send(nil)
        saveMarginSettings()
        
        print("✅ Applied margin settings to all \(pageCount) pages")
        print("   - Enabled: \(settings.isEnabled)")
        print("   - Anchor: \(settings.anchorPosition.rawValue)")
        print("   - Scale: \(Int(settings.pdfScale * 100))%")
    }
    
    // MARK: - Get Helper
    func getMarginCanvasHelper(for pageIndex: Int) -> MarginCanvasHelper {
        let settings = getMarginSettings(for: pageIndex)
        let size = effectiveSize(for: pageIndex)
        return MarginCanvasHelper(settings: settings, originalPDFSize: size, canvasSize: size)
    }
    
    // MARK: - Check if Enabled
    var hasMarginEnabled: Bool {
        getMarginSettings(for: currentPageIndex).isEnabled
    }
    
    var currentPageMarginSettings: MarginSettings {
        getMarginSettings(for: currentPageIndex)
    }
    
    // MARK: - Persistence
    
    private func saveMarginSettings() {
        let key = getMarginSettingsKey()
        
        if let encoded = try? JSONEncoder().encode(marginSettings) {
            UserDefaults.standard.set(encoded, forKey: key)
            print("💾 Saved margin settings for: \(key)")
        } else {
            print("❌ Failed to encode margin settings")
        }
    }
    
    func loadMarginSettings() {
        let key = getMarginSettingsKey()
        
        guard let data = UserDefaults.standard.data(forKey: key) else {
            print("ℹ️ No saved margin settings found for: \(key)")
            return
        }
        
        if let decoded = try? JSONDecoder().decode([MarginSettings].self, from: data) {
            if decoded.count == marginSettings.count {
                marginSettings = decoded
                print("✅ Loaded saved margin settings for: \(key)")
                
                Self.marginSettingsSubject.send(nil)
            } else {
                print("⚠️ Saved margin settings count mismatch. Keeping defaults.")
            }
        } else {
            print("❌ Failed to decode margin settings")
        }
    }
    
    private func getMarginSettingsKey() -> String {
        if let url = pdfDocument?.documentURL {
            let fileName = url.lastPathComponent
            return "margins_\(fileName)_pages_\(pageCount)"
        }
        return "margins_default_pages_\(pageCount)"
    }
    
    func clearSavedMarginSettings() {
        let key = getMarginSettingsKey()
        UserDefaults.standard.removeObject(forKey: key)
        print("🗑️ Cleared saved margin settings for: \(key)")
    }
}

// MARK: - Tracking Extension
extension PDFManager {
    
    var onMarginSettingsChanged: (() -> Void)? {
        get {
            objc_getAssociatedObject(self, &AssociatedKeys.onMarginSettingsChanged) as? (() -> Void)
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.onMarginSettingsChanged, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }
    
    func updateMarginSettingsWithTracking(
        for pageIndex: Int,
        settings: MarginSettings
    ) {
        guard pageIndex >= 0 && pageIndex < marginSettings.count else {
            print("⚠️ Cannot update margin settings: invalid page index \(pageIndex)")
            return
        }
        
        marginSettings[pageIndex] = settings
        
        onMarginSettingsChanged?()
        
        // ✅ NEW: Notify which specific page changed
        Self.marginSettingsSubject.send([pageIndex])
        
        saveMarginSettings()
        
        print("✅ Updated margin settings for page \(pageIndex + 1)")
        print("   - Enabled: \(settings.isEnabled)")
        print("   - Anchor: \(settings.anchorPosition.rawValue)")
        print("   - Scale: \(Int(settings.pdfScale * 100))%")
    }
    
    func applyMarginSettingsToCurrentPageWithTracking(_ settings: MarginSettings) {
        updateMarginSettingsWithTracking(for: currentPageIndex, settings: settings)
    }
    
    func applyMarginSettingsToAllPagesWithTracking(_ settings: MarginSettings) {
        marginSettings = Array(repeating: settings, count: pageCount)
        
        onMarginSettingsChanged?()
        
        // ✅ NEW: Notify ALL pages changed
        Self.marginSettingsSubject.send(nil)
        
        saveMarginSettings()
        
        print("✅ Applied margin settings to all \(pageCount) pages")
        print("   - Enabled: \(settings.isEnabled)")
        print("   - Anchor: \(settings.anchorPosition.rawValue)")
        print("   - Scale: \(Int(settings.pdfScale * 100))%")
    }
}

// MARK: - Rotation Extension
extension PDFManager {
    // ✅ NEW: Send which pages changed (nil = all pages)
    private static let pageTransformSubject = PassthroughSubject<Set<Int>?, Never>()
    var pageTransformsDidChange: AnyPublisher<Set<Int>?, Never> {
        Self.pageTransformSubject.eraseToAnyPublisher()
    }
    
    private func normalizeDegrees(_ value: Int) -> Int {
        let x = value % 360
        return x < 0 ? x + 360 : x
    }
    
    func rotatePage(at index: Int, by degrees: Int) {
        guard let page = pdfDocument?.page(at: index) else { return }
        let current = page.rotation
        page.rotation = normalizeDegrees(current + degrees)
        
        regenerateThumbnails()
        // ✅ NEW: Send WHICH page changed
        Self.pageTransformSubject.send([index])
        onDocumentChanged?()
        objectWillChange.send()
        
        print("🔁 Rotated page \(index + 1) to \(page.rotation)°")
    }
    
    func rotateCurrentPage(by degrees: Int) {
        rotatePage(at: currentPageIndex, by: degrees)
    }
    
    func rotateAllPages(by degrees: Int) {
        guard let doc = pdfDocument else { return }
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) {
                page.rotation = normalizeDegrees(page.rotation + degrees)
            }
        }
        regenerateThumbnails()
        // ✅ NEW: Send nil to indicate ALL pages changed
        Self.pageTransformSubject.send(nil)
        onDocumentChanged?()
        objectWillChange.send()
        
        print("🔁 Rotated ALL pages by \(degrees)°")
    }
}

extension PDFManager {
    func rotationForPage(_ index: Int) -> Int {
        guard let page = pdfDocument?.page(at: index) else { return 0 }
        return ((page.rotation % 360) + 360) % 360
    }
    
    func effectiveSize(for index: Int) -> CGSize {
        guard let page = pdfDocument?.page(at: index) else {
            return CGSize(width: 595.28, height: 841.89)
        }
        let raw = page.bounds(for: .mediaBox).size
        let rot = rotationForPage(index)
        if rot == 90 || rot == 270 {
            return CGSize(width: raw.height, height: raw.width)
        }
        return raw
    }
    
    func getCurrentPageEffectiveSize() -> CGSize {
        effectiveSize(for: currentPageIndex)
    }
}

// MARK: - Associated Keys
private struct AssociatedKeys {
    static var onMarginSettingsChanged = "onMarginSettingsChanged"
    static var onDocumentChanged = "onDocumentChanged"
}
