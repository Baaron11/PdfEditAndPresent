import SwiftUI
import PencilKit
import PaperKit

// MARK: - SwiftUI Representable
struct UnifiedBoardCanvasView: UIViewControllerRepresentable {
    @ObservedObject var editorData: EditorData
    @ObservedObject var pdfManager: PDFManager
    @Binding var canvasMode: CanvasMode
    @Binding var marginSettings: MarginSettings

    let canvasSize: CGSize
    let currentPageIndex: Int

    // Callbacks
    var onModeChanged: ((CanvasMode) -> Void)?
    var onPaperKitItemAdded: (() -> Void)?
    var onDrawingChanged: ((Int, PKDrawing?, PKDrawing?) -> Void)?

    func makeUIViewController(context: Context) -> UnifiedBoardCanvasController {
        let controller = UnifiedBoardCanvasController()

        // Initialize canvas size
        controller.initializeCanvas(size: canvasSize)

        // Setup both layers
        if let markup = editorData.markup {
            controller.setupPaperKit(markup: markup)
        }
        controller.setupPencilKit()

        // Wire up callbacks
        controller.onModeChanged = { [weak controller] newMode in
            guard controller != nil else { return }
            DispatchQueue.main.async {
                canvasMode = newMode
                onModeChanged?(newMode)
            }
        }

        controller.onPaperKitItemAdded = {
            DispatchQueue.main.async {
                onPaperKitItemAdded?()
            }
        }

        controller.onDrawingChanged = { pageIndex, pdfDrawing, marginDrawing in
            DispatchQueue.main.async {
                // Update PDFManager with new drawings
                if let pdfDrawing = pdfDrawing {
                    pdfManager.setPdfAnchoredDrawing(pdfDrawing, for: pageIndex)
                }
                if let marginDrawing = marginDrawing {
                    pdfManager.setMarginDrawing(marginDrawing, for: pageIndex)
                }
                onDrawingChanged?(pageIndex, pdfDrawing, marginDrawing)
            }
        }

        // Set initial state
        controller.setCanvasMode(canvasMode)
        controller.updateMarginSettings(marginSettings)
        controller.setCurrentPage(currentPageIndex)

        // Load existing drawings from PDFManager
        let pdfDrawing = pdfManager.getPdfAnchoredDrawing(for: currentPageIndex)
        let marginDrawing = pdfManager.getMarginDrawing(for: currentPageIndex)
        controller.setPdfAnchoredDrawing(pdfDrawing, for: currentPageIndex)
        controller.setMarginDrawing(marginDrawing, for: currentPageIndex)

        // Store reference for future updates
        context.coordinator.controller = controller

        return controller
    }

    func updateUIViewController(_ uiViewController: UnifiedBoardCanvasController, context: Context) {
        // Update mode if changed
        if uiViewController.canvasMode != canvasMode {
            uiViewController.setCanvasMode(canvasMode)
        }

        // Update margin settings if changed
        if uiViewController.marginSettings != marginSettings {
            uiViewController.updateMarginSettings(marginSettings)
        }

        // Update page if changed
        let controllerPageIndex = context.coordinator.currentPageIndex
        if controllerPageIndex != currentPageIndex {
            context.coordinator.currentPageIndex = currentPageIndex

            // Load drawings for new page
            let pdfDrawing = pdfManager.getPdfAnchoredDrawing(for: currentPageIndex)
            let marginDrawing = pdfManager.getMarginDrawing(for: currentPageIndex)
            uiViewController.setPdfAnchoredDrawing(pdfDrawing, for: currentPageIndex)
            uiViewController.setMarginDrawing(marginDrawing, for: currentPageIndex)
            uiViewController.setCurrentPage(currentPageIndex)
        }

        // Update canvas size if changed
        if uiViewController.canvasSize != canvasSize {
            uiViewController.initializeCanvas(size: canvasSize)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPageIndex: currentPageIndex)
    }

    final class Coordinator {
        var controller: UnifiedBoardCanvasController?
        var currentPageIndex: Int

        init(currentPageIndex: Int) {
            self.currentPageIndex = currentPageIndex
        }
    }
}

// MARK: - Convenience Initializer
extension UnifiedBoardCanvasView {
    /// Initialize with just EditorData and PDFManager, using default bindings
    init(
        editorData: EditorData,
        pdfManager: PDFManager,
        canvasMode: Binding<CanvasMode>,
        canvasSize: CGSize,
        currentPageIndex: Int,
        onModeChanged: ((CanvasMode) -> Void)? = nil,
        onPaperKitItemAdded: (() -> Void)? = nil,
        onDrawingChanged: ((Int, PKDrawing?, PKDrawing?) -> Void)? = nil
    ) {
        self.editorData = editorData
        self.pdfManager = pdfManager
        self._canvasMode = canvasMode
        self._marginSettings = .constant(pdfManager.currentPageMarginSettings)
        self.canvasSize = canvasSize
        self.currentPageIndex = currentPageIndex
        self.onModeChanged = onModeChanged
        self.onPaperKitItemAdded = onPaperKitItemAdded
        self.onDrawingChanged = onDrawingChanged
    }
}

// MARK: - Preview Modifier (for testing)
extension UnifiedBoardCanvasView {
    static let defaultSize = CGSize(width: 595.28, height: 841.89) // A4
}
