import SwiftUI

struct DrawingToolbar: View {
    @Binding var selectedBrush: BrushConfiguration?
    @ObservedObject var drawingViewModel: DrawingViewModel
    @ObservedObject var brushManager: BrushManager
    let onClear: () -> Void
    var onToolModeChanged: ((DrawingToolMode) -> Void)?

    // Undo/Redo state from canvas controller
    var canUndo: Bool = false
    var canRedo: Bool = false

    @State private var showBrushEditor = false
    @State private var isCursorSelected = false
    @AppStorage("showBrushNames") private var showBrushNames: Bool = true

    enum DrawingToolMode {
        case cursorPan
        case drawing
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                // ===== SELECT/CURSOR TOOL =====
                ToolButton(
                    iconName: "pointer.arrow",
                    label: "Select",
                    isSelected: isCursorSelected,
                    showNames: showBrushNames,
                    action: {
                        isCursorSelected = true
                        selectedBrush = nil
                        onToolModeChanged?(.cursorPan)
                    }
                )

                Divider().frame(height: 30)

                // ===== BRUSH BUTTONS (Scrollable) =====
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(brushManager.brushes) { brush in
                            BrushButton(
                                brush: brush,
                                isSelected: selectedBrush?.id == brush.id,
                                showBrushNames: showBrushNames,
                                action: {
                                    selectedBrush = brush
                                    isCursorSelected = false
                                    drawingViewModel.selectBrush(brush)
                                    onToolModeChanged?(.drawing)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }

                Spacer()

                // ===== RULER =====
                ToolButton(
                    iconName: drawingViewModel.isRulerActive ? "ruler.fill" : "ruler",
                    label: "Ruler",
                    isSelected: drawingViewModel.isRulerActive,
                    showNames: showBrushNames,
                    action: {
                        drawingViewModel.toggleRuler()
                    }
                )

                // ===== LASSO =====
                Menu {
                    Button {
                        if drawingViewModel.isLassoActive {
                            drawingViewModel.endLasso()
                        } else {
                            drawingViewModel.beginLasso()
                        }
                    } label: {
                        Label(drawingViewModel.isLassoActive ? "Exit Lasso" : "Enter Lasso", systemImage: "lasso")
                    }

                    Divider()

                    Button {
                        drawingViewModel.cut()
                    } label: {
                        Label("Cut", systemImage: "scissors")
                    }

                    Button {
                        drawingViewModel.copy()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    Button {
                        drawingViewModel.paste()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }

                    Button(role: .destructive) {
                        drawingViewModel.deleteSelection()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        drawingViewModel.selectAll()
                    } label: {
                        Label("Select All", systemImage: "selection.pin.in.out")
                    }

                    Button {
                        drawingViewModel.duplicate()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }

                } label: {
                    ToolButton(
                        iconName: drawingViewModel.isLassoActive ? "lasso.and.sparkles" : "lasso",
                        label: "Lasso",
                        isSelected: drawingViewModel.isLassoActive,
                        showNames: showBrushNames,
                        action: {}  // Menu handles the action
                    )
                }

                // ===== SETTINGS/EDIT BRUSHES =====
                ToolButton(
                    iconName: "slider.horizontal.3",
                    label: "Settings",
                    isSelected: false,
                    showNames: showBrushNames,
                    action: { showBrushEditor = true },
                    accentColor: .blue
                )

                Divider().frame(height: 30)

                // ===== UNDO/REDO =====
                ToolButton(
                    iconName: "arrow.uturn.backward",
                    label: "Undo",
                    isSelected: false,
                    showNames: showBrushNames,
                    action: { drawingViewModel.undo() },
                    isDisabled: !canUndo
                )

                ToolButton(
                    iconName: "arrow.uturn.forward",
                    label: "Redo",
                    isSelected: false,
                    showNames: showBrushNames,
                    action: { drawingViewModel.redo() },
                    isDisabled: !canRedo
                )

                Divider().frame(height: 30)

                // ===== CLEAR =====
                ToolButton(
                    iconName: "trash",
                    label: "Clear",
                    isSelected: false,
                    showNames: showBrushNames,
                    action: onClear,
                    accentColor: .red
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .background(Color(UIColor.systemBackground))
        }
        .background(Color(UIColor.systemBackground))
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            isCursorSelected = true
            onToolModeChanged?(.cursorPan)
        }
        .sheet(isPresented: $showBrushEditor) {
            BrushEditorView(
                brushManager: brushManager,
                showBrushNames: $showBrushNames
            )
        }
    }
}

// MARK: - Unified Tool Button Component
struct ToolButton: View {
    let iconName: String
    let label: String
    let isSelected: Bool
    let showNames: Bool
    let action: () -> Void
    var isDisabled: Bool = false
    var accentColor: Color = .blue

    var body: some View {
        Button(action: action) {
            if showNames {
                // When showing names: stack icon + text
                VStack(spacing: 4) {
                    Image(systemName: iconName)
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? .white : (isDisabled ? .gray : .primary))
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(isSelected ? accentColor : Color.gray.opacity(0.2))
                        )

                    Text(label)
                        .font(.system(size: 10))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 50)
                        .frame(height: 12)
                }
            } else {
                // When hiding names: center icon vertically
                VStack {
                    Spacer()
                    Image(systemName: iconName)
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? .white : (isDisabled ? .gray : .primary))
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(isSelected ? accentColor : Color.gray.opacity(0.2))
                        )
                    Spacer()
                }
                .frame(height: 56)  // Same total height as when names are shown
            }
        }
        .disabled(isDisabled)
    }
}

// MARK: - Brush Button (specialized for brushes)
struct BrushButton: View {
    let brush: BrushConfiguration
    let isSelected: Bool
    let showBrushNames: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if showBrushNames {
                // When showing names: stack icon + text
                VStack(spacing: 4) {
                    Image(systemName: brush.type.iconName)
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? .white : brush.color.color)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(isSelected ? brush.color.color : Color.gray.opacity(0.2))
                        )

                    Text(brush.name)
                        .font(.system(size: 10))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 50)
                        .frame(height: 12)
                }
            } else {
                // When hiding names: center icon vertically
                VStack {
                    Spacer()
                    Image(systemName: brush.type.iconName)
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? .white : brush.color.color)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(isSelected ? brush.color.color : Color.gray.opacity(0.2))
                        )
                    Spacer()
                }
                .frame(height: 56)  // Same total height as when names are shown
            }
        }
    }
}
