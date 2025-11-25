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

    // NEW: Provide access to the canvas controller through the protocol
    var canvasController: UnifiedBoardCanvasController? { get }
}

final class UnifiedBoardCanvasAdapter: DrawingCanvasAPI {
    private let api: UnifiedBoardToolAPI
    internal weak var canvasController: UnifiedBoardCanvasController?

    init(api: UnifiedBoardToolAPI, controller: UnifiedBoardCanvasController? = nil) {
        self.api = api
        self.canvasController = controller
        if controller != nil {
            print("✅ [ADAPTER-INIT] Weak reference to controller established")
        } else {
            print("⚠️ [ADAPTER-INIT] Controller not provided to adapter")
        }
    }

    func setInk(ink: PKInkingTool.InkType, color: UIColor, width: CGFloat) {
        guard canvasController != nil else {
            print("⚠️ [ADAPTER] Controller is no longer available (weak reference released), cannot set ink")
            return
        }

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        print("🖊️ [ADAPTER] Setting ink with color: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255))")
        api.setInkTool(ink, color, width)
    }

    func setEraser() {
        guard canvasController != nil else {
            print("⚠️ [ADAPTER] Controller is no longer available (weak reference released), cannot set eraser")
            return
        }

        print("🧽 [ADAPTER] Setting eraser")
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

    deinit {
        print("🧹 UnifiedBoardCanvasAdapter deinit - weak controller reference will be auto-released")
    }
}
