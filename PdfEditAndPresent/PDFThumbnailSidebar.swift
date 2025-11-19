import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - PDF Thumbnail Sidebar (Single Page Mode) with improved insert dialog
struct PDFThumbnailSidebar: View {
    @ObservedObject var pdfManager: PDFManager
    @Binding var isOpen: Bool
    
    @State private var draggedPageIndex: Int?
    @State private var dropTargetPosition: Int?
    @State private var isDraggingOver: Bool = false
    @State private var pageToDelete: Int?
    @State private var showDeleteConfirmation = false
    @State private var moveCounter = 0
    @State private var isEditMode = false
    @State private var showFilePicker = false
    @State private var showInsertPositionDialog = false
    @State private var showPageNumberInput = false
    @State private var selectedPDFURL: URL?
    @State private var insertPosition: String = ""
    @State private var insertMethod: InsertMethod = .atEnd
    @State private var pages: [Int] = []
    
    enum InsertMethod {
        case atFront
        case atEnd
        case afterPage
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    // ✅ FIXED: Add drop handler to top indicator line
                    if let dropTarget = dropTargetPosition, dropTarget == 0 && isDraggingOver {
                        dropIndicatorLine
                            .onDrop(of: [.text], delegate: SinglePageDropDelegate(
                                pageIndex: -1,  // Special marker for before first page
                                draggedPageIndex: $draggedPageIndex,
                                hoveredPageIndex: .constant(nil),
                                dropTargetPosition: $dropTargetPosition,
                                isDraggingOver: $isDraggingOver,
                                pdfManager: pdfManager,
                                moveCounter: $moveCounter
                            ))
                    }
                    
                    // ✅ FIXED: Remove duplicate ID modifier and use only the ForEach id
                    ForEach(pages, id: \.self) { pageIndex in
                        thumbnailItem(for: pageIndex)
                        
                        // ✅ FIXED: Add drop handler to between-page indicator lines
                        if let dropTarget = dropTargetPosition, dropTarget == pageIndex + 1 && isDraggingOver {
                            dropIndicatorLine
                                .onDrop(of: [.text], delegate: SinglePageDropDelegate(
                                    pageIndex: pageIndex,
                                    draggedPageIndex: $draggedPageIndex,
                                    hoveredPageIndex: .constant(nil),
                                    dropTargetPosition: $dropTargetPosition,
                                    isDraggingOver: $isDraggingOver,
                                    pdfManager: pdfManager,
                                    moveCounter: $moveCounter
                                ))
                        }
                    }
                    
