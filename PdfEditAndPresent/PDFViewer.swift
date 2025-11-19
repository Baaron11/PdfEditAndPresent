import SwiftUI
import PDFKit

// MARK: - PDF Viewer (Bottom Layer)
struct PDFViewer: UIViewRepresentable {
    @ObservedObject var pdfManager: PDFManager
    let currentPageIndex: Int
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = pdfManager.pdfDocument
        pdfView.displayMode = .singlePage
        pdfView.autoScales = false
        pdfView.backgroundColor = .systemBackground
        
        return pdfView
    }
    
    func updateUIView(_ pdfView: PDFView, context: Context) {
        pdfView.document = pdfManager.pdfDocument
        
        // Navigate to current page
        if let page = pdfManager.getCurrentPage() {
            pdfView.go(to: page)
        }
    }
}

// MARK: - PDF Background with Margin Support
struct PDFPageBackground: View {
    @ObservedObject var pdfManager: PDFManager
    let currentPageIndex: Int

    @State private var renderedImage: UIImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            // ✅ Match the continuous scroll grey exactly
            Color(UIColor.systemGray6)
                .ignoresSafeArea()

            VStack {
                if let image = renderedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .background(Color.white)
                } else if isLoading {
                    ProgressView().scaleEffect(1.5)
                } else {
                    Text("Failed to load page").foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { renderPage() }
        .onChange(of: currentPageIndex) { renderPage() }
        .onReceive(pdfManager.marginSettingsDidChange) { changedPages in
            if let specificPages = changedPages {
                if specificPages.contains(currentPageIndex) {
                    print("🔄 Current page \(currentPageIndex + 1) margin changed - re-rendering")
                    renderPage()
                }
            } else {
                print("🔄 All pages margin changed - re-rendering current page")
                renderPage()
            }
        }
        .onReceive(pdfManager.pageTransformsDidChange) { changedPages in
            if let specificPages = changedPages {
                if specificPages.contains(currentPageIndex) {
                    print("🔄 Current page \(currentPageIndex + 1) rotated - re-rendering")
                    renderPage()
                }
            } else {
                print("🔄 All pages rotated - re-rendering current page")
                renderPage()
            }
        }
    }

    // MARK: - Rendering

    private func renderPage() {
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async {
            guard let page = pdfManager.pdfDocument?.page(at: currentPageIndex) else {
                DispatchQueue.main.async { isLoading = false }
                return
            }

            let marginSettings = pdfManager.getMarginSettings(for: currentPageIndex)

            let image: UIImage?
            if marginSettings.isEnabled {
                image = renderPageWithMargins(page: page, marginSettings: marginSettings)
            } else {
                image = renderPageNormal(page: page)
            }

            DispatchQueue.main.async {
                renderedImage = image
                isLoading = false
            }
        }
    }

    /// Swap width/height for 90°/270° so the margin canvas treats the page as the opposite orientation.
    private func effectiveSize(for page: PDFPage) -> CGSize {
        let raw = page.bounds(for: .mediaBox).size
        let rot = ((page.rotation % 360) + 360) % 360
        return (rot == 90 || rot == 270) ? CGSize(width: raw.height, height: raw.width) : raw
    }

    /// Render page WITHOUT margins (respects rotation)
    private func renderPageNormal(page: PDFPage) -> UIImage? {
        let eff = effectiveSize(for: page)
        let scale: CGFloat = 2.0
        return page.thumbnail(
            of: CGSize(width: eff.width * scale, height: eff.height * scale),
            for: .mediaBox
        )
    }

    /// Render page WITH margins (respects rotation + keeps Y-flip)
    private func renderPageWithMargins(page: PDFPage, marginSettings: MarginSettings) -> UIImage? {
        let eff = effectiveSize(for: page)

        // Treat the margin canvas as the rotated page size so margins “follow” orientation.
        let helper = MarginCanvasHelper(
            settings: marginSettings,
            originalPDFSize: eff,
            canvasSize: eff
        )

        let scale: CGFloat = 2.0
        let renderSize = CGSize(width: eff.width * scale, height: eff.height * scale)

        let renderer = UIGraphicsImageRenderer(size: renderSize)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: renderSize))

            let pdfFrame = helper.pdfFrameInCanvas
            let scaledPDFRect = CGRect(
                x: pdfFrame.origin.x * scale,
                y: pdfFrame.origin.y * scale,
                width: pdfFrame.width * scale,
                height: pdfFrame.height * scale
            )

            context.cgContext.saveGState()

            // Core Graphics has origin at bottom-left; flip Y for UIKit coordinates.
            context.cgContext.translateBy(x: 0, y: renderSize.height)
            context.cgContext.scaleBy(x: 1, y: -1)

            // Position to the (flipped) pdf frame origin
            let flippedY = renderSize.height - (scaledPDFRect.origin.y + scaledPDFRect.height)
            context.cgContext.translateBy(x: scaledPDFRect.origin.x, y: flippedY)

            // Scale into the PDF area by device scale and margin scale
            context.cgContext.scaleBy(x: scale * marginSettings.pdfScale, y: scale * marginSettings.pdfScale)

            // Draw the real page — PDFKit applies page.rotation automatically
            page.draw(with: .mediaBox, to: context.cgContext)

            context.cgContext.restoreGState()

            // Optional: thin border around the PDF area (drawn in unflipped coords)
            context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
            context.cgContext.setLineWidth(1.0)
            context.cgContext.stroke(scaledPDFRect)
        }

        return image
    }
}

// MARK: - Preview
#Preview {
    PDFPageBackground(
        pdfManager: PDFManager(),
        currentPageIndex: 0
    )
}
