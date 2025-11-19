import SwiftUI

struct ChangePageSizeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var unit: Unit = .inches
    @State private var preset: Preset = .letter
    @State private var widthVal: Double = 8.5
    @State private var heightVal: Double = 11.0
    @State private var isPortrait: Bool = true

    enum Unit: String, CaseIterable { case inches, millimeters, points }
    enum Preset: String, CaseIterable {
        case letter = "Letter (8.5×11 in)"
        case legal  = "Legal (8.5×14 in)"
        case tabloid = "Tabloid (11×17 in)"
        case a5 = "A5 (148×210 mm)"
        case a4 = "A4 (210×297 mm)"
        case a3 = "A3 (297×420 mm)"
        case a2 = "A2 (420×594 mm)"
        case a1 = "A1 (594×841 mm)"
        case custom = "Custom…"
    }

    var widthRange: ClosedRange<Double> {
        switch unit {
        case .inches: return 1.0...60.0
        case .millimeters: return 10.0...1500.0
        case .points: return 72.0...4320.0
        }
    }

    var heightRange: ClosedRange<Double> { widthRange }

    var body: some View {
        NavigationStack {
            Form {
                // Preset
                Picker("Preset", selection: $preset) {
                    ForEach(Preset.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .onChange(of: preset) { applyPreset($0) }

                // Units
                Picker("Units", selection: $unit) {
                    Text("in").tag(Unit.inches)
                    Text("mm").tag(Unit.millimeters)
                    Text("pt").tag(Unit.points)
                }
                .pickerStyle(.segmented)
                .onChange(of: unit) { _ in convertUnitsKeepingPoints() }

                // Custom wheels (only when custom)
                if preset == .custom {
                    HStack(alignment: .top, spacing: 24) {
                        WheelNumberPicker(title: "Width", value: $widthVal, step: stepForUnit(), range: widthRange)
                        WheelNumberPicker(title: "Height", value: $heightVal, step: stepForUnit(), range: heightRange)
                    }
                }

                // Orientation
                Toggle(isOn: $isPortrait) {
                    Text(isPortrait ? "Portrait" : "Landscape")
                }
                .onChange(of: isPortrait) { _ in swapIfNeeded() }

                // Preview
                PageSizePreview(width: widthVal, height: heightVal, unit: unit)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            .navigationTitle("Change Page Size")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        // Convert current UI values to points and APPLY them.
                        let pts = convertToPoints(width: widthVal, height: heightVal, unit: unit)
                        DocumentManager.shared.setPageSize(widthPoints: pts.w, heightPoints: pts.h)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func stepForUnit() -> Double {
        switch unit {
        case .inches: return 0.1
        case .millimeters: return 1.0
        case .points: return 1.0
        }
    }

    private func swapIfNeeded() {
        // If Landscape, ensure width >= height by swapping values; reverse in Portrait.
        let shouldBeLandscape = !isPortrait
        if shouldBeLandscape, heightVal > widthVal {
            swap(&widthVal, &heightVal)
        } else if !shouldBeLandscape == false, widthVal > heightVal, isPortrait {
            // keep portrait with height >= width
            swap(&widthVal, &heightVal)
        }
    }

    private func applyPreset(_ preset: Preset) {
        switch preset {
        case .letter:
            unit = .inches; widthVal = 8.5; heightVal = 11.0; isPortrait = true
        case .legal:
            unit = .inches; widthVal = 8.5; heightVal = 14.0; isPortrait = true
        case .tabloid:
            unit = .inches; widthVal = 11.0; heightVal = 17.0; isPortrait = true
        case .a5:
            unit = .millimeters; widthVal = 148; heightVal = 210; isPortrait = true
        case .a4:
            unit = .millimeters; widthVal = 210; heightVal = 297; isPortrait = true
        case .a3:
            unit = .millimeters; widthVal = 297; heightVal = 420; isPortrait = true
        case .a2:
            unit = .millimeters; widthVal = 420; heightVal = 594; isPortrait = true
        case .a1:
            unit = .millimeters; widthVal = 594; heightVal = 841; isPortrait = true
        case .custom:
            // leave current selections as-is
            break
        }
    }

    private func convertUnitsKeepingPoints() {
        // Convert current width/height to points (from old unit), then back to new unit.
        let pts = convertToPoints(width: widthVal, height: heightVal, unit: unit)
        switch unit {
        case .inches:
            widthVal = pts.w / 72.0
            heightVal = pts.h / 72.0
        case .millimeters:
            widthVal = (pts.w / 72.0) * 25.4
            heightVal = (pts.h / 72.0) * 25.4
        case .points:
            widthVal = pts.w
            heightVal = pts.h
        }
    }

    private func convertToPoints(width: Double, height: Double, unit: Unit) -> (w: CGFloat, h: CGFloat) {
        switch unit {
        case .inches:
            return (CGFloat(width * 72.0), CGFloat(height * 72.0))
        case .millimeters:
            return (CGFloat((width / 25.4) * 72.0), CGFloat((height / 25.4) * 72.0))
        case .points:
            return (CGFloat(width), CGFloat(height))
        }
    }
}

// MARK: - Subviews

struct WheelNumberPicker: View {
    let title: String
    @Binding var value: Double
    let step: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            Picker("", selection: $value) {
                ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: step)), id: \.self) { v in
                    Text(label(for: v)).tag(v)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxHeight: 160)
        }
    }

    private func label(for v: Double) -> String {
        step < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }
}

struct PageSizePreview: View {
    let width: Double
    let height: Double
    let unit: ChangePageSizeSheet.Unit

    var body: some View {
        let w = widthPoints()
        let h = heightPoints()
        let maxSide: CGFloat = 200
        let scale = min(maxSide / max(w, h), 1)
        let rectSize = CGSize(width: w * scale, height: h * scale)

        return VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 8).stroke(.secondary, lineWidth: 1)
                    .frame(width: rectSize.width, height: rectSize.height)
                Text("\(display(width)) × \(display(height)) \(unitLabel())")
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func widthPoints() -> CGFloat {
        switch unit {
        case .inches: return CGFloat(width * 72.0)
        case .millimeters: return CGFloat((width / 25.4) * 72.0)
        case .points: return CGFloat(width)
        }
    }

    private func heightPoints() -> CGFloat {
        switch unit {
        case .inches: return CGFloat(height * 72.0)
        case .millimeters: return CGFloat((height / 25.4) * 72.0)
        case .points: return CGFloat(height)
        }
    }

    private func unitLabel() -> String {
        switch unit {
        case .inches: return "in"
        case .millimeters: return "mm"
        case .points: return "pt"
        }
    }

    private func display(_ v: Double) -> String {
        switch unit {
        case .inches: return String(format: "%.1f", v)
        case .millimeters, .points: return String(format: "%.0f", v)
        }
    }
}
