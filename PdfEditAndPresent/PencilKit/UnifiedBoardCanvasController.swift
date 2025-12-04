import UIKit
import PDFKit
import PencilKit
import PaperKit

// MARK: - Unified Board Canvas Controller
@MainActor
public final class UnifiedBoardCanvasController: UIViewController, DrawingCanvasAPI {
    // MARK: - Properties

    // NEW: Implement protocol property - return self so callers can access the controller
    public var canvasController: UnifiedBoardCanvasController? { self }

    var canvasMode: CanvasMode = .idle {
        didSet {
            updateGestureRouting()
            print("Canvas mode changed to: \(canvasMode)")
        }
    }

    // Canvas size (includes PDF + margins) - logical size, not visual size
    private(set) var canvasSize: CGSize = .zero

    // Container view that holds all layers - fills the entire view controller
    private let containerView = UIView()

    // Layer 1: PaperKit (markup) - pdfHost
    private(set) var paperKitController: PaperMarkupViewController?
    private var paperKitView: UIView?

    // Layer 2: Single unified drawing canvas (expanded to 2.8x page size)
    private(set) var drawingCanvas: PKCanvasView?

    // Shared tool picker
    private var pencilKitToolPicker: PKToolPicker?

    // Layer 4: Interactive overlay for mode switching
    private let modeInterceptor = UIView()

    // Gesture recognizers
    private var tapGestureRecognizer: UITapGestureRecognizer?
    private var panGestureRecognizer: UIPanGestureRecognizer?
    private var twoFingerPanGestureRecognizer: UIPanGestureRecognizer?
    private var pinchGestureRecognizer: UIPinchGestureRecognizer?

    // Observers for form focus (TextField/TextView)
    private var interactionObservers: [NSObjectProtocol] = []

    // Lasso controller for PencilKit selection
    private var lassoController: PKLassoSelectionController?

    // Active canvas tracking (which layer receives strokes)
    private var activeDrawingLayer: DrawingRegion = .pdf

    // Coordinate transformer
    private var transformer: DrawingCoordinateTransformer?

    // Margin settings for current page
    private(set) var marginSettings: MarginSettings = MarginSettings()

    // Per-page drawing storage (normalized)
    private var pdfAnchoredDrawings: [Int: PKDrawing] = [:]
    private var marginDrawings: [Int: PKDrawing] = [:]
    private var currentPageIndex: Int = 0

    // Callbacks
    var onModeChanged: ((CanvasMode) -> Void)?
    var onPaperKitItemAdded: (() -> Void)?
    var onDrawingChanged: ((Int, PKDrawing?, PKDrawing?) -> Void)?
    var onCanvasModeChanged: ((CanvasMode) -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?

    // Alignment state
    private(set) var currentAlignment: PDFAlignment = .center

    // Previous tool for lasso restore
    var previousTool: PKTool?

    // 🔗 SHARED TOOL STATE: Reference to DrawingViewModel for accessing shared tool state
    weak var toolStateProvider: DrawingViewModel?

    // ⚠️ ERASER ONLY: Keep eraser state local (NOT shared) - used internally for lasso flow
    private var currentEraserTool: PKEraserTool?
    private var eraserBeforeLasso: PKEraserTool?

    // PDFManager reference for querying page sizes
    weak var pdfManager: PDFManager?

    private var currentZoomLevel: CGFloat = 1.0
    private var currentPageRotation: Int = 0
    private var currentZoomScale: CGFloat = 1.0
    
    private weak var externalPDFView: PDFView?

    private var canvasWidthConstraint: NSLayoutConstraint?
    private var canvasHeightConstraint: NSLayoutConstraint?
    
    private var marginDrawingTransforms: [Int: CGAffineTransform] = [:]

    private var marginDrawingsNormalized: [Int: PKDrawing] = [:]  // 0.0-1.0 space
    
    private var previousPdfFrame: [Int: CGRect] = [:]
    
    private var pageDrawings: [Int: PKDrawing] = [:]

    var useNewMarginApproach = true  // Set to false to test old approach


    // MARK: - Initialization

    public override func viewDidLoad() {
        super.viewDidLoad()
        print("UnifiedBoardCanvasController viewDidLoad")
        view.backgroundColor = .clear
        view.isOpaque = false
        setupContainerView()
        setupModeInterceptor()
        setupGestureRecognizers()
        
        // ✅ Disable PDF's native pinch zoom (small delay ensures PDF is loaded)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.disablePDFViewGestures()
        }
        
        updateCanvasInteractionState()
        print("Setup complete")
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("UnifiedBoardCanvasController viewDidAppear - actual bounds: \(view.bounds)")

        // Find the nearest PDF scroll view in both Single and Continuous modes
        if let scroll = hostScrollView(from: view.superview) ?? hostScrollView(from: view) {
            // Make scroll not steal PencilKit strokes
            scroll.delaysContentTouches = false
            scroll.canCancelContentTouches = true

            if let drawGR = drawingCanvas?.drawingGestureRecognizer {
                // Prefer PencilKit drawing over scroll panning
                scroll.panGestureRecognizer.require(toFail: drawGR)
            }

            // While in drawing mode, temporarily disable scroll panning
            onCanvasModeChanged = { [weak scroll] mode in
                let drawing = (mode == .drawing)
                scroll?.isScrollEnabled = !drawing
                print("🎯 scroll.isScrollEnabled=\(!drawing)")
            }
        }

        // Debug prints
        if let canvas = drawingCanvas {
            print("🎯 drawingCanvas frame=\(canvas.frame) bounds=\(canvas.bounds)")
            print("🎯 drawingCanvas isUserInteractionEnabled=\(canvas.isUserInteractionEnabled)")
        }
        print("🎯 containerView frame=\(containerView.frame) bounds=\(containerView.bounds)")
        debugCanvasLayout(label: "viewDidAppear")
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        print("📍 [LAYOUT] viewDidLayoutSubviews() called")
        print("📍 [LAYOUT]   containerView.bounds: \(containerView.bounds)")

        // At this point containerView has a real size - reapply transforms
        applyTransforms()

        // Debug prints for canvas frames AFTER layout
        if let canvas = drawingCanvas {
            print("📍 [LAYOUT]   drawingCanvas ACTUAL frame: \(canvas.frame)")
            print("📍 [LAYOUT]   drawingCanvas ACTUAL bounds: \(canvas.bounds)")
            print("📍 [LAYOUT]   drawingCanvas transform: \(canvas.transform)")
        }
        print("📍 [LAYOUT]   containerView ACTUAL frame: \(containerView.frame)")
        print("📍 [LAYOUT]   view.bounds: \(view.bounds)")
    }

    deinit {
        for o in interactionObservers { NotificationCenter.default.removeObserver(o) }
    }

    public func setPDFView(_ pdfView: PDFView) {
        self.externalPDFView = pdfView
        print("✅ [PDF-SYNC] PDFView reference stored in canvas controller")
    }
    
    private func savePageDrawings() {
        if useNewMarginApproach {
            saveCurrentPageDrawingsNew()
        } else {
            saveCurrentPageDrawings()
        }
    }

    private func loadPageDrawings(for pageIndex: Int) {
        if useNewMarginApproach {
            loadPageDrawingsNew(for: pageIndex)
        } else {
            loadPageDrawingsOld(for: pageIndex)
        }
    }
    
    // MARK: - Private Setup

    private func setupContainerView() {
        containerView.clipsToBounds = false
        containerView.backgroundColor = .clear
        containerView.isOpaque = false

        // Fill entire view controller view using Auto Layout
        view.addSubview(containerView)
        containerView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        print("Container view set up with Auto Layout")
    }
    private func disablePDFViewGestures() {
        // Recursively find all PDFView instances and disable their pinch gestures
        func disableGesturesInView(_ view: UIView) {
            // If this view is a PDFView, disable its pinch gestures
            if NSStringFromClass(type(of: view)).contains("PDFView") {
                view.gestureRecognizers?.forEach { recognizer in
                    if recognizer is UIPinchGestureRecognizer {
                        recognizer.isEnabled = false
                        print("🔍 [FIX] Disabled PDFView pinch gesture")
                    }
                }
            }
            
            // Recursively check subviews
            for subview in view.subviews {
                disableGesturesInView(subview)
            }
        }
        
        // Start from the current view and search downward
        disableGesturesInView(self.view)
    }
    // MARK: - Canvas Setup Helpers

