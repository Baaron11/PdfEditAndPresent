//
//  PDFSettingsSheet.swift
//  UnifiedBoard
//
//  Created by Brandon Ramirez on 11/7/25.
//


import SwiftUI

// MARK: - PDF Settings Sheet
struct PDFSettingsSheet: View {
    @ObservedObject var pdfManager: PDFManager
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("Display Mode") {
                    Picker("Viewing Mode", selection: $pdfManager.displayMode) {
                        Text("Single Page").tag(PDFDisplayMode.singlePage)
                        Text("Continuous Scroll").tag(PDFDisplayMode.continuousScroll)
                    }
                    
                    Text(modeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Zoom") {
                    HStack {
                        Text("Zoom Level")
                        Spacer()
                        Text("\(Int(pdfManager.zoomLevel * 100))%")
                            .fontWeight(.semibold)
                    }
                    
                    Slider(
                        value: $pdfManager.zoomLevel,
                        in: pdfManager.minZoom...pdfManager.maxZoom,
                        step: 0.1
                    )
                    
                    HStack(spacing: 12) {
                        Button(action: { pdfManager.zoomOut() }) {
                            Label("Zoom Out", systemImage: "minus.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: { pdfManager.zoomToFit() }) {
                            Label("Fit", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: { pdfManager.zoomIn() }) {
                            Label("Zoom In", systemImage: "plus.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
                Section("Information") {
                    HStack {
                        Text("Total Pages")
                        Spacer()
                        Text("\(pdfManager.pageCount)")
                            .fontWeight(.semibold)
                    }
                    
                    HStack {
                        Text("Current Page")
                        Spacer()
                        Text("\(pdfManager.currentPageIndex + 1)")
                            .fontWeight(.semibold)
                    }
                }
            }
            .navigationTitle("PDF Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var modeDescription: String {
        switch pdfManager.displayMode {
        case .singlePage:
            return "Display one page at a time. Navigate using page controls."
        case .continuousScroll:
            return "Scroll continuously through all pages. Scroll to navigate."
        }
    }
}

#Preview {
    PDFSettingsSheet(pdfManager: PDFManager())
}