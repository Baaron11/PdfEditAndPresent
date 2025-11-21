//
//  PKLassoSelectionController.swift
//  PDFMaster
//
//  Created by Brandon Ramirez on 11/6/25.
//


import UIKit
import PencilKit

/// Manages the PKLassoTool for selection operations on PKCanvasViews.
/// Supports switching between multiple canvas views for dual-layer drawing systems.
/// Provides customizable hooks and forwards PKCanvasViewDelegate to an external delegate if you already use one.
public final class PKLassoSelectionController: NSObject, PKCanvasViewDelegate {

    // MARK: - Types

    public enum SelectionAction {
        case cut, copy, paste, deleteSelection, selectAll, duplicate
    }

    public enum DuplicateStrategy {
        /// Use system copy+paste behavior (default).
        case systemCopyPaste
        /// Provide a custom duplication routine.
        case custom((_ canvas: PKCanvasView) -> Void)
    }

    // MARK: - Properties

    private weak var canvasView: PKCanvasView?

    /// If you already have your own PKCanvasViewDelegate, set it here to keep receiving callbacks.
    public weak var externalDelegate: PKCanvasViewDelegate?

    private var previousTool: PKTool?
    private(set) public var isLassoActive: Bool = false

    /// Called just before switching to lasso.
    public var onWillBeginLasso: ((_ canvas: PKCanvasView) -> Void)?

    /// Called after restoring the previous tool (i.e., lasso completed/cancelled).
    public var onDidEndLasso: ((_ canvas: PKCanvasView) -> Void)?

    /// Called after performing any selection action (cut/copy/paste/delete/selectAll/duplicate).
    public var onDidPerformAction: ((_ action: SelectionAction, _ canvas: PKCanvasView) -> Void)?

    /// Strategy to use when `duplicate()` is invoked.
    public var duplicateStrategy: DuplicateStrategy = .systemCopyPaste

    // MARK: - Init

    /// Initialize with a canvasView. This class sets itself as delegate,
    /// but forwards all delegate methods to `externalDelegate`.
    public init(canvasView: PKCanvasView) {
        self.canvasView = canvasView
        super.init()
        // Keep existing delegate if present; we'll forward to it.
        if let existing = canvasView.delegate, existing !== self {
            self.externalDelegate = existing
        }
        canvasView.delegate = self
    }

    deinit {
        // Restore delegate if we were forwarding (best-effort).
        if let canvas = canvasView, let forward = externalDelegate, canvas.delegate === self {
            canvas.delegate = forward
        }
    }

    // MARK: - Public API: Target Canvas Switching

    /// Switch the target canvas view (for dual-layer systems).
    /// This allows the lasso controller to operate on different canvases.
    public func setTargetCanvas(_ newCanvas: PKCanvasView?) {
        guard let newCanvas = newCanvas, newCanvas !== canvasView else { return }

        // Restore delegate on old canvas if needed
        if let oldCanvas = canvasView, oldCanvas.delegate === self {
            if let forward = externalDelegate {
                oldCanvas.delegate = forward
            }
        }

        // End lasso on old canvas if active
        if isLassoActive {
            endLassoAndRestorePreviousTool()
        }

        // Set up new canvas
        canvasView = newCanvas

        // Store existing delegate for forwarding
        if let existing = newCanvas.delegate, existing !== self {
            externalDelegate = existing
        }

        newCanvas.delegate = self
    }

    /// Get the current target canvas
    public var targetCanvas: PKCanvasView? {
        return canvasView
    }

    // MARK: - Public API: Lasso lifecycle

    /// Switch to the lasso tool, remembering the previous tool to restore later.
    public func beginLasso() {
        guard let canvas = canvasView else { return }
        if !(canvas.tool is PKLassoTool) {
            previousTool = canvas.tool
            onWillBeginLasso?(canvas)
            canvas.tool = PKLassoTool()
            isLassoActive = true
            canvas.becomeFirstResponder()
        }
    }

    /// Restore the previous tool (if any) and end lasso mode.
    public func endLassoAndRestorePreviousTool() {
        guard let canvas = canvasView else { return }
        if isLassoActive {
            if let prev = previousTool {
                canvas.tool = prev
            }
            isLassoActive = false
            onDidEndLasso?(canvas)
        }
    }

    /// Explicitly set the tool that should be restored when lasso ends.
    public func setPreviousTool(_ tool: PKTool?) {
        previousTool = tool
    }

    // MARK: - Public API: Selection operations

    @discardableResult
    public func perform(_ action: SelectionAction) -> Bool {
        guard let canvas = canvasView else { return false }
        switch action {
        case .cut:            canvas.cut(nil)
        case .copy:           canvas.copy(nil)
        case .paste:          canvas.paste(nil)
        case .deleteSelection:canvas.delete(nil)
        case .selectAll:      canvas.selectAll(nil)
        case .duplicate:
            switch duplicateStrategy {
            case .systemCopyPaste:
                canvas.copy(nil)
                canvas.paste(nil)
            case .custom(let handler):
                handler(canvas)
            }
        }
        onDidPerformAction?(action, canvas)
        return true
    }

    public func cut()            { _ = perform(.cut) }
    public func copy()           { _ = perform(.copy) }
    public func paste()          { _ = perform(.paste) }
    public func deleteSelection(){ _ = perform(.deleteSelection) }
    public func selectAll()      { _ = perform(.selectAll) }
    public func duplicate()      { _ = perform(.duplicate) }

    // MARK: - PKCanvasViewDelegate (forwarding)

    public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        externalDelegate?.canvasViewDrawingDidChange?(canvasView)
    }

    public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        // Track if user manually switched to a different tool (e.g., from ToolPicker)
        isLassoActive = canvasView.tool is PKLassoTool
        if isLassoActive {
            onWillBeginLasso?(canvasView)
        }
        externalDelegate?.canvasViewDidBeginUsingTool?(canvasView)
    }

    public func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        // If the active tool is no longer lasso, consider lasso ended.
        let stillLasso = canvasView.tool is PKLassoTool
        if !stillLasso && isLassoActive {
            isLassoActive = false
            onDidEndLasso?(canvasView)
        }
        externalDelegate?.canvasViewDidEndUsingTool?(canvasView)
    }
}
