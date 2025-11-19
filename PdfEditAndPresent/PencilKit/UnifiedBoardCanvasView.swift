import SwiftUI
import PencilKit
import PaperKit

// MARK: - SwiftUI Representable
struct UnifiedBoardCanvasView: UIViewControllerRepresentable {
    @ObservedObject var editorData: EditorData
    @Binding var canvasMode: CanvasMode
    
    let canvasSize: CGSize
    
    // Callbacks
    var onModeChanged: ((CanvasMode) -> Void)?
    var onPaperKitItemAdded: (() -> Void)?
    
    func makeUIViewController(context: Context) -> UnifiedBoardCanvasController {
        let controller = UnifiedBoardCanvasController()
        
        // Initialize canvas size
        controller.initializeCanvas(size: canvasSize)
        
        // Setup both layers
        if let markup = editorData.markup {
            controller.setupPaperKit(markup: markup)
        }
        controller.setupPencilKit()
        
        // Wire up callbacks (no weak capture needed for Context)
        controller.onModeChanged = { [weak controller] newMode in
            guard controller != nil else { return }
            DispatchQueue.main.async {
                canvasMode = newMode
                onModeChanged?(newMode)
            }
        }
        
        controller.onPaperKitItemAdded = {
            DispatchQueue.main.async {
                onPaperKitItemAdded?()
            }
        }
        
        // Set initial state
        controller.setCanvasMode(canvasMode)
        
        // Store reference for future updates
        context.coordinator.controller = controller
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UnifiedBoardCanvasController, context: Context) {
        // Update mode if changed
        if uiViewController.canvasMode != canvasMode {
            uiViewController.setCanvasMode(canvasMode)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    final class Coordinator {
        var controller: UnifiedBoardCanvasController?
    }
}

// MARK: - Preview Modifier (for testing)
extension UnifiedBoardCanvasView {
    static let defaultSize = CGSize(width: 595.28, height: 841.89) // A4
}
