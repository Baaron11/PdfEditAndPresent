import SwiftUI
import PDFKit

struct LabeledContinuousPDFPreview: UIViewRepresentable {
    let document: PDFDocument
    let labels: [String]            // one per page in *this* (subset) document
    @Binding var currentPage: Int

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .secondarySystemBackground
        v.document = document
        v.delegate = context.coordinator

        if let page = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) {
            v.go(to: page)
        }

        // Hook scroll/zoom to keep badges positioned
        if let scroll = v.subviews.compactMap({ $0 as? UIScrollView }).first {
            scroll.delegate = context.coordinator
        }

        context.coordinator.updateBadges(on: v, labels: labels)
        return v
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document { uiView.document = document }
        uiView.displayMode = .singlePageContinuous
        uiView.displayDirection = .vertical
        uiView.autoScales = true

        if let p = uiView.document?.page(at: max(0, min(currentPage-1, (uiView.document?.pageCount ?? 1)-1))) {
            uiView.go(to: p)
        }
        context.coordinator.updateBadges(on: uiView, labels: labels)
    }

    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, PDFViewDelegate, UIScrollViewDelegate {
        var parent: LabeledContinuousPDFPreview
        init(_ p: LabeledContinuousPDFPreview) { self.parent = p }

        // Reposition when current page changes:
        func pdfViewPageChanged(_ sender: Notification) {
            guard let v = sender.object as? PDFView,
                  let page = v.currentPage,
                  let idx = v.document?.index(for: page) else { return }
            parent.currentPage = idx + 1
            updateBadges(on: v, labels: parent.labels)
        }

        // Reposition during scroll/zoom:
        func scrollViewDidScroll(_ scrollView: UIScrollView) { updateFrom(scrollView) }
        func scrollViewDidZoom(_ scrollView: UIScrollView)   { updateFrom(scrollView) }
        private func updateFrom(_ scrollView: UIScrollView) {
            guard let v = scrollView.superview as? PDFView else { return }
            updateBadges(on: v, labels: parent.labels)
        }

        func updateBadges(on view: PDFView, labels: [String]) {
            guard let docView = view.documentView, let doc = view.document else { return }
            // Remove old
            docView.subviews.filter { $0.tag == 4242 }.forEach { $0.removeFromSuperview() }

            let pad: CGFloat = 6
            let badgeSize = CGSize(width: 76, height: 22)

            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let mediaBox = page.bounds(for: .mediaBox)
                var rect = view.convert(mediaBox, from: page) // into PDFView coords
                rect = docView.convert(rect, from: view)      // into documentView coords

                // Only add for pages currently (roughly) visible to avoid dozens of UILabels
                if !docView.bounds.insetBy(dx: -400, dy: -400).intersects(rect) { continue }

                let frame = CGRect(x: rect.minX + pad, y: rect.minY + pad, width: badgeSize.width, height: badgeSize.height)
                let label = UILabel(frame: frame)
                label.tag = 4242
                label.textAlignment = .center
                label.font = .systemFont(ofSize: 12, weight: .semibold)
                label.text = (i < labels.count) ? labels[i] : "Page \(i+1)"
                label.textColor = .label
                label.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.6)
                label.layer.cornerRadius = 10
                label.clipsToBounds = true
                docView.addSubview(label)
            }
        }
    }
}
