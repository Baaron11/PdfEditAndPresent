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
    private var canvasController: UnifiedBoardCanvasController?

    init(api: UnifiedBoardToolAPI, controller: UnifiedBoardCanvasController? = nil) {
        self.api = api
        if let controller = controller {
            self.canvasController = controller
            print("✅ [ADAPTER-INIT] Controller attached directly in init - no casting needed")
        } else {
            print("⚠️ [ADAPTER-INIT] Controller not provided to adapter")
        }
    }

    /// Attach the controller to establish strong reference after initialization
    /// This ensures the adapter persists through SwiftUI re-renders
    func attachController(_ controller: UnifiedBoardCanvasController) {
        self.canvasController = controller
        print("🔗 Adapter attached to controller (strong reference)")
    }

    func setInk(ink: PKInkingTool.InkType, color: UIColor, width: CGFloat) {
        guard let controller = canvasController else {
            print("⚠️ [ADAPTER] Controller not attached, cannot set ink")
            return
        }

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        print("🖊️ [ADAPTER] Setting ink through controller: \(ink.rawValue) width=\(width)")
        print("   Color at adapter: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255))")
        api.setInkTool(ink, color, width)
    }

    func setEraser() {
        guard let controller = canvasController else {
            print("⚠️ [ADAPTER] Controller not attached, cannot set eraser")
            return
        }

        print("🧽 [ADAPTER] Setting eraser through controller")
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
        print("🧹 UnifiedBoardCanvasAdapter deinit - breaking controller reference")
        canvasController = nil
    }
}
