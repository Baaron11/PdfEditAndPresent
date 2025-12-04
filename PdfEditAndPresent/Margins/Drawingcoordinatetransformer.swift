import UIKit
import PDFKit
import PencilKit

// MARK: - Drawing Region
enum DrawingRegion: Equatable {
    case pdf
    case margin
}

// MARK: - Drawing Area (Detailed)
enum DrawingArea: Equatable {
    case pdf
    case margin(MarginSide)
    case outside
    var description: String {
        switch self {
        case .pdf: return "PDF Area"
        case .margin(let side): return "Margin (\(side.description))"
        case .outside: return "Outside Canvas"
        }
    }
}

enum MarginSide: Equatable {
    case top, bottom, left, right
    var description: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}


// MARK: - Drawing Coordinate Transformer (Dual-Layer Dynamic Canvas)
/// Converts between view space, canvas space, and PDF space.
/// Supports dual-layer drawing with PDF-anchored and margin-anchored strokes.
struct DrawingCoordinateTransformer {

    let marginHelper: MarginCanvasHelper
    let canvasViewBounds: CGRect
    let zoomScale: CGFloat
    let contentOffset: CGPoint

    init(
        marginHelper: MarginCanvasHelper,
        canvasViewBounds: CGRect,
        zoomScale: CGFloat = 1.0,
        contentOffset: CGPoint = .zero
    ) {
        self.marginHelper = marginHelper
        self.canvasViewBounds = canvasViewBounds
        self.zoomScale = zoomScale
        self.contentOffset = contentOffset
    }

    // MARK: - Core Geometry

    /// The rectangle where the PDF sits within the logical canvas
    var pdfFrameInCanvas: CGRect {
        marginHelper.pdfFrameInCanvas
    }

    /// Transform to apply to pdfHost and pdfDrawingCanvas (positions PDF content within canvas)
    var displayTransform: CGAffineTransform {
        let pdfFrame = marginHelper.pdfFrameInCanvas
        let scale = marginHelper.settings.pdfScale
        return CGAffineTransform(translationX: pdfFrame.origin.x, y: pdfFrame.origin.y)
            .scaledBy(x: scale, y: scale)
    }

    // MARK: - Coordinate Conversions

    /// Convert view-space point to canvas-space point
    func viewToCanvas(_ viewPoint: CGPoint) -> CGPoint {
        let adjustedX = (viewPoint.x + contentOffset.x) / zoomScale
        let adjustedY = (viewPoint.y + contentOffset.y) / zoomScale
        return CGPoint(x: adjustedX, y: adjustedY)
    }

    /// Convert canvas-space point to view-space point
    func canvasToView(_ canvasPoint: CGPoint) -> CGPoint {
        let viewX = (canvasPoint.x * zoomScale) - contentOffset.x
        let viewY = (canvasPoint.y * zoomScale) - contentOffset.y
        return CGPoint(x: viewX, y: viewY)
    }

    /// Determine which region a view-space point falls into
    func region(forViewPoint viewPoint: CGPoint) -> DrawingRegion {
        let canvasPoint = viewToCanvas(viewPoint)
        if marginHelper.isPointInPDFArea(canvasPoint) {
            return .pdf
        }
        return .margin
    }

    /// Detailed area detection for a view-space point
    func getDrawingArea(_ viewPoint: CGPoint) -> DrawingArea {
        let canvasPoint = viewToCanvas(viewPoint)
        if marginHelper.isPointInPDFArea(canvasPoint) { return .pdf }

        let margins = marginHelper.getMarginAreas()
        if margins.top.contains(canvasPoint) { return .margin(.top) }
        if margins.bottom.contains(canvasPoint) { return .margin(.bottom) }
        if margins.left.contains(canvasPoint) { return .margin(.left) }
        if margins.right.contains(canvasPoint) { return .margin(.right) }
        return .outside
    }

    // MARK: - PKDrawing Normalization (PDF Space)