    private func pinCanvas(_ canvas: PKCanvasView, to host: UIView) {
        print("📐 [CONSTRAINT] pinCanvas() called for drawingCanvas")
        print("📐 [CONSTRAINT]   Setting width constraint: \(canvasSize.width)")
        print("📐 [CONSTRAINT]   Setting height constraint: \(canvasSize.height)")

        canvas.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(canvas)

        let widthConstraint = canvas.widthAnchor.constraint(equalToConstant: canvasSize.width)
        let heightConstraint = canvas.heightAnchor.constraint(equalToConstant: canvasSize.height)

        // ✅ SET IDENTIFIERS SO WE CAN FIND THEM LATER
        widthConstraint.identifier = "drawingCanvas_width"
        heightConstraint.identifier = "drawingCanvas_height"

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: host.topAnchor),
            widthConstraint,
            heightConstraint
        ])

        // Setup
        canvas.backgroundColor = UIColor.blue.withAlphaComponent(0.2)
        canvas.isOpaque = false
        canvas.isUserInteractionEnabled = false
        canvas.drawingPolicy = .anyInput
        canvas.maximumZoomScale = 1.0
        canvas.minimumZoomScale = 1.0
        canvas.isScrollEnabled = false

        // Clipping
        canvas.clipsToBounds = true
        canvas.layer.masksToBounds = true

        print("📐 [CONSTRAINT]   Constraints activated for drawingCanvas")
    }

    private func hostScrollView(from view: UIView?) -> UIScrollView? {
        var v = view
        while let cur = v {
            if let sv = cur as? UIScrollView { return sv }
            v = cur.superview
        }
        return nil
    }

    private func updateCanvasInteractionState() {
        verifyToolOnCanvas("BEFORE updateCanvasInteractionState")
        let shouldInteract = (canvasMode == .drawing)

        drawingCanvas?.isUserInteractionEnabled = shouldInteract

        print("🎯 Canvas interaction: \(shouldInteract ? "ENABLED" : "DISABLED") (mode=\(canvasMode))")

        if shouldInteract {
            print("🎯 Canvas debug info:")
            print("   bounds: \(drawingCanvas?.bounds ?? .zero)")
            print("   frame: \(drawingCanvas?.frame ?? .zero)")
            print("   isHidden: \(drawingCanvas?.isHidden ?? true)")
            print("   isUserInteractionEnabled: \(drawingCanvas?.isUserInteractionEnabled ?? false)")

            // Ensure canvas is on top of other views
            if let canvas = drawingCanvas, let superview = canvas.superview {
                superview.bringSubviewToFront(canvas)
            }
        }
        verifyToolOnCanvas("AFTER updateCanvasInteractionState")
    }

    /// Enable or disable drawing on PKCanvasViews
    func enableDrawing(_ enabled: Bool) {
        drawingCanvas?.isUserInteractionEnabled = enabled
    }

    // MARK: - Tool Verification (temporary diagnostic)

    private func verifyToolOnCanvas(_ label: String) {
        print("🔍 [VERIFY] \(label)")

        if let canvas = drawingCanvas {
            print("   drawingCanvas exists: ✅ YES")

            if let tool = canvas.tool as? PKInkingTool {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                tool.color.getRed(&r, green: &g, blue: &b, alpha: nil)
                print("   Tool type: PKInkingTool (\(tool.inkType.rawValue))")
                print("   Tool color: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255))")
                print("   Tool width: \(tool.width)")
            } else if canvas.tool is PKEraserTool {
                print("   Tool type: PKEraserTool")
            } else {
                print("   Tool type: Unknown")
            }
        } else {
            print("   drawingCanvas exists: ❌ NIL")
        }
    }

    /// Format a tool into a human-readable description for logging
    private func toolDescription(_ tool: PKTool) -> String {
        if let inkTool = tool as? PKInkingTool {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            inkTool.color.getRed(&r, green: &g, blue: &b, alpha: nil)
            return "\(inkTool.inkType.rawValue) RGB(\(Int(r*255)),\(Int(g*255)),\(Int(b*255)))"
        } else if tool is PKEraserTool {
            return "eraser"
        }
        return "unknown"
    }

    // MARK: - Touch Debugging

    // Debug touch routing
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("🖱️ [TOUCH-BEGIN] Tool at touch start: \(toolDescription(drawingCanvas?.tool))")
        print("🔴 [TOUCH] touchesBegan - \(touches.count) touches")
        if let touch = touches.first {
            let location = touch.location(in: view)
            print("   Location in view: \(location)")
        }

        // DEBUG: Check canvas tool at touch time
        print("   drawingCanvas.tool: \(toolDescription(drawingCanvas?.tool))")

        super.touchesBegan(touches, with: event)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("🔴 [CONTROLLER] touchesMoved - \(touches.count) touches")
        super.touchesMoved(touches, with: event)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("🔴 [CONTROLLER] touchesEnded - \(touches.count) touches")
        super.touchesEnded(touches, with: event)
    }

    // MARK: - Public API

    /// Initialize canvas with size (PDF + margins)
    func initializeCanvas(size: CGSize) {
        print("🎛️ [LIFECYCLE] initializeCanvas called with size: \(size.width) x \(size.height)")
        print("🎛️ [LIFECYCLE]   Previous canvasSize was: \(canvasSize.width) x \(canvasSize.height)")
        canvasSize = size
        rebuildTransformer()
        print("🎛️ [LIFECYCLE]   canvasSize now set to: \(canvasSize.width) x \(canvasSize.height)")
    }

    /// Setup PaperKit layer (pdfHost)
    func setupPaperKit(markup: PaperMarkup) {
        // Clean up old controller
        if let existingController = paperKitController {
            existingController.willMove(toParent: nil)
            existingController.view.removeFromSuperview()
            existingController.removeFromParent()
        }

        let controller = PaperMarkupViewController(supportedFeatureSet: .latest)
        controller.markup = markup
        controller.zoomRange = 0.8...1.5

        addChild(controller)
        containerView.addSubview(controller.view)
        controller.didMove(toParent: self)

        // Fill entire container via Auto Layout
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        // Make PaperKit's view transparent
        controller.view.isOpaque = false
        controller.view.backgroundColor = .clear
        controller.view.layer.isOpaque = false
        controller.view.layer.backgroundColor = UIColor.clear.cgColor

        // Set contentView to suppress PaperKit's default white background
        let clearUnderlay = UIView()
        clearUnderlay.isOpaque = false
        clearUnderlay.backgroundColor = .clear
        controller.contentView = clearUnderlay

        makeViewTreeTransparentDeep(controller.view)

        paperKitController = controller
        paperKitView = controller.view

        containerView.sendSubviewToBack(controller.view)
        setupPaperKitDropInteraction(on: controller.view)
        installPaperKitInteractionObservers()

        print("PaperKit setup complete")
    }

    /// Setup single unified PencilKit canvas (expanded to 2.8x page size)
    func setupPencilKit() {
        print("📋 [SETUP-PENCILKIT] CALLED - will recreate canvas!")
        print("   Current drawingCanvas: \(drawingCanvas != nil ? "✅ EXISTS" : "❌ NIL")")
        print("   Current tool before setup: \(drawingCanvas?.tool != nil ? "✅ SET" : "❌ NIL")")
        if let tool = drawingCanvas?.tool {
            print("   Tool before setup: \(toolDescription(tool))")
        }

        print("🎛️ [LIFECYCLE] setupPencilKit() called")
        print("🎛️ [LIFECYCLE]   Current canvasSize (EXPANDED): \(canvasSize.width) x \(canvasSize.height)")
        print("🎛️ [LIFECYCLE]   Current pageRotation: \(currentPageRotation)°")

        // ⚠️ CRITICAL: Preserve tool state BEFORE destroying canvas
        // First try to get from SHARED state (DrawingViewModel), then fall back to eraser
        let toolToRestore: PKTool?
        if let sharedInkingTool = toolStateProvider?.sharedCurrentInkingTool {
            print("💾 [PRESERVE] 🔗 Using sharedCurrentInkingTool from DrawingViewModel")
            toolToRestore = sharedInkingTool
        } else if let eraser = currentEraserTool {
            print("💾 [PRESERVE] Saving currentEraserTool before canvas destruction")
            toolToRestore = eraser
        } else {
            print("ℹ️ [PRESERVE] No tool to preserve, will use default black pen")
            toolToRestore = nil
        }

        // Clean up old canvas
        drawingCanvas?.removeFromSuperview()

        // Create single unified canvas (Layer 2) - sized to expanded canvas
        let canvas = PKCanvasView()
        drawingCanvas = canvas
        print("🎛️ [LIFECYCLE]   About to call pinCanvas() for drawingCanvas")
        pinCanvas(canvas, to: containerView)
        canvas.delegate = self

        // Shared tool picker
        let toolPicker = PKToolPicker()
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)

        pencilKitToolPicker = toolPicker

        // Enable multi-touch
        canvas.isMultipleTouchEnabled = true

        // Initialize lasso controller with the canvas
        lassoController = PKLassoSelectionController(canvasView: canvas)

        // Reconfigure canvas constraints to match current expanded canvas size
        reconfigureCanvasConstraints(zoomLevel: 1.0)  // ✅ Always base size, let SwiftUI scaleEffect handle zoom

        // Set initial tool (default black)
        let defaultTool = PKInkingTool(.pen, color: .black, width: 2)
        canvas.tool = defaultTool
        previousTool = defaultTool

        // ✅ CRITICAL: Restore the tool that was saved BEFORE canvas destruction
        // This ensures tool selection persists across page navigation
        if let savedTool = toolToRestore {
            print("✨ [RESTORE] Restoring saved tool to newly created canvas")
            if let inked = savedTool as? PKInkingTool {
                print("   Restoring inking tool: \(toolDescription(inked))")
                print("   ✅ Restored from SHARED state (DrawingViewModel)")
                canvas.tool = inked
                previousTool = inked
            } else if let eraser = savedTool as? PKEraserTool {
                print("   Restoring eraser tool")
                canvas.tool = eraser
                currentEraserTool = eraser
                previousTool = eraser
            }
        } else if let storedEraserTool = currentEraserTool {
            // Fallback: use eraser if available
            print("✨ [RESTORE] Fallback: Restoring currentEraserTool")
            canvas.tool = storedEraserTool
            previousTool = storedEraserTool
        }

        // Bring container on top of PDF, then canvas above anything inside
        view.bringSubviewToFront(containerView)
        containerView.bringSubviewToFront(canvas)
        containerView.bringSubviewToFront(modeInterceptor)

        // Apply initial transforms
        applyTransforms()

        print("📋 [SETUP-PENCILKIT] COMPLETE - new expanded canvas created")
        print("   New drawingCanvas: \(drawingCanvas != nil ? "✅ EXISTS" : "❌ NIL")")
        if let tool = drawingCanvas?.tool {
            print("   New drawingCanvas.tool: \(toolDescription(tool))")
        }
        print("Unified PencilKit canvas setup complete")
    }
    
    func setCanvasMode(_ mode: CanvasMode) {
        print("📍 [MODE-CHANGE] setCanvasMode(\(mode))")
        print("   sharedCurrentInkingTool: \(toolStateProvider?.sharedCurrentInkingTool != nil ? "✅ SET" : "❌ NIL")")

        verifyToolOnCanvas("BEFORE setCanvasMode(\(mode))")
        
        // ⚠️ CRITICAL: Defer all state updates outside the current view update cycle
        // This prevents "Publishing changes from within view updates" warnings and AttributeGraph cycles
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.canvasMode = mode
            self.updateCanvasInteractionState()
            self.onModeChanged?(mode)
            self.onCanvasModeChanged?(mode)

            if mode == .selecting {
                print("   Entering SELECTING mode - starting lasso")
                print("   💾 Saving tool before lasso...")

                if let inked = self.toolStateProvider?.sharedCurrentInkingTool {
                    self.toolStateProvider?.sharedToolBeforeLasso = inked
                    print("      ✅ Saved inking tool to SHARED state: \(self.toolDescription(inked))")
                } else if let eraser = self.currentEraserTool {
                    self.eraserBeforeLasso = eraser
                    print("      ✅ Saved eraser tool (local)")
                }

                self.lassoController?.beginLasso()
            } else {
                print("   Exiting SELECTING mode - ending lasso")
                self.lassoController?.endLassoAndRestorePreviousTool()

                if let savedInkingTool = self.toolStateProvider?.sharedToolBeforeLasso {
                    print("   ✅ Restoring saved inking tool from SHARED state before lasso")
                    print("      Restored: \(self.toolDescription(savedInkingTool))")
                    self.drawingCanvas?.tool = savedInkingTool
                    self.currentEraserTool = nil
                    self.previousTool = savedInkingTool
                } else if let savedEraserTool = self.eraserBeforeLasso {
                    print("   ✅ Restoring saved eraser tool from before lasso (local)")
                    self.drawingCanvas?.tool = savedEraserTool
                    self.currentEraserTool = savedEraserTool
                    self.previousTool = savedEraserTool
                } else if let sharedTool = self.toolStateProvider?.sharedCurrentInkingTool {
                    // ✅ NEW: Fall back to the current shared tool (what user actually has selected)
                    print("   ✅ Restoring from SHARED state (fallback): \(self.toolDescription(sharedTool))")
                    self.drawingCanvas?.tool = sharedTool
                    self.currentEraserTool = nil
                    self.previousTool = sharedTool
                } else {
                    print("   ⚠️ No tool found anywhere, using black pen default")
                    let defaultTool = PKInkingTool(.pen, color: .black, width: 2)
                    self.drawingCanvas?.tool = defaultTool
                    self.previousTool = defaultTool
                }

                self.toolStateProvider?.sharedToolBeforeLasso = nil
                self.eraserBeforeLasso = nil
            }

            self.verifyToolOnCanvas("AFTER setCanvasMode(\(mode))")
        }
    }

    /// Auto-switch to select mode (called after PaperKit item added)
    func autoSwitchToSelectMode() {
        setCanvasMode(.selecting)
        onPaperKitItemAdded?()
    }

    /// Set PDF alignment (left, center, right)
    func setAlignment(_ alignment: PDFAlignment) {
        currentAlignment = alignment
        applyAlignmentTransform()
    }

    /// Update margin settings and reapply transforms

   
    func updateMarginSettings(_ newSettings: MarginSettings) {
        print("📐 [MARGIN-CHANGE] Changing margin settings")
        print("   Old: enabled=\(marginSettings.isEnabled), anchor=\(marginSettings.anchorPosition), scale=\(marginSettings.pdfScale)")
        print("   New: enabled=\(newSettings.isEnabled), anchor=\(newSettings.anchorPosition), scale=\(newSettings.pdfScale)")
        
        guard let canvas = drawingCanvas,
              let transformer = transformer else {
            print("📐 [MARGIN-CHANGE] No canvas or transformer, bailing")
            return
        }
        
        // ===== STEP 1: Classify current strokes =====
        // Identify which strokes are on the PDF vs in margins
        print("📐 [MARGIN-CHANGE] STEP 1: Classifying strokes")
        
        let currentDrawing = canvas.drawing
        let currentPDFFrame = computePDFFrameInCanvasSimple()
        
        var pdfStrokes: [PKStroke] = []
        var marginStrokes: [PKStroke] = []
        
        for stroke in currentDrawing.strokes {
            if currentPDFFrame.intersects(stroke.renderBounds) {
                pdfStrokes.append(stroke)
                print("   Stroke \(stroke.renderBounds) → PDF")
            } else {
                marginStrokes.append(stroke)
                print("   Stroke \(stroke.renderBounds) → MARGIN")
            }
        }
        
        // ===== STEP 2: Normalize PDF strokes to PDF-relative coordinates =====
        // This converts them from canvas-space to PDF-space (0.0-1.0)
        // That way they'll stay on the PDF no matter where it moves
        print("📐 [MARGIN-CHANGE] STEP 2: Normalizing PDF strokes")
        
        let pdfDrawing = PKDrawing(strokes: pdfStrokes)
        let normalizedPDFDrawing = transformer.normalizeDrawingFromCanvasToPDF(pdfDrawing)
        
        print("   Normalized \(pdfStrokes.count) PDF strokes")
        
        // ===== STEP 3: Store both normalized PDF strokes and margin strokes =====
        print("📐 [MARGIN-CHANGE] STEP 3: Storing strokes")
        
        // Store for the current page
        pdfAnchoredDrawings[currentPageIndex] = normalizedPDFDrawing
        marginDrawings[currentPageIndex] = PKDrawing(strokes: marginStrokes)
        
        print("   Stored \(normalizedPDFDrawing.strokes.count) normalized PDF strokes")
        print("   Stored \(marginStrokes.count) margin strokes")
        
        // ===== STEP 4: Update margin settings =====
        print("📐 [MARGIN-CHANGE] STEP 4: Updating settings")
        marginSettings = newSettings
        
        // ===== STEP 5: Rebuild transformer with new settings =====
        print("📐 [MARGIN-CHANGE] STEP 5: Rebuilding transformer")
        rebuildTransformer()
        
        // ===== STEP 6: Update canvas positioning =====
        print("📐 [MARGIN-CHANGE] STEP 6: Updating positioning")
        updateCanvasPositionNew()
        
        // ===== STEP 7: Denormalize and reload =====
        // Now denormalize the PDF strokes with the NEW PDF position/scale
        // This positions them correctly relative to the PDF in its new location
        print("📐 [MARGIN-CHANGE] STEP 7: Denormalizing and reloading")
        
        // ✅ FIX: Access self.transformer directly (it was rebuilt in step 5)
        if let newTransformer = self.transformer {
            // Denormalize PDF strokes from PDF-space to new canvas-space
            let denormalizedPDFDrawing = newTransformer.denormalizeDrawingFromPDFToCanvas(normalizedPDFDrawing)
            
            // Combine with margin strokes
            let combined = PKDrawing(strokes: denormalizedPDFDrawing.strokes + marginStrokes)
            canvas.drawing = combined
            
            print("   Denormalized to canvas space: \(denormalizedPDFDrawing.strokes.count) + \(marginStrokes.count) strokes")
        } else {
            print("   ERROR: transformer is nil after rebuild!")
        }
        
        print("📐 [MARGIN-CHANGE] COMPLETE")
    }
    
    func updateMarginSettingsTest(_ settings: MarginSettings) {
        saveCurrentPageDrawingsNew()  // Save using new method
        marginSettings = settings
        
        let newFrame = computePDFFrameInCanvasSimple()
        print("📐 [NEW] PDF Frame: \(newFrame)")
        
        loadPageDrawingsNew(for: currentPageIndex)  // Load using new method
        
        // NEW: Update visual transform instead of trying to transform strokes
        updateCanvasPositionNew()
    }

    private func updateCanvasPositionNew() {
        let frame = computePDFFrameInCanvasSimple()
        var scale = marginSettings.pdfScale
        
        print("📐 [POSITION-NEW-A] Frame: \(frame), Scale: \(scale), Enabled: \(marginSettings.isEnabled)")
        
        if marginSettings.isEnabled {
            // ===== MARGINS ENABLED =====
            
            // Clamp scale to minimum
            let minScale = 0.15
            if scale < minScale {
                print("⚠️  [SCALE-CLAMP] Scale \(scale) below minimum \(minScale), clamping to \(minScale)")
                scale = minScale
            }
            
            // Canvas and viewport dimensions
            let viewportWidth: CGFloat = view.bounds.width   // 612
            let viewportHeight: CGFloat = view.bounds.height  // 792
            let canvasWidth: CGFloat = 1713.6
            let canvasHeight: CGFloat = 2217.6
            
            // ===== KEY FIX: Calculate visible canvas region based on anchor position =====
            // The viewport shows a 612×792 window into the 1713.6×2217.6 canvas
            // Which part of the canvas is visible depends on the anchor
            
            let visibleCanvasLeft: CGFloat
            let visibleCanvasTop: CGFloat
            
            switch marginSettings.anchorPosition {
            case .topLeft:
                // Top-left: show canvas from 0→612
                visibleCanvasLeft = 0
                visibleCanvasTop = 0
                
            case .topRight:
                // Top-right: show canvas from right edge going left
                visibleCanvasLeft = canvasWidth - viewportWidth  // 1713.6 - 612 = 1101.6
                visibleCanvasTop = 0
                
            case .topCenter:
                // Top-center: show horizontally centered portion
                visibleCanvasLeft = (canvasWidth - viewportWidth) / 2  // 550.8
                visibleCanvasTop = 0
                
            case .center:
                // Full center: both horizontally and vertically centered
                visibleCanvasLeft = (canvasWidth - viewportWidth) / 2   // 550.8
                visibleCanvasTop = (canvasHeight - viewportHeight) / 2  // 712.8
                
            case .centerLeft:
                // Center vertically, left horizontally
                visibleCanvasLeft = 0
                visibleCanvasTop = (canvasHeight - viewportHeight) / 2  // 712.8
                
            case .centerRight:
                // Center vertically, right horizontally
                visibleCanvasLeft = canvasWidth - viewportWidth  // 1101.6
                visibleCanvasTop = (canvasHeight - viewportHeight) / 2  // 712.8
                
            case .bottomLeft:
                // Bottom-left: show bottom portion
                visibleCanvasLeft = 0
                visibleCanvasTop = canvasHeight - viewportHeight  // 1425.6
                
            case .bottomRight:
                // Bottom-right
                visibleCanvasLeft = canvasWidth - viewportWidth  // 1101.6
                visibleCanvasTop = canvasHeight - viewportHeight  // 1425.6
                
            case .bottomCenter:
                // Bottom-center
                visibleCanvasLeft = (canvasWidth - viewportWidth) / 2  // 550.8
                visibleCanvasTop = canvasHeight - viewportHeight  // 1425.6
            }
            
            // ===== COORDINATE SPACE CONVERSION =====
            // frame.origin is in CANVAS space
            // containerView.layer.position expects VIEWPORT space
            // To show canvas region starting at (visibleCanvasLeft, visibleCanvasTop) at viewport (0, 0),
            // position the container at (0 - visibleCanvasLeft, 0 - visibleCanvasTop)
            
            let containerPosition = CGPoint(
                x: 0 - visibleCanvasLeft,
                y: 0 - visibleCanvasTop
            )
            
            containerView.translatesAutoresizingMaskIntoConstraints = true
            containerView.layer.anchorPoint = CGPoint(x: 0, y: 0)
            containerView.layer.position = containerPosition
            containerView.transform = CGAffineTransform.identity
            
            // Keep drawing canvas at full size
            if let canvas = drawingCanvas {
                canvas.transform = CGAffineTransform.identity
            }
            
            print("📐 [POSITION-NEW-B] MARGINS ENABLED:")
            print("   Anchor: \(marginSettings.anchorPosition)")
            print("   Visible canvas: (\(visibleCanvasLeft), \(visibleCanvasTop)) to (\(visibleCanvasLeft + viewportWidth), \(visibleCanvasTop + viewportHeight))")
            print("   containerView position (viewport space): \(containerPosition)")
            print("   Canvas PDF location: \(frame)")
            
        } else {
            // ===== MARGINS DISABLED: Center via Auto Layout =====
            containerView.translatesAutoresizingMaskIntoConstraints = false
            containerView.transform = CGAffineTransform.identity
            if let canvas = drawingCanvas {
                canvas.transform = CGAffineTransform.identity
            }
            
            print("📐 [POSITION-NEW-B] MARGINS DISABLED: Using Auto Layout for centering")
        }
    }


    private func transformMarginStrokes(from oldFrame: CGRect, to newFrame: CGRect) {
        guard let transformer = transformer else {
            print("   transformer is NIL!")
            return
        }
        
        print("🔍 [HELPER-SETTINGS] isEnabled: \(transformer.marginHelper.settings.isEnabled)")
        print("🔍 [ACTUAL-FRAME] transformer.pdfFrameInCanvas: \(transformer.pdfFrameInCanvas)")
        
        print("[DEBUG-TRANSFORM] Entry point:")
        print("   Parameter oldFrame: \(oldFrame)")
        print("   Parameter newFrame: \(newFrame)")
        print("   transformer.pdfFrameInCanvas: \(transformer.pdfFrameInCanvas)")
        print("   self.marginSettings: \(marginSettings)")
        
        guard oldFrame != .zero && newFrame != .zero else { return }
        
        let marginDrawing = marginDrawings[currentPageIndex] ?? PKDrawing()
        
        print("🔄 [MARGIN-TRANSFORM] Transforming margin strokes")
        print("   Old frame: \(oldFrame)")
        print("   New frame: \(newFrame)")
        
        let scaleX = newFrame.width / oldFrame.width
        let scaleY = newFrame.height / oldFrame.height
        let translateX = newFrame.minX - oldFrame.minX * scaleX
        let translateY = newFrame.minY - oldFrame.minY * scaleY
        
        let transform = CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY,
                                          tx: translateX, ty: translateY)
        
        print("   Scale: (\(scaleX), \(scaleY)), Translate: (\(translateX), \(translateY))")
        
        let transformedDrawing = marginDrawing.transformed(using: transform)
        marginDrawings[currentPageIndex] = transformedDrawing
        
        print("   ✅ Applied transform to \(transformedDrawing.strokes.count) margin strokes")
    }

    private func transformStroke(_ stroke: PKStroke, scaleX: CGFloat, scaleY: CGFloat,
                                 translateX: CGFloat, translateY: CGFloat) -> PKStroke? {
        // Create a copy with transformed points
        let transform = CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY,
                                          tx: translateX, ty: translateY)
        
        // PKStroke doesn't provide direct point access, so we need to use the drawing approach
        // Get the stroke's bounds and apply transform
        let oldBounds = stroke.renderBounds
        let newBounds = oldBounds.applying(transform)
        
        // Unfortunately PKStroke is immutable and we can't directly transform it
        // We need to work with the points through PKDrawing
        // This is a limitation - we may need to store stroke data differently
        
        // For now, recreate the stroke (this is a workaround)
        var newStroke = stroke
        // Note: This won't actually transform the stroke since PKStroke is immutable
        // See below for a better solution
        return newStroke
    }
 

 
    
    
    /// Set current page index and load drawings
    func setCurrentPage(_ pageIndex: Int) {
        print("🎛️ [LIFECYCLE] setCurrentPage() called with pageIndex: \(pageIndex)")
        print("🎛️ [LIFECYCLE]   Previous currentPageIndex: \(currentPageIndex)")
        print("🎛️ [LIFECYCLE]   Current canvasSize: \(canvasSize.width) x \(canvasSize.height)")

        // Save current page drawings before switching
        saveCurrentPageDrawings()

        currentPageIndex = pageIndex

        // Get the EXPANDED canvas size from PDFManager for this specific page
        if let pdfManager = pdfManager {
            let expandedSize = pdfManager.expandedCanvasSize(for: pageIndex)
            print("🎛️ [LIFECYCLE]   PDFManager returned EXPANDED size for page \(pageIndex + 1): \(expandedSize.width) x \(expandedSize.height)")
            canvasSize = expandedSize
        } else {
            print("🎛️ [LIFECYCLE]   WARNING: pdfManager is nil, keeping canvasSize: \(canvasSize)")
        }

        loadPageDrawings(for: pageIndex)
        rebuildTransformer()

        // ✅ CRITICAL: Update constraints when page size changes!
        reconfigureCanvasConstraints(zoomLevel: 1.0)

        print("🎛️ [LIFECYCLE]   About to call applyTransforms()")
        applyTransforms()
        print("🎛️ [LIFECYCLE]   setCurrentPage() complete")
    }

    /// Get PDF-anchored drawing for a page (normalized)
    func getPdfAnchoredDrawing(for pageIndex: Int) -> PKDrawing {
        return pdfAnchoredDrawings[pageIndex] ?? PKDrawing()
    }

    /// Get margin drawing for a page (canvas space)
    func getMarginDrawing(for pageIndex: Int) -> PKDrawing {
        return marginDrawings[pageIndex] ?? PKDrawing()
    }

    /// Set PDF-anchored drawing for a page (normalized)
    func setPdfAnchoredDrawing(_ drawing: PKDrawing, for pageIndex: Int) {
        pdfAnchoredDrawings[pageIndex] = drawing
        if pageIndex == currentPageIndex {
            loadPdfDrawingToCanvas()
        }
    }

    /// Set margin drawing for a page (canvas space)
    func setMarginDrawing(_ drawing: PKDrawing, for pageIndex: Int) {
        marginDrawings[pageIndex] = drawing
        if pageIndex == currentPageIndex {
            drawingCanvas?.drawing = drawing
        }
    }

    /// Migrate legacy single-drawing to dual-layer format
    func migrateLegacyDrawing(_ drawing: PKDrawing, for pageIndex: Int) {
        // Assume legacy drawing was PDF-anchored
        pdfAnchoredDrawings[pageIndex] = drawing
        marginDrawings[pageIndex] = PKDrawing()
        if pageIndex == currentPageIndex {
            loadPageDrawings(for: pageIndex)
        }
    }
    
    func updateCanvasForZoom(_ zoomLevel: CGFloat) {
        // Note: Constraints stay at BASE size (1.0)
        // SwiftUI scaleEffect is the ONLY zoom source
        // (Verbose logging removed - no action needed here)
    }


















































































































    // MARK: - Transform Management

    private func rebuildTransformer() {
        print("🔧 [REBUILD-TRANSFORMER] Starting rebuild from:")
        if Thread.callStackSymbols.count > 1 {
            print("   Caller: \(Thread.callStackSymbols[1])")
        }
        print("   marginSettings.pdfScale: \(marginSettings.pdfScale)")
        print("   marginSettings.isEnabled: \(marginSettings.isEnabled)")
        // canvasSize is now the EXPANDED size (2.8x the original page size)
        // We need to get the original PDF page size for MarginCanvasHelper
        let originalPDFSize: CGSize
        if let pdfManager = pdfManager {
            originalPDFSize = pdfManager.effectiveSize(for: currentPageIndex)
        } else {
            // Fallback: calculate from expanded size
            originalPDFSize = CGSize(width: canvasSize.width / 2.8, height: canvasSize.height / 2.8)
        }


        let helper = MarginCanvasHelper(
            settings: marginSettings,
            originalPDFSize: originalPDFSize,
            canvasSize: canvasSize  // This is the expanded size
        )
        
        print("   helper.pdfFrameInCanvas AFTER init: \(helper.pdfFrameInCanvas)")
        
        transformer = DrawingCoordinateTransformer(
            marginHelper: helper,
            canvasViewBounds: view.bounds,
            zoomScale: 1.0,
            contentOffset: .zero
        )
        
        if let transformer = transformer {
            print("   transformer.pdfFrameInCanvas AFTER creation: \(transformer.pdfFrameInCanvas)")
        }
        print("🔧 [REBUILD-TRANSFORMER] Complete")
    }

    private func applyTransforms() {
        guard let transformer = transformer else {
            print("🔄 [TRANSFORM] applyTransforms() called but transformer is nil")
            return
        }

        print("🔄 [TRANSFORM] applyTransforms() called")
        print("🔄 [TRANSFORM]   canvasSize: \(canvasSize.width) x \(canvasSize.height)")
        print("🔄 [TRANSFORM]   currentPageRotation: \(currentPageRotation)°")
        print("🔄 [TRANSFORM]   containerView.bounds: \(containerView.bounds)")

        // Apply display transform to pdfHost (PaperKit) only
        let displayTransform = transformer.displayTransform
        paperKitView?.transform = displayTransform

        // Apply rotation transform to canvas views
        let rotationRadians = CGFloat(currentPageRotation) * .pi / 180.0

        print("🔄 [TRANSFORM]   rotationRadians: \(rotationRadians)")

        // Determine container size based on rotation
        let isRotated90or270 = (currentPageRotation == 90 || currentPageRotation == 270)
        let containerWidth = isRotated90or270 ? canvasSize.height : canvasSize.width
        let containerHeight = isRotated90or270 ? canvasSize.width : canvasSize.height

        print("🔄 [TRANSFORM]   isRotated90or270: \(isRotated90or270)")
        print("🔄 [TRANSFORM]   containerSize: \(containerWidth) x \(containerHeight)")

        // Update container bounds to match rotated page dimensions
        containerView.bounds = CGRect(x: 0, y: 0, width: containerWidth, height: containerHeight)

        // Use bounds and center instead of frame - these are stable with transforms
        // Set canvas bounds to the original canvas size (before visual rotation)
        let canvasBounds = CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
        drawingCanvas?.bounds = canvasBounds
        // marginDrawingCanvas removed - using single unified canvas

        // Calculate the center position that will place the rotated canvas at origin
        // After rotation, the visual frame has dimensions (containerWidth x containerHeight)
        // We want the visual frame to start at (0, 0), so center should be at (containerWidth/2, containerHeight/2)
        let centerX = containerWidth / 2
        let centerY = containerHeight / 2
        drawingCanvas?.center = CGPoint(x: centerX, y: centerY)
        // marginDrawingCanvas removed - using single unified canvas(x: centerX, y: centerY)

        // Now apply the rotation transform - this rotates around the center we just set
        drawingCanvas?.transform = CGAffineTransform(rotationAngle: rotationRadians)
        // marginDrawingCanvas removed - using single unified canvas

        print("🔄 [TRANSFORM]   Applied rotation transform to both canvases")
        print("🔄 [TRANSFORM]   Canvas bounds: \(canvasBounds)")
        print("🔄 [TRANSFORM]   Canvas center: (\(centerX), \(centerY))")

        // Update margin canvas visibility based on margins enabled
        // Margin canvas visibility: now handled in single canvas

        print("🔄 [TRANSFORM]   Final containerView.bounds: \(containerView.bounds)")
        print("🔄 [TRANSFORM]   pdfDrawingCanvas.frame: \(drawingCanvas?.frame ?? .zero)")
    }

    private func reconfigureCanvasConstraints(zoomLevel: CGFloat = 1.0) {
        guard let canvas = drawingCanvas else { return }

        // Calculate base size (no zoom multiplication - that's SwiftUI's job)
        let baseSize = canvasSize

        print("🎯 [RECONFIG] Canvas constraints reconfigured")
        print("🎯 [RECONFIG]   Base size (EXPANDED): \(baseSize)")
        print("🎯 [RECONFIG]   Zoom level: \(String(format: "%.4f", zoomLevel))")

        // Deactivate old constraints
        [canvasWidthConstraint, canvasHeightConstraint].forEach { $0?.isActive = false }

        // Remove from superview
        canvas.removeFromSuperview()

        // Re-add canvas
        canvas.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(canvas)

        let width = canvas.widthAnchor.constraint(equalToConstant: baseSize.width)
        let height = canvas.heightAnchor.constraint(equalToConstant: baseSize.height)

        canvasWidthConstraint = width
        canvasHeightConstraint = height

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: containerView.topAnchor),
            width,
            height
        ])

        canvas.backgroundColor = UIColor.blue.withAlphaComponent(0.2)
        canvas.isOpaque = false
        canvas.isUserInteractionEnabled = false
        canvas.drawingPolicy = .anyInput
        canvas.maximumZoomScale = 1.0
        canvas.minimumZoomScale = 1.0
        canvas.isScrollEnabled = false
        canvas.clipsToBounds = true

        containerView.setNeedsLayout()
        containerView.layoutIfNeeded()

        print("🎯 [RECONFIG]   Constraints created at EXPANDED SIZE ✅")
    }
    // MARK: - Drawing Persistence

    private func saveCurrentPageDrawings() {
        guard let canvas = drawingCanvas,
              let transformer = transformer else { return }

        let currentCanvasDrawing = canvas.drawing
        let pdfFrame = transformer.pdfFrameInCanvas

        // Get the previously saved drawings
        let previousPdfDrawing = pdfAnchoredDrawings[currentPageIndex] ?? PKDrawing(strokes: [])
        let previousMarginDrawing = marginDrawings[currentPageIndex] ?? PKDrawing(strokes: [])
        
        // Count of strokes from previous saves
        let previousPdfCount = previousPdfDrawing.strokes.count
        let previousMarginCount = previousMarginDrawing.strokes.count
        let previousTotalCount = previousPdfCount + previousMarginCount
        
        // Find NEW strokes (ones that weren't there before)
        let allCurrentStrokes = currentCanvasDrawing.strokes
        let newStrokes = allCurrentStrokes.count > previousTotalCount
            ? Array(allCurrentStrokes.suffix(allCurrentStrokes.count - previousTotalCount))
            : []
        
        // For new strokes, classify and add them
        var newPdfStrokes: [PKStroke] = []
        var newMarginStrokes: [PKStroke] = []
        
        for stroke in newStrokes {
            if pdfFrame.intersects(stroke.renderBounds) {
                newPdfStrokes.append(stroke)
            } else {
                newMarginStrokes.append(stroke)
            }
        }
        
        // Combine with previously saved strokes
        let allPdfStrokes = previousPdfDrawing.strokes + newPdfStrokes
        let allMarginStrokes = previousMarginDrawing.strokes + newMarginStrokes
        
        // PDF strokes: normalize and store
        let pdfDrawing = PKDrawing(strokes: allPdfStrokes)
        let pdfNormalized = transformer.normalizeDrawingFromCanvasToPDF(pdfDrawing)
        pdfAnchoredDrawings[currentPageIndex] = pdfNormalized
        
        // Margin strokes: store in canvas space
        let marginDrawing = PKDrawing(strokes: allMarginStrokes)
        marginDrawings[currentPageIndex] = marginDrawing
        
        // Store PDF frame for transform calculation
        previousPdfFrame[currentPageIndex] = pdfFrame
        
        print("💾 [SAVE] PDF: \(allPdfStrokes.count), Margin: \(allMarginStrokes.count)")
    }

    private func saveCurrentPageDrawingsNew() {
        guard let canvas = drawingCanvas else { return }
        pageDrawings[currentPageIndex] = canvas.drawing
        print("💾 [SAVE-NEW] Strokes: \(canvas.drawing.strokes.count)")
    }
    private func loadPageDrawingsNew(for pageIndex: Int) {
        guard let canvas = drawingCanvas else { return }
        let drawing = pageDrawings[pageIndex] ?? PKDrawing()
        canvas.drawing = drawing
        print("🔄 [LOAD-NEW] Strokes: \(drawing.strokes.count)")
    }
    func computePDFFrameInCanvasSimple() -> CGRect {
        let settings = marginSettings
        let size = pdfManager?.effectiveSize(for: currentPageIndex)
            ?? CGSize(width: 612, height: 792)
        
        let scaledW = size.width * CGFloat(settings.pdfScale)
        let scaledH = size.height * CGFloat(settings.pdfScale)
        
        if !settings.isEnabled {
            let x = (canvasSize.width - scaledW) / 2
            let y = (canvasSize.height - scaledH) / 2
            return CGRect(x: x, y: y, width: scaledW, height: scaledH)
        }
        
        let (row, col) = settings.anchorPosition.gridPosition
        
        let x: CGFloat = {
            switch col {
            case 0: return 0
            case 1: return (canvasSize.width - scaledW) / 2
            case 2: return canvasSize.width - scaledW
            default: return 0
            }
        }()
        
        let y: CGFloat = {
            switch row {
            case 0: return 0
            case 1: return (canvasSize.height - scaledH) / 2
            case 2: return canvasSize.height - scaledH
            default: return 0
            }
        }()
        
        return CGRect(x: x, y: y, width: scaledW, height: scaledH)
    }


    private func loadPageDrawingsOld(for pageIndex: Int) {
        guard let canvas = drawingCanvas,
              let transformer = transformer else { return }

        // PDF strokes: denormalize from PDF space to canvas space
        let pdfNormalized = pdfAnchoredDrawings[pageIndex] ?? PKDrawing()
        let pdfInCanvas = transformer.denormalizeDrawingFromPDFToCanvas(pdfNormalized)
        
        // Margin strokes: already in canvas space, use directly!
        let marginInCanvas = marginDrawings[pageIndex] ?? PKDrawing()
        
        let combined = PKDrawing(strokes: pdfInCanvas.strokes + marginInCanvas.strokes)
        canvas.drawing = combined
        
        print("🔄 [LOAD] PDF: \(pdfInCanvas.strokes.count), Margin: \(marginInCanvas.strokes.count)")
    }
    private func loadPageDrawingsWithoutRebuild(for pageIndex: Int) {
        guard let canvas = drawingCanvas else { return }
        
        // Load drawings but skip the rebuildTransformer() call
        let pdfDrawing = pdfAnchoredDrawings[pageIndex] ?? PKDrawing()
        let marginDrawing = marginDrawings[pageIndex] ?? PKDrawing()
        let combinedStrokes = pdfDrawing.strokes + marginDrawing.strokes
        canvas.drawing = PKDrawing(strokes: combinedStrokes)
        
        print("🔄 [LOAD] PDF: \(pdfDrawing.strokes.count), Margin: \(marginDrawing.strokes.count)")
    }
    
    private func applyTransformToDrawing(_ drawing: PKDrawing, transform: CGAffineTransform) -> PKDrawing {
        // Apply transform to each point in each stroke
        var transformedStrokes: [PKStroke] = []
        
        for stroke in drawing.strokes {
            let bounds = stroke.renderBounds
            let transformedBounds = bounds.applying(transform)
            
            // Create new stroke with transformed bounds
            // Note: This is still limited because we can't access individual points
            // A better solution would be to store points separately
            transformedStrokes.append(stroke)  // Placeholder
        }
        
        return PKDrawing(strokes: transformedStrokes)
    }
    private func loadPdfDrawingToCanvas() {
        loadPageDrawings(for: currentPageIndex)
    }

    // MARK: - Input Routing

    private func determineActiveLayer(for point: CGPoint) -> DrawingRegion {
        guard let transformer = transformer else { return .pdf }
        return transformer.region(forViewPoint: point)
    }

    private func routeInputToLayer(_ region: DrawingRegion) {
        // With single unified canvas, all input goes to the same canvas
        // The region is tracked for informational purposes only
        activeDrawingLayer = region
        drawingCanvas?.isUserInteractionEnabled = (canvasMode == .drawing)
        lassoController?.setTargetCanvas(drawingCanvas)
    }

    // MARK: - Mode Interceptor

    private func setupModeInterceptor() {
        modeInterceptor.backgroundColor = .clear
        modeInterceptor.isOpaque = false
        modeInterceptor.isUserInteractionEnabled = true
        modeInterceptor.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(modeInterceptor)

        NSLayoutConstraint.activate([
            modeInterceptor.topAnchor.constraint(equalTo: containerView.topAnchor),
            modeInterceptor.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            modeInterceptor.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            modeInterceptor.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handlePaperKitTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        modeInterceptor.addGestureRecognizer(tap)
        tapGestureRecognizer = tap

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePaperKitPan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = self
        modeInterceptor.addGestureRecognizer(pan)
        panGestureRecognizer = pan

        print("Mode interceptor setup complete")
        updateGestureRouting()
    }

    // MARK: - Two-Finger Gestures

    private func setupGestureRecognizers() {
        // ✅ TWO-FINGER PAN - Works in both modes
        let twoPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoPanGesture.minimumNumberOfTouches = 2
        twoPanGesture.maximumNumberOfTouches = 2
        twoPanGesture.cancelsTouchesInView = true  // ✅ Prevent touches from reaching other handlers
        containerView.addGestureRecognizer(twoPanGesture)
        print("🖱️ [SETUP] Two-finger pan gesture added")
        
        // ✅ PINCH-TO-ZOOM - Works in both modes
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.cancelsTouchesInView = true  // ✅ CRITICAL: Prevent PDF's native pinch-zoom from triggering
        containerView.addGestureRecognizer(pinchGesture)
        print("🔍 [SETUP] Pinch zoom gesture added")
    }

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            print("🖱️ [TWO-FINGER-PAN] Started")
        case .changed:
            let translation = gesture.translation(in: containerView)
            print("🖱️ [TWO-FINGER-PAN] Pan coordinates: x=\(Int(translation.x)), y=\(Int(translation.y))")

            // Apply translation to containerView
            var currentTransform = containerView.transform
            currentTransform.tx += translation.x
            currentTransform.ty += translation.y
            containerView.transform = currentTransform

            // Reset translation for next update
            gesture.setTranslation(.zero, in: containerView)
        case .ended:
            print("🖱️ [TWO-FINGER-PAN] Ended")
        case .cancelled:
            print("🖱️ [TWO-FINGER-PAN] Cancelled")
        default:
            break
        }
    }
    
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.numberOfTouches == 2 else { return }
        
        switch gesture.state {
        case .changed:
            let scale = gesture.scale
            let newScale = currentZoomScale * scale
            let clampedScale = max(0.5, min(3.0, newScale))
            
            // Scale canvas container
            //containerView.transform = CGAffineTransform(scaleX: clampedScale, y: clampedScale)
            currentZoomScale = clampedScale
            gesture.scale = 1.0
            
            print("🔍 [PINCH-ZOOM] Scale: \(String(format: "%.2f", clampedScale))x")
            
            // ✅ CALL THE CALLBACK - this tells parent (PDFEditorScreenRefactored) about the zoom
            if let callback = self.onZoomChanged {
                print("🔗 [PINCH] ✅ Callback exists, calling with scale=\(String(format: "%.2f", clampedScale))")
                callback(clampedScale)
            } else {
                print("🔗 [PINCH] ⚠️ Callback is NIL - not wired up!")
            }
            
        case .ended, .cancelled:
            print("🔍 [PINCH-ZOOM] Ended at scale: \(String(format: "%.2f", currentZoomScale))x")
            
        default:
            break
        }
    }


    private func updatePDFViewZoom(_ scale: CGFloat) {
        if let pdfView = externalPDFView {
            pdfView.scaleFactor = scale
            print("📄 [ZOOM] ✅ PDFView scaleFactor set to: \(String(format: "%.2f", scale))x")
        } else {
            print("📄 [ZOOM] ⚠️ No PDFView reference - make sure to call setPDFView() after creating the controller")
        }
    }

    private func findPDFViewInHierarchy(_ view: UIView) -> UIView? {
        // Check if this view is a PDFView
        if NSStringFromClass(type(of: view)).contains("PDFView") {
            print("📄 [ZOOM-DEBUG]   Found PDFView at: \(NSStringFromClass(type(of: view)))")
            return view
        }
        
        // Recursively search subviews
        for subview in view.subviews {
            if let pdfView = findPDFViewInHierarchy(subview) {
                return pdfView
            }
        }
        
        return nil
    }

































































    private func debugCanvasLayout(label: String = "") {
        let labelStr = label.isEmpty ? "" : " [\(label)]"
        print("🔍 Canvas Layout\(labelStr)")
        print("   Drawing Canvas frame: \(drawingCanvas?.frame ?? .zero)")
        print("   Drawing Canvas bounds: \(drawingCanvas?.bounds ?? .zero)")
        print("   Container frame: \(containerView.frame)")
        print("   Container bounds: \(containerView.bounds)")
        print("   View frame: \(view.frame)")
        print("   View bounds: \(view.bounds)")
    }

    private func setupPaperKitDropInteraction(on view: UIView) {
        let dropInteraction = UIDropInteraction(delegate: self)
        view.addInteraction(dropInteraction)
    }

    // MARK: - View Transparency Helper (Deep)

    private func makeViewTreeTransparentDeep(_ view: UIView) {
        view.backgroundColor = .clear
        view.isOpaque = false
        view.layer.backgroundColor = UIColor.clear.cgColor
        view.layer.isOpaque = false

        if let scroll = view as? UIScrollView {
            scroll.backgroundColor = .clear
            scroll.isOpaque = false
            scroll.layer.backgroundColor = UIColor.clear.cgColor
            scroll.layer.isOpaque = false
        }

        for subview in view.subviews {
            makeViewTreeTransparentDeep(subview)
        }
    }

    // MARK: - Gesture Routing

    private func updateGestureRouting() {
        switch canvasMode {
        case .drawing:
            print("🖊️ Drawing mode - routing touches to PKCanvasView")
            enableDrawing(true)
            paperKitView?.isUserInteractionEnabled = false
            modeInterceptor.isUserInteractionEnabled = true

            // CRITICAL: Allow modeInterceptor to pass touches through
            if let scrollView = modeInterceptor as? UIScrollView {
                scrollView.canCancelContentTouches = false
                scrollView.delaysContentTouches = false
            }

            print("🖊️ modeInterceptor touch config:")
            print("   canCancelContentTouches: false")
            print("   delaysContentTouches: false")
        case .selecting:
            print("🎯 Selecting mode - enabling PaperKit")
            enableDrawing(false)
            paperKitView?.isUserInteractionEnabled = true
            modeInterceptor.isUserInteractionEnabled = true
        case .idle:
            print("🛑 Idle mode - all disabled")
            enableDrawing(false)
            paperKitView?.isUserInteractionEnabled = false
            modeInterceptor.isUserInteractionEnabled = false
        }
    }

    // MARK: - PaperKit Interaction Auto-Switch

    private func installPaperKitInteractionObservers() {
        guard let paperView = paperKitView else { return }

        // Flip to select whenever a text input inside PaperKit begins editing
        let tfObs = NotificationCenter.default.addObserver(
            forName: UITextField.textDidBeginEditingNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.maybeSwitchToSelectIfDescendant(of: paperView, editingObject: note.object)
            }
        }
        let tvObs = NotificationCenter.default.addObserver(
            forName: UITextView.textDidBeginEditingNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.maybeSwitchToSelectIfDescendant(of: paperView, editingObject: note.object)
            }
        }
        interactionObservers.append(contentsOf: [tfObs, tvObs])
    }

    private func maybeSwitchToSelectIfDescendant(of root: UIView, editingObject: Any?) {
        guard canvasMode == .drawing else { return }
        guard let v = editingObject as? UIView else { return }
        if v.isDescendant(of: root) {
            autoSwitchToSelectMode()
        }
    }

    @objc private func handlePaperKitTap(_ gr: UITapGestureRecognizer) {
        guard canvasMode == .drawing, gr.state == .ended else { return }

        let point = gr.location(in: view)

        // Route input based on touch location
        let region = determineActiveLayer(for: point)
        routeInputToLayer(region)

        guard let paperView = paperKitView else { return }
        let p = gr.location(in: paperView)
        let hit = paperView.hitTest(p, with: nil)
        if isInteractiveElement(hit) {
            autoSwitchToSelectMode()
        }
    }

    @objc private func handlePaperKitPan(_ gr: UIPanGestureRecognizer) {
        guard canvasMode == .drawing else { return }

        if gr.state == .began {
            let point = gr.location(in: view)
            let region = determineActiveLayer(for: point)
            routeInputToLayer(region)
        }

        guard let paperView = paperKitView else { return }
        let p = gr.location(in: paperView)
        let hit = paperView.hitTest(p, with: nil)
        // Flip early when a drag starts on something interactive
        if gr.state == .began, isInteractiveElement(hit) {
            autoSwitchToSelectMode()
        }
    }

    // Heuristics for "interactive element" inside PaperKit
    private func isInteractiveElement(_ v: UIView?) -> Bool {
        guard let v = v else { return false }
        if v is UIControl || v is UITextField || v is UITextView { return true }
        if let gestures = v.gestureRecognizers, !gestures.isEmpty { return true }
        let traits = v.accessibilityTraits
        if traits.contains(.button) || traits.contains(.image) || traits.contains(.selected) { return true }
        // Class-name hints for custom PaperKit views
        let name = NSStringFromClass(type(of: v))
        if name.contains("Paper") || name.contains("Markup") || name.contains("Form")
            || name.contains("Shape") || name.contains("Annotation") { return true }
        return false
    }

    // MARK: - Alignment Transform

    private func applyAlignmentTransform() {
        let transform: CGAffineTransform = alignmentTransform(for: currentAlignment)

        UIView.animate(withDuration: 0.2) { [weak self] in
            self?.containerView.transform = transform
        }
    }

    private func alignmentTransform(for alignment: PDFAlignment) -> CGAffineTransform {
        let parentBounds = view.bounds
        let containerWidth = canvasSize.width

        let xOffset: CGFloat = {
            switch alignment {
            case .left:
                return 0
            case .center:
                return (parentBounds.width - containerWidth) / 2
            case .right:
                return parentBounds.width - containerWidth
            }
        }()

        return CGAffineTransform(translationX: xOffset, y: 0)
    }

    // MARK: - Tool Picker Management

    func showToolPicker() {
        guard let toolPicker = pencilKitToolPicker,
              let canvas = drawingCanvas else { return }
        toolPicker.setVisible(true, forFirstResponder: canvas)
    }

    func hideToolPicker() {
        guard let toolPicker = pencilKitToolPicker,
              let canvas = drawingCanvas else { return }
        toolPicker.setVisible(false, forFirstResponder: canvas)
    }

    /// Get the currently active drawing canvas
    var activeCanvas: PKCanvasView? {
        return drawingCanvas
    }

    /// Update zoom and rotation from SwiftUI view
    func updateZoomAndRotation(_ zoomLevel: CGFloat, _ rotation: Int) {
        if zoomLevel != currentZoomLevel {
            currentZoomLevel = zoomLevel
            print("🔍 Canvas zoom updated: \(Int(zoomLevel * 100))%")
        }

        // Always update the rotation value to ensure it's set before any layout
        // This fixes the issue where viewDidLayoutSubviews() calls applyTransforms()
        // before the rotation is properly initialized
        let rotationChanged = rotation != currentPageRotation
        currentPageRotation = rotation

        if rotationChanged {
            print("🔄 Canvas rotation updated: \(rotation)°")
            // Apply the rotation transform to canvas views
            applyTransforms()
        }
    }
}

