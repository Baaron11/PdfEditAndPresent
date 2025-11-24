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

    var zoomLevel: CGFloat = 1.0
    var pageRotation: Int = 0

    // Callbacks
    var onModeChanged: ((CanvasMode) -> Void)?
    var onPaperKitItemAdded: (() -> Void)?
    var onDrawingChanged: ((Int, PKDrawing?, PKDrawing?) -> Void)?
    var onToolAPIReady: ((UnifiedBoardToolAPI) -> Void)?

    func makeUIViewController(context: Context) -> UnifiedBoardCanvasController {
        print("🎛️ [SWIFTUI] makeUIViewController() - creating controller")
        print("🎛️ [SWIFTUI]   canvasSize: \(canvasSize.width) x \(canvasSize.height)")
        print("🎛️ [SWIFTUI]   pageRotation: \(pageRotation)°")
        print("🎛️ [SWIFTUI]   currentPageIndex: \(currentPageIndex)")

        let controller = UnifiedBoardCanvasController()

        // Set rotation BEFORE initializing canvas to ensure viewDidLayoutSubviews
        // uses the correct rotation value from the start
        controller.updateZoomAndRotation(zoomLevel, pageRotation)

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

        // Emit tool API
        let api = UnifiedBoardToolAPI(
            setInkTool: { [weak controller] ink, color, width in controller?.setInkTool(ink, color: color, width: width) },
            setEraser: { [weak controller] in controller?.setEraser() },
            beginLasso: { [weak controller] in controller?.beginLassoSelection() },
            endLasso: { [weak controller] in controller?.endLassoSelection() },
            undo: { [weak controller] in controller?.undo() },
            redo: { [weak controller] in controller?.redo() }
        )
        DispatchQueue.main.async {
            onToolAPIReady?(api)
        }

        controller.updateZoomAndRotation(zoomLevel, pageRotation)

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
            print("🎛️ [SWIFTUI] updateUIViewController - page changed: \(controllerPageIndex) → \(currentPageIndex)")
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
            print("🎛️ [SWIFTUI] updateUIViewController - canvasSize changed")
            print("🎛️ [SWIFTUI]   Controller canvasSize: \(uiViewController.canvasSize.width) x \(uiViewController.canvasSize.height)")
            print("🎛️ [SWIFTUI]   New canvasSize: \(canvasSize.width) x \(canvasSize.height)")
            uiViewController.initializeCanvas(size: canvasSize)
        }

        // Check rotation change
        let oldRotation = context.coordinator.lastRotation
        if oldRotation != pageRotation {
            print("🔄 [SWIFTUI] updateUIViewController - pageRotation changed: \(oldRotation)° → \(pageRotation)°")
            context.coordinator.lastRotation = pageRotation
        }

        uiViewController.updateZoomAndRotation(zoomLevel, pageRotation)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPageIndex: currentPageIndex, lastRotation: pageRotation)
    }

    final class Coordinator {
        var controller: UnifiedBoardCanvasController?
        var currentPageIndex: Int
        var lastRotation: Int

        init(currentPageIndex: Int, lastRotation: Int) {
            self.currentPageIndex = currentPageIndex
            self.lastRotation = lastRotation
        }
    }
}

// MARK: - Preview Modifier (for testing)
extension UnifiedBoardCanvasView {
    static let defaultSize = CGSize(width: 595.28, height: 841.89) // A4
}
