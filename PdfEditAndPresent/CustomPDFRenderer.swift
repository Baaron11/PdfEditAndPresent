// Printing/CustomPDFRenderer.swift
import UIKit
import PDFKit

final class CustomPDFRenderer: UIPrintPageRenderer {
    private let doc: PDFDocument
    private let includeAnnotations: Bool
    private let pagesPerSheet: Int
    private let borderStyle: PDFManager.BorderStyle

    init(pdfData: Data,
         pagesPerSheet: Int,
         paperSize: PDFManager.PaperSize,
         borderStyle: PDFManager.BorderStyle,
         includeAnnotations: Bool)
    {
        self.doc = PDFDocument(data: pdfData) ?? PDFDocument()
        self.pagesPerSheet = max(1, pagesPerSheet)
        self.borderStyle = borderStyle
        self.includeAnnotations = includeAnnotations
        super.init()

        // Paper rect
        if paperSize != .systemDefault {
            let rect = paperSize.pageRect
            setValue(NSValue(cgRect: rect), forKey: "paperRect")
            // leave printableRect equal to paperRect so we control margins inside drawPage
            setValue(NSValue(cgRect: rect.insetBy(dx: 18, dy: 18)), forKey: "printableRect")
        }
    }

    override var numberOfPages: Int {
        let count = max(1, doc.pageCount)
        return Int(ceil(Double(count) / Double(pagesPerSheet)))
    }

    override func drawContentForPage(at pageIndex: Int, in contentRect: CGRect) {
        guard doc.pageCount > 0 else { return }

        // Compute grid for n-up
        let grid = gridFor(pagesPerSheet: pagesPerSheet)
        let cells = cells(in: contentRect, rows: grid.rows, cols: grid.cols, spacing: 8)

        let startPage = pageIndex * pagesPerSheet
        for i in 0..<pagesPerSheet {
            let pIndex = startPage + i
            if pIndex >= doc.pageCount { break }
            guard let page = doc.page(at: pIndex) else { continue }

            let cell = cells[i]
            let pageBox = page.bounds(for: .mediaBox)
            let scale = min(cell.width / pageBox.width, cell.height / pageBox.height)
            let drawRect = CGRect(
                x: cell.midX - (pageBox.width * scale)/2,
                y: cell.midY - (pageBox.height * scale)/2,
                width: pageBox.width * scale,
                height: pageBox.height * scale
            )

            // Draw page
            UIColor.white.setFill()
            UIRectFill(drawRect)
            if let ctx = UIGraphicsGetCurrentContext() {
                ctx.saveGState()
                ctx.translateBy(x: drawRect.minX, y: drawRect.maxY)
                ctx.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: ctx)
                if includeAnnotations {
                    for ann in page.annotations {
                        ann.draw(with: .mediaBox, in: ctx)
                    }
                }
                ctx.restoreGState()
            }

            // Borders
            drawBorder(in: drawRect)
        }
    }

    private func gridFor(pagesPerSheet: Int) -> (rows: Int, cols: Int) {
        switch pagesPerSheet {
        case 1: return (1,1)
        case 2: return (1,2)
        case 4: return (2,2)
        case 6: return (2,3)
        case 8: return (2,4)
        default: return (Int(ceil(sqrt(Double(pagesPerSheet)))), Int(ceil(Double(pagesPerSheet) / ceil(sqrt(Double(pagesPerSheet))))))
        }
    }

    private func cells(in rect: CGRect, rows: Int, cols: Int, spacing: CGFloat) -> [CGRect] {
        var out: [CGRect] = []
        let w = (rect.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        let h = (rect.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let x = rect.minX + CGFloat(c) * (w + spacing)
                let y = rect.minY + CGFloat(r) * (h + spacing)
                out.append(CGRect(x: x, y: y, width: w, height: h))
            }
        }
        return out
    }

    private func drawBorder(in rect: CGRect) {
        guard borderStyle != .none, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.label.cgColor)
        switch borderStyle {
        case .singleHair:
            ctx.setLineWidth(0.25)
            ctx.stroke(rect)
        case .singleThin:
            ctx.setLineWidth(0.75)
            ctx.stroke(rect)
        case .doubleHair:
            ctx.setLineWidth(0.25)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            ctx.stroke(rect.insetBy(dx: 3, dy: 3))
        case .doubleThin:
            ctx.setLineWidth(0.75)
            ctx.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
            ctx.stroke(rect.insetBy(dx: 3.5, dy: 3.5))
        default:
            break
        }
        ctx.restoreGState()
    }
}
