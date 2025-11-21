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
            print("🎨 Canvas mode changed to: \(canvasMode)")
        }
    }
    
    // Canvas size (includes PDF + margins) - logical size, not visual size
    private(set) var canvasSize: CGSize = .zero
    
    // Container view that holds all layers - fills the entire view controller
    private let containerView = UIView()
    
    // Layer 1: PaperKit (markup)
    private(set) var paperKitController: PaperMarkupViewController?
    private var paperKitView: UIView?
    
    // Layer 2: PencilKit (drawing)
    private(set) var pencilKitCanvas: PKCanvasView?
    private var pencilKitToolPicker: PKToolPicker?
    
    // Layer 3: Interactive overlay for mode switching
    private let modeInterceptor = UIView()
    
    // Gesture recognizers
    private var tapGestureRecognizer: UITapGestureRecognizer?

    // Observers for form focus (TextField/TextView)
    private var interactionObservers: [NSObjectProtocol] = []

    // Optional: keep a reference if you want to remove/replace later
    private var panGestureRecognizer: UIPanGestureRecognizer?

    // Lasso controller for PencilKit selection
    private var lassoController: PKLassoSelectionController?

    // Callbacks
    var onModeChanged: ((CanvasMode) -> Void)?
    var onPaperKitItemAdded: (() -> Void)?
    
    // Alignment state
    private(set) var currentAlignment: PDFAlignment = .center
    
    // MARK: - Initialization
    
    override func viewDidLoad() {
        super.viewDidLoad()
        print("📱 UnifiedBoardCanvasController viewDidLoad")
        view.backgroundColor = .clear
        view.isOpaque = false
        setupContainerView()
        setupModeInterceptor()
        print("✅ Setup complete")
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("📱 UnifiedBoardCanvasController viewDidAppear - actual bounds: \(view.bounds)")
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
        
        print("✅ Container view set up with Auto Layout")
    }
    
    // MARK: - Public API
    
    /// Initialize canvas with size (PDF + margins)
    func initializeCanvas(size: CGSize) {
        canvasSize = size
        print("📐 Canvas initialized: logical size=\(size)")
    }
    
    /// Setup PaperKit layer
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

        // 🔑 Set contentView to suppress PaperKit's default white background
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

        print("✅ PaperKit setup complete")
    }
    
    /// Setup PencilKit layer (goes on top)
    func setupPencilKit() {
        // Clean up old PencilKit if it exists
        if let existingCanvas = pencilKitCanvas {
            existingCanvas.removeFromSuperview()
        }
        
        let canvas = PKCanvasView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(canvas)
        
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: containerView.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        
        let toolPicker = PKToolPicker()
        toolPicker.setVisible(false, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
        
        pencilKitCanvas = canvas
        pencilKitToolPicker = toolPicker

        // Initialize lasso controller for selection operations
        lassoController = PKLassoSelectionController(canvasView: canvas)

        // Set initial tool
        canvas.tool = PKInkingTool(.pen, color: .black, width: 2)

        print("✅ PencilKit setup complete")
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

        print("✅ Mode interceptor setup complete")
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
            pencilKitCanvas?.isUserInteractionEnabled = true
            paperKitView?.isUserInteractionEnabled   = false
            // IMPORTANT: keep the interceptor enabled so it can *observe* and flip to select
            modeInterceptor.isUserInteractionEnabled = true
            print("🎯 Drawing mode: PencilKit enabled, interceptor watching")

        case .selecting:
            pencilKitCanvas?.isUserInteractionEnabled = false
            paperKitView?.isUserInteractionEnabled   = true
            modeInterceptor.isUserInteractionEnabled = true
            print("🎯 Select mode: PaperKit enabled")

        case .idle:
            pencilKitCanvas?.isUserInteractionEnabled = false
            paperKitView?.isUserInteractionEnabled   = false
            modeInterceptor.isUserInteractionEnabled = false
            print("🎯 Idle mode: All disabled")
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
}

// MARK: - PDF Alignment Enum
enum PDFAlignment: Equatable {
    case left
    case center
    case right
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
