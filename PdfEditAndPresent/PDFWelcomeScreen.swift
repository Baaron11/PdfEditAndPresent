import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - PDF Welcome Screen (Fixed)
struct PDFWelcomeScreen: View {
    @StateObject private var pdfViewModel = PDFViewModel()
    @StateObject private var recentFilesManager = RecentFilesManager.shared
    @State private var showFilePicker = false
    @State private var navigateToEditor = false
    @State private var isLoading = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack(spacing: 40) {
                    Spacer()
                    
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 64))
                            .foregroundColor(.blue)
                        
                        Text("PDFMaster")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.primary)
                        
                        Text("Create and annotate PDFs with ease")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Action Buttons
                    VStack(spacing: 16) {
                        // Create New PDF
                        Button(action: {
                            isLoading = true
                            pdfViewModel.createNewPDF()
                            // Ensure PDF is ready before navigating
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                navigateToEditor = true
                                isLoading = false
                            }
                        }) {
                            Group {
                                if isLoading {
                                    HStack(spacing: 12) {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                        Text("Creating PDF...")
                                            .font(.system(size: 16, weight: .semibold))
                                    }
                                } else {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.badge.plus")
                                            .font(.system(size: 18, weight: .semibold))
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Create New PDF")
                                                .font(.system(size: 16, weight: .semibold))
                                            Text("Start with a blank page")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        Spacer()
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isLoading)
                        
                        // Open PDF
                        Button(action: {
                            showFilePicker = true
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 18, weight: .semibold))
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Open PDF")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("Choose a file from your device")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isLoading)
                    }
                    
                    Spacer()
                    
                    // Recent Files (if available)
                    if !recentFilesManager.items.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recent Files")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 20)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(recentFilesManager.items.prefix(5), id: \.self) { recentFile in
                                        Button(action: {
                                            if let url = recentFilesManager.resolveURL(for: recentFile) {
                                                isLoading = true
                                                pdfViewModel.loadPDF(from: url)
                                                // Ensure PDF is ready before navigating
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                                    navigateToEditor = true
                                                    isLoading = false
                                                }
                                            }
                                        }) {
                                            VStack(spacing: 8) {
                                                Image(systemName: "text.document")
                                                    .font(.system(size: 24))

                                                Text(recentFile.displayName.replacingOccurrences(of: ".pdf", with: ""))
                                                    .font(.system(size: 11, weight: .medium))
                                                    .lineLimit(1)
                                            }
                                            .frame(width: 80, height: 80)
                                            .background(Color.white)
                                            .foregroundColor(.blue)
                                            .cornerRadius(8)
                                        }
                                        .disabled(isLoading)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding(20)
            }
            
            // Navigation
            NavigationLink(isActive: $navigateToEditor) {
                if pdfViewModel.currentDocument != nil {
                    PDFEditorScreenRefactored(pdfViewModel: pdfViewModel)
                        .navigationBarBackButtonHidden()
                }
            } label: {
                EmptyView()
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf],
            onCompletion: { result in
                switch result {
                case .success(let url):
                    isLoading = true
                    pdfViewModel.loadPDF(from: url)
                    // Ensure PDF is ready before navigating
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        navigateToEditor = true
                        isLoading = false
                    }
                case .failure(let error):
                    print("❌ File picker error: \(error)")
                    isLoading = false
                }
            }
        )
    }
}

#Preview {
    PDFWelcomeScreen()
}
