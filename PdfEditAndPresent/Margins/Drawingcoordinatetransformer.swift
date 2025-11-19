import UIKit
import PDFKit
import PencilKit

// MARK: - Drawing Coordinate Transformer (Dynamic Canvas)
/// Converts between view/touch space, a logical canvas (page-sized), and PDF space.
/// Canvas size is provided by MarginCanvasHelper and typically equals the current page size.
struct DrawingCoordinateTransformer {
    
    let marginHelper: MarginCanvasHelper
    let canvasViewBounds: CGRect
    let scaleFactor: CGFloat
    
    init(
        marginHelper: MarginCanvasHelper,
        canvasViewBounds: CGRect,
        scaleFactor: CGFloat = 1.0
    ) {
        self.marginHelper = marginHelper
        self.canvasViewBounds = canvasViewBounds
        self.scaleFactor = scaleFactor
    }
    
    // MARK: - Touch Point Transformation
    
    /// UIView touch point → normalized [0,1] → canvas space (page sized)
    func convertTouchPointToCanvasSpace(_ touchPoint: CGPoint) -> CGPoint {
        let normalizedX = (touchPoint.x - canvasViewBounds.origin.x) / canvasViewBounds.width
        let normalizedY = (touchPoint.y - canvasViewBounds.origin.y) / canvasViewBounds.height
        let clampedX = max(0, min(normalizedX, 1.0))
        let clampedY = max(0, min(normalizedY, 1.0))
        
        let canvasSize = marginHelper.canvasSize
        return CGPoint(x: clampedX * canvasSize.width, y: clampedY * canvasSize.height)
    }
    
    /// Canvas point → normalized [0,1] → view space
    func convertCanvasPointToTouchSpace(_ canvasPoint: CGPoint) -> CGPoint {
        let canvasSize = marginHelper.canvasSize
        let normalizedX = canvasPoint.x / canvasSize.width
        let normalizedY = canvasPoint.y / canvasSize.height
        let clampedX = max(0, min(normalizedX, 1.0))
        let clampedY = max(0, min(normalizedY, 1.0))
        
        return CGPoint(
            x: canvasViewBounds.origin.x + (clampedX * canvasViewBounds.width),
            y: canvasViewBounds.origin.y + (clampedY * canvasViewBounds.height)
        )
    }
    
    // MARK: - PDF Point Transformation
    
    func convertDrawingPointToPDFSpace(_ drawingPoint: CGPoint) -> CGPoint? {
        let canvasPoint = convertTouchPointToCanvasSpace(drawingPoint)
        return marginHelper.convertDrawingToPDFCoordinate(canvasPoint)
    }
    
    func convertPDFPointToDrawingSpace(_ pdfPoint: CGPoint) -> CGPoint {
        let canvasPoint = marginHelper.convertPDFToDrawingCoordinate(pdfPoint)
        return convertCanvasPointToTouchSpace(canvasPoint)
    }
    
    // MARK: - Drawing Transformation
    
    func getDisplayTransform() -> CGAffineTransform {
        let pdfFrame = marginHelper.pdfFrameInCanvas
        return CGAffineTransform(translationX: pdfFrame.origin.x, y: pdfFrame.origin.y)
            .scaledBy(x: marginHelper.settings.pdfScale, y: marginHelper.settings.pdfScale)
    }
    
    func getNormalizeTransform() -> CGAffineTransform {
        let pdfFrame = marginHelper.pdfFrameInCanvas
        return CGAffineTransform(translationX: -pdfFrame.origin.x, y: -pdfFrame.origin.y)
            .scaledBy(x: 1.0 / marginHelper.settings.pdfScale, y: 1.0 / marginHelper.settings.pdfScale)
    }
    
    func applyDisplayTransformToContext(_ context: CGContext) {
        context.concatenate(getDisplayTransform())
    }
    
    func applyNormalizeTransformToContext(_ context: CGContext) {
        context.concatenate(getNormalizeTransform())
    }
    
    // MARK: - Region Detection
    
    func getDrawingArea(_ drawingPoint: CGPoint) -> DrawingArea {
        let canvasPoint = convertTouchPointToCanvasSpace(drawingPoint)
        if marginHelper.isPointInPDFArea(canvasPoint) { return .pdf }
        
        let margins = marginHelper.getMarginAreas()
        if margins.top.contains(canvasPoint) { return .margin(.top) }
        if margins.bottom.contains(canvasPoint) { return .margin(.bottom) }
        if margins.left.contains(canvasPoint) { return .margin(.left) }
        if margins.right.contains(canvasPoint) { return .margin(.right) }
        return .outside
    }
    
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
        let topLeft = convertCanvasPointToTouchSpace(canvasRect.origin)
        let bottomRight = convertCanvasPointToTouchSpace(CGPoint(x: canvasRect.maxX, y: canvasRect.maxY))
        return CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }
    
    func getPDFRectInViewSpace() -> CGRect {
        convertMarginRectToViewSpace(marginHelper.pdfFrameInCanvas)
    }
    
    func getCanvasRectInViewSpace() -> CGRect {
        let rect = CGRect(origin: .zero, size: marginHelper.canvasSize)
        return convertMarginRectToViewSpace(rect)
    }
    
    func isPointWithinCanvas(_ drawingPoint: CGPoint) -> Bool {
        getCanvasRectInViewSpace().contains(drawingPoint)
    }
    
    func clampPointToDrawableArea(_ drawingPoint: CGPoint) -> CGPoint {
        let area = getDrawingArea(drawingPoint)
        if case .pdf = area { return drawingPoint }
        if case .margin = area { return drawingPoint }
        
        let canvasRect = getCanvasRectInViewSpace()
        let clampedX = max(canvasRect.minX, min(drawingPoint.x, canvasRect.maxX))
        let clampedY = max(canvasRect.minY, min(drawingPoint.y, canvasRect.maxY))
        return CGPoint(x: clampedX, y: clampedY)
    }
}

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

extension DrawingCoordinateTransformer {
    func debugPrintTransformInfo() {
        print("=== DrawingCoordinateTransformer Debug Info ===")
        print("Canvas Bounds: \(canvasViewBounds)")
        print("Scale Factor: \(scaleFactor)")
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
