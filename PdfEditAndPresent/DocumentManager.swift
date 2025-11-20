//
//  DocumentManager.swift
//  PdfEditAndPresent
//
//  Created by Claude on 2025-11-19.
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import Combine

/// Singleton manager for document-level operations
final class DocumentManager: ObservableObject {
    static let shared = DocumentManager()

    // MARK: - Published Properties
    @Published var currentFileName: String = "Untitled.pdf"
    @Published var showSaveAsExporter: Bool = false
    @Published var showChangeFileSizeSheet: Bool = false

    // MARK: - Internal References
    var fileURL: URL? {
        pdfViewModel?.currentURL
    }

    var hasUnsavedChanges: Bool {
        get { pdfViewModel?.hasUnsavedChanges ?? false }
        set { pdfViewModel?.hasUnsavedChanges = newValue }
    }

    /// Returns true if the document has never been saved (no fileURL)
    var isNewUnsavedDocument: Bool {
        fileURL == nil
    }

    // MARK: - Dependencies
    weak var pdfViewModel: PDFViewModel?
    weak var pdfManager: PDFManager?

    // MARK: - Callbacks
    var onSaveAsRequested: ((@escaping (Bool) -> Void) -> Void)?
    var saveCompletionHandler: ((Bool) -> Void)?

    private init() {}

    // MARK: - Setup
    func configure(with viewModel: PDFViewModel, pdfManager: PDFManager) {
        self.pdfViewModel = viewModel
        self.pdfManager = pdfManager
        updateCurrentFileName()
    }

    func updateCurrentFileName() {
        if let url = fileURL {
            currentFileName = url.deletingPathExtension().lastPathComponent
        } else {
            currentFileName = "Untitled"
        }
    }

    // MARK: - Save Operations

    /// Saves the document, or prompts for Save As if it's a new/untitled document
    /// - Parameter completion: Called with true if save succeeded, false if cancelled or failed
    func saveOrPromptIfUntitled(completion: ((Bool) -> Void)? = nil) {
        if fileURL != nil {
            // Existing file - save in place
            let success = saveDocument()
            completion?(success)
        } else {
            // New/untitled document - trigger Save As flow
            saveCompletionHandler = completion
            if let onSaveAs = onSaveAsRequested {
                onSaveAs { [weak self] success in
                    self?.saveCompletionHandler?(success)
                    self?.saveCompletionHandler = nil
                }
            } else {
                // Fallback: trigger the exporter state
                showSaveAsExporter = true
            }
        }
    }

    /// Saves the current document to its existing URL
    /// - Returns: true if save succeeded
    @discardableResult
    func saveDocument() -> Bool {
        guard let document = pdfViewModel?.currentDocument,
              let url = fileURL else {
            print("❌ Cannot save: no document or URL")
            return false
        }

        let success = document.write(to: url)

        if success {
            print("✅ PDF saved successfully to: \(url.lastPathComponent)")
            hasUnsavedChanges = false
        } else {
            print("❌ Failed to write PDF to: \(url.lastPathComponent)")
        }

        return success
    }

    /// Completes Save As flow after user selects location
    func completeSaveAs(to url: URL) {
        guard let document = pdfViewModel?.currentDocument else {
            saveCompletionHandler?(false)
            saveCompletionHandler = nil
            return
        }

        let oldURL = pdfViewModel?.currentURL
        let success = document.write(to: url)

        if success {
            pdfViewModel?.currentURL = url
            hasUnsavedChanges = false
            updateCurrentFileName()

            // Update recent files
            RecentFilesManager.shared.updateAfterSaveAsOrRename(from: oldURL, to: url)

            print("✅ Document saved as: \(url.lastPathComponent)")
        }

        saveCompletionHandler?(success)
        saveCompletionHandler = nil
    }

    /// Called when user cancels Save As dialog
    func cancelSaveAs() {
        saveCompletionHandler?(false)
        saveCompletionHandler = nil
    }

