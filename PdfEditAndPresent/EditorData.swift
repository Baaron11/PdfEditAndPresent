import SwiftUI
import PencilKit
import PaperKit
import UniformTypeIdentifiers
import Combine

// MARK: - EditorData with proper lifecycle management

@MainActor
class EditorData: ObservableObject {
    @Published var controller: PaperMarkupViewController?
    @Published var markup: PaperMarkup?
    @Published var toolPicker = PKToolPicker()
    @Published var documentName: String = "Untitled"
    @Published var lastSavedDate: Date?
    
    // MARK: - Initialization
    
    func initializeController(_ rect: CGRect) {
        // Always create a fresh PaperMarkup
        let markup = PaperMarkup(bounds: rect)
        
        // Create a fresh controller
        let controller = PaperMarkupViewController(supportedFeatureSet: .latest)
        controller.markup = markup
        controller.zoomRange = 0.8...1.5
        
        // Set transparency properties
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        
        // Update published properties
        self.markup = markup
        self.controller = controller
        
        print("✅ Initialized PaperMarkup with bounds: \(rect)")
    }
    
    // MARK: - Markup Editing
    
    func insertText(_ text: NSAttributedString, rect: CGRect) {
        markup?.insertNewTextbox(attributedText: text, frame: rect)
        refreshController()
    }
    
    func insertImage(_ image: UIImage, rect: CGRect) {
        guard let cgImage = image.cgImage else { return }
        markup?.insertNewImage(cgImage, frame: rect)
        refreshController()
    }
    
    func insertShape(_ configuration: ShapeConfiguration, rect: CGRect) {
        markup?.insertNewShape(configuration: configuration, frame: rect)
        refreshController()
    }
    
    // MARK: - Utility
    
    func refreshController() {
        // Trigger update by toggling the published property
        if let currentMarkup = markup {
            self.markup = currentMarkup
        }
        if let currentController = controller {
            currentController.markup = markup
        }
    }
    
    func clearCanvas() {
        // Fully clear and reinitialize
        markup = nil
        controller = nil
        
        // Create a default A4-sized new canvas
        let defaultRect = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        initializeController(defaultRect)
        
        print("🧹 Canvas cleared and reinitialized")
    }
}
