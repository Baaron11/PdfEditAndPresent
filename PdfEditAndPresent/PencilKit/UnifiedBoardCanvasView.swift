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
    var onZoomChanged: ((CGFloat) -> Void)?

    func makeUIViewController(context: Context) -> UnifiedBoardCanvasController {
//        print("[SWIFTUI] makeUIViewController() - creating controller")
//        print("[SWIFTUI]   canvasSize: \(canvasSize.width) x \(canvasSize.height)")
//        print("[SWIFTUI]   pageRotation: \(pageRotation)°")
//        print("[SWIFTUI]   currentPageIndex: \(currentPageIndex)")
//        print("[SWIFTUI]   onZoomChanged closure exists: \(onZoomChanged != nil ? "YES" : "NO")")

        let controller = UnifiedBoardCanvasController()

        // Initialize canvas first
        controller.initializeCanvas(size: canvasSize)

        if let markup = editorData.markup {
            controller.setupPaperKit(markup: markup)
        }
        controller.setupPencilKit()

        // Store callback in coordinator
        //print("[CANVAS-VIEW] Storing onZoomChanged callback in coordinator")
        context.coordinator.onZoomChanged = onZoomChanged

        // Forward zoom changes from controller -> SwiftUI
        //print("[CANVAS-VIEW] Setting onZoomChanged callback on controller")
        controller.onZoomChanged = { [weak controller] newZoom in
            guard controller != nil else {
                //print("[CANVAS-VIEW] Controller weak reference is nil in onZoomChanged")
                return
            }
            //print("[CANVAS-VIEW] onZoomChanged callback fired with newZoom=\(String(format: "%.2f", newZoom))")
            DispatchQueue.main.async {
                //print("[CANVAS-VIEW] About to forward to coordinator...")
                //print("[CANVAS-VIEW]   coordinator.onZoomChanged is nil: \(context.coordinator.onZoomChanged == nil ? "YES" : "NO")")
                if let closure = context.coordinator.onZoomChanged {
                    //print("[CANVAS-VIEW] Calling coordinator onZoomChanged with: \(String(format: "%.2f", newZoom))")
                    closure(newZoom)
                } else {
                    //print("[CANVAS-VIEW] Coordinator onZoomChanged is NIL")
                }
            }
        }

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
                if let pdfDrawing = pdfDrawing {
                    pdfManager.setPdfAnchoredDrawing(pdfDrawing, for: pageIndex)
                }
                if let marginDrawing = marginDrawing {
                    pdfManager.setMarginDrawing(marginDrawing, for: pageIndex)
                }
                onDrawingChanged?(pageIndex, pdfDrawing, marginDrawing)
            }
        }

        controller.setCanvasMode(canvasMode)
        controller.updateMarginSettings(marginSettings)
        controller.setCurrentPage(currentPageIndex)

        let pdfDrawing = pdfManager.getPdfAnchoredDrawing(for: currentPageIndex)
        let marginDrawing = pdfManager.getMarginDrawing(for: currentPageIndex)
        controller.setPdfAnchoredDrawing(pdfDrawing, for: currentPageIndex)
        controller.setMarginDrawing(marginDrawing, for: currentPageIndex)

        context.coordinator.controller = controller

        let api = UnifiedBoardToolAPI(
            setInkTool: { [weak controller] ink, color, width in controller?.setInk(ink: ink, color: color, width: width) },
            setEraser: { [weak controller] in controller?.setEraser() },
            beginLasso: { [weak controller] in controller?.beginLasso() },
            endLasso: { [weak controller] in controller?.endLasso() },
            undo: { [weak controller] in controller?.undo() },
            redo: { [weak controller] in controller?.redo() },
            toggleRuler: { [weak controller] in controller?.toggleRuler() },
            canvasController: controller
        )
        DispatchQueue.main.async {
            onToolAPIReady?(api)
        }

        // Apply initial zoom & rotation once
        controller.updateZoomAndRotation(zoomLevel, pageRotation)

        // Keep coordinator in sync with initial values
        context.coordinator.lastZoomLevel = zoomLevel
        context.coordinator.lastRotation = pageRotation

        return controller
    }

    func updateUIViewController(_ uiViewController: UnifiedBoardCanvasController, context: Context) {
        context.coordinator.onZoomChanged = onZoomChanged

        if uiViewController.canvasMode != canvasMode {
            uiViewController.setCanvasMode(canvasMode)
        }

        if uiViewController.marginSettings != marginSettings {
            uiViewController.updateMarginSettings(marginSettings)
        }

        let controllerPageIndex = context.coordinator.currentPageIndex
        if controllerPageIndex != currentPageIndex {
            print("[SWIFTUI] updateUIViewController - page changed: \(controllerPageIndex) → \(currentPageIndex)")
            context.coordinator.currentPageIndex = currentPageIndex

            let pdfDrawing = pdfManager.getPdfAnchoredDrawing(for: currentPageIndex)
            let marginDrawing = pdfManager.getMarginDrawing(for: currentPageIndex)
            uiViewController.setPdfAnchoredDrawing(pdfDrawing, for: currentPageIndex)
            uiViewController.setMarginDrawing(marginDrawing, for: currentPageIndex)
            uiViewController.setCurrentPage(currentPageIndex)
        }

        if uiViewController.canvasSize != canvasSize {
            print("[SWIFTUI] updateUIViewController - canvasSize changed")
            print("[SWIFTUI]   Controller canvasSize: \(uiViewController.canvasSize.width) x \(uiViewController.canvasSize.height)")
            print("[SWIFTUI]   New canvasSize: \(canvasSize.width) x \(canvasSize.height)")
            uiViewController.initializeCanvas(size: canvasSize)
        }

        // 1) Handle zoom changes: update constraints/overlay ONCE
        let oldZoom = context.coordinator.lastZoomLevel
        let zoomChangeThreshold: CGFloat = 0.01  // Only update if zoom changes by 1% or more
        if abs(zoomLevel - oldZoom) > zoomChangeThreshold {
            print("[SWIFTUI] updateUIViewController - zoomLevel changed: \(String(format: "%.2f", oldZoom)) → \(String(format: "%.2f", zoomLevel))")
            uiViewController.updateCanvasForZoom(zoomLevel)
            context.coordinator.lastZoomLevel = zoomLevel
        }

        // 2) Handle rotation changes: update rotation (and absolute zoom if needed) ONCE
        let oldRotation = context.coordinator.lastRotation
        if oldRotation != pageRotation {
            print("[SWIFTUI] updateUIViewController - pageRotation changed: \(oldRotation)° → \(pageRotation)°")
            context.coordinator.lastRotation = pageRotation

            // Important: only call this when rotation actually changes, so zoom isn't applied twice
            uiViewController.updateZoomAndRotation(zoomLevel, pageRotation)
        }

        // Note: we intentionally removed the unconditional
        // uiViewController.updateZoomAndRotation(zoomLevel, pageRotation)
        // at the end to avoid double-applying zoom to the active page.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPageIndex: currentPageIndex, lastRotation: pageRotation)
    }

    final class Coordinator {
        var controller: UnifiedBoardCanvasController?
        var currentPageIndex: Int
        var lastRotation: Int
        var lastZoomLevel: CGFloat = 1.0
        var onZoomChanged: ((CGFloat) -> Void)?

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
