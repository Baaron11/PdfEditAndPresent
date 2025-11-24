import UIKit
import PencilKit
import PaperKit

// MARK: - Unified Board Canvas Controller
@MainActor
final class UnifiedBoardCanvasController: UIViewController {
    // MARK: - Properties

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

    // Layer 2: PDF-anchored drawing canvas (moves/scales with PDF)
    private(set) var pdfDrawingCanvas: PKCanvasView?

    // Layer 3: Margin-anchored drawing canvas (identity transform in canvas space)
    private(set) var marginDrawingCanvas: PKCanvasView?

    // Shared tool picker
    private var pencilKitToolPicker: PKToolPicker?

    // Layer 4: Interactive overlay for mode switching
    private let modeInterceptor = UIView()

    // Gesture recognizers
    private var tapGestureRecognizer: UITapGestureRecognizer?
    private var panGestureRecognizer: UIPanGestureRecognizer?

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

    // Alignment state
    private(set) var currentAlignment: PDFAlignment = .center

    // Previous tool for lasso restore
    private var previousTool: PKTool?

    // ✅ Store the current tool so it persists if canvases are recreated (continuous scroll)
    private var currentInkingTool: PKInkingTool?
    private var currentEraserTool: PKEraserTool?

    // PDFManager reference for querying page sizes
    weak var pdfManager: PDFManager?

    private var currentZoomLevel: CGFloat = 1.0
    private var currentPageRotation: Int = 0

    // MARK: - Initialization

