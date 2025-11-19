//
//  SidebarActionButtonStyle.swift
//  PdfEditAndPresent
//
//  Created by Claude on 2025-11-19.
//

import SwiftUI

struct SidebarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44) // slim, not a page tile
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: configuration.isPressed ? 2 : 1)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.15), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SidebarActionButton: View {
    let systemImage: String
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).imageScale(.large)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.leading, 10)
    }
}
