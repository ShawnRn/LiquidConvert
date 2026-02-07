//
//  LicenseView.swift
//  LiquidConvert
//
//  Created by Shawn Rain.
//

import SwiftUI

struct LicenseView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    
    struct LicenseItem: Identifiable {
        let id = UUID()
        let name: String
        let licenseType: String
        let description: String?
        let url: String?
        let copyright: String
        let tags: [String]
    }
    
    // Filtered data directly
    let licenses = [
        LicenseItem(
            name: "Sparkle",
            licenseType: "MIT",
            description: "A software update framework for macOS.",
            url: "https://sparkle-project.org/",
            copyright: "Copyright (c) 2006-present Andy Matuschak",
            tags: ["Framework"]
        ),
        LicenseItem(
            name: "CuteGIF",
            licenseType: "GPL-3.0",
            description: "A high-performance GIF encoder/decoder.",
            url: "https://github.com/tasy5kg/CuteGIF",
            copyright: "Copyright (c) 2026 tasy5kg",
            tags: ["Core"]
        )
    ]
    
    var body: some View {
        ZStack {
            // Background - Softer, slightly darker than cards
            Group {
                if colorScheme == .dark {
                    Color(nsColor: .windowBackgroundColor) // Dark mode: standard dark bg
                } else {
                    Color(nsColor: .quaternaryLabelColor) // Light mode: slight gray/dimmed bg
                        .opacity(0.5)
                }
            }
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.blue)
                        .frame(width: 64, height: 64)
                        .background(
                            Circle()
                                .fill(Color.blue.opacity(0.1))
                        )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("开源许可")
                            .font(.system(size: 24, weight: .bold))
                        
                        Text("感谢这些伟大的开源项目，它们让 LiquidConvert 的诞生成为可能。")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    // Removed padding(.top, 4) for better center alignment
                    
                    Spacer()
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 24)
                
                // List (Scrollable)
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(licenses) { item in
                            LicenseItemView(item: item)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 80) // Space for bottom button
                }
            }
            
            // Bottom Button Overlay
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: {
                        dismiss()
                    }) {
                        Text("完成")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                }
                .padding(.horizontal, 32) // Match card padding
                .padding(.bottom, 24)
            }
        }
        .frame(width: 600, height: 450)
    }
}

struct LicenseItemView: View {
    let item: LicenseView.LicenseItem
    @State private var isHovered = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(item.name)
                            .font(.headline)
                            .fontWeight(.bold)
                        
                        Text(item.licenseType)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    
                    if let description = item.description {
                        Text(description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    
                    if let url = item.url, let link = URL(string: url) {
                        Link(item.url ?? "", destination: link)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }

                    Text(item.copyright)
                        .font(.caption)
                        .foregroundColor(.tertiaryLabel)
                        .padding(.top, 4)
                }
                
                Spacer()
                
                HStack(spacing: 4) {
                    ForEach(item.tags, id: \.self) { tag in
                         Text(tag)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .foregroundColor(.secondary)
                            .cornerRadius(6)
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : .white)
        )
        // Add subtle shadow for the 'card' lift effect which usually accompanies brighter cards on darker bg
        .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 2)
    }
}
