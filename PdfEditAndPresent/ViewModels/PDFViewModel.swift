//
//  PDFViewModel.swift
//  UnifiedBoard
//
//  Created by Brandon Ramirez on 11/7/25.
//


// PDFViewModel.swift
// Location: Shared/ViewModels/PDFViewModel.swift

import SwiftUI
import PDFKit
import Combine

class PDFViewModel: ObservableObject {
    @Published var currentDocument: PDFDocument?
    @Published var currentURL: URL?
    @Published var hasUnsavedChanges = false
    @Published var recentFiles: [URL]?
    
  
    
    private var cancellables = Set<AnyCancellable>()
    var pdfManager: PDFManager?
    
    init() {
        loadRecentFiles()
    }
    
    // MARK: - Create New PDF

    func createNewPDF() {
        let page = PDFPage()
        _ = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)

        let document = PDFDocument()
        document.insert(page, at: 0)

        currentDocument = document

        // New document starts without a file - Save will trigger Save As
        currentURL = nil
        hasUnsavedChanges = true

        print("✅ Created new blank PDF (unsaved)")
    }
    
    func createNewPDFWithDrawingSupport(drawingViewModel: DrawingViewModel) {
        createNewPDF()
        drawingViewModel.clearAllDrawings()
    }
    // MARK: - Setup PDF Manager (Wire up unsaved changes callbacks)
    func setupPDFManager(_ manager: PDFManager) {
        self.pdfManager = manager
        
        // ✅ Wire up document changes (page reordering, adding/deleting pages, inserting PDFs)
        manager.onDocumentChanged = { [weak self] in
            self?.hasUnsavedChanges = true
            
            // ✅ CRITICAL: Keep currentDocument in sync with pdfManager's updated document
            self?.currentDocument = manager.pdfDocument
            
            print("📝 Document changed - unsaved changes flag set to true")
            print("📄 Updated currentDocument to latest version from PDFManager")
        }
        
        // ✅ Wire up margin settings changes
        manager.onMarginSettingsChanged = { [weak self] in
            self?.hasUnsavedChanges = true
            print("📐 Margin settings changed - unsaved changes flag set to true")
        }
    }
    
    
    // MARK: - Load PDF
    
    func loadPDF(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        guard let document = PDFDocument(url: url) else {
            print("❌ Failed to load PDF from: \(url.lastPathComponent)")
            return
        }
        
        currentDocument = document
        currentURL = url
        hasUnsavedChanges = false

        // Update recent files using new manager
        RecentFilesManager.shared.addOrBump(url: url)
        addToRecentFiles(url) // Keep old system for backward compatibility

        print("✅ Loaded PDF: \(url.lastPathComponent)")
    }
    
    func loadPDFWithDrawings(from url: URL, drawingViewModel: DrawingViewModel) {
        let accessing = url.startAccessingSecurityScopedResource()
        
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        guard let document = PDFDocument(url: url) else {
            print("❌ Failed to load PDF from: \(url.lastPathComponent)")
            return
        }
        
        currentDocument = document
        currentURL = url
        hasUnsavedChanges = false
        
        let loadedDrawings = DrawingPersistence.loadDrawingsHybrid(from: document, at: url)
        
        if !loadedDrawings.isEmpty {
            drawingViewModel.importDrawings(loadedDrawings)
            print("✅ Loaded PDF with \(loadedDrawings.count) pages of drawings")
        } else {
            drawingViewModel.clearAllDrawings()
            print("✅ Loaded PDF (no drawings)")
        }

        // Update recent files using new manager
        RecentFilesManager.shared.addOrBump(url: url)
        addToRecentFiles(url) // Keep old system for backward compatibility
    }
    
    // MARK: - Save Functionality
    
    func saveCurrentDocument() {
            guard let document = currentDocument,
                  let url = currentURL else {
                print("❌ Cannot save: no document or URL")
                return
            }
            
            
            
            let success = document.write(to: url)
            
            if success {
                print("✅ PDF saved successfully to: \(url.lastPathComponent)")
                hasUnsavedChanges = false
            } else {
                print("❌ Failed to write PDF to: \(url.lastPathComponent)")
            }
        }
    
    func saveDocumentWithDrawings(drawingViewModel: DrawingViewModel) {
        guard let document = currentDocument,
              let url = currentURL else {
            print("❌ Cannot save: no document or URL")
            return
        }
        
        let drawings = drawingViewModel.drawings
        
        DrawingPersistence.saveDrawingsHybrid(drawings, to: document, at: url)
        
        let success = document.write(to: url)
        
        if success {
            print("✅ PDF saved successfully with \(drawings.count) pages of drawings")
            hasUnsavedChanges = false
            drawingViewModel.resetModifiedState()
        } else {
            print("❌ Failed to write PDF to disk")
        }
    }
    
    // ✅ UPDATED: Save as Copy with custom filename - preserves margin settings
    func saveAsNewDocument(_ document: PDFDocument, withName customName: String? = nil, pdfManager: PDFManager? = nil) {
        guard let url = currentURL else {
            print("❌ Cannot save as copy: no current URL")
            return
        }
        
        let documentsDirectory = url.deletingLastPathComponent()
        
        // Use custom name if provided, otherwise use default "filename_copy"
        let filename: String
        if let customName = customName, !customName.isEmpty {
            // Add .pdf extension if not already present
            if customName.lowercased().hasSuffix(".pdf") {
                filename = customName
            } else {
                filename = "\(customName).pdf"
            }
        } else {
            // Default: original_copy.pdf
            let originalName = url.deletingPathExtension().lastPathComponent
            filename = "\(originalName)_copy.pdf"
        }
        
        let newURL = documentsDirectory.appendingPathComponent(filename)
        
        // Check if file already exists
        if FileManager.default.fileExists(atPath: newURL.path) {
            print("⚠️ File already exists: \(filename)")
            return
        }
        
        let success = document.write(to: newURL)
        
        if success {
            print("✅ PDF copy saved to: \(newURL.lastPathComponent)")

            // Preserve margin settings if PDFManager is provided
            if let pdfManager = pdfManager {
                preserveMarginSettings(from: url, to: newURL, pdfManager: pdfManager)
            }

            // Update recent files
            RecentFilesManager.shared.updateAfterSaveAsOrRename(from: url, to: newURL)

            currentURL = newURL
            hasUnsavedChanges = false
            addToRecentFiles(newURL) // Keep old system for backward compatibility
        } else {
            print("❌ Failed to save PDF copy")
        }
    }
    
    // ✅ NEW: Helper function to transfer margin settings from old PDF to new PDF
    private func preserveMarginSettings(from oldURL: URL, to newURL: URL, pdfManager: PDFManager) {
        guard let document = PDFDocument(url: newURL) else {
            print("⚠️ Could not load newly saved copy to transfer margins")
            return
        }
        
        let pageCount = document.pageCount
        
        // Create keys for both old and new PDF locations
        let oldFileName = oldURL.lastPathComponent
        let newFileName = newURL.lastPathComponent
        let oldKey = "margins_\(oldFileName)_pages_\(pageCount)"
        let newKey = "margins_\(newFileName)_pages_\(pageCount)"
        
        // Try to load margin settings from the old PDF
        if let marginData = UserDefaults.standard.data(forKey: oldKey) {
            if let decodedMargins = try? JSONDecoder().decode([MarginSettings].self, from: marginData) {
                // Save to new PDF's key
                if let encodedMargins = try? JSONEncoder().encode(decodedMargins) {
                    UserDefaults.standard.set(encodedMargins, forKey: newKey)
                    print("✅ Transferred margin settings from \(oldFileName) to \(newFileName)")
                }
            }
        } else {
            print("ℹ️ No margin settings to transfer for original PDF")
        }
    }
    
    func saveAsNewDocumentWithDrawings(_ document: PDFDocument, drawingViewModel: DrawingViewModel) {
        guard let url = currentURL else {
            print("❌ Cannot save as copy: no current URL")
            return
        }
        
        let filename = url.deletingPathExtension().lastPathComponent
        let timestamp = Date().timeIntervalSince1970
        let newFilename = "\(filename) Copy \(Int(timestamp)).pdf"
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newFilename)
        
        let drawings = drawingViewModel.drawings
        
        DrawingPersistence.saveDrawingsHybrid(drawings, to: document, at: newURL)
        
        let success = document.write(to: newURL)
        
        if success {
            print("✅ PDF copy saved to: \(newURL.lastPathComponent)")
            loadPDFWithDrawings(from: newURL, drawingViewModel: drawingViewModel)
        } else {
            print("❌ Failed to save PDF copy")
        }
    }
    
    // MARK: - Rename Functionality
    
    func renameCurrentPDF(to newName: String) {
        guard let currentURL = currentURL else {
            print("❌ Cannot rename: no current URL")
            return
        }
        
        var cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !cleanName.hasSuffix(".pdf") {
            cleanName += ".pdf"
        }
        
        let directory = currentURL.deletingLastPathComponent()
        let newURL = directory.appendingPathComponent(cleanName)
        
        if FileManager.default.fileExists(atPath: newURL.path) && newURL != currentURL {
            print("❌ File already exists with that name")
            return
        }
        
        do {
            try FileManager.default.moveItem(at: currentURL, to: newURL)

            // Update recent files with new name
            RecentFilesManager.shared.updateAfterSaveAsOrRename(from: currentURL, to: newURL)

            self.currentURL = newURL

            print("✅ PDF renamed to: \(cleanName)")

            updateRecentFiles() // Keep old system for backward compatibility

        } catch {
            print("❌ Failed to rename PDF: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Recent Files Management
    
    private func loadRecentFiles() {
        if let paths = UserDefaults.standard.stringArray(forKey: "recentPDFs") {
            recentFiles = paths.compactMap { path in
                let url = URL(fileURLWithPath: path)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }
    }
    
    private func addToRecentFiles(_ url: URL) {
        var recent = recentFiles ?? []
        
        recent.removeAll { $0 == url }
        
        recent.insert(url, at: 0)
        
        if recent.count > 10 {
            recent = Array(recent.prefix(10))
        }
        
        recentFiles = recent
        
        let paths = recent.map { $0.path }
        UserDefaults.standard.set(paths, forKey: "recentPDFs")
    }
    
    private func updateRecentFiles() {
        if let currentURL = currentURL {
            addToRecentFiles(currentURL)
        }
    }
}