// MARK: - PDF Alignment Enum
enum PDFAlignment: Equatable {
    case left
    case center
    case right
}

// MARK: - PKCanvasViewDelegate
extension UnifiedBoardCanvasController: PKCanvasViewDelegate {
    public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let toolBefore = canvasView.tool
        print("✍️ [DRAW-START-BEFORE] Tool: \(toolDescription(toolBefore))")

        // Check if this is the right canvas view
        print("   canvasView address: \(ObjectIdentifier(canvasView))")
        if let canvas = drawingCanvas {
            print("   drawingCanvas address: \(ObjectIdentifier(canvas))")
            if ObjectIdentifier(canvasView) == ObjectIdentifier(canvas) {
                print("   ✅ Drawing on unified canvas")
            } else {
                print("   ⚠️ UNEXPECTED CANVAS! Drawing on unknown canvas!")
            }
        }

        // ✅ Check what tool is about to draw
        print("✍️ [DRAW-START] About to draw")

        if let tool = canvasView.tool as? PKInkingTool {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            tool.color.getRed(&r, green: &g, blue: &b, alpha: nil)
            print("   Tool: \(tool.inkType.rawValue), color RGB(\(Int(r*255)), \(Int(g*255)), \(Int(b*255))), width=\(tool.width)")
        } else if canvasView.tool is PKEraserTool {
            print("   Tool: Eraser")
        }

