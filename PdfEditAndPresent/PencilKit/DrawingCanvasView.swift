// DrawingCanvasView.swift
// Location: Shared/Views/Drawing/DrawingCanvasView.swift

import SwiftUI
import PencilKit
import PDFKit

// MARK: - Drawing Canvas View
struct DrawingCanvasView: View {
    @ObservedObject var viewModel: DrawingViewModel
    @Binding var currentPage: Int
    @Binding var isDrawingMode: Bool
    @Binding var selectedTool: DrawingTool
    @Binding var scale: CGFloat
    @Binding var alignment: PDFAlignment
    let pdfDocument: PDFDocument
    let baseScale: CGFloat

    @State private var canvasView = PKCanvasView()
    @State private var toolPicker = PKToolPicker()

    var body: some View {
        DrawingCanvasRepresentable(
            canvasView: $canvasView,
            toolPicker: $toolPicker,
            viewModel: viewModel,
            currentPage: $currentPage,
            isDrawingMode: $isDrawingMode,
            selectedTool: $selectedTool,
            scale: $scale,
            alignment: $alignment,
            pdfDocument: pdfDocument,
            baseScale: baseScale
        )
        .allowsHitTesting(isDrawingMode)
    }
}

// MARK: - PencilKit Canvas Representable
struct DrawingCanvasRepresentable: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @Binding var toolPicker: PKToolPicker
    @ObservedObject var viewModel: DrawingViewModel
    @Binding var currentPage: Int
    @Binding var isDrawingMode: Bool
    @Binding var selectedTool: DrawingTool
    @Binding var scale: CGFloat
    @Binding var alignment: PDFAlignment
    let pdfDocument: PDFDocument
    let baseScale: CGFloat

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.delegate = context.coordinator
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput

        // Allow the canvas to bounce
        canvasView.alwaysBounceVertical = true
        canvasView.alwaysBounceHorizontal = true

        // Hide default tool picker but keep it observing the canvas
        toolPicker.setVisible(false, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)

        // Set initial tool
        updateTool(canvasView)

        // Initialize coordinator state
        context.coordinator.currentScale = scale
        context.coordinator.currentAlignment = alignment

        // Load drawing for current page
        if let drawing = viewModel.getDrawing(for: currentPage) {
            canvasView.drawing = drawing
        }

        // Canvas undo/redo closures (read the canvas' own undo manager)
        viewModel.canvasUndoHandler = { [weak canvasView] in canvasView?.undoManager?.undo() }
        viewModel.canvasRedoHandler = { [weak canvasView] in canvasView?.undoManager?.redo() }

        // Attach VM to this canvas & picker (wires ruler + lasso controllers)
        viewModel.attachCanvas(canvasView: canvasView, toolPicker: toolPicker)

        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Update drawing mode
        uiView.isUserInteractionEnabled = isDrawingMode

        // Update tool unless in lasso mode (lasso owns the tool)
        if !viewModel.isLassoActive {
            updateTool(uiView)
        }

        // Check if scale or alignment changed
        let scaleChanged = abs(context.coordinator.currentScale - scale) > 0.001
        let alignmentChanged = context.coordinator.currentAlignment != alignment
        let pageChanged = context.coordinator.lastPage != currentPage

        if scaleChanged || alignmentChanged {
            context.coordinator.currentScale = scale
            context.coordinator.currentAlignment = alignment
            context.coordinator.applyTransform(to: uiView)
        }

        // Handle page changes
        if pageChanged {
            // Save current page drawing before switching
            if context.coordinator.lastPage >= 0 {
                let untransformedDrawing = context.coordinator.removeTransform(from: uiView.drawing)
                DispatchQueue.main.async {
                    viewModel.saveDrawingWithoutNotification(untransformedDrawing, for: context.coordinator.lastPage)
                }
            }

            // Load new page drawing
            uiView.drawing = viewModel.getDrawing(for: currentPage) ?? PKDrawing()
            context.coordinator.lastPage = currentPage

            // Apply transform to new drawing
            context.coordinator.applyTransform(to: uiView)
        }

        if isDrawingMode {
            uiView.becomeFirstResponder()
            toolPicker.setVisible(false, forFirstResponder: uiView)
        } else {
            uiView.resignFirstResponder()
        }

        // Keep VM flags in sync (e.g., if user toggled ruler in picker)
        viewModel.syncFromCanvas()
    }

    // NOTE: We keep your original tool mapping. Lasso is a separate mode in the VM.
    private func updateTool(_ canvasView: PKCanvasView) {
        let tool: PKTool

        switch selectedTool {
        case .pen:
            tool = PKInkingTool(.pen, color: .black, width: 2)
        case .pencil:
            tool = PKInkingTool(.pencil, color: .darkGray, width: 1)
        case .marker:
            tool = PKInkingTool(.marker, color: .black, width: 5)
        case .highlighter:
            tool = PKInkingTool(.marker, color: UIColor.yellow.withAlphaComponent(0.5), width: 15)
        case .eraser:
            tool = PKEraserTool(.bitmap)
        }

        // Don't override if lasso is currently active
        if !(canvasView.tool is PKLassoTool) {
            canvasView.tool = tool
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: DrawingCanvasRepresentable
        var lastPage: Int = -1
        var currentScale: CGFloat = 1.0
        var currentAlignment: PDFAlignment = .center
        private var isApplyingTransform = false

        init(_ parent: DrawingCanvasRepresentable) {
            self.parent = parent
            super.init()
        }

        func applyTransform(to canvasView: PKCanvasView) {
            guard let page = parent.pdfDocument.page(at: parent.currentPage) else { return }

            isApplyingTransform = true
            defer { isApplyingTransform = false }

            let containerBounds = canvasView.bounds
            let pageBounds = page.bounds(for: .mediaBox)

            // Calculate the scale factor relative to base
            let scaleFactor = currentScale / parent.baseScale

            // Calculate scaled page dimensions
            let scaledPageWidth = pageBounds.width * currentScale
            let scaledPageHeight = pageBounds.height * currentScale

            // Calculate horizontal offset based on alignment
            let horizontalOffset: CGFloat = {
                switch currentAlignment {
                case .left:
                    return 0
                case .center:
                    return max(0, (containerBounds.width - scaledPageWidth) / 2)
                case .right:
                    return max(0, containerBounds.width - scaledPageWidth)
                }
            }()

            // Calculate vertical offset (centered with padding)
            let verticalOffset = max(0, (containerBounds.height - scaledPageHeight) / 2)

            // Remove existing transform from drawing
            let baseDrawing = removeTransform(from: canvasView.drawing)

            // Create new transformed drawing
            let transform = CGAffineTransform.identity
                .translatedBy(x: horizontalOffset, y: verticalOffset)
                .scaledBy(x: scaleFactor, y: scaleFactor)

            let transformedDrawing = baseDrawing.transformed(using: transform)
            canvasView.drawing = transformedDrawing
        }

        func removeTransform(from drawing: PKDrawing) -> PKDrawing {
            guard let page = parent.pdfDocument.page(at: parent.currentPage) else { return drawing }

            let containerBounds = parent.canvasView.bounds
            let pageBounds = page.bounds(for: .mediaBox)

            let scaleFactor = currentScale / parent.baseScale
            let scaledPageWidth = pageBounds.width * currentScale
            let scaledPageHeight = pageBounds.height * currentScale

            let horizontalOffset: CGFloat = {
                switch currentAlignment {
                case .left:
                    return 0
                case .center:
                    return max(0, (containerBounds.width - scaledPageWidth) / 2)
                case .right:
                    return max(0, containerBounds.width - scaledPageWidth)
                }
            }()

            let verticalOffset = max(0, (containerBounds.height - scaledPageHeight) / 2)

            // Create inverse transform
            let inverseTransform = CGAffineTransform.identity
                .translatedBy(x: horizontalOffset, y: verticalOffset)
                .scaledBy(x: scaleFactor, y: scaleFactor)
                .inverted()

            return drawing.transformed(using: inverseTransform)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Don't save changes during transform application
            guard !isApplyingTransform else { return }

            // Remove transform before saving
            let baseDrawing = removeTransform(from: canvasView.drawing)

            // Save asynchronously to avoid publishing during view update
            DispatchQueue.main.async {
                self.parent.viewModel.saveDrawingWithoutNotification(baseDrawing, for: self.parent.currentPage)
                self.parent.viewModel.markAsModifiedAsync()
            }
        }
    }
}