    // MARK: - Page Size Operations

    /// Sets the page size for all pages in the document
    func setPageSize(widthPoints: CGFloat, heightPoints: CGFloat) {
        pdfManager?.setPageSize(widthPoints: Double(widthPoints), heightPoints: Double(heightPoints))
    }

    // MARK: - PDF Optimization

    func presentChangeFileSizeSheet() {
        showChangeFileSizeSheet = true
    }

    /// Rewrites the PDF with optimization options
    func rewritePDF(with options: PDFOptimizeOptions, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let document = pdfViewModel?.currentDocument else {
            completion(.failure(DocumentManagerError.noDocument))
            return
        }

        // Determine source URL - use existing fileURL or create temp for new docs
        let sourceURL: URL
        let isNewDocument = (fileURL == nil)

        if let existingURL = fileURL {
            sourceURL = existingURL
        } else {
            // New/unsaved document - write to temp first
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("pdf")

            guard document.write(to: tempURL) else {
                completion(.failure(DocumentManagerError.optimizationFailed))
                return
            }
            sourceURL = tempURL
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let optimizedURL = try self?.optimizePDF(document: document, sourceURL: sourceURL, options: options, isNewDocument: isNewDocument)

                DispatchQueue.main.async {
                    if let url = optimizedURL {
                        // Replace current document with optimized version
                        if let optimizedDoc = PDFDocument(url: url) {
                            self?.pdfViewModel?.currentDocument = optimizedDoc
                            self?.pdfManager?.setPDFDocument(optimizedDoc)

                            // For new documents, adopt the temp URL as the new fileURL
                            if isNewDocument {
                                self?.pdfViewModel?.currentURL = url
                                self?.updateCurrentFileName()
                            }

                            self?.hasUnsavedChanges = false

                            // Update recent files
                            RecentFilesManager.shared.addOrBump(url: url)

                            completion(.success(url))
                        } else {
                            completion(.failure(DocumentManagerError.failedToLoadOptimized))
                        }
                    } else {
                        completion(.failure(DocumentManagerError.optimizationFailed))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func optimizePDF(document: PDFDocument, sourceURL: URL, options: PDFOptimizeOptions, isNewDocument: Bool = false) throws -> URL {
        // Create output URL
        let tempDir = FileManager.default.temporaryDirectory
        let outputFilename = sourceURL.deletingPathExtension().lastPathComponent + "_optimized.pdf"
        let outputURL = tempDir.appendingPathComponent(outputFilename)

        // If original preset, just copy the file
        if options.preset == .original {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)

            // For new documents with original preset, return the temp URL
            if isNewDocument {
                return outputURL
            }
            return outputURL
        }

        // Create PDF context for output
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // Default letter size

        guard let context = CGContext(outputURL as CFURL, mediaBox: &mediaBox, nil) else {
            throw DocumentManagerError.failedToCreateContext
        }

        // Process each page
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            let pageRect = page.bounds(for: .mediaBox)

            // Begin new page
            context.beginPDFPage(nil)

            // Calculate render scale based on DPI settings
            let renderScale: CGFloat
            if options.downsampleImages {
                renderScale = options.maxImageDPI / 72.0
            } else {
                renderScale = 1.0
            }

            // Render page to image for compression
            let renderWidth = pageRect.width * renderScale
            let renderHeight = pageRect.height * renderScale

            // Create bitmap context for rendering
            let colorSpace: CGColorSpace
            if options.grayscaleImages {
                colorSpace = CGColorSpaceCreateDeviceGray()
            } else {
                colorSpace = CGColorSpaceCreateDeviceRGB()
            }

            let bitmapInfo: UInt32
            if options.grayscaleImages {
                bitmapInfo = CGImageAlphaInfo.none.rawValue
            } else {
                bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            }

            guard let bitmapContext = CGContext(
                data: nil,
                width: Int(renderWidth),
                height: Int(renderHeight),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                context.endPDFPage()
                continue
            }

            // Fill with white background
            bitmapContext.setFillColor(UIColor.white.cgColor)
            bitmapContext.fill(CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight))

            // Scale and render PDF page
            bitmapContext.scaleBy(x: renderScale, y: renderScale)

            // Draw PDF content
            if options.flattenAnnotations {
                // Render with annotations flattened
                page.draw(with: .mediaBox, to: bitmapContext)
            } else {
                // Render without annotations (they'll be preserved separately if possible)
                page.draw(with: .mediaBox, to: bitmapContext)
            }

            // Get rendered image
            guard let renderedImage = bitmapContext.makeImage() else {
                context.endPDFPage()
                continue
            }

            // Compress as JPEG
            let uiImage = UIImage(cgImage: renderedImage)
            guard let jpegData = uiImage.jpegData(compressionQuality: options.imageQuality) else {
                context.endPDFPage()
                continue
            }

            // Create compressed image
            guard let compressedImage = UIImage(data: jpegData)?.cgImage else {
                context.endPDFPage()
                continue
            }

            // Draw compressed image back to PDF context
            context.draw(compressedImage, in: pageRect)

            context.endPDFPage()
        }

        context.closePDF()

        // For new documents, keep in temp directory
        if isNewDocument {
            return outputURL
        }

        // Replace original file with optimized version
        let finalURL = sourceURL

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: outputURL, to: finalURL)

        return finalURL
    }
}