        print("✍️ [CANVAS DREW]")
        print("   Drawing stroke count: \(canvasView.drawing.strokes.count)")
        if let lastStroke = canvasView.drawing.strokes.last {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            lastStroke.ink.color.getRed(&r, green: &g, blue: &b, alpha: nil)
            print("   Last stroke color: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255))")
        }

        // Save drawings using region-based partitioning
        saveCurrentPageDrawings()
    }

    public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        // Track tool changes
    }

    public func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        // No need to sync tools between canvases - single canvas only
    }
}

// MARK: - UIDropInteraction Delegate
extension UnifiedBoardCanvasController: UIDropInteractionDelegate {
    public func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        return canvasMode == .selecting && session.hasItemsConforming(toTypeIdentifiers: ["public.json"])
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        autoSwitchToSelectMode()
    }
}

// MARK: - UIGestureRecognizerDelegate
extension UnifiedBoardCanvasController: UIGestureRecognizerDelegate {

    /// Allow multiple gesture recognizers to work simultaneously
    /// This is crucial for sidebar edge pan and drawing gestures
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {

        // Allow sidebar edge pan gesture to work
        if otherGestureRecognizer is UIScreenEdgePanGestureRecognizer {
            print("🎯 Edge pan detected - allowing simultaneous recognition")
            return true
        }

        return true
    }

