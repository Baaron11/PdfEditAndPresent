import SwiftUI
import PaperKit
import PencilKit
import UniformTypeIdentifiers

// MARK: - PaperKit Canvas View

struct PaperKitCanvasView: View {
    @ObservedObject var data: EditorData
    let size: CGSize

    var body: some View {
        Group {
            if let controller = data.controller {
                PaperControllerView(
                    controller: controller,
                    onDropTool: { tool, point in
                        insertTool(tool, at: point)
                    }
                )
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            } else {
                ProgressView("Loading canvas...")
                    .frame(width: size.width, height: size.height)
                    .onAppear {
                        data.initializeController(
                            CGRect(origin: .zero, size: size)
                        )
                    }
            }
        }
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }

    private func insertTool(_ tool: TeachingTool, at point: CGPoint) {
        // Create rect centered on drop point
        let rect = CGRect(
            x: point.x - 100,
            y: point.y - 50,
            width: 200,
            height: 100
        )

        switch tool.type {
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.label
            ]
            let text = NSAttributedString(string: tool.content, attributes: attrs)
            data.insertText(text, rect: rect)

        case .formula:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Times New Roman", size: 18) ?? UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.label
            ]
            let formulaText = tool.formula ?? tool.content
            let text = NSAttributedString(string: formulaText, attributes: attrs)
            data.insertText(text, rect: rect)

        case .graph:
            let config = ShapeConfiguration(
                type: .rectangle,
                fillColor: UIColor.systemGray6.cgColor
            )
            let graphRect = CGRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: 250,
                height: 250
            )
            data.insertShape(config, rect: graphRect)

        case .shape:
            let config = ShapeConfiguration(
                type: .rectangle,
                fillColor: UIColor.systemGray5.cgColor
            )
            data.insertShape(config, rect: rect)

        case .image:
            if let imageName = tool.imageName,
               let image = UIImage(systemName: imageName) ?? UIImage(named: imageName) {
                data.insertImage(image, rect: rect)
            }

        case .customDrawing:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let text = NSAttributedString(string: "[Custom Drawing]", attributes: attrs)
            data.insertText(text, rect: rect)
        }

        print("Inserted \(tool.type.displayName) at \(point)")
    }
}

// MARK: - Paper Controller UIViewControllerRepresentable

fileprivate struct PaperControllerView: UIViewControllerRepresentable {
    var controller: PaperMarkupViewController
    var onDropTool: (TeachingTool, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDropTool: onDropTool)
    }

    func makeUIViewController(context: Context) -> PaperMarkupViewController {
        // Add drop interaction if not already added
        if !controller.view.interactions.contains(where: { $0 is UIDropInteraction }) {
            let dropInteraction = UIDropInteraction(delegate: context.coordinator)
            controller.view.addInteraction(dropInteraction)
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: PaperMarkupViewController,
        context: Context
    ) {
        // Update coordinator callback if needed
        context.coordinator.onDropTool = onDropTool
    }

    // MARK: - Coordinator for Drop Handling

    final class Coordinator: NSObject, UIDropInteractionDelegate {
        var onDropTool: (TeachingTool, CGPoint) -> Void

        init(onDropTool: @escaping (TeachingTool, CGPoint) -> Void) {
            self.onDropTool = onDropTool
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            canHandle session: UIDropSession
        ) -> Bool {
            // Accept JSON data (which contains our encoded TeachingTool)
            session.hasItemsConforming(toTypeIdentifiers: [UTType.json.identifier])
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            sessionDidUpdate session: UIDropSession
        ) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            performDrop session: UIDropSession
        ) {
            guard let view = interaction.view else { return }
            let locationInView = session.location(in: view)

            for item in session.items {
                item.itemProvider.loadDataRepresentation(
                    forTypeIdentifier: UTType.json.identifier
                ) { [weak self] data, error in
                    Task { @MainActor in
                        guard
                            let data = data,
                            let tool = try? JSONDecoder().decode(
                                TeachingTool.self,
                                from: data
                            )
                        else {
                            print("Failed to decode dropped tool")
                            return
                        }

                        self?.onDropTool(tool, locationInView)
                    }
                }
            }
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            sessionDidEnter session: UIDropSession
        ) {
            // Optional: Add visual feedback when drag enters
            interaction.view?.layer.borderColor = UIColor.systemBlue.cgColor
            interaction.view?.layer.borderWidth = 2
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            sessionDidExit session: UIDropSession
        ) {
            // Remove visual feedback when drag exits
            interaction.view?.layer.borderColor = nil
            interaction.view?.layer.borderWidth = 0
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            sessionDidEnd session: UIDropSession
        ) {
            // Clean up visual feedback
            interaction.view?.layer.borderColor = nil
            interaction.view?.layer.borderWidth = 0
        }
    }
}

// MARK: - Preview

#Preview {
    let editorData = EditorData()
    return PaperKitCanvasView(
        data: editorData,
        size: CGSize(width: 400, height: 600)
    )
    .onAppear {
        editorData.initializeController(CGRect(x: 0, y: 0, width: 400, height: 600))
    }
}
