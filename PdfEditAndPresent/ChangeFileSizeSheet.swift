//
//  ChangeFileSizeSheet.swift
//  PdfEditAndPresent
//
//  Created by Claude on 11/19/25.
//

import SwiftUI

struct ChangeFileSizeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var pdfManager: PDFManager

    @State private var unit: SizeUnit = .inches
    @State private var selection: PagePreset = .letter
    @State private var width: Double = 8.5
    @State private var height: Double = 11.0
    @State private var isPortrait: Bool = true

    enum SizeUnit: String, CaseIterable {
        case inches = "in"
        case millimeters = "mm"
        case points = "pt"
    }

    enum PagePreset: String, CaseIterable {
        case letter = "Letter (8.5×11 in)"
        case legal = "Legal (8.5×14 in)"
        case tabloid = "Tabloid (11×17 in)"
        case a5 = "A5 (148×210 mm)"
        case a4 = "A4 (210×297 mm)"
        case a3 = "A3 (297×420 mm)"
        case a2 = "A2 (420×594 mm)"
        case a1 = "A1 (594×841 mm)"
        case custom = "Custom…"

        var sizeInPoints: (width: Double, height: Double) {
            switch self {
            case .letter: return (8.5 * 72, 11.0 * 72)
            case .legal: return (8.5 * 72, 14.0 * 72)
            case .tabloid: return (11.0 * 72, 17.0 * 72)
            case .a5: return (148 * 2.83465, 210 * 2.83465)
            case .a4: return (210 * 2.83465, 297 * 2.83465)
            case .a3: return (297 * 2.83465, 420 * 2.83465)
            case .a2: return (420 * 2.83465, 594 * 2.83465)
            case .a1: return (594 * 2.83465, 841 * 2.83465)
            case .custom: return (8.5 * 72, 11.0 * 72)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Preset picker
                Section("Page Size") {
                    Picker("Preset", selection: $selection) {
                        ForEach(PagePreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 120)
                    .onChange(of: selection) { _, newValue in
                        applyPreset(newValue)
                    }
                }

                // Unit selector
                Section("Units") {
                    Picker("Units", selection: $unit) {
                        Text("in").tag(SizeUnit.inches)
                        Text("mm").tag(SizeUnit.millimeters)
                        Text("pt").tag(SizeUnit.points)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: unit) { _, _ in
                        convertUnitsKeepingPoints()
                    }
                }

                // Custom size pickers
                if selection == .custom {
                    Section("Custom Size") {
                        HStack(spacing: 16) {
                            VStack {
                                Text("Width")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Picker("Width", selection: $width) {
                                    ForEach(widthValues, id: \.self) { value in
                                        Text(formatValue(value)).tag(value)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(height: 120)
                            }

                            VStack {
                                Text("Height")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Picker("Height", selection: $height) {
                                    ForEach(heightValues, id: \.self) { value in
                                        Text(formatValue(value)).tag(value)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(height: 120)
                            }
                        }
                    }
                }

                // Orientation toggle
                Section("Orientation") {
                    HStack {
                        Button(action: {
                            if !isPortrait {
                                isPortrait = true
                                swapDimensions()
                            }
                        }) {
                            VStack {
                                Image(systemName: "rectangle.portrait")
                                    .font(.title2)
                                Text("Portrait")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(isPortrait ? Color.blue.opacity(0.2) : Color.clear)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            if isPortrait {
                                isPortrait = false
                                swapDimensions()
                            }
                        }) {
                            VStack {
                                Image(systemName: "rectangle")
                                    .font(.title2)
                                Text("Landscape")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(!isPortrait ? Color.blue.opacity(0.2) : Color.clear)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Size preview
                Section("Preview") {
                    SizePreviewView(width: width, height: height, unit: unit)
                        .frame(height: 120)
                }
            }
            .navigationTitle("Change File Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let pts = convertToPoints()
                        pdfManager.setPageSize(widthPoints: pts.width, heightPoints: pts.height)
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadCurrentPageSize()
            }
        }
    }

    // MARK: - Computed Properties

    private var widthValues: [Double] {
        switch unit {
        case .inches:
            return Array(stride(from: 1.0, through: 60.0, by: 0.1))
        case .millimeters:
            return Array(stride(from: 10.0, through: 1500.0, by: 1.0))
        case .points:
            return Array(stride(from: 72.0, through: 4320.0, by: 1.0))
        }
    }

    private var heightValues: [Double] {
        widthValues
    }

    // MARK: - Helper Methods

    private func formatValue(_ value: Double) -> String {
        switch unit {
        case .inches:
            return String(format: "%.1f", value)
        case .millimeters, .points:
            return String(format: "%.0f", value)
        }
    }

    private func loadCurrentPageSize() {
        let currentSize = pdfManager.getCurrentPageSize()
        let widthPts = Double(currentSize.width)
        let heightPts = Double(currentSize.height)

        // Convert to current unit
        switch unit {
        case .inches:
            width = pointsToInches(widthPts)
            height = pointsToInches(heightPts)
        case .millimeters:
            width = pointsToMillimeters(widthPts)
            height = pointsToMillimeters(heightPts)
        case .points:
            width = widthPts
            height = heightPts
        }

        isPortrait = height >= width

        // Try to match a preset
        matchPreset(widthPts: widthPts, heightPts: heightPts)
    }

    private func matchPreset(widthPts: Double, heightPts: Double) {
        let tolerance = 1.0
        for preset in PagePreset.allCases where preset != .custom {
            let presetSize = preset.sizeInPoints
            let w = isPortrait ? presetSize.width : presetSize.height
            let h = isPortrait ? presetSize.height : presetSize.width

            if abs(widthPts - w) < tolerance && abs(heightPts - h) < tolerance {
                selection = preset
                return
            }
        }
        selection = .custom
    }

    private func applyPreset(_ preset: PagePreset) {
        guard preset != .custom else { return }

        let size = preset.sizeInPoints
        let widthPts = isPortrait ? size.width : size.height
        let heightPts = isPortrait ? size.height : size.width

        switch unit {
        case .inches:
            width = pointsToInches(widthPts)
            height = pointsToInches(heightPts)
        case .millimeters:
            width = pointsToMillimeters(widthPts)
            height = pointsToMillimeters(heightPts)
        case .points:
            width = widthPts
            height = heightPts
        }
    }

    private func convertUnitsKeepingPoints() {
        // First convert current values to points
        let widthPts: Double
        let heightPts: Double

        // We need the previous unit to convert from
        // Since we've already changed unit, we store points internally
        // For simplicity, recalculate from preset or keep current
        let currentPts = convertToPoints()

        // Now convert from points to new unit
        switch unit {
        case .inches:
            width = pointsToInches(currentPts.width)
            height = pointsToInches(currentPts.height)
        case .millimeters:
            width = pointsToMillimeters(currentPts.width)
            height = pointsToMillimeters(currentPts.height)
        case .points:
            width = currentPts.width
            height = currentPts.height
        }
    }

    private func swapDimensions() {
        let temp = width
        width = height
        height = temp
    }

    private func convertToPoints() -> (width: Double, height: Double) {
        switch unit {
        case .inches:
            return (inchesToPoints(width), inchesToPoints(height))
        case .millimeters:
            return (millimetersToPoints(width), millimetersToPoints(height))
        case .points:
            return (width, height)
        }
    }

    // MARK: - Unit Conversions

    private func pointsToInches(_ pts: Double) -> Double {
        return pts / 72.0
    }

    private func inchesToPoints(_ inches: Double) -> Double {
        return inches * 72.0
    }

    private func pointsToMillimeters(_ pts: Double) -> Double {
        return pts / 2.83465
    }

    private func millimetersToPoints(_ mm: Double) -> Double {
        return mm * 2.83465
    }
}

// MARK: - Size Preview View
struct SizePreviewView: View {
    let width: Double
    let height: Double
    let unit: ChangeFileSizeSheet.SizeUnit

    var body: some View {
        GeometryReader { geometry in
            let maxSize = min(geometry.size.width - 40, geometry.size.height - 40)
            let aspectRatio = width / height
            let previewWidth: CGFloat
            let previewHeight: CGFloat

            if aspectRatio > 1 {
                previewWidth = maxSize
                previewHeight = maxSize / CGFloat(aspectRatio)
            } else {
                previewHeight = maxSize
                previewWidth = maxSize * CGFloat(aspectRatio)
            }

            VStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)

                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                }
                .frame(width: previewWidth, height: previewHeight)

                Text(sizeLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sizeLabel: String {
        let unitStr = unit.rawValue
        switch unit {
        case .inches:
            return String(format: "%.1f × %.1f %@", width, height, unitStr)
        case .millimeters, .points:
            return String(format: "%.0f × %.0f %@", width, height, unitStr)
        }
    }
}

#Preview {
    ChangeFileSizeSheet(pdfManager: PDFManager())
}
