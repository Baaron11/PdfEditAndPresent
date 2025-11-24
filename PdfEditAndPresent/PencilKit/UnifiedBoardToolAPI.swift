import UIKit
import PencilKit

public struct UnifiedBoardToolAPI {
    public var setInkTool: (_ ink: PKInkingTool.InkType, _ color: UIColor, _ width: CGFloat) -> Void
    public var setEraser: () -> Void
    public var beginLasso: () -> Void
    public var endLasso: () -> Void
    public var undo: () -> Void
    public var redo: () -> Void
    public var toggleRuler: () -> Void
    public var canvasController: UnifiedBoardCanvasController?
}
