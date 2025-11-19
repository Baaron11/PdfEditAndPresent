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
        
        // Set initial tool
        canvas.tool = PKInkingTool(.pen, color: .black, width: 2)
        
        print("✅ PencilKit setup complete")
    }
    
    /// Set canvas mode (drawing, selecting, idle)
    func setCanvasMode(_ mode: CanvasMode) {
        self.canvasMode = mode
        onModeChanged?(mode)
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
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleModeSwitch))
        modeInterceptor.addGestureRecognizer(tap)
        tapGestureRecognizer = tap
        
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
           // Form placement takes priority
         
           
           switch canvasMode {
           case .drawing:
               pencilKitCanvas?.isUserInteractionEnabled = true
               paperKitView?.isUserInteractionEnabled = false
               modeInterceptor.isUserInteractionEnabled = false
               print("🎯 Drawing mode: PencilKit enabled")
               
           case .selecting:
               pencilKitCanvas?.isUserInteractionEnabled = false
               paperKitView?.isUserInteractionEnabled = true
               modeInterceptor.isUserInteractionEnabled = true
               print("🎯 Select mode: PaperKit enabled")
               
           case .idle:
               pencilKitCanvas?.isUserInteractionEnabled = false
               paperKitView?.isUserInteractionEnabled = false
               modeInterceptor.isUserInteractionEnabled = false
               print("🎯 Idle mode: All disabled")
           }
       }
    
    @objc private func handleModeSwitch(_ gesture: UITapGestureRecognizer) {
        print("📍 Mode switch gesture detected")
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