                    // Slim action buttons
                    sidebarActionButtons
                }
                .padding(8)
            }
            .background(Color.gray.opacity(0.05))
        }
        .frame(width: 120)
        .background(Color.white)
        .overlay(
            VStack { }
                .frame(width: 1)
                .background(Color.gray.opacity(0.2))
                .frame(maxWidth: .infinity, alignment: .trailing)
        )
        .onAppear {
            updatePages()
        }
        .onChange(of: pdfManager.pageCount) { _, _ in
            updatePages()
        }
        .onReceive(pdfManager.objectWillChange) { _ in
            updatePages()
        }
        .alert("Delete Page?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let pageIndex = pageToDelete {
                    deletePage(at: pageIndex)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete page \(pageToDelete.map { $0 + 1 } ?? 0)? This cannot be undone.")
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf],
            onCompletion: { result in
                if case .success(let url) = result {
                    selectedPDFURL = url
                    showInsertPositionDialog = true
                }
            }
        )
        .confirmationDialog("Insert Position", isPresented: $showInsertPositionDialog) {
            Button("At Front") {
                insertMethod = .atFront
                insertPDF()
            }
            Button("At End") {
                insertMethod = .atEnd
                insertPDF()
            }
            Button("After Page...") {
                insertMethod = .afterPage
                showPageNumberInput = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Where would you like to insert the PDF?")
        }
        .alert("After Which Page?", isPresented: $showPageNumberInput) {
            TextField("Page number", text: $insertPosition)
                .keyboardType(.numberPad)
            
            Button("Insert") {
                if !insertPosition.isEmpty {
                    insertPDF()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter the page number after which to insert (1-\(pdfManager.pageCount))")
        }
    }
    
    private var dropIndicatorLine: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.blue)
            .frame(height: 3)
            .padding(.vertical, 2)
    }
    
    private func updatePages() {
        print("🔄 Updating pages array in PDFThumbnailSidebar - pageCount: \(pdfManager.pageCount)")
        pages = Array(0..<pdfManager.pageCount)
    }
    
    @ViewBuilder
    private func thumbnailItem(for pageIndex: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            thumbnailButton(for: pageIndex)
                .onDrag {
                    draggedPageIndex = pageIndex
                    print("🎯 Started dragging page \(pageIndex + 1)")
                    return NSItemProvider(object: "\(pageIndex)" as NSString)
                }
                .onDrop(of: [.text], delegate: SinglePageDropDelegate(
                    pageIndex: pageIndex,
                    draggedPageIndex: $draggedPageIndex,
                    hoveredPageIndex: .constant(nil),
                    dropTargetPosition: $dropTargetPosition,
                    isDraggingOver: $isDraggingOver,
                    pdfManager: pdfManager,
                    moveCounter: $moveCounter
                ))
            
            // ✅ FIXED: Show delete button - just check edit mode and not dragging
            // Don't use a separate pageToDelete check here as it causes state conflicts
            if isEditMode && draggedPageIndex != pageIndex {
                Button(action: {
                    pageToDelete = pageIndex
                    showDeleteConfirmation = true
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.blue))
                }
                .padding(3)
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func thumbnailButton(for pageIndex: Int) -> some View {
        Button(action: { pdfManager.currentPageIndex = pageIndex }) {
            thumbnailContent(for: pageIndex)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(pdfManager.currentPageIndex == pageIndex ? Color.blue.opacity(0.2) : Color.white)
                .border(pdfManager.currentPageIndex == pageIndex ? Color.blue : Color.gray.opacity(0.3), width: pdfManager.currentPageIndex == pageIndex ? 2 : 1)
                .cornerRadius(4)
                .opacity(draggedPageIndex == pageIndex ? 0.5 : 1.0)
        }
    }
    
    @ViewBuilder
    private func thumbnailContent(for pageIndex: Int) -> some View {
        VStack(spacing: 4) {
            if pageIndex < pdfManager.thumbnails.count,
               let image = pdfManager.thumbnails[pageIndex] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 100)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 100)
            }
            
            Text("Page \(pageIndex + 1)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary)
        }
    }
    
    // MARK: - Sidebar Action Buttons (Slim Style)
    @ViewBuilder
    private var sidebarActionButtons: some View {
        VStack(spacing: 12) {
            Button {
                pdfManager.addBlankPage()
            } label: {
                SidebarActionButton(systemImage: "plus", title: "Add Page")
            }
            .buttonStyle(SidebarActionButtonStyle())

            Button {
                showFilePicker = true
            } label: {
                SidebarActionButton(systemImage: "doc.badge.plus", title: "Add PDF")
            }
            .buttonStyle(SidebarActionButtonStyle())

            Button {
                isEditMode.toggle()
                if !isEditMode {
                    pageToDelete = nil
                    draggedPageIndex = nil
                }
            } label: {
                SidebarActionButton(systemImage: isEditMode ? "checkmark.circle.fill" : "nosign", title: isEditMode ? "Done" : "Remove...")
            }
            .buttonStyle(SidebarActionButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // Keep individual properties for compatibility
    @ViewBuilder
    private var addPageButton: some View {
        EmptyView()
    }

    @ViewBuilder
    private var addPDFButton: some View {
        EmptyView()
    }

    @ViewBuilder
    private var removePageButton: some View {
        EmptyView()
    }

    
    private func insertPDF() {
        guard let pdfURL = selectedPDFURL else { return }
        
        let targetPosition: Int
        switch insertMethod {
        case .atFront:
            targetPosition = 0
            print("📥 Inserting PDF at front")
        case .atEnd:
            targetPosition = pdfManager.pageCount
            print("📥 Inserting PDF at end")
        case .afterPage:
            if let pageNum = Int(insertPosition), pageNum > 0 && pageNum <= pdfManager.pageCount {
                targetPosition = pageNum
                print("📥 Inserting PDF after page \(pageNum)")
            } else {
                print("❌ Invalid page number: \(insertPosition)")
                return
            }
        }
        
        pdfManager.insertPDF(from: pdfURL, at: targetPosition)
        
        // ✅ Reset all state
        selectedPDFURL = nil
        insertPosition = ""
        insertMethod = .atEnd
        showPageNumberInput = false
    }
    
    private func deletePage(at index: Int) {
        print("🗑️ Deleting page \(index + 1)")
        pdfManager.deletePage(at: index)
        
        // ✅ FIXED: Reset all drag state after delete
        draggedPageIndex = nil
        pageToDelete = nil
        
        if pdfManager.currentPageIndex >= pdfManager.pageCount {
            pdfManager.currentPageIndex = max(0, pdfManager.pageCount - 1)
        }
    }
}

#Preview {
    PDFThumbnailSidebar(
        pdfManager: PDFManager(),
        isOpen: .constant(true)
    )
}
