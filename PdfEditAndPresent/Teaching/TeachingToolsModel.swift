import SwiftUI
import Foundation

// MARK: - Tool Types

enum TeachingToolType: String, Codable, CaseIterable {
    case text
    case formula
    case graph
    case shape
    case image
    case customDrawing

    var icon: String {
        switch self {
        case .text: return "textformat"
        case .formula: return "function"
        case .graph: return "chart.xyaxis.line"
        case .shape: return "square.on.circle"
        case .image: return "photo"
        case .customDrawing: return "scribble"
        }
    }

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .formula: return "Formula"
        case .graph: return "Graph"
        case .shape: return "Shape"
        case .image: return "Image"
        case .customDrawing: return "Drawing"
        }
    }
}

// MARK: - Add Mode

enum AddMode: String, CaseIterable {
    case drag
    case click

    var displayName: String {
        switch self {
        case .drag: return "Drag"
        case .click: return "Click"
        }
    }

    var icon: String {
        switch self {
        case .drag: return "hand.draw"
        case .click: return "cursorarrow.click"
        }
    }
}

// MARK: - Teaching Tool

struct TeachingTool: Identifiable, Codable, Hashable {
    let id: UUID
    let type: TeachingToolType
    let name: String
    let content: String
    let formula: String?
    let imageName: String?
    let category: String

    init(
        id: UUID = UUID(),
        type: TeachingToolType,
        name: String,
        content: String,
        formula: String? = nil,
        imageName: String? = nil,
        category: String = "General"
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.content = content
        self.formula = formula
        self.imageName = imageName
        self.category = category
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TeachingTool, rhs: TeachingTool) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Tool Category

struct ToolCategory: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    var tools: [TeachingTool]
}

// MARK: - Teaching Tools ViewModel

@MainActor
class TeachingToolsViewModel: ObservableObject {
    @Published var categories: [ToolCategory] = []
    @Published var selectedCategory: String? = nil
    @Published var searchText: String = ""

    init() {
        loadDefaultTools()
    }

