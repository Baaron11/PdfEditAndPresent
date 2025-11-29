import SwiftUI
import PDFKit
import Combine
import UniformTypeIdentifiers

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

    // MARK: - Merge PDF State
    @Published var showMergeImporter = false
    @Published var showMergePositionDialog = false
    @Published var selectedMergeURLs: [URL] = []
    @Published var mergeInsertPosition: String = ""
    @Published var showMergePageNumberInput = false

    enum MergeInsertMethod {
        case atFront
        case atEnd
        case afterPage
    }
    @Published var mergeInsertMethod: MergeInsertMethod = .atEnd

    // MARK: - Print Preview State
    @Published var showPrintPreview: Bool = false

    // Print settings enums
    enum DuplexMode: String, CaseIterable { case none, shortEdge, longEdge }
    enum PageOrientation: String, CaseIterable { case auto, portrait, landscape }

    enum PaperSize: String, CaseIterable {
        case systemDefault, letter, legal, a4
        var pageRect: CGRect {
            switch self {
            case .systemDefault: return .zero   // let printer decide
            case .letter: return CGRect(x: 0, y: 0, width: 612, height: 792)   // 8.5x11 @ 72dpi
            case .legal:  return CGRect(x: 0, y: 0, width: 612, height: 1008)
            case .a4:     return CGRect(x: 0, y: 0, width: 595, height: 842)
            }
        }
    }

    enum BorderStyle: String, CaseIterable { case none, singleHair, singleThin, doubleHair, doubleThin }

    // MARK: - Selected Printer
    @Published var selectedPrinterName: String = "Select Printer"
    @Published var selectedPrinter: UIPrinter?

    // MARK: - Editor Current Page (1-based)
    @Published var editorCurrentPage: Int = 1

    private let printerURLKey = "selected.printer.url"
    
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
            //print("🔍 Zoom set to \(Int(zoomLevel * 100))%")
        }
    }
    
    func setZoomToValue(_ percentage: Double) {
        let level = CGFloat(percentage / 100.0)
        let clampedZoom = max(minZoom, min(level, maxZoom))
        if clampedZoom != zoomLevel {
            zoomLevel = clampedZoom
            //print("🔍 Custom zoom set to \(Int(zoomLevel * 100))%")
        }
    }
    
    func zoomToFit() {
        zoomLevel = 1.0
        //print("🔍 Zoom reset to fit")
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

    /// Set page size for all pages in the document
    func setPageSize(widthPoints: Double, heightPoints: Double) {
        guard let document = pdfDocument else {
            print("❌ No document to resize")
            return
        }

        guard document.pageCount > 0 else {
            print("⚠️ Document has no pages")
            return
        }

        print("📐 Resizing all pages to \(widthPoints) x \(heightPoints) points")

        let newDocument = PDFDocument()
        let newMediaBox = CGRect(x: 0, y: 0, width: widthPoints, height: heightPoints)

        for i in 0..<document.pageCount {
            guard let originalPage = document.page(at: i) else { continue }

            // Create a new page with the desired size
            let newPage = PDFPage()
            newPage.setBounds(newMediaBox, for: .mediaBox)

            // Get the original page content and draw it centered on the new page
            let originalBounds = originalPage.bounds(for: .mediaBox)

            // Calculate scaling to fit original content in new page
            let scaleX = widthPoints / originalBounds.width
            let scaleY = heightPoints / originalBounds.height
            let scale = min(scaleX, scaleY, 1.0) // Don't scale up, only down if needed

            let scaledWidth = originalBounds.width * scale
            let scaledHeight = originalBounds.height * scale
            let offsetX = (widthPoints - scaledWidth) / 2
            let offsetY = (heightPoints - scaledHeight) / 2

            // Render original page content onto new page
            if let cgPage = originalPage.pageRef {
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: widthPoints, height: heightPoints))
                let image = renderer.image { context in
                    let ctx = context.cgContext

                    // Fill with white background
                    ctx.setFillColor(UIColor.white.cgColor)
                    ctx.fill(CGRect(x: 0, y: 0, width: widthPoints, height: heightPoints))

                    // Transform for PDF coordinate system (flip Y)
                    ctx.translateBy(x: offsetX, y: heightPoints - offsetY)
                    ctx.scaleBy(x: scale, y: -scale)

                    // Draw the original page
                    ctx.drawPDFPage(cgPage)
                }

                // Create PDF page from image
                if let cgImage = image.cgImage {
                    let imagePage = PDFPage(image: UIImage(cgImage: cgImage))
                    if let finalPage = imagePage {
                        newDocument.insert(finalPage, at: newDocument.pageCount)
                    } else {
                        newDocument.insert(newPage, at: newDocument.pageCount)
                    }
                } else {
                    newDocument.insert(newPage, at: newDocument.pageCount)
                }
            } else {
                newDocument.insert(newPage, at: newDocument.pageCount)
            }
        }

        print("✅ Resized document to \(newDocument.pageCount) pages")

        // Update document
        self.updateDocument(newDocument)
        regenerateThumbnails()

        // Notify about document change
        onDocumentChanged?()
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

    // MARK: - Merge PDF Methods

    /// Unified entry point. Call this from both: File menu and sidebar button.
    func triggerMergePDF() {
        DispatchQueue.main.async { self.showMergeImporter = true }
    }

    /// Called after picker returns URLs; shows position dialog for merge
    func handlePickedPDFsForMerge(urls: [URL]) {
        selectedMergeURLs = urls
        showMergePositionDialog = true
    }

    /// Performs the actual merge at the selected position
    func performMergePDF() {
        guard !selectedMergeURLs.isEmpty else { return }

        let targetPosition: Int
        switch mergeInsertMethod {
        case .atFront:
            targetPosition = 0
        case .atEnd:
            targetPosition = pageCount
        case .afterPage:
            if let pageNum = Int(mergeInsertPosition), pageNum > 0 && pageNum <= pageCount {
                targetPosition = pageNum
            } else {
                return
            }
        }

        for url in selectedMergeURLs {
            // Start security-scoped access
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            insertPDF(from: url, at: targetPosition)
        }
        print("✅ Merged \(selectedMergeURLs.count) PDF(s) into document at position \(targetPosition)")

        // Reset state
        selectedMergeURLs = []
        mergeInsertPosition = ""
        mergeInsertMethod = .atEnd
        showMergePageNumberInput = false
    }

    /// Legacy method for backwards compatibility - merges all at end
    func mergeSelectedPDFs(urls: [URL]) {
        for url in urls {
            // Start security-scoped access
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            insertPDF(from: url, at: pageCount)
        }
        print("✅ Merged \(urls.count) PDF(s) into document")
    }

    // MARK: - Print Preview Methods

    /// Entry point from File menu
    func presentPrintPreview() {
        showPrintPreview = true
    }

    /// Build a subset PDF from the selected page range. Returns Data (for printing).
    func makeSubsetPDFData(range: ClosedRange<Int>?) -> Data? {
        guard let doc = pdfDocument else { return nil }
        // If no range or range covers all pages, just return full data
        if range == nil || (range!.lowerBound == 1 && range!.upperBound == doc.pageCount) {
            return doc.dataRepresentation()
        }
        // Create a new PDF with selected pages (1-based indices)
        let newDoc = PDFDocument()
        let start = max(1, range!.lowerBound)
        let end   = min(doc.pageCount, range!.upperBound)
        var insertIndex = 0
        for pageIndex in (start - 1)...(end - 1) {
            if let page = doc.page(at: pageIndex) {
                newDoc.insert(page, at: insertIndex)
                insertIndex += 1
            }
        }
        return newDoc.dataRepresentation()
    }

    /// Restore last-used printer from UserDefaults
    func restoreLastPrinterIfAvailable() {
        guard selectedPrinter == nil,
              let s = UserDefaults.standard.string(forKey: printerURLKey),
              let url = URL(string: s) else { return }
        selectedPrinter = UIPrinter(url: url)
        selectedPrinter?.contactPrinter { available in
            DispatchQueue.main.async {
                self.selectedPrinterName = available ? (self.selectedPrinter?.displayName ?? "Selected Printer")
                                                     : "Select Printer"
            }
        }
    }

    /// Present picker anchored to a specific UIView and rect
    func presentPrinterPicker(from sourceView: UIView, sourceRect: CGRect) {
        let picker = UIPrinterPickerController(initiallySelectedPrinter: selectedPrinter)
        picker.present(from: sourceRect, in: sourceView, animated: true) { controller, userDidSelect, _ in
            if userDidSelect {
                self.selectedPrinter = controller.selectedPrinter
                self.selectedPrinterName = controller.selectedPrinter?.displayName ?? "Selected Printer"
                if let url = controller.selectedPrinter?.url {
                    UserDefaults.standard.set(url.absoluteString, forKey: self.printerURLKey)
                }
            }
        }
    }

    /// Present the system print interaction controller with data + options
    func presentPrintController(pdfData: Data,
                                jobName: String,
                                copies: Int,
                                color: Bool,
                                duplex: DuplexMode,
                                orientation: PageOrientation,
                                pagesPerSheet: Int = 1,
                                paperSize: PaperSize = .systemDefault,
                                borderStyle: BorderStyle = .none,
                                includeAnnotations: Bool = true) {
        let controller = UIPrintInteractionController.shared
        controller.showsNumberOfCopies = false
        controller.showsPaperSelectionForLoadedPapers = false
        controller.printInfo = configuredPrintInfo(jobName: jobName, color: color, duplex: duplex, orientation: orientation)

        // Use a custom renderer so we can support pages-per-sheet, paper size, borders, and annotations
        controller.printPageRenderer = CustomPDFRenderer(
            pdfData: pdfData,
            pagesPerSheet: pagesPerSheet,
            paperSize: paperSize,
            borderStyle: borderStyle,
            includeAnnotations: includeAnnotations
        )

        if let printer = selectedPrinter {
            // This bypasses the full Apple preview and prints directly (shows minimal progress UI)
            controller.print(to: printer, completionHandler: nil)
            return
        }

        // Fall back to presenting the system sheet if no printer selected yet
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
           let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            controller.present(from: root.view.bounds, in: root.view, animated: true, completionHandler: nil)
        } else {
            controller.present(animated: true, completionHandler: nil)
        }
    }

    private func configuredPrintInfo(jobName: String, color: Bool, duplex: DuplexMode, orientation: PageOrientation) -> UIPrintInfo {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = jobName
        info.outputType = color ? .photo : .grayscale
        switch duplex {
        case .none: info.duplex = .none
        case .shortEdge: info.duplex = .shortEdge
        case .longEdge: info.duplex = .longEdge
        }
        info.orientation = (orientation == .landscape) ? .landscape : .portrait
        return info
    }

    /// Forwarder for Save As used by print preview
    func saveDocumentAs(completion: ((Bool, URL?) -> Void)? = nil) {
        // Call existing Save As implementation
        // This is a placeholder - implement based on your existing save logic
        completion?(false, nil)
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

// MARK: - Print Preview Helpers

enum OptimizeError: Error {
    case noDocument
    case writeFailed
}

extension PDFManager {
    enum PageSelectionMode { case all, custom(ClosedRange<Int>), current(Int) }

    /// Convenience property to get file URL from document
    var fileURL: URL? {
        pdfDocument?.documentURL
    }

    /// Build a new PDF `Data` containing only the selected pages.
    func subsetPDFData(for selection: PageSelectionMode) -> Data? {
        guard let doc = pdfDocument else { return nil }
        switch selection {
        case .all:
            return doc.dataRepresentation()

        case .current(let page):
            let idx = max(1, min(page, doc.pageCount)) - 1
            let newDoc = PDFDocument()
            if let p = doc.page(at: idx) { newDoc.insert(p, at: 0) }
            return newDoc.dataRepresentation()

        case .custom(let r):
            let start = max(1, r.lowerBound)
            let end   = min(doc.pageCount, r.upperBound)
            let newDoc = PDFDocument()
            var insert = 0
            for i in (start - 1)...(end - 1) {
                if let p = doc.page(at: i) {
                    newDoc.insert(p, at: insert)
                    insert += 1
                }
            }
            return newDoc.dataRepresentation()
        }
    }

    /// Optimize in-memory PDF data using the same options/pipeline as Change File Size.
    /// Implementation may write to a temp URL and read back.
    func optimizePDFData(_ data: Data,
                         options: PDFOptimizeOptions,
                         completion: @escaping (Result<Data, Error>) -> Void) {
        // Reuse your existing rewrite pipeline. Minimal pass-through fallback:
        if options.preset == .original {
            completion(.success(data))
            return
        }
        let tmpIn  = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        let tmpOut = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        do {
            try data.write(to: tmpIn)
            guard let d = PDFDocument(url: tmpIn) else {
                completion(.failure(OptimizeError.noDocument)); return
            }
            // Call your existing rewrite function here if you have it:
            // rewritePDF(document: d, to: tmpOut, options: options) { ... }
            // Fallback: just write unchanged to prove the pipe works
            if d.write(to: tmpOut), let outData = try? Data(contentsOf: tmpOut) {
                completion(.success(outData))
            } else {
                completion(.failure(OptimizeError.writeFailed))
            }
        } catch {
            completion(.failure(error))
        }
    }
}
