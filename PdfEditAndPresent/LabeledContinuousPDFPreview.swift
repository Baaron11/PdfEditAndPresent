import SwiftUI
import PDFKit

struct LabeledContinuousPDFPreview: UIViewRepresentable {
    let document: PDFDocument
    let labels: [String]
    @Binding var currentPage: Int

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
        v.document  = document
        v.delegate  = context.coordinator

        if let p = document.page(at: max(0, min(currentPage-1, document.pageCount-1))) {
            v.go(to: p)
        }
        DispatchQueue.main.async { context.coordinator.fit() }

        if let scroll = v.subviews.compactMap({ $0 as? UIScrollView }).first {
            scroll.delegate = context.coordinator
        }

        if let reg = onRegisterZoomHandlers {
            DispatchQueue.main.async {
                reg({ context.coordinator.zoomIn() },
                    { context.coordinator.zoomOut() },
                    { context.coordinator.fit() })
            }
        }

        context.coordinator.updateBadges(labels: labels)
        return v
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
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
        init(_ p: LabeledContinuousPDFPreview) { self.parent = p }

        // Zoom helpers
        func fit() {
            guard let v = pdfView else { return }
            v.autoScales = true
            v.minScaleFactor = v.scaleFactorForSizeToFit
            v.maxScaleFactor = max(v.maxScaleFactor, 8.0)
            v.scaleFactor   = v.minScaleFactor
        }
        func zoomIn()  {
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
                  let idx  = v.document?.index(for: page) else { return }
            parent.currentPage = idx + 1
            updateBadges(labels: parent.labels)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { updateBadges(labels: parent.labels) }
        func scrollViewDidZoom  (_ scrollView: UIScrollView) { updateBadges(labels: parent.labels) }

        // Liquid-glass badges
        private let baseTag = 50_000

        func updateBadges(labels: [String]) {
            guard let v = pdfView,
                  let docView = v.documentView,
                  let doc = v.document else { return }

            // Remove previous badges
            for sub in docView.subviews where (baseTag...baseTag+20_000).contains(sub.tag) {
                sub.removeFromSuperview()
            }

            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let pageRectInView = v.convert(page.bounds(for: .mediaBox), from: page)
                let r = docView.convert(pageRectInView, from: v)
                if !docView.bounds.insetBy(dx: -400, dy: -400).intersects(r) { continue }

                let size  = CGSize(width: 180, height: 54)
                let frame = CGRect(x: r.midX - size.width/2, y: r.midY - size.height/2,
                                   width: size.width, height: size.height)

                let tag = baseTag + i
                let text = (i < labels.count) ? labels[i] : "Page \(i+1)"

                if let badge = docView.viewWithTag(tag) as? UIVisualEffectView {
                    badge.frame = frame
                    if let label = (badge.contentView.subviews.first as? UIVisualEffectView)?
                        .contentView.subviews.compactMap({ $0 as? UILabel }).first {
                        label.text = text
                    }
                } else {
                    let badge = makeGlassBadge(text: text)
                    badge.tag  = tag
                    badge.frame = frame
                    docView.addSubview(badge)
                }
            }
        }

        private func makeGlassBadge(text: String) -> UIVisualEffectView {
            // Blur base
            let blur = UIBlurEffect(style: .systemThinMaterial)
            let blurView = UIVisualEffectView(effect: blur)
            blurView.layer.cornerRadius = 14
            blurView.layer.masksToBounds = true

            // Subtle border + soft shadow
            blurView.layer.borderWidth = 0.75
            blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
            blurView.layer.shadowColor = UIColor.black.cgColor
            blurView.layer.shadowOpacity = 0.20
            blurView.layer.shadowRadius = 10
            blurView.layer.shadowOffset = CGSize(width: 0, height: 2)

            // Vibrancy label
            let vibrancy = UIVisualEffectView(effect: UIVibrancyEffect(blurEffect: blur))
            let label = UILabel()
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 20, weight: .semibold)
            label.text = text

            blurView.contentView.addSubview(vibrancy)
            vibrancy.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                vibrancy.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
                vibrancy.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
                vibrancy.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
                vibrancy.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor)
            ])

            vibrancy.contentView.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: vibrancy.contentView.leadingAnchor, constant: 14),
                label.trailingAnchor.constraint(equalTo: vibrancy.contentView.trailingAnchor, constant: -14),
                label.centerYAnchor.constraint(equalTo: vibrancy.contentView.centerYAnchor)
            ])

            return blurView
        }
    }
}