    var filteredTools: [TeachingTool] {
        let allTools = categories.flatMap { $0.tools }

        if searchText.isEmpty {
            if let category = selectedCategory {
                return allTools.filter { $0.category == category }
            }
            return allTools
        }

        return allTools.filter { tool in
            tool.name.localizedCaseInsensitiveContains(searchText) ||
            tool.content.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func loadDefaultTools() {
        categories = [
            ToolCategory(
                name: "Math",
                icon: "function",
                tools: [
                    TeachingTool(type: .formula, name: "Quadratic Formula", content: "x = (-b +/- sqrt(b^2 - 4ac)) / 2a", formula: "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}", category: "Math"),
                    TeachingTool(type: .formula, name: "Pythagorean Theorem", content: "a^2 + b^2 = c^2", formula: "a^2 + b^2 = c^2", category: "Math"),
                    TeachingTool(type: .formula, name: "Area of Circle", content: "A = pi * r^2", formula: "A = \\pi r^2", category: "Math"),
                    TeachingTool(type: .formula, name: "Slope Formula", content: "m = (y2 - y1) / (x2 - x1)", formula: "m = \\frac{y_2 - y_1}{x_2 - x_1}", category: "Math"),
                    TeachingTool(type: .formula, name: "Distance Formula", content: "d = sqrt((x2-x1)^2 + (y2-y1)^2)", formula: "d = \\sqrt{(x_2-x_1)^2 + (y_2-y_1)^2}", category: "Math"),
                    TeachingTool(type: .graph, name: "Coordinate Plane", content: "X-Y coordinate system", imageName: "chart.xyaxis.line", category: "Math"),
                    TeachingTool(type: .graph, name: "Number Line", content: "Linear number representation", imageName: "ruler", category: "Math"),
                ]
            ),
            ToolCategory(
                name: "Science",
                icon: "atom",
                tools: [
                    TeachingTool(type: .formula, name: "Newton's Second Law", content: "F = ma", formula: "F = ma", category: "Science"),
                    TeachingTool(type: .formula, name: "Kinetic Energy", content: "KE = (1/2)mv^2", formula: "KE = \\frac{1}{2}mv^2", category: "Science"),
                    TeachingTool(type: .formula, name: "Einstein's Equation", content: "E = mc^2", formula: "E = mc^2", category: "Science"),
                    TeachingTool(type: .formula, name: "Ohm's Law", content: "V = IR", formula: "V = IR", category: "Science"),
                    TeachingTool(type: .formula, name: "Ideal Gas Law", content: "PV = nRT", formula: "PV = nRT", category: "Science"),
                    TeachingTool(type: .image, name: "Atom Diagram", content: "Atomic structure", imageName: "atom", category: "Science"),
                ]
            ),
            ToolCategory(
                name: "Shapes",
                icon: "square.on.circle",
                tools: [
                    TeachingTool(type: .shape, name: "Rectangle", content: "Rectangle shape", imageName: "rectangle", category: "Shapes"),
                    TeachingTool(type: .shape, name: "Circle", content: "Circle shape", imageName: "circle", category: "Shapes"),
                    TeachingTool(type: .shape, name: "Triangle", content: "Triangle shape", imageName: "triangle", category: "Shapes"),
                    TeachingTool(type: .shape, name: "Square", content: "Square shape", imageName: "square", category: "Shapes"),
                    TeachingTool(type: .shape, name: "Oval", content: "Oval/Ellipse shape", imageName: "oval", category: "Shapes"),
                    TeachingTool(type: .shape, name: "Hexagon", content: "Hexagon shape", imageName: "hexagon", category: "Shapes"),
                    TeachingTool(type: .shape, name: "Arrow Right", content: "Right arrow", imageName: "arrow.right", category: "Shapes"),
                    TeachingTool(type: .shape, name: "Arrow Left", content: "Left arrow", imageName: "arrow.left", category: "Shapes"),
                ]
            ),
            ToolCategory(
                name: "Text",
                icon: "textformat",
                tools: [
                    TeachingTool(type: .text, name: "Title", content: "Title Text", category: "Text"),
                    TeachingTool(type: .text, name: "Subtitle", content: "Subtitle Text", category: "Text"),
                    TeachingTool(type: .text, name: "Body Text", content: "Enter your text here...", category: "Text"),
                    TeachingTool(type: .text, name: "Bullet Point", content: "* Point 1\n* Point 2\n* Point 3", category: "Text"),
                    TeachingTool(type: .text, name: "Numbered List", content: "1. First item\n2. Second item\n3. Third item", category: "Text"),
                    TeachingTool(type: .text, name: "Note", content: "Note: Important information here", category: "Text"),
                ]
            ),
            ToolCategory(
                name: "Diagrams",
                icon: "diagram.2.and.line.horizontal",
                tools: [
                    TeachingTool(type: .graph, name: "Flowchart Box", content: "Process step", imageName: "rectangle", category: "Diagrams"),
                    TeachingTool(type: .graph, name: "Decision Diamond", content: "Decision point", imageName: "diamond", category: "Diagrams"),
                    TeachingTool(type: .image, name: "Connector Arrow", content: "Flow connector", imageName: "arrow.right.circle", category: "Diagrams"),
                    TeachingTool(type: .graph, name: "Bar Chart", content: "Data visualization", imageName: "chart.bar", category: "Diagrams"),
                    TeachingTool(type: .graph, name: "Pie Chart", content: "Percentage breakdown", imageName: "chart.pie", category: "Diagrams"),
                    TeachingTool(type: .graph, name: "Line Graph", content: "Trend visualization", imageName: "chart.line.uptrend.xyaxis", category: "Diagrams"),
                ]
            ),
        ]

        selectedCategory = categories.first?.name
    }

    func addCustomTool(_ tool: TeachingTool) {
        if let index = categories.firstIndex(where: { $0.name == tool.category }) {
            categories[index].tools.append(tool)
        } else {
            // Create new category if doesn't exist
            let newCategory = ToolCategory(
                name: tool.category,
                icon: "folder",
                tools: [tool]
            )
            categories.append(newCategory)
        }
    }
}

// MARK: - NSItemProvider Extension for Drag & Drop

extension TeachingTool {
    static let typeIdentifier = "com.pdfboard.teachingtool"

    func toItemProvider() -> NSItemProvider {
        let provider = NSItemProvider()

        // Register as JSON data
        provider.registerDataRepresentation(forTypeIdentifier: "public.json", visibility: .all) { completion in
            do {
                let data = try JSONEncoder().encode(self)
                completion(data, nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }

        return provider
    }
}
