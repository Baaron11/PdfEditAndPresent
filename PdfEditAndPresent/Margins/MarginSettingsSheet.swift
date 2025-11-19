import SwiftUI

// MARK: - Margin Settings Sheet (dynamic page size + restored UI)
struct MarginSettingsSheet: View {
    @ObservedObject var pdfManager: PDFManager
    @Environment(\.dismiss) var dismiss
    
    @State private var isEnabled: Bool = false
    @State private var anchorPosition: AnchorPosition = .topLeft   // default when enabling
    @State private var pdfScale: CGFloat = 0.8                     // default when enabling
    @State private var applyToAllPages: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header
            HStack {
                Text("Margin Settings")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.gray)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            
            Divider()
            
            // MARK: Enable Margins Toggle
            HStack {
                Text("Enable Margins")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Toggle("", isOn: $isEnabled)
                    .onChange(of: isEnabled) { oldValue, newValue in
                        if newValue {
                            // Smart defaults on enable
                            anchorPosition = .topLeft
                            pdfScale = 0.8
                        }
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            
            // Only show controls when enabled
            if isEnabled {
                Divider()
                
                // MARK: Main content (side-by-side)
                HStack(spacing: 40) {
                    // LEFT: Position grid + Scale + Apply-To
                    VStack(alignment: .leading, spacing: 24) {
                        // Page Position Grid
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Page Position")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            VStack(spacing: 10) {
                                ForEach([0, 1, 2], id: \.self) { row in
                                    HStack(spacing: 10) {
                                        ForEach([0, 1, 2], id: \.self) { col in
                                            let position = AnchorPosition.allCases.first {
                                                let (r, c) = $0.gridPosition
                                                return r == row && c == col
                                            }
                                            
                                            if let position = position {
                                                Button(action: { anchorPosition = position }) {
                                                    Image(systemName: position.symbolName)
                                                        .font(.system(size: 14))
                                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                        .aspectRatio(1, contentMode: .fit)
                                                        .background(
                                                            anchorPosition == position
                                                                ? Color.blue
                                                                : Color.gray.opacity(0.15)
                                                        )
                                                        .foregroundColor(
                                                            anchorPosition == position ? .white : .gray
                                                        )
                                                        .cornerRadius(8)
                                                }
                                            }
                                        }
                                    }
                                    .frame(height: 44)
                                }
                            }
                        }
                        
                        // Scale Slider
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Scale")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(pdfScale * 100))%")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                            
                            Slider(value: $pdfScale, in: 0.1...1.0, step: 0.05)
                                .tint(.blue)
                        }
                        
                        // Apply To
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Apply To")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 12) {
                                Button(action: { applyToAllPages = false }) {
                                    Text("Current Page")
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .background(applyToAllPages ? Color.gray.opacity(0.1) : Color.blue)
                                        .foregroundColor(applyToAllPages ? .gray : .white)
                                        .cornerRadius(8)
                                }
                                
                                Button(action: { applyToAllPages = true }) {
                                    Text("All Pages")
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 9)
                                        .background(applyToAllPages ? Color.blue : Color.gray.opacity(0.1))
                                        .foregroundColor(applyToAllPages ? .white : .gray)
                                        .cornerRadius(8)
                                }
                            }
                        }
                        
                        Spacer()
                    }
                    .frame(maxWidth: 160)
                    
                    // RIGHT: Dynamic Preview (matches actual page size/orientation)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Preview")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        previewCanvas
                            .frame(maxWidth: .infinity)
                            .aspectRatio(dynamicAspectRatio, contentMode: .fit)
                            .border(Color.gray.opacity(0.3))
                            .cornerRadius(8)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                Divider()
            }
            
            // MARK: Action Buttons
            HStack(spacing: 12) {
                Button(action: { dismiss() }) {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.gray.opacity(0.1))
                        .foregroundColor(.gray)
                        .cornerRadius(8)
                }
                
                Button(action: applySettings) {
                    Text("Apply")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
        .presentationDetents(isEnabled ? [.large] : [.fraction(0.25)])
        .presentationDragIndicator(.hidden)
        .onAppear(perform: loadCurrentSettings)
        // If page changes while the sheet is open, keep the preview/settings in sync
        .onChange(of: pdfManager.currentPageIndex) {
            loadCurrentSettings()
        }
    }
    
    // MARK: - Helpers
    
    private func loadCurrentSettings() {
        let currentSettings = pdfManager.getMarginSettings(for: pdfManager.currentPageIndex)
        isEnabled = currentSettings.isEnabled
        anchorPosition = currentSettings.anchorPosition
        pdfScale = currentSettings.pdfScale
        applyToAllPages = currentSettings.appliedToAllPages
    }
    
    private var currentPageSize: CGSize {
        pdfManager.getCurrentPageEffectiveSize()
    }
    
    private var dynamicAspectRatio: CGFloat {
        // Avoid divide-by-zero; matches current page orientation/size
        max(0.1, currentPageSize.width / max(1, currentPageSize.height))
    }
    
    private var previewCanvas: some View {
        let helper = MarginCanvasHelper(
            settings: MarginSettings(
                isEnabled: isEnabled,
                anchorPosition: anchorPosition,
                pdfScale: pdfScale
            ),
            originalPDFSize: currentPageSize,
            canvasSize: currentPageSize   // preserve page size; margins appear inside
        )
        
        return GeometryReader { geometry in
            ZStack {
                // Page canvas background
                Rectangle().fill(Color(.systemGray6))
                
                // PDF area (white) positioned and scaled by current settings
                let pdfFrame = helper.pdfFrameInCanvas
                let canvas = helper.canvasSize
                
                let scaleX = geometry.size.width / max(1, canvas.width)
                let scaleY = geometry.size.height / max(1, canvas.height)
                
                let x = pdfFrame.origin.x * scaleX
                let y = pdfFrame.origin.y * scaleY
                let width = pdfFrame.width * scaleX
                let height = pdfFrame.height * scaleY
                
                Rectangle()
                    .fill(Color.white)
                    .border(Color.gray.opacity(0.5), width: 1)
                    .frame(width: width, height: height)
                    .position(x: x + width / 2, y: y + height / 2)
            }
        }
    }
    
    private func applySettings() {
        let newSettings = MarginSettings(
            isEnabled: isEnabled,
            anchorPosition: anchorPosition,
            pdfScale: pdfScale,
            appliedToAllPages: applyToAllPages
        )
        if applyToAllPages {
            pdfManager.applyMarginSettingsToAllPagesWithTracking(newSettings)
        } else {
            pdfManager.applyMarginSettingsToCurrentPageWithTracking(newSettings)
        }
        dismiss()
    }
}
