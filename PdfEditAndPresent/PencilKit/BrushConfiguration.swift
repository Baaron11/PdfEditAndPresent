// BrushConfiguration.swift
// Location: Shared/Models/BrushConfiguration.swift

import SwiftUI
import PencilKit
import Combine

// MARK: - Brush Type
enum BrushType: String, Codable, CaseIterable {
    case pen = "Pen"
    case pencil = "Pencil"
    case marker = "Marker"
    case eraser = "Eraser"

    var iconName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "paintbrush.pointed"
        case .eraser: return "eraser"
        }
    }

    var inkType: PKInkingTool.InkType {
        switch self {
        case .pen: return .pen
        case .pencil: return .pencil
        case .marker: return .marker
        case .eraser: return .pen // fallback, eraser should use setEraser() instead
        }
    }
}

// MARK: - Brush Configuration
struct BrushConfiguration: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: BrushType
    var color: CodableColor
    var width: CGFloat
    var order: Int
    var showName: Bool = true  // ✅ NEW: Show name in UI
    
    init(id: UUID = UUID(), name: String, type: BrushType, color: CodableColor, width: CGFloat, order: Int, showName: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.color = color
        self.width = width
        self.order = order
        self.showName = showName
    }
    
    // Create PKInkingTool from this configuration
    func createTool() -> PKTool {
        switch type {
        case .pen:
            return PKInkingTool(.pen, color: color.uiColor, width: width)
        case .pencil:
            return PKInkingTool(.pencil, color: color.uiColor, width: width)
        case .marker:
            return PKInkingTool(.marker, color: color.uiColor, width: width)
        case .eraser:
            return PKEraserTool(.bitmap)
        }
    }
    
    // Default brushes
    static let defaults: [BrushConfiguration] = [
        BrushConfiguration(
            name: "Black Pen",
            type: .pen,
            color: CodableColor(.black),
            width: 2,
            order: 0,
            showName: true
        ),
        BrushConfiguration(
            name: "Red Pen",
            type: .pen,
            color: CodableColor(.red),
            width: 2,
            order: 1,
            showName: true
        ),
        BrushConfiguration(
            name: "Black Marker",
            type: .marker,
            color: CodableColor(.black),
            width: 5,
            order: 2,
            showName: true
        ),
        BrushConfiguration(
            name: "Yellow Highlighter",
            type: .marker,
            color: CodableColor(UIColor.yellow.withAlphaComponent(0.5)),
            width: 15,
            order: 3,
            showName: true
        ),
        BrushConfiguration(
            name: "Eraser",
            type: .eraser,
            color: CodableColor(.clear),
            width: 10,
            order: 4,
            showName: true
        )
    ]
}

// MARK: - Codable Color Wrapper
struct CodableColor: Codable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    
    init(_ uiColor: UIColor) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = r
        self.green = g
        self.blue = b
        self.alpha = a
    }
    
    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    
    var color: Color {
        Color(uiColor: uiColor)
    }
}

// MARK: - Brush Manager
class BrushManager: ObservableObject {
    @Published var brushes: [BrushConfiguration] = []
    
    private let storageKey = "savedBrushes"
    
    init() {
        loadBrushes()
    }
    
    func loadBrushes() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([BrushConfiguration].self, from: data) {
            brushes = decoded.sorted { $0.order < $1.order }
            print("✅ Loaded \(brushes.count) custom brushes")
        } else {
            brushes = BrushConfiguration.defaults
            saveBrushes()
            print("✅ Loaded default brushes")
        }
    }
    
    func saveBrushes() {
        if let encoded = try? JSONEncoder().encode(brushes) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
            print("✅ Saved \(brushes.count) brushes")
        }
    }
    
    func addBrush(_ brush: BrushConfiguration) {
        var newBrush = brush
        newBrush.order = brushes.count
        brushes.append(newBrush)
        saveBrushes()
    }
    
    func updateBrush(_ brush: BrushConfiguration) {
        if let index = brushes.firstIndex(where: { $0.id == brush.id }) {
            brushes[index] = brush
            saveBrushes()
        }
    }
    
    func deleteBrush(at offsets: IndexSet) {
        brushes.remove(atOffsets: offsets)
        reorderBrushes()
        saveBrushes()
    }
    
    func moveBrush(from source: IndexSet, to destination: Int) {
        brushes.move(fromOffsets: source, toOffset: destination)
        reorderBrushes()
        saveBrushes()
    }
    
    private func reorderBrushes() {
        for (index, _) in brushes.enumerated() {
            brushes[index].order = index
        }
    }
    
    func resetToDefaults() {
        brushes = BrushConfiguration.defaults
        saveBrushes()
    }
}