    /// Convert a PKDrawing from canvas space to normalized PDF space (0-1 range)
    func normalizeDrawingFromCanvasToPDF(_ drawing: PKDrawing) -> PKDrawing {
        let pdfFrame = marginHelper.pdfFrameInCanvas
        guard pdfFrame.width > 0 && pdfFrame.height > 0 else { return drawing }

        // Correct matrix: translate to origin, then scale down
        let transform = CGAffineTransform(
            a: 1.0 / pdfFrame.width, b: 0,
            c: 0, d: 1.0 / pdfFrame.height,
            tx: -pdfFrame.origin.x / pdfFrame.width, ty: -pdfFrame.origin.y / pdfFrame.height
        )

        return drawing.transformed(using: transform)
    }

    /// Convert a PKDrawing from normalized PDF space (0-1) back to canvas space
    func denormalizeDrawingFromPDFToCanvas(_ drawing: PKDrawing) -> PKDrawing {
        let pdfFrame = marginHelper.pdfFrameInCanvas
        guard pdfFrame.width > 0 && pdfFrame.height > 0 else { return drawing }

        // Correct matrix: scale on diagonal, origin as direct translation
        let transform = CGAffineTransform(
            a: pdfFrame.width, b: 0,
            c: 0, d: pdfFrame.height,
            tx: pdfFrame.origin.x, ty: pdfFrame.origin.y
        )

        return drawing.transformed(using: transform)
    }

    /// Normalize stroke paths from canvas coordinates to PDF-relative coordinates
    func normalizePathFromCanvasToPDF(_ drawing: PKDrawing) -> PKDrawing {
        return normalizeDrawingFromCanvasToPDF(drawing)
    }

    /// Denormalize stroke paths from PDF-relative coordinates to canvas coordinates
    func denormalizePathFromPDFToCanvas(_ drawing: PKDrawing) -> PKDrawing {
        return denormalizeDrawingFromPDFToCanvas(drawing)
    }

    // MARK: - Point Transformations

    /// Convert a canvas point to normalized PDF space (0-1)
    func canvasPointToPDFNormalized(_ canvasPoint: CGPoint) -> CGPoint? {
        let pdfFrame = marginHelper.pdfFrameInCanvas
        guard pdfFrame.contains(canvasPoint) else { return nil }

        let normalizedX = (canvasPoint.x - pdfFrame.origin.x) / pdfFrame.width
        let normalizedY = (canvasPoint.y - pdfFrame.origin.y) / pdfFrame.height
        return CGPoint(x: normalizedX, y: normalizedY)
    }

    /// Convert a normalized PDF point (0-1) back to canvas space
    func pdfNormalizedToCanvasPoint(_ normalizedPoint: CGPoint) -> CGPoint {
        let pdfFrame = marginHelper.pdfFrameInCanvas
        let canvasX = normalizedPoint.x * pdfFrame.width + pdfFrame.origin.x
        let canvasY = normalizedPoint.y * pdfFrame.height + pdfFrame.origin.y
        return CGPoint(x: canvasX, y: canvasY)
    }

    // MARK: - Legacy Compatibility

    func convertTouchPointToCanvasSpace(_ touchPoint: CGPoint) -> CGPoint {
        return viewToCanvas(touchPoint)
    }

    func convertCanvasPointToTouchSpace(_ canvasPoint: CGPoint) -> CGPoint {
        return canvasToView(canvasPoint)
    }

    func convertDrawingPointToPDFSpace(_ drawingPoint: CGPoint) -> CGPoint? {
        let canvasPoint = viewToCanvas(drawingPoint)
        return marginHelper.convertDrawingToPDFCoordinate(canvasPoint)
    }

    func convertPDFPointToDrawingSpace(_ pdfPoint: CGPoint) -> CGPoint {
        let canvasPoint = marginHelper.convertPDFToDrawingCoordinate(pdfPoint)
        return canvasToView(canvasPoint)
    }

    func getDisplayTransform() -> CGAffineTransform {
        return displayTransform
    }

    func getNormalizeTransform() -> CGAffineTransform {
        let pdfFrame = marginHelper.pdfFrameInCanvas
        return CGAffineTransform(translationX: -pdfFrame.origin.x, y: -pdfFrame.origin.y)
            .scaledBy(x: 1.0 / marginHelper.settings.pdfScale, y: 1.0 / marginHelper.settings.pdfScale)
    }

