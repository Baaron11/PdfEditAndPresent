import UIKit
import PencilKit

// Protocol your DrawingViewModel can call into
protocol DrawingCanvasAPI: AnyObject {
    func setInk(ink: PKInkingTool.InkType, color: UIColor, width: CGFloat)
    func setEraser()
    func beginLasso()
    func endLasso()
    func undo()
    func redo()
    func toggleRuler() // no-op if unsupported
}

final class UnifiedBoardCanvasAdapter: DrawingCanvasAPI {
    private let api: UnifiedBoardToolAPI

    init(api: UnifiedBoardToolAPI) {
        self.api = api
    }

    func setInk(ink: PKInkingTool.InkType, color: UIColor, width: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        print("🖊️ [ADAPTER] setInk: \(ink.rawValue) width=\(width)")
        print("   Color at adapter: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255))")
        api.setInkTool(ink, color, width)
    }

    func setEraser() {
        print("🧽 eraser")
        api.setEraser()
    }

    func beginLasso() {
        print("🔗 begin lasso")
        api.beginLasso()
    }

    func endLasso() {
        print("🔗 end lasso")
        api.endLasso()
    }

    func undo() {
        print("↩️ undo")
        api.undo()
    }

    func redo() {
        print("↪️ redo")
        api.redo()
    }

    func toggleRuler() {
        print("📏 toggle ruler (no-op unless implemented)")
        // If you add ruler support in controller later, call it here.
    }
}
