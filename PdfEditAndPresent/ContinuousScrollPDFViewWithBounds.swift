import SwiftUI
import PDFKit

// MARK: - Continuous Scroll PDF View with No Bounce
struct ContinuousScrollPDFViewWithBounds: View {
    @ObservedObject var pdfManager: PDFManager
    @State private var pageImages: [UIImage?] = []
    @State private var isRendering = false
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            pageStackView
                .scaleEffect(pdfManager.zoomLevel, anchor: .topLeading)
        }
        //.disableScrollBounce()
        .background(Color.gray.opacity(0.05))
        .onAppear {
            renderAllPages()
        }
        .onChange(of: pdfManager.pdfDocument) { _, _ in
            renderAllPages()
        }
        .onChange(of: pdfManager.pageCount) { _, _ in
            renderAllPages()
        }
    }
    
    private var pageStackView: some View {
        VStack(spacing: 8) {
            ForEach(0..<pdfManager.pageCount, id: \.self) { pageIndex in
                pageView(for: pageIndex)
            }
        }
        .padding(12)
    }
    
    @ViewBuilder
    private func pageView(for pageIndex: Int) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color.white
                
                if pageIndex < pageImages.count, let image = pageImages[pageIndex] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .frame(height: 600)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color.white)
            .border(Color.gray.opacity(0.3), width: 1)
            .cornerRadius(4)
            
            if pageIndex < pdfManager.pageCount - 1 {
                Divider()
                    .frame(height: 2)
                    .background(Color.gray.opacity(0.2))
                    .padding(.vertical, 4)
            }
        }
    }
    
    private func renderAllPages() {
        isRendering = true
        pageImages = Array(repeating: nil, count: pdfManager.pageCount)
        
        let pageCount = pdfManager.pageCount
        let document = pdfManager.pdfDocument
        
        print("📜 Starting to render \(pageCount) pages")
        
        DispatchQueue.global(qos: .userInitiated).async {
            guard let document = document else {
                print("❌ No document to render")
                return
            }
            
            for pageIndex in 0..<pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                
                let bounds = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2.0
                
                let image = page.thumbnail(of: CGSize(
                    width: bounds.width * scale,
                    height: bounds.height * scale
                ), for: .mediaBox)
                
                DispatchQueue.main.async {
                    if pageIndex < pageImages.count {
                        pageImages[pageIndex] = image
                        print("✅ Rendered page \(pageIndex + 1)")
                    }
                    
                    if pageIndex == pageCount - 1 {
                        isRendering = false
                        print("✅ All pages rendered!")
                    }
                }
            }
        }
    }
}

#Preview {
    ContinuousScrollPDFViewWithBounds(pdfManager: PDFManager())
}
