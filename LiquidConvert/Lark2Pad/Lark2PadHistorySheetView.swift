//
//  Lark2PadHistorySheetView.swift
//  LiquidConvert
//
//  SwiftUI sheet view displaying 30-day conversion history stored in iCloud / custom folder.
//

import SwiftUI

struct Lark2PadHistorySheetView: View {
    @ObservedObject var historyManager = Lark2PadHistoryManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedItem: Lark2PadHistoryItem?
    @State private var toastMessage: String?

    private var filteredItems: [Lark2PadHistoryItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return historyManager.historyItems
        }
        return historyManager.historyItems.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.markdown.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if historyManager.historyItems.isEmpty {
                emptyStateView
            } else {
                HSplitView {
                    historyList
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

                    detailPreview
                        .frame(minWidth: 350, maxWidth: .infinity)
                }
            }

            Divider()
            footerBar
        }
        .frame(width: 840, height: 560)
        .overlay(alignment: .top) {
            if let toast = toastMessage {
                Text(toast)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.blue))
                    .shadow(radius: 4)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            if selectedItem == nil, let first = historyManager.historyItems.first {
                selectedItem = first
            }
        }
    }

    private var headerBar: some View {
        HStack {
            Label("30 天转换历史", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            Text("暂无转换历史")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("转换记录将在此处保留 30 天，并自动同步至 iCloud。")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索历史...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(12)

            List(filteredItems, selection: $selectedItem) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    HStack {
                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
                .tag(item)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detailPreview: some View {
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.title3.weight(.bold))
                    Text(item.date.formatted(date: .numeric, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("复制公众号排版") {
                        copyToClipboard(text: item.wechatHTML, isHTML: true, msg: "已复制公众号排版！")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button("复制到主站 (WordPress)") {
                        copyToClipboard(text: item.wordpressHTML, isHTML: false, msg: "已复制主站 (WordPress) 格式！")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button("复制 Markdown") {
                        copyToClipboard(text: item.markdown, isHTML: false, msg: "已复制 Markdown！")
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                ScrollView {
                    Text(item.markdown)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        } else {
            VStack {
                Spacer()
                Text("选择左侧记录查看详情")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Image(systemName: "icloud.fill")
                .foregroundStyle(.blue)
            Text("存储位置: \(historyManager.currentFolderURL.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button("更换文件夹 (iCloud)") {
                historyManager.selectFolder()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if !historyManager.customFolderPath.isEmpty {
                Button("重置") {
                    historyManager.resetToDefaultFolder()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func copyToClipboard(text: String, isHTML: Bool, msg: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if isHTML {
            pb.setString(text, forType: .html)
            pb.setString(text, forType: .string)
        } else {
            pb.setString(text, forType: .string)
        }
        withAnimation {
            toastMessage = msg
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                toastMessage = nil
            }
        }
    }
}
