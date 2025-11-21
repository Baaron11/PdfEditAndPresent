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

        // Go to current page and FIT after first layout
        if let p = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) {
            v.go(to: p)
        }
        DispatchQueue.main.async { context.coordinator.fit() }

        // Reposition badges as the user scrolls/zooms
        if let scroll = v.subviews.compactMap({ $0 as? UIScrollView }).first {
            scroll.delegate = context.coordinator
        }

        context.coordinator.updateBadges(labels: labels)
        return v
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
            // New doc: go to target page and fit again
            if let p = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) {
                uiView.go(to: p)
            }
            DispatchQueue.main.async { context.coordinator.fit() }
        } else if let p = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) {
            uiView.go(to: p)
        }
        context.coordinator.updateBadges(labels: labels)
    }

    final class Coord: NSObject, PDFViewDelegate, UIScrollViewDelegate {
        let parent: LabeledContinuousPDFPreview
        weak var pdfView: PDFView?

        init(_ parent: LabeledContinuousPDFPreview) { self.parent = parent }

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
            parent.currentPage = idx + 1
            updateBadges(labels: parent.labels)
        }

        // Keep badges positioned while scrolling/zooming
        func scrollViewDidScroll(_ scrollView: UIScrollView) { updateBadges(labels: parent.labels) }
        func scrollViewDidZoom(_ scrollView: UIScrollView)   { updateBadges(labels: parent.labels) }

        // Centered, large page badges that stick to each page
        func updateBadges(labels: [String]) {
            guard let v = pdfView,
                  let docView = v.documentView,
                  let doc = v.document else { return }

            docView.subviews.filter { $0.tag == 4242 }.forEach { $0.removeFromSuperview() }

            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                // Page rect in documentView coordinates
                let media = page.bounds(for: .mediaBox)
                var r = v.convert(media, from: page)
                r = docView.convert(r, from: v)

                // Skip far-off pages (perf)
                if !docView.bounds.insetBy(dx: -400, dy: -400).intersects(r) { continue }

                let size = CGSize(width: 180, height: 54)
                let frame = CGRect(x: r.midX - size.width/2, y: r.midY - size.height/2, width: size.width, height: size.height)

                let lab = UILabel(frame: frame)
                lab.tag = 4242
                lab.textAlignment = .center
                lab.font = .systemFont(ofSize: 22, weight: .bold)
                lab.textColor = .label
                lab.text = (i < labels.count) ? labels[i] : "Page \(i+1)"
                lab.backgroundColor = UIColor.systemGray5.withAlphaComponent(0.75)
                lab.layer.cornerRadius = 12
                lab.clipsToBounds = true
                docView.addSubview(lab)
            }
        }
    }
}