    override func viewDidLoad() {
        super.viewDidLoad()
        print("UnifiedBoardCanvasController viewDidLoad")
        view.backgroundColor = .clear
        view.isOpaque = false
        setupContainerView()
        setupModeInterceptor()
        updateCanvasInteractionState()
        print("Setup complete")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("UnifiedBoardCanvasController viewDidAppear - actual bounds: \(view.bounds)")

        // Find the nearest PDF scroll view in both Single and Continuous modes
        if let scroll = hostScrollView(from: view.superview) ?? hostScrollView(from: view) {
            // Make scroll not steal PencilKit strokes
            scroll.delaysContentTouches = false
            scroll.canCancelContentTouches = true

            if let drawGR = pdfDrawingCanvas?.drawingGestureRecognizer {
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
        if let pdfCanvas = pdfDrawingCanvas {
            print("🎯 pdfCanvas frame=\(pdfCanvas.frame) bounds=\(pdfCanvas.bounds)")
            print("🎯 pdfCanvas isUserInteractionEnabled=\(pdfCanvas.isUserInteractionEnabled)")
        }
        print("🎯 containerView frame=\(containerView.frame) bounds=\(containerView.bounds)")
        debugCanvasLayout(label: "viewDidAppear")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        print("📍 [LAYOUT] viewDidLayoutSubviews() called")
        print("📍 [LAYOUT]   containerView.bounds: \(containerView.bounds)")

        // At this point containerView has a real size - reapply transforms
        applyTransforms()

        // Debug prints for canvas frames AFTER layout
        if let pdfCanvas = pdfDrawingCanvas {
            print("📍 [LAYOUT]   pdfDrawingCanvas ACTUAL frame: \(pdfCanvas.frame)")
            print("📍 [LAYOUT]   pdfDrawingCanvas ACTUAL bounds: \(pdfCanvas.bounds)")
            print("📍 [LAYOUT]   pdfDrawingCanvas transform: \(pdfCanvas.transform)")
        }
        if let marginCanvas = marginDrawingCanvas {
            print("📍 [LAYOUT]   marginDrawingCanvas ACTUAL frame: \(marginCanvas.frame)")
            print("📍 [LAYOUT]   marginDrawingCanvas ACTUAL bounds: \(marginCanvas.bounds)")
            print("📍 [LAYOUT]   marginDrawingCanvas transform: \(marginCanvas.transform)")
        }
        print("📍 [LAYOUT]   containerView ACTUAL frame: \(containerView.frame)")
        print("📍 [LAYOUT]   view.bounds: \(view.bounds)")
    }

    deinit {
        for o in interactionObservers { NotificationCenter.default.removeObserver(o) }
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

    // MARK: - Canvas Setup Helpers

    private func pinCanvas(_ canvas: PKCanvasView, to host: UIView) {
        let canvasName = canvas === pdfDrawingCanvas ? "pdfDrawingCanvas" : (canvas === marginDrawingCanvas ? "marginDrawingCanvas" : "unknownCanvas")
        print("📐 [CONSTRAINT] pinCanvas() called for \(canvasName)")
        print("📐 [CONSTRAINT]   Setting width constraint: \(canvasSize.width)")
        print("📐 [CONSTRAINT]   Setting height constraint: \(canvasSize.height)")

        canvas.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(canvas)

        // Constrain canvas to PDF page size (NOT container size)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: host.topAnchor),
            canvas.widthAnchor.constraint(equalToConstant: canvasSize.width),
            canvas.heightAnchor.constraint(equalToConstant: canvasSize.height)
        ])

        // Setup
        canvas.backgroundColor = UIColor.blue.withAlphaComponent(0.2)
        canvas.isOpaque = false
        canvas.isUserInteractionEnabled = false
        canvas.allowsFingerDrawing = true
        canvas.drawingPolicy = .anyInput
        canvas.maximumZoomScale = 1.0
        canvas.minimumZoomScale = 1.0
        canvas.isScrollEnabled = false

        // Clipping
        canvas.clipsToBounds = true
        canvas.layer.masksToBounds = true

        print("📐 [CONSTRAINT]   Constraints activated for \(canvasName)")
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

        pdfDrawingCanvas?.isUserInteractionEnabled = shouldInteract
        marginDrawingCanvas?.isUserInteractionEnabled = shouldInteract

        print("🎯 Canvas interaction: \(shouldInteract ? "ENABLED" : "DISABLED") (mode=\(canvasMode))")

        if shouldInteract {
            print("🎯 Canvas debug info:")
            print("   bounds: \(pdfDrawingCanvas?.bounds ?? .zero)")
            print("   frame: \(pdfDrawingCanvas?.frame ?? .zero)")
            print("   isHidden: \(pdfDrawingCanvas?.isHidden ?? true)")
            print("   isUserInteractionEnabled: \(pdfDrawingCanvas?.isUserInteractionEnabled ?? false)")

            // Ensure canvas is on top of other views
            if let canvas = pdfDrawingCanvas, let superview = canvas.superview {
                superview.bringSubviewToFront(canvas)
            }
        }
        verifyToolOnCanvas("AFTER updateCanvasInteractionState")
    }

    /// Enable or disable drawing on PKCanvasViews
    func enableDrawing(_ enabled: Bool) {
        pdfDrawingCanvas?.isUserInteractionEnabled = enabled
        marginDrawingCanvas?.isUserInteractionEnabled = enabled
    }

    // MARK: - Tool Verification (temporary diagnostic)

    private func verifyToolOnCanvas(_ label: String) {
        print("🔍 [VERIFY] \(label)")

        if let pdf = pdfDrawingCanvas {
            print("   pdfCanvas exists: ✅ YES")

            if let tool = pdf.tool as? PKInkingTool {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                tool.color.getRed(&r, green: &g, blue: &b, alpha: nil)
                print("   Tool type: PKInkingTool (\(tool.inkType.rawValue))")
                print("   Tool color: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255))")
                print("   Tool width: \(tool.width)")
            } else if pdf.tool is PKEraserTool {
                print("   Tool type: PKEraserTool")
            } else {
                print("   Tool type: Unknown")
            }
        } else {
            print("   pdfCanvas exists: ❌ NIL")
        }
    }

    // MARK: - Touch Debugging

    // Debug touch routing
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("🔴 [TOUCH] touchesBegan - \(touches.count) touches")
        if let touch = touches.first {
            let location = touch.location(in: view)
            print("   Location in view: \(location)")
        }

        // DEBUG: Check BOTH canvas tools at touch time
        print("   pdfCanvas.tool: \(pdfDrawingCanvas?.tool ?? PKInkingTool(.pen, color: .black, width: 1))")
        if let tool = pdfDrawingCanvas?.tool as? PKInkingTool {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            tool.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            print("   pdfCanvas tool color: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255))")
        }

        print("   marginCanvas.tool: \(marginDrawingCanvas?.tool ?? PKInkingTool(.pen, color: .black, width: 1))")
        if let tool = marginDrawingCanvas?.tool as? PKInkingTool {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            tool.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            print("   marginCanvas tool color: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255))")
        }

        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        print("🔴 [CONTROLLER] touchesMoved - \(touches.count) touches")
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
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

    /// Setup dual PencilKit layers
    func setupPencilKit() {
        print("🎛️ [LIFECYCLE] setupPencilKit() called")
        print("🎛️ [LIFECYCLE]   Current canvasSize: \(canvasSize.width) x \(canvasSize.height)")
        print("🎛️ [LIFECYCLE]   Current pageRotation: \(currentPageRotation)°")

        // Clean up old canvases
        pdfDrawingCanvas?.removeFromSuperview()
        marginDrawingCanvas?.removeFromSuperview()

        // Create PDF-anchored canvas (Layer 2)
        let pdfCanvas = PKCanvasView()
        pdfDrawingCanvas = pdfCanvas  // Set reference before pinCanvas so name detection works
        print("🎛️ [LIFECYCLE]   About to call pinCanvas() for pdfDrawingCanvas")
        pinCanvas(pdfCanvas, to: containerView)
        pdfCanvas.delegate = self

        // Create margin-anchored canvas (Layer 3)
        let marginCanvas = PKCanvasView()
        marginDrawingCanvas = marginCanvas  // Set reference before pinCanvas
        print("🎛️ [LIFECYCLE]   About to call pinCanvas() for marginDrawingCanvas")
        pinCanvas(marginCanvas, to: containerView)
        marginCanvas.delegate = self

        // Shared tool picker
        let toolPicker = PKToolPicker()
        toolPicker.setVisible(false, forFirstResponder: pdfCanvas)
        toolPicker.addObserver(pdfCanvas)
        toolPicker.addObserver(marginCanvas)

        // References already set above for name detection in pinCanvas
        pencilKitToolPicker = toolPicker

        // Enable multi-touch for both canvases
        pdfCanvas.isMultipleTouchEnabled = true
        marginCanvas.isMultipleTouchEnabled = true

        // Initialize lasso controller with the active canvas
        lassoController = PKLassoSelectionController(canvasView: pdfCanvas)

        // Reconfigure canvas constraints to match current page size
        reconfigureCanvasConstraints()

        // Set initial tool
        let defaultTool = PKInkingTool(.pen, color: .black, width: 2)
        pdfCanvas.tool = defaultTool
        marginCanvas.tool = defaultTool
        previousTool = defaultTool

        // ✅ CRITICAL: If a tool was previously selected, restore it now
        // This handles the case where canvases are recreated during page scrolling
        if let storedInkingTool = currentInkingTool {
            print("🎨 [PERSISTENCE] Restoring stored inking tool to newly created canvases")
            pdfCanvas.tool = storedInkingTool
            marginCanvas.tool = storedInkingTool
            previousTool = storedInkingTool
        } else if let storedEraserTool = currentEraserTool {
            print("🧹 [PERSISTENCE] Restoring stored eraser tool to newly created canvases")
            pdfCanvas.tool = storedEraserTool
            marginCanvas.tool = storedEraserTool
            previousTool = storedEraserTool
        }

        // Bring container on top of PDF, then canvases above anything inside
        view.bringSubviewToFront(containerView)
        containerView.bringSubviewToFront(pdfCanvas)
        containerView.bringSubviewToFront(marginCanvas)
        containerView.bringSubviewToFront(modeInterceptor)

        // Apply initial transforms
        applyTransforms()

        print("Dual PencilKit layers setup complete")
    }

    /// Set canvas mode (drawing, selecting, idle)
    func setCanvasMode(_ mode: CanvasMode) {
        print("📍 [MODE-CHANGE] setCanvasMode(\(mode))")
        print("   currentInkingTool: \(currentInkingTool != nil ? "✅ SET" : "❌ NIL")")

        verifyToolOnCanvas("BEFORE setCanvasMode(\(mode))")
        self.canvasMode = mode
        updateCanvasInteractionState()
        onModeChanged?(mode)
        onCanvasModeChanged?(mode)

        if mode == .selecting {
            print("   Entering SELECTING mode - starting lasso")
            lassoController?.beginLasso()
        } else {
            print("   Exiting SELECTING mode - ending lasso")
            lassoController?.endLassoAndRestorePreviousTool()

            // ✅ CRITICAL FIX: Restore to the currently selected tool, not the previous tool
            // This ensures the user's selected brush color is preserved after exiting lasso
            if let currentTool = currentInkingTool {
                print("   ✅ Restoring to currentInkingTool (user's selected brush)")
                pdfDrawingCanvas?.tool = currentTool
                marginDrawingCanvas?.tool = currentTool
                previousTool = currentTool
            } else if let currentEraser = currentEraserTool {
                print("   ✅ Restoring to currentEraserTool (user's selected eraser)")
                pdfDrawingCanvas?.tool = currentEraser
                marginDrawingCanvas?.tool = currentEraser
                previousTool = currentEraser
            }
        }

        verifyToolOnCanvas("AFTER setCanvasMode(\(mode))")
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
    func updateMarginSettings(_ settings: MarginSettings) {
        marginSettings = settings
        rebuildTransformer()
        applyTransforms()
    }

    /// Set current page index and load drawings
    func setCurrentPage(_ pageIndex: Int) {
        print("🎛️ [LIFECYCLE] setCurrentPage() called with pageIndex: \(pageIndex)")
        print("🎛️ [LIFECYCLE]   Previous currentPageIndex: \(currentPageIndex)")
        print("🎛️ [LIFECYCLE]   Current canvasSize: \(canvasSize.width) x \(canvasSize.height)")

        // Save current page drawings before switching
        saveCurrentPageDrawings()

        currentPageIndex = pageIndex

        // Get the actual page size from PDFManager for this specific page
        if let pdfManager = pdfManager {
            let pageSize = pdfManager.effectiveSize(for: pageIndex)
            print("🎛️ [LIFECYCLE]   PDFManager returned size for page \(pageIndex + 1): \(pageSize.width) x \(pageSize.height)")
            canvasSize = pageSize
        } else {
            print("🎛️ [LIFECYCLE]   WARNING: pdfManager is nil, keeping canvasSize: \(canvasSize)")
        }

        loadPageDrawings(for: pageIndex)
        rebuildTransformer()
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
            marginDrawingCanvas?.drawing = drawing
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

    // MARK: - Transform Management

    private func rebuildTransformer() {
        let helper = MarginCanvasHelper(
            settings: marginSettings,
            originalPDFSize: canvasSize,
            canvasSize: canvasSize
        )
        transformer = DrawingCoordinateTransformer(
            marginHelper: helper,
            canvasViewBounds: view.bounds,
            zoomScale: 1.0,
            contentOffset: .zero
        )
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
        pdfDrawingCanvas?.bounds = canvasBounds
        marginDrawingCanvas?.bounds = canvasBounds

        // Calculate the center position that will place the rotated canvas at origin
        // After rotation, the visual frame has dimensions (containerWidth x containerHeight)
        // We want the visual frame to start at (0, 0), so center should be at (containerWidth/2, containerHeight/2)
        let centerX = containerWidth / 2
        let centerY = containerHeight / 2
        pdfDrawingCanvas?.center = CGPoint(x: centerX, y: centerY)
        marginDrawingCanvas?.center = CGPoint(x: centerX, y: centerY)

        // Now apply the rotation transform - this rotates around the center we just set
        pdfDrawingCanvas?.transform = CGAffineTransform(rotationAngle: rotationRadians)
        marginDrawingCanvas?.transform = CGAffineTransform(rotationAngle: rotationRadians)

        print("🔄 [TRANSFORM]   Applied rotation transform to both canvases")
        print("🔄 [TRANSFORM]   Canvas bounds: \(canvasBounds)")
        print("🔄 [TRANSFORM]   Canvas center: (\(centerX), \(centerY))")

        // Update margin canvas visibility based on margins enabled
        marginDrawingCanvas?.isHidden = !marginSettings.isEnabled

        print("🔄 [TRANSFORM]   Final containerView.bounds: \(containerView.bounds)")
        print("🔄 [TRANSFORM]   pdfDrawingCanvas.frame: \(pdfDrawingCanvas?.frame ?? .zero)")
    }

    private func reconfigureCanvasConstraints() {
        guard let pdfCanvas = pdfDrawingCanvas,
              let marginCanvas = marginDrawingCanvas else { return }

        // Deactivate old constraints
        pdfCanvas.constraints.forEach { $0.isActive = false }
        marginCanvas.constraints.forEach { $0.isActive = false }

        // Re-pin with new canvasSize
        pdfCanvas.removeFromSuperview()
        marginCanvas.removeFromSuperview()

        pinCanvas(pdfCanvas, to: containerView)
        pinCanvas(marginCanvas, to: containerView)

        // Force layout update
        containerView.setNeedsLayout()
        containerView.layoutIfNeeded()

        print("🎯 Canvas constraints reconfigured for size: \(canvasSize)")
    }

    // MARK: - Drawing Persistence

    private func saveCurrentPageDrawings() {
        guard let pdfCanvas = pdfDrawingCanvas,
              let marginCanvas = marginDrawingCanvas,
              let transformer = transformer else { return }

        // Normalize PDF canvas drawing to PDF space before storing
        let pdfDrawing = transformer.normalizeDrawingFromCanvasToPDF(pdfCanvas.drawing)
        pdfAnchoredDrawings[currentPageIndex] = pdfDrawing

        // Store margin drawing directly in canvas space
        marginDrawings[currentPageIndex] = marginCanvas.drawing

        // Notify delegate
        onDrawingChanged?(currentPageIndex, pdfDrawing, marginCanvas.drawing)
    }

    private func loadPageDrawings(for pageIndex: Int) {
        loadPdfDrawingToCanvas()
        marginDrawingCanvas?.drawing = marginDrawings[pageIndex] ?? PKDrawing()
    }

    private func loadPdfDrawingToCanvas() {
        guard let transformer = transformer else {
            pdfDrawingCanvas?.drawing = PKDrawing()
            return
        }

        let normalizedDrawing = pdfAnchoredDrawings[currentPageIndex] ?? PKDrawing()
        let canvasDrawing = transformer.denormalizeDrawingFromPDFToCanvas(normalizedDrawing)
        pdfDrawingCanvas?.drawing = canvasDrawing
    }

    // MARK: - Input Routing

    private func determineActiveLayer(for point: CGPoint) -> DrawingRegion {
        guard let transformer = transformer else { return .pdf }
        return transformer.region(forViewPoint: point)
    }

    private func routeInputToLayer(_ region: DrawingRegion) {
        activeDrawingLayer = region

        switch region {
        case .pdf:
            pdfDrawingCanvas?.isUserInteractionEnabled = true
            marginDrawingCanvas?.isUserInteractionEnabled = false
            lassoController?.setTargetCanvas(pdfDrawingCanvas)
        case .margin:
            pdfDrawingCanvas?.isUserInteractionEnabled = false
            marginDrawingCanvas?.isUserInteractionEnabled = true
            lassoController?.setTargetCanvas(marginDrawingCanvas)
        }
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

    private func debugCanvasLayout(label: String = "") {
        let labelStr = label.isEmpty ? "" : " [\(label)]"
        print("🔍 Canvas Layout\(labelStr)")
        print("   PDF Canvas frame: \(pdfDrawingCanvas?.frame ?? .zero)")
        print("   PDF Canvas bounds: \(pdfDrawingCanvas?.bounds ?? .zero)")
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
            self?.maybeSwitchToSelectIfDescendant(of: paperView, editingObject: note.object)
        }
        let tvObs = NotificationCenter.default.addObserver(
            forName: UITextView.textDidBeginEditingNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.maybeSwitchToSelectIfDescendant(of: paperView, editingObject: note.object)
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
        guard let toolPicker = pencilKitToolPicker else { return }
        if let activeCanvas = activeDrawingLayer == .pdf ? pdfDrawingCanvas : marginDrawingCanvas {
            toolPicker.setVisible(true, forFirstResponder: activeCanvas)
        }
    }

    func hideToolPicker() {
        guard let toolPicker = pencilKitToolPicker else { return }
        if let pdfCanvas = pdfDrawingCanvas {
            toolPicker.setVisible(false, forFirstResponder: pdfCanvas)
        }
        if let marginCanvas = marginDrawingCanvas {
            toolPicker.setVisible(false, forFirstResponder: marginCanvas)
        }
    }

    /// Get the currently active drawing canvas
    var activeCanvas: PKCanvasView? {
        return activeDrawingLayer == .pdf ? pdfDrawingCanvas : marginDrawingCanvas
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
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        // ✅ Check what tool is about to draw
        print("✍️ [DRAW-START] About to draw")

        if let tool = canvasView.tool as? PKInkingTool {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            tool.color.getRed(&r, green: &g, blue: &b, alpha: nil)
            print("   Tool: \(tool.inkType.rawValue), color RGB(\(Int(r*255)), \(Int(g*255)), \(Int(b*255))), width=\(tool.width)")
        } else if canvasView.tool is PKEraserTool {
            print("   Tool: Eraser")
        }

        // Which canvas drew?
        let whichCanvas = canvasView === pdfDrawingCanvas ? "PDF" : (canvasView === marginDrawingCanvas ? "MARGIN" : "UNKNOWN")
        print("✍️ [CANVAS DREW]")
        print("   Which canvas: \(whichCanvas)")

        if let tool = canvasView.tool as? PKInkingTool {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            tool.color.getRed(&r, green: &g, blue: &b, alpha: nil)
            print("   Tool color: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255))")
        }

        print("   Drawing stroke count: \(canvasView.drawing.strokes.count)")
        if let lastStroke = canvasView.drawing.strokes.last {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            lastStroke.ink.color.getRed(&r, green: &g, blue: &b, alpha: nil)
            print("   Last stroke color: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255))")
        }

        // Save drawings
        if canvasView === pdfDrawingCanvas {
            guard let transformer = transformer else { return }
            let normalized = transformer.normalizeDrawingFromCanvasToPDF(canvasView.drawing)
            pdfAnchoredDrawings[currentPageIndex] = normalized
            onDrawingChanged?(currentPageIndex, normalized, marginDrawings[currentPageIndex])
        } else if canvasView === marginDrawingCanvas {
            marginDrawings[currentPageIndex] = canvasView.drawing
            onDrawingChanged?(currentPageIndex, pdfAnchoredDrawings[currentPageIndex], canvasView.drawing)
        }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        // Track tool changes
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        // Sync tools between canvases
        if canvasView === pdfDrawingCanvas, let marginCanvas = marginDrawingCanvas {
            marginCanvas.tool = canvasView.tool
        } else if canvasView === marginDrawingCanvas, let pdfCanvas = pdfDrawingCanvas {
            pdfCanvas.tool = canvasView.tool
        }
    }
}

// MARK: - UIDropInteraction Delegate
extension UnifiedBoardCanvasController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        return canvasMode == .selecting && session.hasItemsConforming(toTypeIdentifiers: ["public.json"])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        autoSwitchToSelectMode()
    }
}

// MARK: - UIGestureRecognizerDelegate
extension UnifiedBoardCanvasController: UIGestureRecognizerDelegate {

    /// Allow multiple gesture recognizers to work simultaneously
    /// This is crucial for sidebar edge pan and drawing gestures
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
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
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
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
    func setInkTool(_ ink: PKInkingTool.InkType, color: UIColor, width: CGFloat) {
        // DEBUG: What color is the toolbar actually sending?
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        print("🎨 [TOOLBAR] Sent color: R=\(Int(r*255)), G=\(Int(g*255)), B=\(Int(b*255)), A=\(Int(a*255))")

        let tool = PKInkingTool(ink, color: color, width: width)

        print("🎨 [TOOL-ASSIGN] BEFORE assignment")
        print("   New tool: \(ink.rawValue), color RGB(\(Int(r*255)), \(Int(g*255)), \(Int(b*255))), width=\(width)")

        // Check what tool is currently on canvas
        if let currentTool = pdfDrawingCanvas?.tool as? PKInkingTool {
            var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0
            currentTool.color.getRed(&cr, green: &cg, blue: &cb, alpha: nil)
            print("   Current tool on canvas: \(currentTool.inkType.rawValue), color RGB(\(Int(cr*255)), \(Int(cg*255)), \(Int(cb*255)))")
        }

        // Canvas validity check
        print("🔍 pdfDrawingCanvas validity check:")
        print("   pdfDrawingCanvas is nil: \(pdfDrawingCanvas == nil ? "YES ❌" : "NO ✅")")

        // Try assigning with direct reference
        if let canvas = pdfDrawingCanvas {
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

        // ✅ CRITICAL: Store the tool so it persists if canvases are recreated
        currentInkingTool = tool
        currentEraserTool = nil

        pdfDrawingCanvas?.tool = tool
        marginDrawingCanvas?.tool = tool
        previousTool = tool

        print("🎨 [TOOL-ASSIGN] AFTER assignment")

        // Final verification
        if let canvas = pdfDrawingCanvas, let finalTool = canvas.tool as? PKInkingTool {
            var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0
            finalTool.color.getRed(&fr, green: &fg, blue: &fb, alpha: nil)
            print("   Final tool on canvas: \(finalTool.inkType.rawValue), color RGB(\(Int(fr*255)), \(Int(fg*255)), \(Int(fb*255)))")
        }

        // Verify tools were actually set
        print("🖊️ setInkTool: \(ink.rawValue) width=\(width)")
        print("   pdfCanvas.tool: \(pdfDrawingCanvas?.tool != nil ? "✅ SET" : "❌ NIL")")
        print("   marginCanvas.tool: \(marginDrawingCanvas?.tool != nil ? "✅ SET" : "❌ NIL")")
        print("   ✅ Stored in currentInkingTool for persistence")
        // NO setCanvasMode() call - toolbar callback controls mode
    }

    func setEraser() {
        let eraser = PKEraserTool(.vector)

        // ✅ CRITICAL: Store the eraser so it persists if canvases are recreated
        currentEraserTool = eraser
        currentInkingTool = nil

        pdfDrawingCanvas?.tool = eraser
        marginDrawingCanvas?.tool = eraser
        previousTool = eraser  // ✅ FIX: Update previousTool so lasso restore uses eraser

        // Verify tools were actually set
        print("🧽 setEraser")
        print("   pdfCanvas.tool: \(pdfDrawingCanvas?.tool != nil ? "✅ SET" : "❌ NIL")")
        print("   marginCanvas.tool: \(marginDrawingCanvas?.tool != nil ? "✅ SET" : "❌ NIL")")
        // NO setCanvasMode() call - toolbar callback controls mode
    }

    func beginLassoSelection() {
        lassoController?.beginLasso()
        setCanvasMode(.selecting)
    }

    func endLassoSelection() {
        lassoController?.endLassoAndRestorePreviousTool()
        setCanvasMode(.drawing)
    }

    func undo() {
        activeCanvas?.undoManager?.undo()
    }

    func redo() {
        activeCanvas?.undoManager?.redo()
    }
}
