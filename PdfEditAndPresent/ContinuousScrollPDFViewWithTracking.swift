import SwiftUI
import PDFKit
import PencilKit

// MARK: - Continuous Scroll PDF View with Tracking + Margin Support
struct ContinuousScrollPDFViewWithTracking: View {
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
    @State private var pageSizes: [Int: CGSize] = [:]
    @State private var lastMarginSettingsHash: Int = 0

    // live page frames keyed by index, in the ScrollView's named coordinate space
    @State private var pageFrames: [Int: CGRect] = [:]

    // Guards to prevent "jump to page 1" after re-render (rotate/margins)
    @State private var isReRendering = false
    @State private var pendingScrollTarget: Int?
    @State private var isInternalVisibleUpdate = false

    var body: some View {
        GeometryReader { outerGeo in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        // ✅ Consistent grey background across all modes
                        Color(UIColor.systemGray6)
                            .frame(
                                minWidth: outerGeo.size.width,
                                minHeight: outerGeo.size.height
                            )
                        
                        // ✅ Apply zoom to the VStack, not individual pages
                        VStack(spacing: 8) {
                            ForEach(0..<pdfManager.pageCount, id: \.self) { pageIndex in
                                pageView(for: pageIndex, availableWidth: outerGeo.size.width - 16)
                                    .id(pageIndex)
                                    .background(
                                        GeometryReader { g in
                                            Color.clear.preference(
                                                key: PageFramesPreferenceKey.self,
                                                value: [pageIndex: g.frame(in: .named("scrollView"))]
                                            )
                                        }
                                    )
                            }
                        }
                        .padding(8)
                        // ✅ NO minWidth here - let VStack size naturally
                        .scaleEffect(pdfManager.zoomLevel, anchor: .topLeading)
                        .onPreferenceChange(PageFramesPreferenceKey.self) { frames in
                            pageFrames = frames
                            updateVisiblePageFromScroll(viewportHeight: outerGeo.size.height)
                        }
                        .onAppear {
                            renderAllPages()
                            updateMarginHash()
                        }
                        .onChange(of: pdfManager.pdfDocument) { _, _ in
                            pageImages.removeAll()
                            pageSizes.removeAll()
                            pageFrames.removeAll()
                            renderAllPages()
                            updateMarginHash()
                        }
                        .onReceive(pdfManager.pageTransformsDidChange) { changedPages in
                            if let specificPages = changedPages {
                                print("🔄 Re-rendering specific pages after rotation: \(specificPages.map { $0 + 1 })")
                                
                                for pageIndex in specificPages {
                                    pageImages.removeValue(forKey: pageIndex)
                                    pageFrames.removeValue(forKey: pageIndex)
                                }
                                
                                DispatchQueue.global(qos: .userInitiated).async {
                                    for pageIndex in specificPages {
                                        renderPage(at: pageIndex)
                                    }
                                }
                                
                            } else {
                                print("🔄 Re-rendering ALL pages after rotation")
                                let keep = visiblePageIndex
                                isReRendering = true
                                pageImages.removeAll()
                                pageFrames.removeAll()
                                renderAllPages()
                                pendingScrollTarget = keep
                            }
                        }
                        .onReceive(pdfManager.marginSettingsDidChange) { changedPages in
                            if let specificPages = changedPages {
                                print("🔄 Re-rendering pages with margin changes: \(specificPages.map { $0 + 1 })")
                                
                                for pageIndex in specificPages {
                                    pageImages.removeValue(forKey: pageIndex)
                                    pageFrames.removeValue(forKey: pageIndex)
                                }
                                
                                DispatchQueue.global(qos: .userInitiated).async {
                                    for pageIndex in specificPages {
                                        renderPage(at: pageIndex)
                                    }
                                }
                                
                            } else {
                                print("🔄 Re-rendering ALL pages after margin change")
                                let keep = visiblePageIndex
                                isReRendering = true
                                pageImages.removeAll()
                                pageFrames.removeAll()
                                renderAllPages()
                                pendingScrollTarget = keep
                            }
                        }
                    }
                }
                .coordinateSpace(name: "scrollView")
                .background(Color(UIColor.systemGray6))
                .onChange(of: visiblePageIndex) { _, newIndex in
                    guard !isReRendering, !isInternalVisibleUpdate else { return }
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .top)
                    }
                }
                .onChange(of: pendingScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    pendingScrollTarget = nil
                    isReRendering = false
                }
            }
        }
    }

    // MARK: - Page Cell
    @ViewBuilder
    private func pageView(for pageIndex: Int, availableWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // ========== PDF IMAGE LAYER ==========
            VStack(spacing: 0) {
                if let image = pageImages[pageIndex] {
                    let imageSize = CGSize(width: image.size.width / 2.0, height: image.size.height / 2.0)
                    let aspectRatio = imageSize.height / imageSize.width
                    let displayWidth = imageSize.width
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
                    // Placeholder
                    let defaultAspectRatio: CGFloat = 11.0 / 8.5
                    let displayWidth = availableWidth
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
        // ✅ NO TRANSFORMS HERE - Parent VStack handles zoom, rotation is handled by canvas internally
    }

    // MARK: - Margins Hash
    private func checkAndUpdateMarginsIfNeeded() {
        let currentHash = hashMarginSettings()
        if currentHash != lastMarginSettingsHash {
            pageImages.removeAll()
            renderAllPages()
            updateMarginHash()
        }
    }

    private func hashMarginSettings() -> Int {
        var hash = 0
        for (index, settings) in pdfManager.marginSettings.enumerated() {
            let settingHash = (settings.isEnabled ? 1 : 0)
            ^ settings.anchorPosition.hashValue
            ^ Int(settings.pdfScale * 1000)
            hash ^= (settingHash &+ index)
        }
        return hash
    }

    private func updateMarginHash() {
        lastMarginSettingsHash = hashMarginSettings()
    }

    // MARK: - Rendering
    private func renderAllPages() {
        let pageCount = pdfManager.pageCount
        DispatchQueue.global(qos: .userInitiated).async {
            for pageIndex in 0..<pageCount {
                renderPage(at: pageIndex)
            }
        }
    }

    private func renderPage(at pageIndex: Int) {
        guard let page = pdfManager.pdfDocument?.page(at: pageIndex) else { return }
        let settings = pdfManager.getMarginSettings(for: pageIndex)

        let image: UIImage? = settings.isEnabled
            ? renderPageWithMargins(page: page, marginSettings: settings)
            : renderPageNormal(page: page)

        if let image {
            DispatchQueue.main.async {
                pageImages[pageIndex] = image
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

    // MARK: - Visible Page Tracking
    private func updateVisiblePageFromScroll(viewportHeight: CGFloat) {
        guard !isReRendering, !pageFrames.isEmpty else { return }

        let viewport = CGRect(x: 0, y: 0, width: 1, height: max(1, viewportHeight))

        var bestIndex = visiblePageIndex
        var bestOverlap: CGFloat = -1

        for (idx, rect) in pageFrames {
            let overlap = viewport.intersection(rect).height
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestIndex = idx
            } else if overlap == 0 {
                let topDistance = abs(rect.minY)
                let bestTopDistance = abs(pageFrames[bestIndex]?.minY ?? 0)
                if bestOverlap == 0 && topDistance < bestTopDistance {
                    bestIndex = idx
                }
            }
        }

        if bestIndex != visiblePageIndex {
            isInternalVisibleUpdate = true
            visiblePageIndex = bestIndex
            pdfManager.currentPageIndex = bestIndex
            DispatchQueue.main.async { isInternalVisibleUpdate = false }
        }
    }
}

// MARK: - Preference Key
private struct PageFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