// MARK: - Errors

enum DocumentManagerError: LocalizedError {
    case noDocument
    case failedToCreateContext
    case optimizationFailed
    case failedToLoadOptimized

    var errorDescription: String? {
        switch self {
        case .noDocument:
            return "No document available to optimize"
        case .failedToCreateContext:
            return "Failed to create PDF context"
        case .optimizationFailed:
            return "PDF optimization failed"
        case .failedToLoadOptimized:
            return "Failed to load optimized PDF"
        }
    }
}

// MARK: - PDF Optimize Options

struct PDFOptimizeOptions {
    enum Preset: String, CaseIterable {
        case original = "Original"
        case smaller = "Smaller"
        case smallest = "Smallest"
        case custom = "Custom"
    }

    var preset: Preset
    var imageQuality: CGFloat      // 0.40...1.00
    var maxImageDPI: CGFloat       // 72...600
    var downsampleImages: Bool
    var grayscaleImages: Bool
    var stripMetadata: Bool
    var flattenAnnotations: Bool
    var recompressStreams: Bool

    static let original = PDFOptimizeOptions(
        preset: .original,
        imageQuality: 1.0,
        maxImageDPI: 600,
        downsampleImages: false,
        grayscaleImages: false,
        stripMetadata: false,
        flattenAnnotations: false,
        recompressStreams: false
    )

    static let smaller = PDFOptimizeOptions(
        preset: .smaller,
        imageQuality: 0.75,
        maxImageDPI: 144,
        downsampleImages: true,
        grayscaleImages: false,
        stripMetadata: true,
        flattenAnnotations: false,
        recompressStreams: true
    )

    static let smallest = PDFOptimizeOptions(
        preset: .smallest,
        imageQuality: 0.6,
        maxImageDPI: 96,
        downsampleImages: true,
        grayscaleImages: false,
        stripMetadata: true,
        flattenAnnotations: true,
        recompressStreams: true
    )
}

// MARK: - PDF File Document for FileExporter

struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    var pdfDocument: PDFDocument?

    init(pdfDocument: PDFDocument?) {
        self.pdfDocument = pdfDocument
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            pdfDocument = PDFDocument(data: data)
        } else {
            pdfDocument = nil
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let document = pdfDocument,
              let data = document.dataRepresentation() else {
            throw DocumentManagerError.noDocument
        }
        return FileWrapper(regularFileWithContents: data)
    }
}
