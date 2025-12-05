import SwiftUI
import UniformTypeIdentifiers

// MARK: - Teaching Tools Drawer

struct TeachingToolsDrawer: View {
    @Binding var isOpen: Bool
    @ObservedObject var viewModel: TeachingToolsViewModel
    @Binding var addMode: AddMode
    var onToolSelected: ((TeachingTool) -> Void)?
    var onClearCanvas: (() -> Void)?

    @State private var draggedTool: TeachingTool?

    private let drawerWidth: CGFloat = 280

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Spacer()

                if isOpen {
                    drawerContent
                        .frame(width: drawerWidth)
                        .background(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.15), radius: 8, x: -2, y: 0)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isOpen)
    }

    // MARK: - Drawer Content

    private var drawerContent: some View {
        VStack(spacing: 0) {
            // Header
            drawerHeader

            Divider()

            // Search bar
            searchBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            // Add mode toggle
            addModeToggle
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            // Category tabs
            categoryTabs
                .padding(.vertical, 8)

            Divider()

            // Tools grid
            toolsGrid

            Divider()

            // Clear button
            clearButton
                .padding(12)
        }
    }

    // MARK: - Header

    private var drawerHeader: some View {
        HStack {
            Text("Elements")
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isOpen = false
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))

            TextField("Search elements...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))

            if !viewModel.searchText.isEmpty {
                Button(action: {
                    viewModel.searchText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
            }
        }
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Add Mode Toggle

    private var addModeToggle: some View {
        HStack(spacing: 8) {
            ForEach(AddMode.allCases, id: \.self) { mode in
                Button(action: {
                    addMode = mode
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 12))
                        Text(mode.displayName)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(addMode == mode ? Color.blue : Color(.systemGray5))
                    .foregroundColor(addMode == mode ? .white : .primary)
                    .cornerRadius(6)
                }
            }

            Spacer()
        }
    }

    // MARK: - Category Tabs

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.categories) { category in
                    Button(action: {
                        viewModel.selectedCategory = category.name
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: category.icon)
                                .font(.system(size: 12))
                            Text(category.name)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            viewModel.selectedCategory == category.name
                                ? Color.blue
                                : Color(.systemGray5)
                        )
                        .foregroundColor(
                            viewModel.selectedCategory == category.name
                                ? .white
                                : .primary
                        )
                        .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Tools Grid

    private var toolsGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                ForEach(viewModel.filteredTools) { tool in
                    ToolGridItem(
                        tool: tool,
                        addMode: addMode,
                        onTap: {
                            if addMode == .click {
                                onToolSelected?(tool)
                            }
                        }
                    )
                }
            }
            .padding(12)
        }
    }

    // MARK: - Clear Button

    private var clearButton: some View {
        Button(action: {
            onClearCanvas?()
        }) {
            HStack {
                Image(systemName: "trash")
                Text("Clear Canvas")
            }
            .font(.system(size: 14, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.1))
            .foregroundColor(.red)
            .cornerRadius(8)
        }
    }
}

// MARK: - Tool Grid Item

struct ToolGridItem: View {
    let tool: TeachingTool
    let addMode: AddMode
    var onTap: (() -> Void)?

    var body: some View {
        Button(action: {
            onTap?()
        }) {
            VStack(spacing: 6) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                        .frame(width: 50, height: 50)

                    Image(systemName: tool.type.icon)
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                }

                // Name
                Text(tool.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color(.systemBackground))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.systemGray4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onDrag {
            tool.toItemProvider()
        }
    }
}

// MARK: - Draggable Tool View (for drag preview)

struct DraggableToolView: View {
    let tool: TeachingTool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: tool.type.icon)
                .font(.system(size: 28))
                .foregroundColor(.blue)

            Text(tool.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color(.systemBackground))
        .cornerRadius(8)
        .shadow(radius: 4)
    }
}

// MARK: - Preview

#Preview {
    TeachingToolsDrawer(
        isOpen: .constant(true),
        viewModel: TeachingToolsViewModel(),
        addMode: .constant(.drag),
        onToolSelected: { _ in },
        onClearCanvas: { }
    )
}
