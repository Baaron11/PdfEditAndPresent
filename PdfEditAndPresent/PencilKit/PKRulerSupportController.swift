import UIKit
import PencilKit

/// Adds simple, reliable ruler control to an existing PKCanvasView using your PKToolPicker instance.
/// - No deprecated `shared(for:)` calls.
/// - No unavailable `showsRuler` usage.
/// - You control visibility; this controller only ensures the picker observes the canvas.
public final class PKRulerSupportController: NSObject {
    private weak var canvasView: PKCanvasView?
    private var toolPicker: PKToolPicker

    /// Called whenever you explicitly toggle the ruler or when you call `syncFromCanvas()`.
    public var onRulerStateChanged: ((Bool) -> Void)?

    /// Create with your already-owned canvas & toolPicker.
    public init(canvasView: PKCanvasView, toolPicker: PKToolPicker) {
        self.canvasView = canvasView
        self.toolPicker = toolPicker
        super.init()
        attachToolPicker()
        // mirror initial state outward
        onRulerStateChanged?(isRulerActive)
    }

    deinit {
        if let canvas = canvasView {
            toolPicker.removeObserver(canvas)
        }
    }

    // MARK: - Attachment

    /// Attach/reattach the tool picker to the canvas. Safe to call multiple times.
    public func attachToolPicker() {
        guard let canvas = canvasView else { return }
        toolPicker.addObserver(canvas)
        // Do not force visibility here; leave it to caller UX.
        // If you do want it: toolPicker.setVisible(true, forFirstResponder: canvas); canvas.becomeFirstResponder()
    }

    // MARK: - Public API

    /// Get/Set the ruler state on the canvas.
    public var isRulerActive: Bool {
        get { canvasView?.isRulerActive ?? false }
        set {
            guard let canvas = canvasView else { return }
            let changed = (canvas.isRulerActive != newValue)
            canvas.isRulerActive = newValue
            if changed { onRulerStateChanged?(newValue) }
        }
    }

    /// Toggle the ruler on/off.
    public func toggleRuler() {
        isRulerActive.toggle()
    }

    /// Make the picker visible and focused on this canvas (optional helper).
    public func showToolPicker() {
        guard let canvas = canvasView else { return }
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    /// Call this after UI events where the user may have toggled the ruler via the picker UI.
    public func syncFromCanvas() {
        guard let canvas = canvasView else { return }
        onRulerStateChanged?(canvas.isRulerActive)
    }
}
