import Foundation
import SwiftUI

// MARK: - Anchor Position Enum (9-point grid)
enum AnchorPosition: String, CaseIterable, Codable, Hashable {
    case topLeft = "TL"
    case topCenter = "TC"
    case topRight = "TR"
    case centerLeft = "CL"
    case center = "C"
    case centerRight = "CR"
    case bottomLeft = "BL"
    case bottomCenter = "BC"
    case bottomRight = "BR"
    
    var label: String { self.rawValue }
    
    var symbolName: String {
        switch self {
        case .topLeft: return "square.grid.3x3.topleft.filled"
        case .topCenter: return "square.grid.3x3.topmiddle.filled"
        case .topRight: return "square.grid.3x3.topright.filled"
        case .centerLeft: return "square.grid.3x3.middleleft.filled"
        case .center: return "square.grid.3x3.middle.filled"
        case .centerRight: return "square.grid.3x3.middleright.filled"
        case .bottomLeft: return "square.grid.3x3.bottomleft.filled"
        case .bottomCenter: return "square.grid.3x3.bottommiddle.filled"
        case .bottomRight: return "square.grid.3x3.bottomright.filled"
        }
    }
    
    var gridPosition: (row: Int, col: Int) {
        switch self {
        case .topLeft: return (0, 0)
        case .topCenter: return (0, 1)
        case .topRight: return (0, 2)
        case .centerLeft: return (1, 0)
        case .center: return (1, 1)
        case .centerRight: return (1, 2)
        case .bottomLeft: return (2, 0)
        case .bottomCenter: return (2, 1)
        case .bottomRight: return (2, 2)
        }
    }
}

// MARK: - Margin Settings (Per-Page Configuration)
struct MarginSettings: Codable, Equatable {
    var isEnabled: Bool = false
    var anchorPosition: AnchorPosition = .center
    /// 0.1 ... 1.0 (1.0 = original size, <1.0 shrinks PDF to create visible margins)
    var pdfScale: CGFloat = 1.0
    var appliedToAllPages: Bool = false

    /// Minimum margin scale (how small the PDF can shrink). Default 0.10 = 10%
    /// This determines how much extra canvas space is needed for drawing beyond the PDF.
    var minimumMarginScale: CGFloat = 0.10

    /// Maximum margin scale (full size). Default 1.0 = 100%
    var maximumMarginScale: CGFloat = 1.0

    init(
        isEnabled: Bool = false,
        anchorPosition: AnchorPosition = .center,
        pdfScale: CGFloat = 1.0,
        appliedToAllPages: Bool = false,
        minimumMarginScale: CGFloat = 0.10,
        maximumMarginScale: CGFloat = 1.0
    ) {
        self.isEnabled = isEnabled
        self.anchorPosition = anchorPosition
        self.pdfScale = max(0.1, min(pdfScale, 1.0))
        self.appliedToAllPages = appliedToAllPages
        self.minimumMarginScale = max(0.01, min(minimumMarginScale, 1.0))
        self.maximumMarginScale = max(minimumMarginScale, min(maximumMarginScale, 1.0))
    }
}

// MARK: - Margin Canvas Helper (Dynamic Canvas)
/// Positions and converts between the PDF and a logical "canvas" that defaults to the actual page size.
/// If pdfScale < 1, margin space appears within the canvas around the scaled down PDF.
struct MarginCanvasHelper {
    let settings: MarginSettings
    let originalPDFSize: CGSize
    /// The drawing/export canvas. Defaults to `originalPDFSize` to preserve page size.
    let canvasSize: CGSize
    
    init(
        settings: MarginSettings,
        originalPDFSize: CGSize,
        canvasSize: CGSize? = nil
    ) {
        self.settings = settings
        self.originalPDFSize = originalPDFSize
        self.canvasSize = canvasSize ?? originalPDFSize
    }
    
    // MARK: - Calculations
    
    /// Size of the scaled PDF that sits inside the canvas.
    var scaledPDFSize: CGSize {
        CGSize(
            width: originalPDFSize.width * settings.pdfScale,
            height: originalPDFSize.height * settings.pdfScale
        )
    }
    
    /// Offset of the scaled PDF within the canvas based on anchor.
    var pdfOffset: CGPoint {
        let scaledSize = scaledPDFSize
        let canvas = canvasSize
        let (row, col) = settings.anchorPosition.gridPosition
        
        let xPosition: CGFloat = {
            switch col {
            case 0: return 0
            case 1: return (canvas.width - scaledSize.width) / 2
            case 2: return canvas.width - scaledSize.width
            default: return 0
            }
        }()
        
        let yPosition: CGFloat = {
            switch row {
            case 0: return 0
            case 1: return (canvas.height - scaledSize.height) / 2
            case 2: return canvas.height - scaledSize.height
            default: return 0
            }
        }()
        
        return CGPoint(x: xPosition, y: yPosition)
    }
    
    /// The rectangle where the (scaled) PDF is drawn within the canvas.
    var pdfFrameInCanvas: CGRect {
        CGRect(origin: pdfOffset, size: scaledPDFSize)
    }
    
    // MARK: - Coordinate Transformations
    
    func convertDrawingToPDFCoordinate(_ drawingPoint: CGPoint) -> CGPoint? {
        let pdfFrame = pdfFrameInCanvas
        guard pdfFrame.contains(drawingPoint) else { return nil }
        
        let relative = CGPoint(
            x: drawingPoint.x - pdfFrame.origin.x,
            y: drawingPoint.y - pdfFrame.origin.y
        )
        return CGPoint(
            x: relative.x / settings.pdfScale,
            y: relative.y / settings.pdfScale
        )
    }
    
    func convertPDFToDrawingCoordinate(_ pdfPoint: CGPoint) -> CGPoint {
        let pdfFrame = pdfFrameInCanvas
        let scaled = CGPoint(
            x: pdfPoint.x * settings.pdfScale,
            y: pdfPoint.y * settings.pdfScale
        )
        return CGPoint(
            x: scaled.x + pdfFrame.origin.x,
            y: scaled.y + pdfFrame.origin.y
        )
    }
    
    func isPointInPDFArea(_ point: CGPoint) -> Bool {
        pdfFrameInCanvas.contains(point)
    }
    
    /// Margins are the empty areas of the canvas around the scaled PDF
    func getMarginAreas() -> (top: CGRect, bottom: CGRect, left: CGRect, right: CGRect) {
        let pdfFrame = pdfFrameInCanvas
        let canvas = canvasSize
        
        let top = CGRect(x: 0, y: 0, width: canvas.width, height: pdfFrame.minY)
        let bottom = CGRect(x: 0, y: pdfFrame.maxY, width: canvas.width, height: canvas.height - pdfFrame.maxY)
        let left = CGRect(x: 0, y: pdfFrame.minY, width: pdfFrame.minX, height: pdfFrame.height)
        let right = CGRect(x: pdfFrame.maxX, y: pdfFrame.minY, width: canvas.width - pdfFrame.maxX, height: pdfFrame.height)
        
        return (top, bottom, left, right)
    }
}
