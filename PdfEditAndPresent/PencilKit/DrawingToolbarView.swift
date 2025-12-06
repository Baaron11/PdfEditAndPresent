import SwiftUI
import PencilKit

struct DrawingToolbarView: View {
    // Brush manager reference
    @ObservedObject var brushManager: BrushManager
    
    // Simple state for UI controls
    @State private var selectedBrushId: UUID?
    @State private var selectedColor: Color = .black
    @State private var lineWidth: CGFloat = 3

    // Actions injected from caller
    let setInk: (PKInkingTool.InkType, UIColor, CGFloat) -> Void
    let setEraser: () -> Void
    let beginLasso: () -> Void
    let undo: () -> Void
    let redo: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Brushes row
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Render each brush from manager
                        ForEach(brushManager.brushes) { brush in
                            BrushButton(
                                brush: brush,
                                isSelected: selectedBrushId == brush.id,
                                action: {
                                    selectedBrushId = brush.id
                                    selectedColor = brush.color.color
                                    lineWidth = brush.width
                                    
                                    // Apply the selected brush
                                    let tool = brush.createTool()
                                    if let inkTool = tool as? PKInkingTool {
                                        setInk(inkTool.inkType, brush.color.uiColor, brush.width)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
                
                Divider().frame(height: 44)
                
                // Tools
                Button { setEraser() } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(8)
                        .foregroundColor(.primary)
                }

                Button { beginLasso() } label: {
                    Image(systemName: "lasso")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(8)
                        .foregroundColor(.primary)
                }

                Divider().frame(height: 22)

                Button { undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(8)
                        .foregroundColor(.primary)
                }

                Button { redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(8)
                        .foregroundColor(.primary)
                }
            }

            // Color and width controls
            HStack(spacing: 10) {
                ColorPicker("", selection: $selectedColor)
                    .labelsHidden()
                    .frame(width: 36, height: 36)
                    .onChange(of: selectedColor) { newColor in
                        setInk(selectedBrushType, UIColor(newColor), lineWidth)
                    }

                Slider(value: $lineWidth, in: 1...20, step: 1) {
                    Text("Width")
                } minimumValueLabel: {
                    Text("1").font(.caption)
                } maximumValueLabel: {
                    Text("20").font(.caption)
                }
                .frame(width: 180)
                .onChange(of: lineWidth) { newWidth in
                    setInk(selectedBrushType, UIColor(selectedColor), newWidth)
                }

                Button("Apply") {
                    setInk(selectedBrushType, UIColor(selectedColor), lineWidth)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 6)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(radius: 10)
        .onAppear {
            // Select first brush by default
            selectedBrushId = brushManager.brushes.first?.id
            if let firstBrush = brushManager.brushes.first {
                selectedColor = firstBrush.color.color
                lineWidth = firstBrush.width
            }
        }
    }
    
    // Get the currently selected brush's ink type
    private var selectedBrushType: PKInkingTool.InkType {
        if let selectedId = selectedBrushId,
           let brush = brushManager.brushes.first(where: { $0.id == selectedId }) {
            return brush.type.inkType
        }
        return .pen
    }
}

#if DEBUG
struct DrawingToolbarView_Previews: PreviewProvider {
    static var previews: some View {
        DrawingToolbarView(
            brushManager: BrushManager(),
            setInk: { _, _, _ in },
            setEraser: { },
            beginLasso: { },
            undo: { },
            redo: { }
        )
        .preferredColorScheme(.light)
    }
}
#endif