    /// Control which touches are intercepted based on current mode
    /// This prevents canvas from blocking non-drawing interactions
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {

        // For canvas views, only intercept during drawing mode
        if touch.view is PKCanvasView {
            let shouldReceive = (canvasMode == .drawing)
            if !shouldReceive {
                print("🎯 Canvas touch blocked (not in drawing mode)")
            }
            return shouldReceive
        }

        return true
    }
}

// MARK: - Tool API Methods
extension UnifiedBoardCanvasController {

    private func toolDescription(_ tool: PKTool?) -> String {
        guard let tool = tool else { return "NIL" }

        if let inkTool = tool as? PKInkingTool {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            inkTool.color.getRed(&r, green: &g, blue: &b, alpha: nil)
            let red = Int(r * 255)
            let green = Int(g * 255)
            let blue = Int(b * 255)
            let inkType = String(describing: inkTool.inkType).split(separator: ".").last ?? "unknown"
            return "\(inkType) RGB(\(red),\(green),\(blue)) width=\(inkTool.width)"
        } else if tool is PKEraserTool {
            return "eraser"
        } else if tool is PKLassoTool {
            return "lasso"
        } else {
            return "unknown: \(type(of: tool))"
        }
    }

//    func setInk(ink: PKInkingTool.InkType, color: UIColor, width: CGFloat) {
//        // DEBUG: What color is the toolbar actually sending?
//        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
//        color.getRed(&r, green: &g, blue: &b, alpha: &a)
//
//        print("🎨 [TOOLBAR] Sent color: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255)), A=\(Int(a*255))")
//
//        let tool = PKInkingTool(ink, color: color, width: width)
//
//        print("🎨 [TOOL-ASSIGN] BEFORE assignment")
//        print("   New tool: \(ink.rawValue), color RGB(\(Int(r*255)), \(Int(g*255)), \(Int(b*255))), width=\(width)")
//
//        // Check what tool is currently on canvas
//        if let currentTool = pdfDrawingCanvas?.tool as? PKInkingTool {
//            var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0
//            currentTool.color.getRed(&cr, green: &cg, blue: &cb, alpha: nil)
//            print("   Current tool on canvas: \(currentTool.inkType.rawValue), color RGB(\(Int(cr*255)), \(Int(cg*255)), \(Int(cb*255)))")
//        }
//
//        // Canvas validity check
//        print("🔍 pdfDrawingCanvas validity check:")
//        print("   pdfDrawingCanvas is nil: \(pdfDrawingCanvas == nil ? "YES ❌" : "NO ✅")")
//
//        // Try assigning with direct reference
//        if let canvas = pdfDrawingCanvas {
//            canvas.tool = tool
//
//            // Read back immediately to verify
//            if let toolReadBack = canvas.tool as? PKInkingTool {
//                var tbr: CGFloat = 0, tbg: CGFloat = 0, tbb: CGFloat = 0
//                toolReadBack.color.getRed(&tbr, green: &tbg, blue: &tbb, alpha: nil)
//                let readBackColor = "RGB(\(Int(tbr*255)), \(Int(tbg*255)), \(Int(tbb*255)))"
//                let setColor = "RGB(\(Int(r*255)), \(Int(g*255)), \(Int(b*255)))"
//                print("   ✅ Tool assigned to canvas")
//                print("   Set color: \(setColor)")
//                print("   Read back color: \(readBackColor)")
//                print("   Colors match: \(readBackColor == setColor ? "✅ YES" : "❌ NO")")
//            }
//        }
//
//        // ✅ CRITICAL: Store the tool so it persists if canvases are recreated
//        currentInkingTool = tool
//        currentEraserTool = nil
//
//        pdfDrawingCanvas?.tool = tool
//        marginDrawingCanvas?.tool = tool
//        previousTool = tool
//
//        print("🎨 [TOOL-ASSIGN] AFTER assignment")
//
//        // Final verification
//        if let canvas = pdfDrawingCanvas, let finalTool = canvas.tool as? PKInkingTool {
//            var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0
//            finalTool.color.getRed(&fr, green: &fg, blue: &fb, alpha: nil)
//            print("   Final tool on canvas: \(finalTool.inkType.rawValue), color RGB(\(Int(fr*255)), \(Int(fg*255)), \(Int(fb*255)))")
//        }
//
//        // Verify tools were actually set
//        print("🖊️ setInkTool: \(ink.rawValue) width=\(width)")
//        print("   pdfCanvas.tool: \(pdfDrawingCanvas?.tool != nil ? "✅ SET" : "❌ NIL")")
//        print("   marginCanvas.tool: \(marginDrawingCanvas?.tool != nil ? "✅ SET" : "❌ NIL")")
//        print("   ✅ Stored in currentInkingTool for persistence")
//
//        // ⏱️ DIAGNOSTIC: Schedule a check 100ms later to see if tool is still set
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
//            if let currentTool = self.pdfDrawingCanvas?.tool {
//                print("⏱️ [100ms LATER] Tool still set: \(self.toolDescription(currentTool))")
//            } else {
//                print("⏱️ [100ms LATER] Tool is now NIL!")
//            }
//        }
//
//        // ⏱️ Check immediately at next runloop iteration
//        DispatchQueue.main.async {
//            if let currentTool = self.pdfDrawingCanvas?.tool {
//                print("⏱️ [NEXT RUNLOOP] Tool after setInkTool: \(self.toolDescription(currentTool))")
//            }
//        }
//
//        // NO setCanvasMode() call - toolbar callback controls mode
//    }

