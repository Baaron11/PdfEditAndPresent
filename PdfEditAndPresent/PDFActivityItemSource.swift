import UIKit
import UniformTypeIdentifiers

final class PDFActivityItemSource: NSObject, UIActivityItemSource {
    private let data: Data
    private let filename: String

    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename.hasSuffix(".pdf") ? filename : filename + ".pdf"
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return data
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return data
    }

    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        return UTType.pdf.identifier   // "com.adobe.pdf"
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        return filename
    }

    func activityViewController(_ activityViewController: UIActivityViewController, thumbnailImageForActivityType activityType: UIActivity.ActivityType?, suggestedSize size: CGSize) -> UIImage? {
        nil
    }
}
