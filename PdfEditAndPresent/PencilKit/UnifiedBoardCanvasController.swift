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

    // Alignment state
    private(set) var currentAlignment: PDFAlignment = .center

    // Previous tool for lasso restore
    private var previousTool: PKTool?

    // MARK: - Initialization

    override func viewDidLoad() {
        super.viewDidLoad()
        print("UnifiedBoardCanvasController viewDidLoad")
        view.backgroundColor = .clear
        view.isOpaque = false
        setupContainerView()
        setupModeInterceptor()
        print("Setup complete")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("UnifiedBoardCanvasController viewDidAppear - actual bounds: \(view.bounds)")
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

    // MARK: - Public API

    /// Initialize canvas with size (PDF + margins)
    func initializeCanvas(size: CGSize) {
        canvasSize = size
        rebuildTransformer()
        print("Canvas initialized: logical size=\(size)")
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
        // Clean up old canvases
        pdfDrawingCanvas?.removeFromSuperview()
        marginDrawingCanvas?.removeFromSuperview()

        // Create PDF-anchored canvas (Layer 2)
        let pdfCanvas = PKCanvasView()
        pdfCanvas.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(pdfCanvas)

        NSLayoutConstraint.activate([
            pdfCanvas.topAnchor.constraint(equalTo: containerView.topAnchor),
            pdfCanvas.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            pdfCanvas.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            pdfCanvas.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        pdfCanvas.backgroundColor = .clear
        pdfCanvas.isOpaque = false
        pdfCanvas.drawingPolicy = .anyInput
        pdfCanvas.delegate = self

        // Create margin-anchored canvas (Layer 3)
        let marginCanvas = PKCanvasView()
        marginCanvas.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(marginCanvas)

        NSLayoutConstraint.activate([
            marginCanvas.topAnchor.constraint(equalTo: containerView.topAnchor),
            marginCanvas.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            marginCanvas.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            marginCanvas.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        marginCanvas.backgroundColor = .clear
        marginCanvas.isOpaque = false
        marginCanvas.drawingPolicy = .anyInput
        marginCanvas.delegate = self

        // Shared tool picker
        let toolPicker = PKToolPicker()
        toolPicker.setVisible(false, forFirstResponder: pdfCanvas)
        toolPicker.addObserver(pdfCanvas)
        toolPicker.addObserver(marginCanvas)

        pdfDrawingCanvas = pdfCanvas
        marginDrawingCanvas = marginCanvas
        pencilKitToolPicker = toolPicker

        // Initialize lasso controller with the active canvas
        lassoController = PKLassoSelectionController(canvasView: pdfCanvas)

        // Set initial tool
        let defaultTool = PKInkingTool(.pen, color: .black, width: 2)
        pdfCanvas.tool = defaultTool
        marginCanvas.tool = defaultTool
        previousTool = defaultTool

        // Bring mode interceptor to front
        containerView.bringSubviewToFront(modeInterceptor)

        // Apply initial transforms
        applyTransforms()

        print("Dual PencilKit layers setup complete")
    }

    /// Set canvas mode (drawing, selecting, idle)
    func setCanvasMode(_ mode: CanvasMode) {
        self.canvasMode = mode
        onModeChanged?(mode)
        if mode == .selecting {
            lassoController?.beginLasso()
        } else {
            lassoController?.endLassoAndRestorePreviousTool()
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
    func updateMarginSettings(_ settings: MarginSettings) {
        marginSettings = settings
        rebuildTransformer()
        applyTransforms()
    }

    /// Set current page index and load drawings
    func setCurrentPage(_ pageIndex: Int) {
        // Save current page drawings before switching
        saveCurrentPageDrawings()

        currentPageIndex = pageIndex
        loadPageDrawings(for: pageIndex)
        rebuildTransformer()
        applyTransforms()
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
        guard let transformer = transformer else { return }

        // Apply display transform to pdfHost (PaperKit)
        let displayTransform = transformer.displayTransform
        paperKitView?.transform = displayTransform

        // Apply same transform to pdfDrawingCanvas
        pdfDrawingCanvas?.transform = displayTransform

        // marginDrawingCanvas stays at identity (canvas space)
        marginDrawingCanvas?.transform = .identity

        // Update margin canvas visibility based on margins enabled
        marginDrawingCanvas?.isHidden = !marginSettings.isEnabled
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
            pdfDrawingCanvas?.becomeFirstResponder()
            lassoController?.setTargetCanvas(pdfDrawingCanvas)
        case .margin:
            pdfDrawingCanvas?.isUserInteractionEnabled = false
            marginDrawingCanvas?.isUserInteractionEnabled = true
            marginDrawingCanvas?.becomeFirstResponder()
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
            pdfDrawingCanvas?.isUserInteractionEnabled = true
            marginDrawingCanvas?.isUserInteractionEnabled = true
            paperKitView?.isUserInteractionEnabled = false
            // Keep interceptor enabled to observe and flip to select
            modeInterceptor.isUserInteractionEnabled = true
            print("Drawing mode: PencilKit enabled, interceptor watching")

        case .selecting:
            pdfDrawingCanvas?.isUserInteractionEnabled = false
            marginDrawingCanvas?.isUserInteractionEnabled = false
            paperKitView?.isUserInteractionEnabled = true
            modeInterceptor.isUserInteractionEnabled = true
            print("Select mode: PaperKit enabled")

        case .idle:
            pdfDrawingCanvas?.isUserInteractionEnabled = false
            marginDrawingCanvas?.isUserInteractionEnabled = false
            paperKitView?.isUserInteractionEnabled = false
            modeInterceptor.isUserInteractionEnabled = false
            print("Idle mode: All disabled")
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
            activeCanvas.becomeFirstResponder()
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
        // Determine which canvas changed and save appropriately
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
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        // We only observe; don't cancel PK touches.
        return true
    }
}

// MARK: - Tool API Methods
extension UnifiedBoardCanvasController {
    func setInkTool(_ ink: PKInkingTool.InkType, color: UIColor, width: CGFloat) {
        let tool = PKInkingTool(ink, color: color, width: width)
        pdfDrawingCanvas?.tool = tool
        marginDrawingCanvas?.tool = tool
        previousTool = tool
        setCanvasMode(.drawing)
    }

    func setEraser() {
        let eraser = PKEraserTool(.vector)
        pdfDrawingCanvas?.tool = eraser
        marginDrawingCanvas?.tool = eraser
        setCanvasMode(.drawing)
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
