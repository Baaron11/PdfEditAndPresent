//
//  DrawingTool.swift
//  UnifiedBoard
//
//  Created by Brandon Ramirez on 11/7/25.
//


// DrawingViewModel.swift
// Location: Shared/ViewModels/DrawingViewModel.swift

import SwiftUI
import PencilKit
import Combine

// MARK: - Drawing Tool Enum (moved here so it's visible app-wide)
enum DrawingTool: String, CaseIterable {
    case pen = "Pen"
    case pencil = "Pencil"
    case marker = "Marker"
    case highlighter = "Highlighter"
    case eraser = "Eraser"

    var iconName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "paintbrush.pointed"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        }
    }

    var color: Color {
        switch self {
        case .pen: return .black
        case .pencil: return .gray
        case .marker: return .black
        case .highlighter: return .yellow
        case .eraser: return .pink
        }
    }
}

final class DrawingViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var drawings: [Int: PKDrawing] = [:]
    @Published var isModified = false
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var currentTool: DrawingTool = .pen
    @Published var currentColor: Color = .black
    @Published var currentWidth: CGFloat = 2.0

    // Ruler + Lasso state for toolbar
    @Published var isRulerActive: Bool = false
    @Published var isLassoActive: Bool = false

    // MARK: - Undo Manager
    weak var undoManager: UndoManager?

    // MARK: - Canvas Integration Handlers
    var canvasUndoHandler: (() -> Void)?
    var canvasRedoHandler: (() -> Void)?
    // NOTE: Removed set-undo-manager handler; PKCanvasView.undoManager is get-only

    // MARK: - Private
    private var cancellables = Set<AnyCancellable>()
    private var undoObservers: [NSObjectProtocol] = []

    // Keep refs to live canvas/picker & controllers
    private weak var canvasView: PKCanvasView?
    private var toolPickerRef: PKToolPicker?
    private var rulerController: PKRulerSupportController?
    private var lassoController: PKLassoSelectionController?

    // MARK: - Canvas Adapter (for DrawingToolbar integration)
    private weak var canvasAdapter: DrawingCanvasAPI?

    // MARK: - Init
    init() { }

    // MARK: - Canvas Adapter Attachment
    func attachCanvas(_ canvas: DrawingCanvasAPI) {
        self.canvasAdapter = canvas
        print("🧩 DrawingViewModel attached to canvas adapter")
    }

    // MARK: - Canvas Attachment
    func attachCanvas(canvasView: PKCanvasView, toolPicker: PKToolPicker) {
        self.canvasView = canvasView
        self.toolPickerRef = toolPicker

        // RULER
        let ruler = PKRulerSupportController(canvasView: canvasView, toolPicker: toolPicker)
        ruler.onRulerStateChanged = { [weak self] isActive in
            self?.isRulerActive = isActive
        }
        self.rulerController = ruler
        self.isRulerActive = canvasView.isRulerActive

        // LASSO
        let lasso = PKLassoSelectionController(canvasView: canvasView)
        lasso.onWillBeginLasso = { [weak self] _ in self?.isLassoActive = true }
        lasso.onDidEndLasso   = { [weak self] _ in self?.isLassoActive = false }
        self.lassoController = lasso

        syncFromCanvas()
    }

    func syncFromCanvas() {
        if let cv = canvasView {
            isRulerActive = cv.isRulerActive
            isLassoActive = (cv.tool is PKLassoTool)
        }
    }

    // MARK: - Ruler API
    func toggleRuler() {
        isRulerActive.toggle()
        rulerController?.toggleRuler()
        canvasAdapter?.toggleRuler()
        syncFromCanvas()
    }

    // MARK: - Lasso API
    func beginLasso() {
        isLassoActive = true
        lassoController?.beginLasso()
        canvasAdapter?.beginLasso()
        syncFromCanvas()
    }

    func endLasso() {
        isLassoActive = false
        lassoController?.endLassoAndRestorePreviousTool()
        canvasAdapter?.endLasso()
        syncFromCanvas()
    }

    func cut()             { lassoController?.cut() }
    func copy()            { lassoController?.copy() }
    func paste()           { lassoController?.paste() }
    func deleteSelection() { lassoController?.deleteSelection() }
    func selectAll()       { lassoController?.selectAll() }
    func duplicate()       { lassoController?.duplicate() }

    // MARK: - Undo Manager Attachment
    func attachUndoManager(_ manager: UndoManager?) {
        print("📎 Attaching undo manager: \(manager != nil ? "YES" : "NO")")

        // Remove old observers
        undoObservers.forEach { NotificationCenter.default.removeObserver($0) }
        undoObservers.removeAll()

        // Store
        undoManager = manager

        guard let manager = manager else {
            canUndo = false
            canRedo = false
            print("⚠️ No undo manager - undo/redo disabled")
            return
        }

        print("✅ Undo manager attached successfully")
        print("   Levels of undo: \(manager.levelsOfUndo)")

        let didUndo = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerDidUndoChange,
            object: manager,
            queue: .main
        ) { [weak self] _ in
            print("🔔 Did undo notification")
            self?.updateUndoRedoState()
        }

        let didRedo = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerDidRedoChange,
            object: manager,
            queue: .main
        ) { [weak self] _ in
            print("🔔 Did redo notification")
            self?.updateUndoRedoState()
        }

        undoObservers = [didUndo, didRedo]
        updateUndoRedoState()
    }

    private func updateUndoRedoState() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let canUndo = self.undoManager?.canUndo ?? false
            let canRedo = self.undoManager?.canRedo ?? false
            print("🔄 Updating undo/redo state:")
            print("   Can Undo: \(canUndo)")
            print("   Can Redo: \(canRedo)")
            self.canUndo = canUndo
            self.canRedo = canRedo
        }
    }

    // MARK: - Undo/Redo Actions
    func undo() {
        print("⏪ Undo called")
        print("   Has handler: \(canvasUndoHandler != nil)")
        print("   Has undo manager: \(undoManager != nil)")
        print("   Can undo: \(undoManager?.canUndo ?? false)")

        // Prefer adapter if available
        if let adapter = canvasAdapter {
            adapter.undo()
        } else if let handler = canvasUndoHandler {
            print("   Using canvas handler")
            handler()
        } else {
            print("   Using undo manager directly")
            undoManager?.undo()
        }
        updateUndoRedoState()
    }

    func redo() {
        print("⏩ Redo called")
        print("   Has handler: \(canvasRedoHandler != nil)")
        print("   Has undo manager: \(undoManager != nil)")
        print("   Can redo: \(undoManager?.canRedo ?? false)")

        // Prefer adapter if available
        if let adapter = canvasAdapter {
            adapter.redo()
        } else if let handler = canvasRedoHandler {
            print("   Using canvas handler")
            handler()
        } else {
            print("   Using undo manager directly")
            undoManager?.redo()
        }
        updateUndoRedoState()
    }

    // MARK: - Drawing Management
    func getDrawing(for page: Int) -> PKDrawing? {
        drawings[page]
    }

    func setDrawingFromCanvas(_ drawing: PKDrawing, for page: Int) {
        drawings[page] = drawing
        isModified = true
    }

    func saveDrawing(_ drawing: PKDrawing, for page: Int) {
        let oldDrawing = drawings[page]
        undoManager?.registerUndo(withTarget: self) { target in
            target.drawings[page] = oldDrawing
            target.isModified = true
        }
        drawings[page] = drawing
        isModified = true
    }

    func saveDrawingWithoutNotification(_ drawing: PKDrawing, for page: Int) {
        drawings[page] = drawing
    }

    // MARK: - Clear Operations
    func clearDrawing(for page: Int) {
        guard let drawing = drawings[page], !drawing.strokes.isEmpty else { return }

        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Clear Page")

        let oldDrawing = drawing
        undoManager?.registerUndo(withTarget: self) { target in
            target.drawings[page] = oldDrawing
            target.isModified = true
        }

        drawings[page] = PKDrawing()
        isModified = true

        undoManager?.endUndoGrouping()
    }

    func clearAllDrawings() {
        guard !drawings.isEmpty else { return }

        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Clear All Pages")

        let previousDrawings = drawings
        undoManager?.registerUndo(withTarget: self) { target in
            target.drawings = previousDrawings
            target.isModified = true
        }

        drawings = [:]
        isModified = true

        undoManager?.endUndoGrouping()
    }

    // MARK: - Import/Export
    func exportDrawingsData() -> Data? {
        do {
            let encoder = JSONEncoder()
            let drawingsData = drawings.mapValues { $0.dataRepresentation() }
            return try encoder.encode(drawingsData)
        } catch {
            print("Failed to export drawings: \(error)")
            return nil
        }
    }

    func importDrawingsData(_ data: Data) {
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Import Drawings")

        let previousDrawings = drawings
        undoManager?.registerUndo(withTarget: self) { target in
            target.drawings = previousDrawings
            target.isModified = false
        }

        do {
            let decoder = JSONDecoder()
            let drawingsData = try decoder.decode([Int: Data].self, from: data)
            drawings = drawingsData.compactMapValues { try? PKDrawing(data: $0) }
            isModified = false
        } catch {
            print("Failed to import drawings: \(error)")
        }

        undoManager?.endUndoGrouping()
    }

    func importDrawings(_ newDrawings: [Int: PKDrawing]) {
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Import Drawings")

        let previousDrawings = drawings
        undoManager?.registerUndo(withTarget: self) { target in
            target.drawings = previousDrawings
            target.isModified = false
        }

        drawings = newDrawings
        isModified = false

        undoManager?.endUndoGrouping()

        print("Imported \(newDrawings.count) drawings")
    }

    // MARK: - State Management
    func markAsModified() { isModified = true }
    func markAsModifiedAsync() { DispatchQueue.main.async { self.isModified = true } }
    func resetModifiedState() { isModified = false }

    // MARK: - Tool Management
    func selectTool(_ tool: DrawingTool) {
        currentTool = tool

        switch tool {
        case .pen:
            currentColor = .black
            currentWidth = 2.0
        case .pencil:
            currentColor = Color(.darkGray)
            currentWidth = 1.0
        case .marker:
            currentColor = .black
            currentWidth = 5.0
        case .highlighter:
            currentColor = .yellow.opacity(0.5)
            currentWidth = 15.0
        case .eraser:
            break
        }
    }

    // Brushes
    func selectBrush(_ brush: BrushConfiguration) {
        currentColor = brush.color.color
        currentWidth = brush.width

        // Call through to canvas adapter if available
        if brush.type == .eraser {
            canvasAdapter?.setEraser()
        } else {
            canvasAdapter?.setInk(ink: brush.type.inkType, color: brush.color.uiColor, width: brush.width)
        }
    }

    // MARK: - Cleanup
    deinit {
        undoObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
