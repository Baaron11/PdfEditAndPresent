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

    // SINGLE CANVAS: Oversized, masked to show drawable area
    private(set) var pdfDrawingCanvas: PKCanvasView?

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

    // Coordinate transformer
    private var transformer: DrawingCoordinateTransformer?

    // Margin settings for current page
    private(set) var marginSettings: MarginSettings = MarginSettings()

    // Per-page drawing storage
    private var pdfAnchoredDrawings: [Int: PKDrawing] = [:]
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

    // PDFManager reference for querying page sizes
    weak var pdfManager: PDFManager?

    private var currentZoomLevel: CGFloat = 1.0
    private var currentPageRotation: Int = 0

    // MARK: - Dynamic Canvas Size Helpers

    /// Get the current page size from PDFManager
    private func getCurrentPageSize() -> CGSize {
        if let pdfManager = pdfManager {
            return pdfManager.effectiveSize(for: currentPageIndex)
        }
        // Fallback to stored canvasSize if PDFManager unavailable
        return canvasSize
    }

    /// Calculate expansion ratio based on minimum allowed margin scale
    /// If margins can scale to 10%, we need 90% extra space on all sides
    private func getMarginExpansionRatio() -> CGFloat {
        // Minimum margin scale is how small the PDF can get
        // Expansion ratio = how much space we need beyond that
        let minimumMarginScale = marginSettings.minimumMarginScale  // e.g., 0.10
        let expansionRatio = 1.0 - minimumMarginScale

        print("📐 [EXPANSION] Margin scale range: \(minimumMarginScale * 100)% - 100%")
        print("📐 [EXPANSION] Expansion ratio needed: \(expansionRatio * 100)%")

        return expansionRatio
    }

    /// Calculate oversized canvas size based on current page and margin settings
    private var expandedCanvasSize: CGSize {
        let pageSize = getCurrentPageSize()
        let expansionRatio = getMarginExpansionRatio()

        let horizontalMargin = pageSize.width * expansionRatio
        let verticalMargin = pageSize.height * expansionRatio

        let width = pageSize.width + (horizontalMargin * 2)
        let height = pageSize.height + (verticalMargin * 2)

        print("📐 [SIZE] Page: \(pageSize)")
        print("📐 [SIZE] Expanded canvas: \(width) × \(height)")

        return CGSize(width: width, height: height)
    }

    /// Calculate where PDF sits within the expanded canvas
    private var pdfOffsetInCanvas: CGPoint {
        let pageSize = getCurrentPageSize()
        let expansionRatio = getMarginExpansionRatio()

        let xOffset = pageSize.width * expansionRatio
        let yOffset = pageSize.height * expansionRatio

        return CGPoint(x: xOffset, y: yOffset)
    }

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
        if let canvas = pdfDrawingCanvas {
            print("📍 [LAYOUT]   pdfDrawingCanvas ACTUAL frame: \(canvas.frame)")
            print("📍 [LAYOUT]   pdfDrawingCanvas ACTUAL bounds: \(canvas.bounds)")
            print("📍 [LAYOUT]   pdfDrawingCanvas transform: \(canvas.transform)")
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
        let expanded = expandedCanvasSize  // Use dynamic expanded size

        print("📐 [CONSTRAINT] pinCanvas() called")
        print("📐 [CONSTRAINT]   Page size: \(getCurrentPageSize())")
        print("📐 [CONSTRAINT]   Setting expanded size: \(expanded.width) × \(expanded.height)")

        canvas.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(canvas)

        // Constrain canvas to EXPANDED size (allows drawing beyond PDF in margin area)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: host.topAnchor),
            canvas.widthAnchor.constraint(equalToConstant: expanded.width),
            canvas.heightAnchor.constraint(equalToConstant: expanded.height)
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
        canvas.clipsToBounds = true
        canvas.layer.masksToBounds = true

        print("📐 [CONSTRAINT]   Constraints activated")
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

        if !shouldInteract {
            pdfDrawingCanvas?.resignFirstResponder()
        }

        // Update mask - ensure it's applied in drawing mode
        if shouldInteract {
            updateCanvasMask()
        }
    }

    /// Enable or disable drawing on PKCanvasView
    func enableDrawing(_ enabled: Bool) {
        pdfDrawingCanvas?.isUserInteractionEnabled = enabled
        if enabled {
            pdfDrawingCanvas?.becomeFirstResponder()
        }
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

    /// Setup single oversized PencilKit canvas
    func setupPencilKit() {
        print("🎛️ [LIFECYCLE] setupPencilKit() called")
        print("🎛️ [LIFECYCLE]   Page size: \(getCurrentPageSize())")
        print("🎛️ [LIFECYCLE]   Expanded canvas: \(expandedCanvasSize)")
        print("🎛️ [LIFECYCLE]   Current pageRotation: \(currentPageRotation)°")

        // Clean up old canvas
        pdfDrawingCanvas?.removeFromSuperview()

        // Create SINGLE canvas (oversized for drawing + margins)
        let canvas = PKCanvasView()
        pdfDrawingCanvas = canvas
        print("🎛️ [LIFECYCLE]   Creating single oversized PKCanvasView")
        pinCanvas(canvas, to: containerView)
        canvas.delegate = self

        // Shared tool picker
        let toolPicker = PKToolPicker()
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
        pencilKitToolPicker = toolPicker

        // Setup canvas
        canvas.isMultipleTouchEnabled = true
        canvas.becomeFirstResponder()

        // Initialize lasso controller with the single canvas
        lassoController = PKLassoSelectionController(canvasView: canvas)

        // Reconfigure canvas constraints
        reconfigureCanvasConstraints()

        // Set initial tool
        let defaultTool = PKInkingTool(.pen, color: .black, width: 2)
        canvas.tool = defaultTool
        previousTool = defaultTool

        // Bring canvas to front
        view.bringSubviewToFront(containerView)
        containerView.bringSubviewToFront(canvas)
        containerView.bringSubviewToFront(modeInterceptor)

        // Apply initial transforms
        applyTransforms()

        // Initialize mask - CRITICAL for showing only drawable area
        updateCanvasMask()

        print("✅ Canvas size: \(expandedCanvasSize)")
        print("✅ Single oversized PencilKit canvas setup complete")
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
        print("📐 [SETTINGS] Margin settings updated")
        print("📐 [SETTINGS]   Enabled: \(settings.isEnabled)")
        print("📐 [SETTINGS]   Scale: \(settings.pdfScale * 100)%")
        print("📐 [SETTINGS]   Min scale: \(settings.minimumMarginScale * 100)%")
        print("📐 [SETTINGS]   Anchor: \(settings.anchorPosition)")

        marginSettings = settings
        rebuildTransformer()

        // If minimum scale changed, expansion ratio changes
        let newExpansion = getMarginExpansionRatio()
        print("📐 [SETTINGS]   Expansion ratio: \(newExpansion * 100)%")
        print("📐 [SETTINGS]   Expanded canvas: \(expandedCanvasSize)")

        // Update mask when margins change
        updateCanvasMask()

        applyTransforms()
    }

    /// Set current page index and load drawings
    func setCurrentPage(_ pageIndex: Int) {
        print("📄 [PAGE] Switching to page \(pageIndex + 1)")
        print("📄 [PAGE]   Previous page: \(currentPageIndex + 1)")

        // Save current page drawings before switching
        saveCurrentPageDrawings()

        currentPageIndex = pageIndex

        // Get the actual page size from PDFManager for this specific page
        if let pdfManager = pdfManager {
            let pageSize = pdfManager.effectiveSize(for: pageIndex)
            print("📄 [PAGE]   New page size: \(pageSize)")
            canvasSize = pageSize
        } else {
            print("📄 [PAGE]   WARNING: pdfManager is nil, keeping canvasSize: \(canvasSize)")
        }

        // Log dynamic expansion calculations
        let newPageSize = getCurrentPageSize()
        let expanded = expandedCanvasSize
        let expansionRatio = getMarginExpansionRatio()
        print("📄 [PAGE]   Page size from PDFManager: \(newPageSize)")
        print("📄 [PAGE]   Expansion ratio: \(expansionRatio * 100)%")
        print("📄 [PAGE]   Expanded canvas size: \(expanded)")

        loadPageDrawings(for: pageIndex)
        rebuildTransformer()

        // Reconfigure canvas constraints for the new page size
        reconfigureCanvasConstraints()

        // Reapply transforms and update mask
        applyTransforms()
        updateCanvasMask()

        print("📄 [PAGE]   Page \(pageIndex + 1) loaded successfully")
    }

    /// Get drawing for a page (stored in canvas space, mask handles visibility)
    func getDrawing(for pageIndex: Int) -> PKDrawing {
        return pdfAnchoredDrawings[pageIndex] ?? PKDrawing()
    }

    /// Set drawing for a page
    func setDrawing(_ drawing: PKDrawing, for pageIndex: Int) {
        pdfAnchoredDrawings[pageIndex] = drawing
        if pageIndex == currentPageIndex {
            pdfDrawingCanvas?.drawing = drawing
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

        guard let canvas = pdfDrawingCanvas else {
            print("🔄 [TRANSFORM] No canvas to transform")
            return
        }

        let pageSize = getCurrentPageSize()
        let expanded = expandedCanvasSize

        print("🔄 [TRANSFORM] applyTransforms() called")
        print("🔄 [TRANSFORM]   Page size: \(pageSize.width) x \(pageSize.height)")
        print("🔄 [TRANSFORM]   Expanded canvas: \(expanded.width) x \(expanded.height)")
        print("🔄 [TRANSFORM]   Rotation: \(currentPageRotation)°")
        print("🔄 [TRANSFORM]   containerView.bounds: \(containerView.bounds)")

        // Apply display transform to pdfHost (PaperKit) only
        let displayTransform = transformer.displayTransform
        paperKitView?.transform = displayTransform

        // Calculate rotation
        let rotationRadians = CGFloat(currentPageRotation) * .pi / 180.0
        let isRotated90or270 = (currentPageRotation == 90 || currentPageRotation == 270)

        print("🔄 [TRANSFORM]   rotationRadians: \(rotationRadians)")
        print("🔄 [TRANSFORM]   isRotated90or270: \(isRotated90or270)")

        // Frame size after rotation (dimensions swap for 90°/270°)
        let frameWidth: CGFloat
        let frameHeight: CGFloat

        if isRotated90or270 {
            frameWidth = expanded.height   // swapped
            frameHeight = expanded.width   // swapped
        } else {
            frameWidth = expanded.width
            frameHeight = expanded.height
        }

        print("🔄 [TRANSFORM]   Frame after rotation: \(frameWidth) x \(frameHeight)")

        // Update container bounds to match rotated expanded canvas dimensions
        containerView.bounds = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)

        // Set bounds and center
        canvas.bounds = CGRect(origin: .zero, size: expanded)
        canvas.center = CGPoint(x: frameWidth / 2, y: frameHeight / 2)

        // Apply rotation
        let rotationTransform = CGAffineTransform(rotationAngle: rotationRadians)
        canvas.transform = rotationTransform

        print("🔄 [TRANSFORM]   Canvas transform applied")

        // ✅ CRITICAL: Update mask after transforms
        updateCanvasMask()

        print("🔄 [TRANSFORM]   Final containerView.bounds: \(containerView.bounds)")
    }

    /// Update the mask that clips the dynamically-sized canvas to show only valid drawing area
    private func updateCanvasMask() {
        print("🎭 [MASK] Updating canvas mask")

        guard let canvas = pdfDrawingCanvas else {
            print("🎭 [MASK] No canvas to mask")
            return
        }

        let settings = marginSettings
        let pageSize = getCurrentPageSize()  // Get from PDFManager dynamically
        let offset = pdfOffsetInCanvas       // Automatically calculated from expansion ratio
        let expanded = expandedCanvasSize    // Dynamically calculated
        let isRotated90or270 = currentPageRotation == 90 || currentPageRotation == 270

        // TRUE PAGE DIMENSIONS - swap for 90°/270° rotations
        let truePageWidth: CGFloat = isRotated90or270 ? pageSize.height : pageSize.width
        let truePageHeight: CGFloat = isRotated90or270 ? pageSize.width : pageSize.height

        // CONTAINER DIMENSIONS - dynamically calculated based on margin settings
        let containerWidth: CGFloat = isRotated90or270 ? expanded.height : expanded.width
        let containerHeight: CGFloat = isRotated90or270 ? expanded.width : expanded.height

        print("🎭 [MASK]   Page size: \(pageSize)")
        print("🎭 [MASK]   Expanded canvas: \(expanded)")
        print("🎭 [MASK]   Container: \(containerWidth) x \(containerHeight)")
        print("🎭 [MASK]   PDF offset in canvas: \(offset)")
        print("🎭 [MASK]   Margins enabled: \(settings.isEnabled)")

        // Create mask if needed
        if canvas.layer.mask == nil {
            let maskLayer = CAShapeLayer()
            maskLayer.fillColor = UIColor.black.cgColor
            canvas.layer.mask = maskLayer
            print("🎭 [MASK]   Created new mask layer")
        }

        guard let maskLayer = canvas.layer.mask as? CAShapeLayer else {
            print("🎭 [MASK]   ERROR: Could not get mask layer")
            return
        }

        // Calculate mask rect based on margins
        let maskRect: CGRect

        if settings.isEnabled {
            // MARGINS ENABLED: Scale down the visible area
            let scaledWidth = truePageWidth * settings.pdfScale
            let scaledHeight = truePageHeight * settings.pdfScale

            let anchorX = CGFloat(settings.anchorPosition.gridPosition.col) / 2.0  // 0, 0.5, 1.0
            let anchorY = CGFloat(settings.anchorPosition.gridPosition.row) / 2.0  // 0, 0.5, 1.0

            // Position based on anchor and centering in expanded canvas
            let offsetX = (containerWidth - scaledWidth) * anchorX
            let offsetY = (containerHeight - scaledHeight) * anchorY

            maskRect = CGRect(x: offsetX, y: offsetY, width: scaledWidth, height: scaledHeight)

            print("🎭 [MASK]   Margins applied:")
            print("🎭 [MASK]   - Scale: \(settings.pdfScale * 100)%")
            print("🎭 [MASK]   - Anchor: \(settings.anchorPosition)")
            print("🎭 [MASK]   - Mask rect: \(maskRect)")
        } else {
            // MARGINS DISABLED: Show full page centered in expanded canvas
            let offsetX = (containerWidth - truePageWidth) / 2.0
            let offsetY = (containerHeight - truePageHeight) / 2.0

            maskRect = CGRect(x: offsetX, y: offsetY, width: truePageWidth, height: truePageHeight)

            print("🎭 [MASK]   Margins disabled - showing full page")
            print("🎭 [MASK]   - Mask rect: \(maskRect)")
        }

        // Update mask path
        let maskPath = UIBezierPath(rect: maskRect)
        maskLayer.path = maskPath.cgPath

        print("🎭 [MASK]   Mask updated successfully")
    }

    private func reconfigureCanvasConstraints() {
        guard let canvas = pdfDrawingCanvas else { return }

        // Deactivate old constraints
        canvas.constraints.forEach { $0.isActive = false }

        // Re-pin with new canvasSize
        canvas.removeFromSuperview()
        pinCanvas(canvas, to: containerView)

        // Force layout update
        containerView.setNeedsLayout()
        containerView.layoutIfNeeded()

        print("🎯 Canvas constraints reconfigured:")
        print("🎯   Page size: \(getCurrentPageSize())")
        print("🎯   Expanded canvas: \(expandedCanvasSize)")
    }

    // MARK: - Drawing Persistence

    private func saveCurrentPageDrawings() {
        guard let canvas = pdfDrawingCanvas else { return }

        // Store drawing directly - mask handles what's visible
        pdfAnchoredDrawings[currentPageIndex] = canvas.drawing

        onDrawingChanged?(currentPageIndex, canvas.drawing, nil)
    }

    private func loadPageDrawings(for pageIndex: Int) {
        let drawing = pdfAnchoredDrawings[pageIndex] ?? PKDrawing()
        pdfDrawingCanvas?.drawing = drawing
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
            modeInterceptor.isUserInteractionEnabled = false
            print("🖊️ Drawing mode active — PKCanvasView enabled")
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

        guard let paperView = paperKitView else { return }
        let p = gr.location(in: paperView)
        let hit = paperView.hitTest(p, with: nil)
        if isInteractiveElement(hit) {
            autoSwitchToSelectMode()
        }
    }

    @objc private func handlePaperKitPan(_ gr: UIPanGestureRecognizer) {
        guard canvasMode == .drawing else { return }

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
              let canvas = pdfDrawingCanvas else { return }
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    func hideToolPicker() {
        guard let toolPicker = pencilKitToolPicker,
              let canvas = pdfDrawingCanvas else { return }
        toolPicker.setVisible(false, forFirstResponder: canvas)
    }

    /// Get the currently active drawing canvas
    var activeCanvas: PKCanvasView? {
        return pdfDrawingCanvas
    }

    /// Update zoom and rotation from SwiftUI view
    func updateZoomAndRotation(_ zoomLevel: CGFloat, _ rotation: Int) {
        if zoomLevel != currentZoomLevel {
            currentZoomLevel = zoomLevel
            print("🔍 Canvas zoom updated: \(Int(zoomLevel * 100))%")
        }

        if rotation != currentPageRotation {
            currentPageRotation = rotation
            print("🔄 Canvas rotation updated: \(rotation)°")
            // Apply the rotation transform to canvas views
            applyTransforms()
        }
    }
}

// MARK: - Diagnostics

extension UnifiedBoardCanvasController {
    /// Print complete view hierarchy of containerView
    func printViewHierarchy() {
        print("\n🔍 [DIAGNOSTIC] VIEW HIERARCHY")
        print("containerView subviews count: \(containerView.subviews.count)")
        printViewTree(containerView, indent: 0)
        print("")
    }

    private func printViewTree(_ view: UIView, indent: Int) {
        let indentation = String(repeating: "  ", count: indent)
        let typeName = String(describing: type(of: view))
        print("\(indentation)├─ \(typeName): frame=\(view.frame), bounds=\(view.bounds), hidden=\(view.isHidden), opaque=\(view.isOpaque)")

        for subview in view.subviews {
            printViewTree(subview, indent: indent + 1)
        }
    }

    /// Check canvas instance state
    func verifyCanvasInstances(label: String) {
        print("\n🔍 [DIAGNOSTIC] CANVAS INSTANCE - \(label)")
        print("pdfDrawingCanvas instance: \(Unmanaged.passUnretained(pdfDrawingCanvas as AnyObject).toOpaque()) - isHidden: \(pdfDrawingCanvas?.isHidden ?? true)")
        print("")
    }

    /// Inspect all constraints affecting the canvas
    func printCanvasConstraints() {
        print("\n🔍 [DIAGNOSTIC] CANVAS CONSTRAINTS")

        if let canvas = pdfDrawingCanvas {
            print("pdfDrawingCanvas constraints:")
            for constraint in canvas.constraints {
                print("  - \(constraint)")
            }
        }

        print("\ncontainerView constraints affecting canvas:")
        for constraint in containerView.constraints {
            if (constraint.firstItem as? UIView) === pdfDrawingCanvas ||
               (constraint.secondItem as? UIView) === pdfDrawingCanvas {
                print("  - \(constraint)")
            }
        }
        print("")
    }

    /// Check canvas drawing state
    func printCanvasDrawingState() {
        print("\n🔍 [DIAGNOSTIC] CANVAS DRAWING STATE")

        if let canvas = pdfDrawingCanvas {
            print("pdfDrawingCanvas:")
            print("  - drawing.strokes.count: \(canvas.drawing.strokes.count)")
            print("  - drawing.bounds: \(canvas.drawing.bounds)")
            print("  - isUserInteractionEnabled: \(canvas.isUserInteractionEnabled)")
            print("  - backgroundColor: \(canvas.backgroundColor as Any)")
            print("  - alpha: \(canvas.alpha)")
        }
        print("")
    }

    /// Check layer ordering and rendering
    func printLayerOrdering() {
        print("\n🔍 [DIAGNOSTIC] LAYER ORDERING")

        for (index, subview) in containerView.subviews.enumerated() {
            var description = "\(index): \(String(describing: type(of: subview)))"

            if subview === pdfDrawingCanvas {
                description += " [pdfDrawingCanvas]"
            } else if subview === paperKitView {
                description += " [paperKitView]"
            } else if subview === modeInterceptor {
                description += " [modeInterceptor]"
            }

            print("  \(description) - frame: \(subview.frame), hidden: \(subview.isHidden)")
        }
        print("")
    }

    /// Check transform states
    func printTransformStates() {
        print("\n🔍 [DIAGNOSTIC] TRANSFORM STATES")

        print("pdfDrawingCanvas:")
        if let canvas = pdfDrawingCanvas {
            print("  - transform: \(canvas.transform)")
            print("  - bounds: \(canvas.bounds)")
            print("  - frame: \(canvas.frame)")
            print("  - center: \(canvas.center)")
        }

        print("containerView:")
        print("  - bounds: \(containerView.bounds)")
        print("  - frame: \(containerView.frame)")
        print("")
    }

    /// Master diagnostic - call this to get full picture
    func runFullDiagnostics(label: String) {
        print("\n" + String(repeating: "=", count: 60))
        print("🔍 [FULL DIAGNOSTIC] \(label)")
        print(String(repeating: "=", count: 60))

        printViewHierarchy()
        verifyCanvasInstances(label: label)
        printCanvasConstraints()
        printCanvasDrawingState()
        printLayerOrdering()
        printTransformStates()

        print(String(repeating: "=", count: 60) + "\n")
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
        // Single canvas - store drawing directly
        pdfAnchoredDrawings[currentPageIndex] = canvasView.drawing
        onDrawingChanged?(currentPageIndex, canvasView.drawing, nil)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        // Track tool changes
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        // Tool management is simpler with single canvas
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
        previousTool = tool
        setCanvasMode(.drawing)
        print("🖊️ setInk \(ink) width=\(width)")
    }

    func setEraser() {
        let eraser = PKEraserTool(.vector)
        pdfDrawingCanvas?.tool = eraser
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
