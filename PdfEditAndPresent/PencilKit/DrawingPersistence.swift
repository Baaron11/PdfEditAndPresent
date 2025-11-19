//
//  DrawingPersistence.swift
//  UnifiedBoard
//
//  Created by Brandon Ramirez on 11/7/25.
//


//
//  DrawingPersistence.swift
//  PDFMaster
//
//  Created by Brandon Ramirez on 10/18/25.
//


// DrawingPersistence.swift
// Location: Shared/Utils/DrawingPersistence.swift
//
// Handles saving and loading drawings to/from PDF metadata

import Foundation
import PDFKit
import PencilKit

enum DrawingPersistence {
    
    private static let drawingDataKey = "com.pdfmaster.drawings"
    private static let drawingVersionKey = "com.pdfmaster.drawings.version"
    private static let currentVersion = "1.0"
    
    // MARK: - Save Drawings to PDF
    
    /// Save all drawings into the PDF document's metadata
    /// - Parameters:
    ///   - drawings: Dictionary of page index to PKDrawing
    ///   - document: The PDF document to save to
    static func saveDrawings(_ drawings: [Int: PKDrawing], to document: PDFDocument) {
        do {
            // Convert drawings to data dictionary
            var drawingsData: [String: Data] = [:]
            
            for (pageIndex, drawing) in drawings {
                let drawingData = drawing.dataRepresentation()
                drawingsData[String(pageIndex)] = drawingData
            }
            
            // Encode to JSON
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(drawingsData)
            
            // Save to PDF document attributes
            var attributes = document.documentAttributes ?? [:]
            attributes[PDFDocumentAttribute.keywordsAttribute] = [drawingDataKey]
            attributes[PDFDocumentAttribute(rawValue: drawingDataKey)] = jsonData
            attributes[PDFDocumentAttribute(rawValue: drawingVersionKey)] = currentVersion
            
            document.documentAttributes = attributes
            
            print("✅ Saved \(drawings.count) drawings to PDF metadata")
            
        } catch {
            print("❌ Failed to save drawings: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Load Drawings from PDF
    
    /// Load drawings from PDF document's metadata
    /// - Parameter document: The PDF document to load from
    /// - Returns: Dictionary of page index to PKDrawing
    static func loadDrawings(from document: PDFDocument) -> [Int: PKDrawing] {
        guard let attributes = document.documentAttributes,
              let jsonData = attributes[PDFDocumentAttribute(rawValue: drawingDataKey)] as? Data
        else {
            print("ℹ️ No drawings found in PDF metadata")
            return [:]
        }
        
        do {
            // Decode from JSON
            let decoder = JSONDecoder()
            let drawingsData = try decoder.decode([String: Data].self, from: jsonData)
            
            // Convert back to PKDrawing dictionary
            var drawings: [Int: PKDrawing] = [:]
            
            for (pageIndexString, drawingData) in drawingsData {
                guard let pageIndex = Int(pageIndexString),
                      let drawing = try? PKDrawing(data: drawingData)
                else { continue }
                
                drawings[pageIndex] = drawing
            }
            
            print("✅ Loaded \(drawings.count) drawings from PDF metadata")
            return drawings
            
        } catch {
            print("❌ Failed to load drawings: \(error.localizedDescription)")
            return [:]
        }
    }
    
    // MARK: - Alternative: Sidecar File Persistence
    
    /// Save drawings to a sidecar JSON file (fallback option)
    /// - Parameters:
    ///   - drawings: Dictionary of page index to PKDrawing
    ///   - pdfURL: The URL of the PDF file
    static func saveDrawingsToSidecar(_ drawings: [Int: PKDrawing], for pdfURL: URL) {
        do {
            // Create sidecar filename: "document.pdf" -> "document.pdf.drawings.json"
            let sidecarURL = pdfURL.appendingPathExtension("drawings.json")
            
            // Convert drawings to data dictionary
            var drawingsData: [String: Data] = [:]
            
            for (pageIndex, drawing) in drawings {
                let drawingData = drawing.dataRepresentation()
                drawingsData[String(pageIndex)] = drawingData
            }
            
            // Encode to JSON
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let jsonData = try encoder.encode(drawingsData)
            
            // Write to file
            try jsonData.write(to: sidecarURL)
            
            print("✅ Saved \(drawings.count) drawings to sidecar: \(sidecarURL.lastPathComponent)")
            
        } catch {
            print("❌ Failed to save sidecar drawings: \(error.localizedDescription)")
        }
    }
    
    /// Load drawings from a sidecar JSON file
    /// - Parameter pdfURL: The URL of the PDF file
    /// - Returns: Dictionary of page index to PKDrawing
    static func loadDrawingsFromSidecar(for pdfURL: URL) -> [Int: PKDrawing] {
        let sidecarURL = pdfURL.appendingPathExtension("drawings.json")
        
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            print("ℹ️ No sidecar file found")
            return [:]
        }
        
        do {
            let jsonData = try Data(contentsOf: sidecarURL)
            
            let decoder = JSONDecoder()
            let drawingsData = try decoder.decode([String: Data].self, from: jsonData)
            
            var drawings: [Int: PKDrawing] = [:]
            
            for (pageIndexString, drawingData) in drawingsData {
                guard let pageIndex = Int(pageIndexString),
                      let drawing = try? PKDrawing(data: drawingData)
                else { continue }
                
                drawings[pageIndex] = drawing
            }
            
            print("✅ Loaded \(drawings.count) drawings from sidecar")
            return drawings
            
        } catch {
            print("❌ Failed to load sidecar drawings: \(error.localizedDescription)")
            return [:]
        }
    }
    
    // MARK: - Hybrid Approach (Recommended)
    
    /// Save using both PDF metadata and sidecar file for redundancy
    static func saveDrawingsHybrid(_ drawings: [Int: PKDrawing], to document: PDFDocument, at url: URL) {
        // Save to PDF metadata (primary)
        saveDrawings(drawings, to: document)
        
        // Also save to sidecar file (backup)
        saveDrawingsToSidecar(drawings, for: url)
    }
    
    /// Load from either PDF metadata or sidecar file (whichever is available)
    static func loadDrawingsHybrid(from document: PDFDocument, at url: URL) -> [Int: PKDrawing] {
        // Try PDF metadata first
        let metadataDrawings = loadDrawings(from: document)
        
        if !metadataDrawings.isEmpty {
            return metadataDrawings
        }
        
        // Fallback to sidecar file
        return loadDrawingsFromSidecar(for: url)
    }
}
