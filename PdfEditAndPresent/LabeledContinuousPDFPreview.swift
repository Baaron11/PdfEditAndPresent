import SwiftUI
import PDFKit

struct LabeledContinuousPDFPreview: UIViewRepresentable {
    let document: PDFDocument
    let labels: [String]
    @Binding var currentPage: Int
    // Register callbacks so the SwiftUI parent can drive zoom/fit
    var onRegisterZoomHandlers: ((_ zoomIn: @escaping ()->Void,
                                  _ zoomOut: @escaping ()->Void,
                                  _ fit: @escaping ()->Void) -> Void)? = nil

    func makeCoordinator() -> Coord { Coord(self) }

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        context.coordinator.pdfView = v

        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .secondarySystemBackground
        v.autoScales = true
        v.document = document
        v.delegate  = context.coordinator

        // Register zoom handlers once the view is alive
        onRegisterZoomHandlers?(
            { [weak coord = context.coordinator] in coord?.zoomIn()  },
            { [weak coord = context.coordinator] in coord?.zoomOut() },
            { [weak coord = context.coordinator] in coord?.fit()     }
        )

        // Go to current page
        if let p = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) {
            v.go(to: p)
        }

        // Reposition badges as the user scrolls/zooms
        if let scroll = v.subviews.compactMap({ $0 as? UIScrollView }).first {
            scroll.delegate = context.coordinator
        }

        context.coordinator.updateBadges(labels: labels)

        // Robust initial fit
        context.coordinator.ensureInitialFitIfNeeded()

        return v
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
            context.coordinator.didInitialFit = false
            // New doc: go to target page
            if let p = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) {
                uiView.go(to: p)
            }
            context.coordinator.ensureInitialFitIfNeeded()
        } else if let p = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) {
            uiView.go(to: p)
        }
        context.coordinator.updateBadges(labels: labels)
    }

    final class Coord: NSObject, PDFViewDelegate, UIScrollViewDelegate {
        let parent: LabeledContinuousPDFPreview
        weak var pdfView: PDFView?
        var didInitialFit: Bool = false
        private var fitRetryWorkItems: [DispatchWorkItem] = []

        init(_ parent: LabeledContinuousPDFPreview) { self.parent = parent }

        // MARK: - Robust Initial Fit

        func ensureInitialFitIfNeeded() {
            // Cancel any pending retries
            fitRetryWorkItems.forEach { $0.cancel() }
            fitRetryWorkItems.removeAll()

            // Try immediately
            tryInitialFit()

            // Retry after short delays to handle late layout
            let delays: [Int] = [50, 150, 300]
            for delay in delays {
                let work = DispatchWorkItem { [weak self] in
                    self?.tryInitialFit()
                }
                fitRetryWorkItems.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
            }
        }

        private func tryInitialFit() {
            guard let v = pdfView else { return }

            // Check if view has settled with non-zero sizes
            let viewSize = v.bounds.size
            let docViewSize = v.documentView?.bounds.size ?? .zero

            guard viewSize.width > 0, viewSize.height > 0,
                  docViewSize.width > 0, docViewSize.height > 0 else {
                return
            }

            // Perform the fit
            v.autoScales = true
            v.minScaleFactor = v.scaleFactorForSizeToFit
            v.maxScaleFactor = max(v.maxScaleFactor, 8.0)
            v.scaleFactor = v.minScaleFactor

            didInitialFit = true
        }

        // MARK: Zoom helpers (used by overlay)
        func fit() {
            guard let v = pdfView else { return }
            v.autoScales = true
            v.minScaleFactor = v.scaleFactorForSizeToFit
            v.maxScaleFactor = max(v.maxScaleFactor, 8.0)
            v.scaleFactor = v.minScaleFactor
        }

        func zoomIn() {
            guard let v = pdfView else { return }
            v.maxScaleFactor = max(v.maxScaleFactor, 8.0)
            v.scaleFactor = min(v.scaleFactor * 1.15, v.maxScaleFactor)
        }

        func zoomOut() {
            guard let v = pdfView else { return }
            v.minScaleFactor = v.scaleFactorForSizeToFit
            v.scaleFactor = max(v.scaleFactor / 1.15, v.minScaleFactor)
        }

        // Keep currentPage in sync
        func pdfViewPageChanged(_ sender: Notification) {
            guard let v = sender.object as? PDFView,
                  let page = v.currentPage,
                  let idx = v.document?.index(for: page) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.currentPage = idx + 1
            }
            updateBadges(labels: parent.labels)
        }

        // Keep badges positioned while scrolling/zooming
        func scrollViewDidScroll(_ scrollView: UIScrollView) { updateBadges(labels: parent.labels) }
        func scrollViewDidZoom(_ scrollView: UIScrollView)   { updateBadges(labels: parent.labels) }

        // MARK: - Liquid Glass Page Badges

        func updateBadges(labels: [String]) {
            guard let v = pdfView,
                  let docView = v.documentView,
                  let doc = v.document else { return }

            // Remove old badges
            docView.subviews.filter { $0.tag == 4242 }.forEach { $0.removeFromSuperview() }

            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                // Page rect in documentView coordinates
                let media = page.bounds(for: .mediaBox)
                var r = v.convert(media, from: page)
                r = docView.convert(r, from: v)

                // Skip far-off pages (perf)
                if !docView.bounds.insetBy(dx: -400, dy: -400).intersects(r) { continue }

                let text = (i < labels.count) ? labels[i] : "Page \(i+1)"
                let badge = createLiquidGlassBadge(text: text)
                badge.tag = 4242

                // Size and position
                let size = CGSize(width: 180, height: 54)
                badge.frame = CGRect(
                    x: r.midX - size.width/2,
                    y: r.midY - size.height/2,
                    width: size.width,
                    height: size.height
                )

                docView.addSubview(badge)
            }
        }

        private func createLiquidGlassBadge(text: String) -> UIView {
            // Container view
            let container = UIView()
            container.isUserInteractionEnabled = false

            // Blur effect view
            let blurEffect = UIBlurEffect(style: .systemMaterial)
            let blurView = UIVisualEffectView(effect: blurEffect)
            blurView.translatesAutoresizingMaskIntoConstraints = false
            blurView.layer.cornerRadius = 16
            blurView.clipsToBounds = true
            container.addSubview(blurView)

            // Vibrancy effect for the label
            let vibrancyEffect = UIVibrancyEffect(blurEffect: blurEffect, style: .label)
            let vibrancyView = UIVisualEffectView(effect: vibrancyEffect)
            vibrancyView.translatesAutoresizingMaskIntoConstraints = false
            blurView.contentView.addSubview(vibrancyView)

            // Label with vibrancy
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.text = text
            label.font = .systemFont(ofSize: 22, weight: .semibold)
            label.textAlignment = .center
            vibrancyView.contentView.addSubview(label)

            // Outer stroke layer for contrast
            let strokeLayer = CAShapeLayer()
            strokeLayer.fillColor = UIColor.clear.cgColor
            strokeLayer.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
            strokeLayer.lineWidth = 0.5
            container.layer.addSublayer(strokeLayer)

            // Subtle shadow
            container.layer.shadowColor = UIColor.black.cgColor
            container.layer.shadowOffset = CGSize(width: 0, height: 2)
            container.layer.shadowRadius = 8
            container.layer.shadowOpacity = 0.15

            // Layout constraints
            NSLayoutConstraint.activate([
                blurView.topAnchor.constraint(equalTo: container.topAnchor),
                blurView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                blurView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                blurView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

                vibrancyView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
                vibrancyView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),
                vibrancyView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
                vibrancyView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),

                label.topAnchor.constraint(equalTo: vibrancyView.contentView.topAnchor),
                label.bottomAnchor.constraint(equalTo: vibrancyView.contentView.bottomAnchor),
                label.leadingAnchor.constraint(equalTo: vibrancyView.contentView.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: vibrancyView.contentView.trailingAnchor),
            ])

            // Update stroke path after layout
            DispatchQueue.main.async {
                let path = UIBezierPath(roundedRect: container.bounds.insetBy(dx: 0.25, dy: 0.25), cornerRadius: 16)
                strokeLayer.path = path.cgPath
            }

            return container
        }
    }
}
