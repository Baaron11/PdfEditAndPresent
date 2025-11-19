//
//  CanvasMode.swift
//  UnifiedBoard
//
//  Created by Brandon Ramirez on 11/7/25.
//


import Foundation


// MARK: - Canvas Mode State Machine
enum CanvasMode {
    case drawing     // User can draw with PencilKit; touches go to PKCanvasView
    case selecting   // User can interact with PaperKit items; touches go to PaperKit
    case idle        // No interaction layer active
}
