import SwiftUI
import PDFKit

struct LabeledContinuousPDFPreview: UIViewRepresentable {
    let document: PDFDocument
    /// Labels per subset order. Example:
    /// - All Pages: ["Page 1","Page 2",...]
    /// - Custom:    ["Page 1","Page 3","Page 5"]
    /// - Current:   ["Page 7"]
    let labels: [String]
    @Binding var currentPage: Int

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .secondarySystemBackground
        v.document = document
        v.delegate = context.coordinator
        if let p = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) { v.go(to: p) }
        return v
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document { uiView.document = document }
        uiView.displayMode = .singlePageContinuous
        uiView.displayDirection = .vertical
        uiView.autoScales = true
        if let p = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) { uiView.go(to: p) }
        context.coordinator.updateBadges(on: uiView, labels: labels)
    }

    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, PDFViewDelegate {
        var parent: LabeledContinuousPDFPreview
        init(_ p: LabeledContinuousPDFPreview) { self.parent = p }

        func pdfViewPageChanged(_ sender: Notification) {
            guard let v = sender.object as? PDFView,
                  let page = v.currentPage,
                  let idx = v.document?.index(for: page) else { return }
            parent.currentPage = idx + 1
            updateBadges(on: v, labels: parent.labels)
        }

        func updateBadges(on view: PDFView, labels: [String]) {
            // Remove old badges
            view.subviews.filter { $0.tag == 42 }.forEach { $0.removeFromSuperview() }

            guard let doc = view.document else { return }
            // Add a badge for each page; only visible pages will show on screen.
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let media = page.bounds(for: .mediaBox)
                // Convert to view coordinates
                var rect = view.convert(media, from: page)
                // If not on screen, skip to avoid extra work
                if !view.bounds.insetBy(dx: -200, dy: -200).intersects(rect) { continue }

                // Place badge at top-left with a little padding
                let pad: CGFloat = 6
                let badgeSize = CGSize(width: 76, height: 22)
                rect = CGRect(x: rect.minX + pad, y: rect.minY + pad, width: badgeSize.width, height: badgeSize.height)

                let label = UILabel(frame: rect)
                label.tag = 42
                label.textAlignment = .center
                label.font = .systemFont(ofSize: 12, weight: .semibold)
                // Choose label text — clamp to labels.count
                let text = (i < labels.count) ? labels[i] : "Page \(i+1)"
                label.text = text
                label.textColor = .label
                label.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.6)
                label.layer.cornerRadius = 10
                label.clipsToBounds = true

                view.addSubview(label)
            }
        }
    }
}