    func applyDisplayTransformToContext(_ context: CGContext) {
        context.concatenate(displayTransform)
    }

    func applyNormalizeTransformToContext(_ context: CGContext) {
        context.concatenate(getNormalizeTransform())
    }

    // MARK: - Rect Conversions

    func getMarginRectsInViewSpace() -> [MarginSide: CGRect] {
        let margins = marginHelper.getMarginAreas()
        var viewMargins: [MarginSide: CGRect] = [:]
        viewMargins[.top] = convertMarginRectToViewSpace(margins.top)
        viewMargins[.bottom] = convertMarginRectToViewSpace(margins.bottom)
        viewMargins[.left] = convertMarginRectToViewSpace(margins.left)
        viewMargins[.right] = convertMarginRectToViewSpace(margins.right)
        return viewMargins
    }

    private func convertMarginRectToViewSpace(_ canvasRect: CGRect) -> CGRect {
        let topLeft = canvasToView(canvasRect.origin)
        let bottomRight = canvasToView(CGPoint(x: canvasRect.maxX, y: canvasRect.maxY))
        return CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }

    func getPDFRectInViewSpace() -> CGRect {
        convertMarginRectToViewSpace(marginHelper.pdfFrameInCanvas)
    }

    func getCanvasRectInViewSpace() -> CGRect {
        let rect = CGRect(origin: .zero, size: marginHelper.canvasSize)
        return convertMarginRectToViewSpace(rect)
    }

    func isPointWithinCanvas(_ viewPoint: CGPoint) -> Bool {
        let canvasPoint = viewToCanvas(viewPoint)
        let canvasRect = CGRect(origin: .zero, size: marginHelper.canvasSize)
        return canvasRect.contains(canvasPoint)
    }

    func clampPointToDrawableArea(_ viewPoint: CGPoint) -> CGPoint {
        let area = getDrawingArea(viewPoint)
        if case .pdf = area { return viewPoint }
        if case .margin = area { return viewPoint }

        let canvasRect = getCanvasRectInViewSpace()
        let clampedX = max(canvasRect.minX, min(viewPoint.x, canvasRect.maxX))
        let clampedY = max(canvasRect.minY, min(viewPoint.y, canvasRect.maxY))
        return CGPoint(x: clampedX, y: clampedY)
    }
}

// MARK: - PKCanvasView Extension

extension PKCanvasView {
    func setupWithMarginTransformer(_ transformer: DrawingCoordinateTransformer) {
        self.backgroundColor = .clear
        self.isOpaque = false
        self.drawingPolicy = .anyInput
        transformer.debugPrintTransformInfo()
    }

    func applyMarginTransform(_ transformer: DrawingCoordinateTransformer) {
        let _ = transformer.getDisplayTransform()
    }
}

// MARK: - Debug Extension

extension DrawingCoordinateTransformer {
    func debugPrintTransformInfo() {
        print("=== DrawingCoordinateTransformer Debug Info ===")
        print("Canvas View Bounds: \(canvasViewBounds)")
        print("Zoom Scale: \(zoomScale)")
        print("Content Offset: \(contentOffset)")
        print("")
        print("Margin Settings:")
        print("  - Enabled: \(marginHelper.settings.isEnabled)")
        print("  - Anchor: \(marginHelper.settings.anchorPosition.rawValue)")
        print("  - Scale: \(Int(marginHelper.settings.pdfScale * 100))%")
        print("")
        print("Canvas Geometry:")
        print("  - Canvas Size: \(marginHelper.canvasSize)")
        print("  - PDF Original Size: \(marginHelper.originalPDFSize)")
        print("  - PDF Scaled Size: \(marginHelper.scaledPDFSize)")
        print("  - PDF Offset: \(marginHelper.pdfOffset)")
        print("  - PDF Frame: \(marginHelper.pdfFrameInCanvas)")
        print("==========================================")
    }
}
