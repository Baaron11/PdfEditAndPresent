import SwiftUI
import PDFKit
import PencilKit

// MARK: - Continuous Scroll PDF View with No Bounce
struct ContinuousScrollPDFViewWithBounds: View {
    @ObservedObject var pdfManager: PDFManager
    @ObservedObject var editorData: EditorData
    @Binding var visiblePageIndex: Int
    @Binding var canvasMode: CanvasMode
    @Binding var marginSettings: MarginSettings

    // Callbacks for canvas events
    var onCanvasModeChanged: ((CanvasMode) -> Void)?
    var onPaperKitItemAdded: (() -> Void)?
    var onDrawingChanged: ((Int, PKDrawing?, PKDrawing?) -> Void)?
    var onToolAPIReady: ((UnifiedBoardToolAPI) -> Void)?

    @State private var pageImages: [Int: UIImage] = [:]
    @State private var isRendering = false
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            pageStackView
        }
        .background(Color(UIColor.systemGray6))
        .onAppear {
            renderAllPages()
        }
        .onChange(of: pdfManager.pdfDocument) { _, _ in
            pageImages.removeAll()
            renderAllPages()
        }
        .onChange(of: pdfManager.pageCount) { _, _ in
            pageImages.removeAll()
            renderAllPages()
        }
    }
    
    private var pageStackView: some View {
        VStack(spacing: 8) {
            ForEach(0..<pdfManager.pageCount, id: \.self) { pageIndex in
                pageView(for: pageIndex, availableWidth: UIScreen.main.bounds.width - 32)
            }
        }
        .padding(12)
    }
    
    @ViewBuilder
    private func pageView(for pageIndex: Int, availableWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // ========== PDF IMAGE LAYER ==========
            VStack(spacing: 0) {
                if let image = pageImages[pageIndex] {
                    let imageSize = CGSize(width: image.size.width / 2.0, height: image.size.height / 2.0)
                    let aspectRatio = imageSize.height / imageSize.width
                    let displayWidth = imageSize.width * pdfManager.zoomLevel
                    let displayHeight = displayWidth * aspectRatio

                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: displayWidth, height: displayHeight)
                        .clipped()
                        .background(Color.white)
                        .cornerRadius(4)
                        .shadow(radius: 2)
                } else {
                    let defaultAspectRatio: CGFloat = 11.0 / 8.5
                    let displayWidth = availableWidth * pdfManager.zoomLevel
                    let displayHeight = displayWidth * defaultAspectRatio

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .shadow(radius: 2)
                        .overlay(ProgressView())
                        .frame(width: displayWidth, height: displayHeight)
                }
            }
            .onAppear {
                if pageImages[pageIndex] == nil {
                    renderPage(at: pageIndex)
                }
            }

            // ========== CANVAS OVERLAY (Per-Page) ==========
            // ✅ NO TRANSFORM - Let the ZStack parent handle transforms
            UnifiedBoardCanvasView(
                editorData: editorData,
                pdfManager: pdfManager,
                canvasMode: $canvasMode,
                marginSettings: $marginSettings,
                canvasSize: pdfManager.effectiveSize(for: pageIndex),
                currentPageIndex: pageIndex,
                zoomLevel: pdfManager.zoomLevel,
                pageRotation: pdfManager.rotationForPage(pageIndex),
                onModeChanged: onCanvasModeChanged,
                onPaperKitItemAdded: onPaperKitItemAdded,
                onDrawingChanged: onDrawingChanged,
                onToolAPIReady: onToolAPIReady
            )
            .id("canvas-\(pageIndex)")
            .allowsHitTesting(canvasMode == .drawing || canvasMode == .selecting)
        }
        // ✅ APPLY TRANSFORMS TO THE ZSTACK, NOT THE CANVAS
        .scaleEffect(pdfManager.zoomLevel, anchor: .topLeading)
        .rotationEffect(
            .degrees(Double(pdfManager.rotationForPage(pageIndex))),
            anchor: .topLeading
        )
    }
    
    // MARK: - Rendering
    private func renderAllPages() {
        isRendering = true
        let pageCount = pdfManager.pageCount
        let document = pdfManager.pdfDocument
        
        print("📜 Starting to render \(pageCount) pages")
        
        DispatchQueue.global(qos: .userInitiated).async {
            guard let document = document else {
                print("❌ No document to render")
                return
            }
            
            for pageIndex in 0..<pageCount {
                renderPage(at: pageIndex)
            }
        }
    }

    private func renderPage(at pageIndex: Int) {
        guard let page = pdfManager.pdfDocument?.page(at: pageIndex) else { return }
        let settings = pdfManager.getMarginSettings(for: pageIndex)

        let image: UIImage? = settings.pdfScale < 1.0
            ? renderPageWithMargins(page: page, marginSettings: settings)
            : renderPageNormal(page: page)

        if let image {
            DispatchQueue.main.async {
                pageImages[pageIndex] = image
                print("✅ Rendered page \(pageIndex + 1)")
            }
        }
    }

    private func renderPageNormal(page: PDFPage) -> UIImage? {
        let base = page.bounds(for: .mediaBox).size
        let rot = ((page.rotation % 360) + 360) % 360
        let effective = (rot == 90 || rot == 270)
            ? CGSize(width: base.height, height: base.width)
            : base

        let scale: CGFloat = 2.0
        return page.thumbnail(
            of: CGSize(width: effective.width * scale, height: effective.height * scale),
            for: .mediaBox
        )
    }

    private func renderPageWithMargins(page: PDFPage, marginSettings: MarginSettings) -> UIImage? {
        let base = page.bounds(for: .mediaBox).size
        let rot = ((page.rotation % 360) + 360) % 360
        let effective = (rot == 90 || rot == 270)
            ? CGSize(width: base.height, height: base.width)
            : base

        let helper = MarginCanvasHelper(
            settings: marginSettings,
            originalPDFSize: effective,
            canvasSize: effective
        )

        let scale: CGFloat = 2.0
        let renderSize = CGSize(width: effective.width * scale, height: effective.height * scale)

        let renderer = UIGraphicsImageRenderer(size: renderSize)
        return renderer.image { context in
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
            context.cgContext.translateBy(x: 0, y: renderSize.height)
            context.cgContext.scaleBy(x: 1, y: -1)

            let flippedY = renderSize.height - (scaledPDFRect.origin.y + scaledPDFRect.height)
            context.cgContext.translateBy(x: scaledPDFRect.origin.x, y: flippedY)

            context.cgContext.scaleBy(x: scale * marginSettings.pdfScale, y: scale * marginSettings.pdfScale)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()

            context.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
            context.cgContext.setLineWidth(1.0)
            context.cgContext.stroke(scaledPDFRect)
        }
    }
}

#Preview {
    ContinuousScrollPDFViewWithBounds(
        pdfManager: PDFManager(),
        editorData: EditorData(),
        visiblePageIndex: .constant(0),
        canvasMode: .constant(.idle),
        marginSettings: .constant(MarginSettings())
    )
}