    func setInk(ink: PKInkingTool.InkType, color: UIColor, width: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        print("🎨 [TOOLBAR] Sent color: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255))")

        let tool = PKInkingTool(ink, color: color, width: width)

        print("🎨 [TOOL-ASSIGN] BEFORE assignment")
        print("   New tool: \(ink.rawValue), color RGB(\(Int(r*255)), \(Int(g*255)), \(Int(b*255))), width=\(width)")

        // Check what tool is currently on canvas
        if let currentTool = drawingCanvas?.tool as? PKInkingTool {
            var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0
            currentTool.color.getRed(&cr, green: &cg, blue: &cb, alpha: nil)
            print("   Current tool on canvas: \(currentTool.inkType.rawValue), color RGB(\(Int(cr*255)), \(Int(cg*255)), \(Int(cb*255)))")
        }

        print("🔍 drawingCanvas validity check:")
        print("   drawingCanvas is nil: \(drawingCanvas == nil ? "YES ❌" : "NO ✅")")

        // Assign to canvas
        if let canvas = drawingCanvas {
            canvas.tool = tool

            // Read back immediately to verify
            if let toolReadBack = canvas.tool as? PKInkingTool {
                var tbr: CGFloat = 0, tbg: CGFloat = 0, tbb: CGFloat = 0
                toolReadBack.color.getRed(&tbr, green: &tbg, blue: &tbb, alpha: nil)
                let readBackColor = "RGB(\(Int(tbr*255)), \(Int(tbg*255)), \(Int(tbb*255)))"
                let setColor = "RGB(\(Int(r*255)), \(Int(g*255)), \(Int(b*255)))"
                print("   ✅ Tool assigned to canvas")
                print("   Set color: \(setColor)")
                print("   Read back color: \(readBackColor)")
                print("   Colors match: \(readBackColor == setColor ? "✅ YES" : "❌ NO")")
            }
        }

        // 🔗 UPDATE SHARED STATE: Store the tool in DrawingViewModel so all controllers use it
        print("   🔗 [SHARED-STATE] Updating toolStateProvider.sharedCurrentInkingTool")
        toolStateProvider?.sharedCurrentInkingTool = tool

        currentEraserTool = nil
        previousTool = tool

        print("🎨 [TOOL-ASSIGN] AFTER assignment")

        // Final verification
        if let canvas = drawingCanvas, let finalTool = canvas.tool as? PKInkingTool {
            var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0
            finalTool.color.getRed(&fr, green: &fg, blue: &fb, alpha: nil)
            print("   Final tool on canvas: \(finalTool.inkType.rawValue), color RGB(\(Int(fr*255)), \(Int(fg*255)), \(Int(fb*255)))")
        }

        // Verify tools were actually set
        print("🖊️ setInkTool: \(ink.rawValue) width=\(width)")
        print("   drawingCanvas.tool: \(drawingCanvas?.tool != nil ? "✅ SET" : "❌ NIL")")
        print("   ✅ Stored in SHARED state (DrawingViewModel) for persistence")

        // ⏱️ DIAGNOSTIC: Schedule a check 100ms later to see if tool is still set
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let currentTool = self.drawingCanvas?.tool {
                print("⏱️ [100ms LATER] Tool still set: \(self.toolDescription(currentTool))")
            } else {
                print("⏱️ [100ms LATER] Tool is now NIL!")
            }
        }

