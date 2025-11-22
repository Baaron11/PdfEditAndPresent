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
        // At this point containerView has a real size - reapply transforms
        print("🧩 viewDidLayoutSubviews container bounds=\(containerView.bounds)")
        applyTransforms()

        // Debug prints for canvas frames
        if let pdfCanvas = pdfDrawingCanvas {
            print("🎯 pdfCanvas frame=\(pdfCanvas.frame) bounds=\(pdfCanvas.bounds)")
        }
        print("🎯 containerView frame=\(containerView.frame) bounds=\(containerView.bounds)")
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
        canvas.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: host.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        canvas.backgroundColor = UIColor.blue.withAlphaComponent(0.2)
        canvas.isOpaque = false

        let debugLabel = UILabel()
        debugLabel.text = "Canvas"
        debugLabel.textColor = .blue
        debugLabel.font = .systemFont(ofSize: 12, weight: .bold)
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(debugLabel)
        NSLayoutConstraint.activate([
            debugLabel.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 10),
            debugLabel.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 10)
        ])

        // Prevent canvas from rendering outside its bounds
        canvas.clipsToBounds = true
        canvas.layer.masksToBounds = true

        canvas.isUserInteractionEnabled = false
        canvas.allowsFingerDrawing = true
        canvas.drawingPolicy = .anyInput

        // Sanity toggles - prevent internal zoom/scroll
        canvas.maximumZoomScale = 1.0
        canvas.minimumZoomScale = 1.0
        canvas.isScrollEnabled = false
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
        let shouldInteract = (canvasMode == .drawing)

        print("🎯 Canvas interaction: \(shouldInteract ? "ENABLED" : "DISABLED") (mode=\(canvasMode))")

        pdfDrawingCanvas?.isUserInteractionEnabled = shouldInteract
        marginDrawingCanvas?.isUserInteractionEnabled = shouldInteract

        if !shouldInteract {
            pdfDrawingCanvas?.resignFirstResponder()
            marginDrawingCanvas?.resignFirstResponder()
        }
    }

    /// Enable or disable drawing on PKCanvasViews
    func enableDrawing(_ enabled: Bool) {
        pdfDrawingCanvas?.isUserInteractionEnabled = enabled
        marginDrawingCanvas?.isUserInteractionEnabled = enabled
        if enabled {
            pdfDrawingCanvas?.becomeFirstResponder()
        }
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
        pinCanvas(pdfCanvas, to: containerView)
        pdfCanvas.delegate = self

        // Create margin-anchored canvas (Layer 3)
        let marginCanvas = PKCanvasView()
        pinCanvas(marginCanvas, to: containerView)
        marginCanvas.delegate = self

        // Shared tool picker
        let toolPicker = PKToolPicker()
        toolPicker.setVisible(false, forFirstResponder: pdfCanvas)
        toolPicker.addObserver(pdfCanvas)
        toolPicker.addObserver(marginCanvas)

        pdfDrawingCanvas = pdfCanvas
        marginDrawingCanvas = marginCanvas
        pencilKitToolPicker = toolPicker

        // Enable multi-touch for both canvases
        pdfCanvas.isMultipleTouchEnabled = true
        marginCanvas.isMultipleTouchEnabled = true
        pdfCanvas.becomeFirstResponder()

        // Initialize lasso controller with the active canvas
        lassoController = PKLassoSelectionController(canvasView: pdfCanvas)

        // Set initial tool
        let defaultTool = PKInkingTool(.pen, color: .black, width: 2)
        pdfCanvas.tool = defaultTool
        marginCanvas.tool = defaultTool
        previousTool = defaultTool

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
        self.canvasMode = mode
        updateCanvasInteractionState()
        onModeChanged?(mode)
        onCanvasModeChanged?(mode)
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

        // Apply display transform to pdfHost (PaperKit) only
        let displayTransform = transformer.displayTransform
        paperKitView?.transform = displayTransform

        // PKCanvasViews stay at identity transform - they fill the container
        // Strokes are normalized/denormalized through the transformer when saving/loading
        // Applying transforms to PKCanvasView breaks touch input coordinates
        pdfDrawingCanvas?.transform = .identity
        marginDrawingCanvas?.transform = .identity

        // Note: Don't set frame manually - Auto Layout constraints handle sizing
        // This was causing zero-size frames when called before layout

        // Update margin canvas visibility based on margins enabled
        marginDrawingCanvas?.isHidden = !marginSettings.isEnabled

        print("🧩 Transforms applied, canvas bounds=\(containerView.bounds.size)")
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
            enableDrawing(true)
            paperKitView?.isUserInteractionEnabled = false
            // Keep interceptor enabled to observe and flip to select
            modeInterceptor.isUserInteractionEnabled = true
            print("🖊️ Drawing mode active — PKCanvasViews enabled")
            print("🎯 pdfCanvas isUserInteractionEnabled=\(pdfDrawingCanvas?.isUserInteractionEnabled ?? false)")

        case .selecting:
            enableDrawing(false)
            paperKitView?.isUserInteractionEnabled = true
            modeInterceptor.isUserInteractionEnabled = true
            print("Select mode: PaperKit enabled")

        case .idle:
            enableDrawing(false)
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
        let tool = PKInkingTool(ink, color: color, width: width)
        pdfDrawingCanvas?.tool = tool
        marginDrawingCanvas?.tool = tool
        previousTool = tool
        setCanvasMode(.drawing)
        print("🖊️ setInk \(ink) width=\(width)")
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
