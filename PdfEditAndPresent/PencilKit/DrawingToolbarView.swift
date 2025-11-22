import SwiftUI
import PencilKit

struct DrawingToolbarView: View {
    // Simple state for UI controls
    @State private var selectedInk: PKInkingTool.InkType = .pen
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
            HStack(spacing: 8) {
                Button {
                    selectedInk = .pen
                    setInk(.pen, uiColor, lineWidth)
                } label: {
                    Image(systemName: "pencil.tip")
                        .padding(6)
                        .background(selectedInk == .pen ? Color.blue.opacity(0.2) : Color.clear)
                        .cornerRadius(6)
                }

                Button {
                    selectedInk = .marker
                    setInk(.marker, uiColor, max(lineWidth, 6))
                } label: {
                    Image(systemName: "highlighter")
                        .padding(6)
                        .background(selectedInk == .marker ? Color.blue.opacity(0.2) : Color.clear)
                        .cornerRadius(6)
                }

                Button { setEraser() } label: {
                    Image(systemName: "eraser")
                        .padding(6)
                }

                Button { beginLasso() } label: {
                    Image(systemName: "lasso")
                        .padding(6)
                }

                Divider().frame(height: 22)

                Button { undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .padding(6)
                }

                Button { redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .padding(6)
                }
            }

            HStack(spacing: 10) {
                ColorPicker("", selection: $selectedColor)
                    .labelsHidden()
                    .frame(width: 36, height: 36)

                Slider(value: $lineWidth, in: 1...20, step: 1) {
                    Text("Width")
                } minimumValueLabel: {
                    Text("1").font(.caption)
                } maximumValueLabel: {
                    Text("20").font(.caption)
                }
                .frame(width: 180)

                Button("Apply") {
                    setInk(selectedInk, uiColor, lineWidth)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 6)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(radius: 10)
    }

    private var uiColor: UIColor { UIColor(selectedColor) }
}