        // ⏱️ Check immediately at next runloop iteration
        DispatchQueue.main.async {
            if let currentTool = self.drawingCanvas?.tool {
                print("⏱️ [NEXT RUNLOOP] Tool after setInkTool: \(self.toolDescription(currentTool))")
            }
        }
    }
    
//    func setEraser() {
//        let eraser = PKEraserTool(.vector)
//
//        // ✅ CRITICAL: Store the eraser so it persists if canvases are recreated
//        currentEraserTool = eraser
//        currentInkingTool = nil
//
//        pdfDrawingCanvas?.tool = eraser
//        marginDrawingCanvas?.tool = eraser
//        previousTool = eraser  // ✅ FIX: Update previousTool so lasso restore uses eraser
//
//        // Verify tools were actually set
//        print("🧽 setEraser")
//        print("   pdfCanvas.tool: \(pdfDrawingCanvas?.tool != nil ? "✅ SET" : "❌ NIL")")
//        print("   marginCanvas.tool: \(marginDrawingCanvas?.tool != nil ? "✅ SET" : "❌ NIL")")
//        // NO setCanvasMode() call - toolbar callback controls mode
//    }
    
    func setEraser() {
        let eraser = PKEraserTool(.vector)

        // ✅ Store the eraser so it persists if canvas is recreated
        currentEraserTool = eraser
        drawingCanvas?.tool = eraser
        previousTool = eraser  // ✅ FIX: Update previousTool so lasso restore uses eraser

        // Verify tool was actually set
        print("🧽 setEraser")
        print("   drawingCanvas.tool: \(drawingCanvas?.tool != nil ? "✅ SET" : "❌ NIL")")
    }

    func beginLasso() {
        lassoController?.beginLasso()
        setCanvasMode(.selecting)
    }

    func endLasso() {
        lassoController?.endLassoAndRestorePreviousTool()
        setCanvasMode(.drawing)
    }

    func toggleRuler() {
        // Ruler functionality can be implemented here
        print("🔲 toggleRuler called")
    }

    func undo() {
        activeCanvas?.undoManager?.undo()
    }

    func redo() {
        activeCanvas?.undoManager?.redo()
    }
}

