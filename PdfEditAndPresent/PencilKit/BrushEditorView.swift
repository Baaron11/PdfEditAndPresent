import SwiftUI

struct BrushEditorView: View {
    @ObservedObject var brushManager: BrushManager
    @Environment(\.dismiss) var dismiss
    
    @State private var showingAddBrush = false
    @State private var editingBrush: BrushConfiguration?
    
    @Binding var showBrushNames: Bool

    
    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(brushManager.brushes) { brush in
                        BrushRowView(brush: brush)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingBrush = brush
                            }
                    }
                    .onDelete { offsets in
                        brushManager.deleteBrush(at: offsets)
                    }
                    .onMove { source, destination in
                        brushManager.moveBrush(from: source, to: destination)
                    }
                } header: {
                    Text("Brushes")
                } footer: {
                    Text("Tap to edit, swipe to delete, drag to reorder")
                }
                
                Section {
                    Toggle("Show Tool Names", isOn: $showBrushNames)
                    
                    Button(action: {
                        showingAddBrush = true
                    }) {
                        Label("Add New Brush", systemImage: "plus.circle.fill")
                    }

                    Button(role: .destructive, action: {
                        brushManager.resetToDefaults()
                    }) {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Edit Brushes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingAddBrush) {
                BrushEditSheet(
                    brush: BrushConfiguration(
                        name: "New Brush",
                        type: .pen,
                        color: CodableColor(.black),
                        width: 2,
                        order: brushManager.brushes.count
                    ),
                    isNew: true
                ) { newBrush in
                    brushManager.addBrush(newBrush)
                }
            }
            .sheet(item: $editingBrush) { brush in
                BrushEditSheet(
                    brush: brush,
                    isNew: false
                ) { updatedBrush in
                    brushManager.updateBrush(updatedBrush)
                }
            }
        }
    }
}

// MARK: - Brush Row View
struct BrushRowView: View {
    let brush: BrushConfiguration
    
    var body: some View {
        HStack(spacing: 12) {
            // Brush icon with color
            Image(systemName: brush.type.iconName)
                .font(.system(size: 24))
                .foregroundColor(brush.color.color)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(brush.name)
                    .font(.headline)
                
                HStack(spacing: 8) {
                    Text(brush.type.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text("Width: \(Int(brush.width))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Color preview
            Circle()
                .fill(brush.color.color)
                .frame(width: 30, height: 30)
                .overlay(
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Brush Edit Sheet
struct BrushEditSheet: View {
    @Environment(\.dismiss) var dismiss
    
    @State private var brush: BrushConfiguration
    let isNew: Bool
    let onSave: (BrushConfiguration) -> Void
    
    @State private var selectedColor: Color
    
    init(brush: BrushConfiguration, isNew: Bool, onSave: @escaping (BrushConfiguration) -> Void) {
        self._brush = State(initialValue: brush)
        self.isNew = isNew
        self.onSave = onSave
        self._selectedColor = State(initialValue: brush.color.color)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("Brush Details") {
                    TextField("Name", text: $brush.name)
                    
                    Picker("Type", selection: $brush.type) {
                        ForEach(BrushType.allCases, id: \.self) { type in
                            HStack {
                                Image(systemName: type.iconName)
                                Text(type.rawValue)
                            }
                            .tag(type)
                        }
                    }
                }
                
                if brush.type != .eraser {
                    Section("Color") {
                        ColorPicker("Brush Color", selection: $selectedColor, supportsOpacity: true)
                        
                        // Color presets
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                            ForEach(colorPresets, id: \.self) { color in
                                Circle()
                                    .fill(color)
                                    .frame(width: 40, height: 40)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                    )
                                    .onTapGesture {
                                        selectedColor = color
                                    }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    
                    Section("Width") {
                        HStack {
                            Text("Width")
                            Spacer()
                            Text("\(Int(brush.width)) pt")
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $brush.width, in: 1...30, step: 1)
                        
                        // Width preview
                        HStack {
                            Spacer()
                            RoundedRectangle(cornerRadius: brush.width / 2)
                                .fill(selectedColor)
                                .frame(width: 100, height: brush.width)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
                
                Section("Preview") {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: brush.type.iconName)
                                .font(.system(size: 50))
                                .foregroundColor(brush.type == .eraser ? .pink : selectedColor)
                            
                            Text(brush.name)
                                .font(.headline)
                            
                            Text("\(brush.type.rawValue) • \(Int(brush.width))pt")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle(isNew ? "New Brush" : "Edit Brush")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        brush.color = CodableColor(UIColor(selectedColor))
                        onSave(brush)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
    }
    
    private var colorPresets: [Color] {
        [
            .black, .white, .gray,
            .red, .orange, .yellow,
            .green, .blue, .purple,
            .pink, .brown, .cyan,
            Color(red: 1, green: 1, blue: 0, opacity: 0.5), // Yellow highlighter
            Color(red: 0, green: 1, blue: 0, opacity: 0.5), // Green highlighter
            Color(red: 1, green: 0.5, blue: 0, opacity: 0.5), // Orange highlighter
        ]
    }
}

// MARK: - Preview
#if DEBUG
struct BrushEditorView_Previews: PreviewProvider {
    @State static var showBrushNames = true

    static var previews: some View {
        BrushEditorView(
            brushManager: BrushManager(),
            showBrushNames: $showBrushNames
        )
    }
}
#endif
