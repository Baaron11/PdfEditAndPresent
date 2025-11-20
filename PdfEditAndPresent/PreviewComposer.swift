import PDFKit
import UIKit

struct PreviewComposer {
    static func compose(subset source: PDFDocument,
                        paperSize: PDFManager.PaperSize,
                        pagesPerSheet: Int,
                        border: PDFManager.BorderStyle) -> PDFDocument? {

        let paperRect: CGRect = {
            switch paperSize {
            case .systemDefault: return CGRect(x: 0, y: 0, width: 612, height: 792) // Letter fallback for preview
            case .letter: return CGRect(x: 0, y: 0, width: 612, height: 792)
            case .legal:  return CGRect(x: 0, y: 0, width: 612, height: 1008)
            case .a4:     return CGRect(x: 0, y: 0, width: 595, height: 842)
            }
        }()

        let fmt = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: paperRect, format: fmt)

        let data = renderer.pdfData { ctx in
            let (rows, cols) = gridFor(pagesPerSheet)
            let cells = cells(in: paperRect.insetBy(dx: 18, dy: 18), rows: rows, cols: cols, spacing: 8)

            var srcIndex = 0
            while srcIndex < source.pageCount {
                ctx.beginPage()
                for cell in cells {
                    guard srcIndex < source.pageCount, let pg = source.page(at: srcIndex) else { break }
                    let box = pg.bounds(for: .mediaBox)
                    let scale = min(cell.width/box.width, cell.height/box.height)
                    let draw = CGRect(x: cell.midX - (box.width*scale)/2,
                                      y: cell.midY - (box.height*scale)/2,
                                      width: box.width*scale, height: box.height*scale)

                    if let cg = UIGraphicsGetCurrentContext() {
                        cg.saveGState()
                        cg.translateBy(x: draw.minX, y: draw.maxY)
                        cg.scaleBy(x: scale, y: -scale)
                        pg.draw(with: .mediaBox, to: cg)
                        cg.restoreGState()
                    }

                    // borders
                    drawBorder(in: draw, style: border)

                    srcIndex += 1
                }
            }
        }

        return PDFDocument(data: data)
    }

    private static func gridFor(_ n: Int) -> (Int, Int) {
        switch n {
        case 1: return (1,1)
        case 2: return (1,2)
        case 4: return (2,2)
        case 6: return (2,3)
        case 8: return (2,4)
        default:
            let r = Int(ceil(sqrt(Double(n))))
            let c = Int(ceil(Double(n)/Double(r)))
            return (r,c)
        }
    }

    private static func cells(in rect: CGRect, rows: Int, cols: Int, spacing: CGFloat) -> [CGRect] {
        var out: [CGRect] = []
        let w = (rect.width - spacing*CGFloat(cols-1)) / CGFloat(cols)
        let h = (rect.height - spacing*CGFloat(rows-1)) / CGFloat(rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let x = rect.minX + CGFloat(c)*(w+spacing)
                let y = rect.minY + CGFloat(r)*(h+spacing)
                out.append(CGRect(x: x, y: y, width: w, height: h))
            }
        }
        return out
    }

    private static func drawBorder(in rect: CGRect, style: PDFManager.BorderStyle) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        UIColor.label.setStroke()
        switch style {
        case .none: break
        case .singleHair:
            ctx.setLineWidth(0.25); ctx.stroke(rect)
        case .singleThin:
            ctx.setLineWidth(0.75); ctx.stroke(rect)
        case .doubleHair:
            ctx.setLineWidth(0.25); ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            ctx.stroke(rect.insetBy(dx: 3, dy: 3))
        case .doubleThin:
            ctx.setLineWidth(0.75); ctx.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
            ctx.stroke(rect.insetBy(dx: 3.5, dy: 3.5))
        }
        ctx.restoreGState()
    }
}
