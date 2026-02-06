//
//  SharedViews.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import SwiftUI

// MARK: - Glass Container (Shared UI Component)
/// A unified translucent card used across all function modules.
struct GlassCard<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                    }
            }
    }
}

// MARK: - Inspector Section (Shared UI Component)
/// A grouped section for settings in the right inspector panel.
struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            content
        }
    }
}

// MARK: - Unified Empty State (Shared UI Component)
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var onBrowse: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.3))
            
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            
            Button("浏览文件") {
                onBrowse()
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
