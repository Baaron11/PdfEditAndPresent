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

    // MARK: - Tool Insertion from Drawer

    func insertToolFromDrawer(_ tool: TeachingTool) {
        // Default center point for click-to-add mode
        let centerPoint = CGPoint(x: 200, y: 300)
        let rect = CGRect(x: centerPoint.x - 100, y: centerPoint.y - 50, width: 200, height: 100)

        switch tool.type {
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.label
            ]
            let text = NSAttributedString(string: tool.content, attributes: attrs)
            insertText(text, rect: rect)

        case .formula:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Times New Roman", size: 18) ?? UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.label
            ]
            let formulaText = tool.formula ?? tool.content
            let text = NSAttributedString(string: formulaText, attributes: attrs)
            insertText(text, rect: rect)

        case .graph:
            let config = ShapeConfiguration(type: .rectangle, fillColor: UIColor.systemGray6.cgColor)
            let graphRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: 250, height: 250)
            insertShape(config, rect: graphRect)

        case .shape:
            let config = ShapeConfiguration(type: .rectangle, fillColor: UIColor.systemGray5.cgColor)
            insertShape(config, rect: rect)

        case .image:
            if let imageName = tool.imageName,
               let image = UIImage(systemName: imageName) ?? UIImage(named: imageName) {
                insertImage(image, rect: rect)
            }

        case .customDrawing:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let text = NSAttributedString(string: "[Custom Drawing Area]", attributes: attrs)
            insertText(text, rect: rect)
        }

        print("📌 Inserted \(tool.type.displayName) from drawer")
    }
}
