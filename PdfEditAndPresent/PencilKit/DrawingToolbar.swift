// DrawingToolbar.swift
// Location: Shared/Views/Drawing/DrawingToolbar.swift

import SwiftUI

struct DrawingToolbar: View {
    @Binding var selectedBrush: BrushConfiguration?
    @ObservedObject var drawingViewModel: DrawingViewModel
    @ObservedObject var brushManager: BrushManager
    let onClear: () -> Void
    var onToolModeChanged: ((DrawingToolMode) -> Void)?

    @State private var showBrushEditor = false
    @State private var isCursorSelected = false

    enum DrawingToolMode {
        case cursorPan
        case drawing
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {

                Button(action: {
                    isCursorSelected = true
                    selectedBrush = nil
                    onToolModeChanged?(.cursorPan)
                }) {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 18))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(isCursorSelected ?
                            Color.blue.opacity(0.15) : Color.gray.opacity(0.2)))
                }

                Divider().frame(height: 30)

                // Brush buttons
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(brushManager.brushes) { brush in
                            BrushButton(
                                brush: brush,
                                isSelected: selectedBrush?.id == brush.id,
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

                // ===== Ruler Toggle =====
                Button(action: {
                    drawingViewModel.toggleRuler()
                }) {
                    Image(systemName: drawingViewModel.isRulerActive ? "ruler.fill" : "ruler")
                        .font(.system(size: 18))
                        .foregroundColor(drawingViewModel.isRulerActive ? .blue : .primary)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(drawingViewModel.isRulerActive ? Color.blue.opacity(0.15) : Color.gray.opacity(0.2))
                        )
                        .accessibilityLabel(drawingViewModel.isRulerActive ? "Hide Ruler" : "Show Ruler")
                }

                // ===== Lasso (with actions menu) =====
                Menu {
                    // Primary lasso toggle at top
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

                    // Selection actions
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
                        Label("Select All", systemImage: "selection.pin.in.out") // fallback if missing; any icon ok
                    }

                    Button {
                        drawingViewModel.duplicate()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }

                } label: {
                    Image(systemName: drawingViewModel.isLassoActive ? "lasso.and.sparkles" : "lasso")
                        .font(.system(size: 18))
                        .foregroundColor(drawingViewModel.isLassoActive ? .blue : .primary)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(drawingViewModel.isLassoActive ? Color.blue.opacity(0.15) : Color.gray.opacity(0.2))
                        )
                        .accessibilityLabel("Lasso")
                }

                // Edit brushes
                Button(action: { showBrushEditor = true }) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18))
                        .foregroundColor(.blue)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(Color.gray.opacity(0.2))
                        )
                }

                Divider().frame(height: 30)

                // Undo/Redo
                HStack(spacing: 12) {
                    Button(action: { drawingViewModel.undo() }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 18))
                            .foregroundColor(drawingViewModel.canUndo ? .primary : .gray)
                    }
                    .disabled(!drawingViewModel.canUndo)

                    Button(action: { drawingViewModel.redo() }) {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 18))
                            .foregroundColor(drawingViewModel.canRedo ? .primary : .gray)
                    }
                    .disabled(!drawingViewModel.canRedo)
                }

                Divider().frame(height: 30)

                // Clear
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.system(size: 18))
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color(UIColor.systemBackground))
        }
        .onAppear {
            isCursorSelected = true
            onToolModeChanged?(.cursorPan)
        }
        .sheet(isPresented: $showBrushEditor) {
            BrushEditorView(brushManager: brushManager)
        }
    }
}

struct BrushButton: View {
    let brush: BrushConfiguration
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
                    .foregroundColor(isSelected ? brush.color.color : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 50)
            }
        }
    }
}
