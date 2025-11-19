//
//  PDFBoardAPP.swift
//  PDFBoard
//
//  Created by Brandon Ramirez on 11/7/25.
//
//
import SwiftUI
import PencilKit
import PaperKit

@main
struct PDFBoardApp: App {
    var body: some Scene {
        WindowGroup {
            // Step 1: PDF Editor with Unified Canvas
            PDFWelcomeScreen()            
        }
    }
}
