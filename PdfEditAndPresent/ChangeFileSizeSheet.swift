import SwiftUI

struct ChangeFileSizeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preset: PDFOptimizeOptions.Preset = .smaller
    @State private var imageQuality: Double = 0.75
    @State private var maxDPI: Double = 144
    @State private var downsample = true
    @State private var grayscale = false
    @State private var stripMetadata = true
    @State private var flatten = false
    @State private var recompress = true
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Preset", selection: $preset) {
                    Text("Original").tag(PDFOptimizeOptions.Preset.original)
                    Text("Smaller").tag(PDFOptimizeOptions.Preset.smaller)
                    Text("Smallest").tag(PDFOptimizeOptions.Preset.smallest)
                    Text("Custom").tag(PDFOptimizeOptions.Preset.custom)
                }
                .onChange(of: preset) { _, newValue in applyPreset(newValue) }

                if preset == .custom {
                    Section("Images") {
                        HStack {
                            Text("Image Quality")
                            Slider(value: $imageQuality, in: 0.4...1.0, step: 0.05)
                            Text("\(Int(imageQuality * 100))%")
                                .frame(width: 40, alignment: .trailing)
                        }
                        HStack {
                            Text("Max Image DPI")
                            Slider(value: $maxDPI, in: 72...600, step: 12)
                            Text("\(Int(maxDPI))")
                                .frame(width: 40, alignment: .trailing)
                        }
                        Toggle("Downsample Images", isOn: $downsample)
                        Toggle("Grayscale Images", isOn: $grayscale)
                    }
                    Section("Other") {
                        Toggle("Strip Metadata", isOn: $stripMetadata)
                        Toggle("Flatten Annotations", isOn: $flatten)
                        Toggle("Recompress Streams", isOn: $recompress)
                    }
                } else {
                    // Brief summary of what the preset will do
                    PresetSummaryView(preset: preset)
                }
            }
            .navigationTitle("Change File Size")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isWorking ? "Applying…" : "Apply") {
                        let opts = currentOptions()
                        isWorking = true
                        DocumentManager.shared.rewritePDF(with: opts) { result in
                            isWorking = false
                            switch result {
                            case .success:
                                dismiss()
                            case .failure(let err):
                                errorMessage = err.localizedDescription
                            }
                        }
                    }
                    .disabled(isWorking)
                }
            }
            .alert("Optimization Failed", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK", role: .cancel) { errorMessage = nil }
            }, message: { Text(errorMessage ?? "") })
        }
    }

    private func applyPreset(_ p: PDFOptimizeOptions.Preset) {
        switch p {
        case .original:
            imageQuality = 1.0; maxDPI = 600; downsample = false; grayscale = false; stripMetadata = false; flatten = false; recompress = false
        case .smaller:
            imageQuality = 0.75; maxDPI = 144; downsample = true; grayscale = false; stripMetadata = true; flatten = false; recompress = true
        case .smallest:
            imageQuality = 0.6; maxDPI = 96; downsample = true; grayscale = false; stripMetadata = true; flatten = true; recompress = true
        case .custom:
            break
        }
    }

    private func currentOptions() -> PDFOptimizeOptions {
        PDFOptimizeOptions(
            preset: preset,
            imageQuality: imageQuality,
            maxImageDPI: maxDPI,
            downsampleImages: downsample,
            grayscaleImages: grayscale,
            stripMetadata: stripMetadata,
            flattenAnnotations: flatten,
            recompressStreams: recompress
        )
    }
}

struct PresetSummaryView: View {
    let preset: PDFOptimizeOptions.Preset
    var body: some View {
        let desc: String = {
            switch preset {
            case .original: return "No quality changes. Keeps original size."
            case .smaller:  return "Recompress images (~75%), downsample to ~144 dpi, strip metadata."
            case .smallest: return "Aggressive recompress (~60%), downsample to ~96 dpi, strip metadata, flatten annotations."
            case .custom:   return ""
            }
        }()
        return Text(desc).font(.footnote).foregroundStyle(.secondary)
    }
}
