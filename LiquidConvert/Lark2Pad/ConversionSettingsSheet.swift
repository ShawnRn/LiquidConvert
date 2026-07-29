import SwiftUI

struct ConversionSettingsSheet: View {
    @Binding var autoUploadImages: Bool
    @Binding var roundImages: Bool
    @Binding var addHeaderBanner: Bool
    @Binding var addFooterBanner: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text("排版与转换设置")
                        .font(.headline)
                }
                
                Spacer()

                Button("完成") {
                    dismiss()
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Settings Form
            Form {
                Section {
                    Toggle(isOn: $autoUploadImages) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动上传图片到私有图床")
                                .font(.body)
                            Text("转换时下载飞书文档图片并上传至公司 S3 私有图床")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $roundImages) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动裁剪图片贝塞尔圆角")
                                .font(.body)
                            Text("对静态图片应用与 Pad 一致的连续圆角")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("图床与图片处理")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(isOn: $addHeaderBanner) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("添加文章开头版式 (DISCOVER THE NEXT)")
                                .font(.body)
                            Text("在公众号文章最上方插入爱范儿橙色 Banner")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $addFooterBanner) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("添加文章结尾版式 (关注卡片与二维码)")
                                .font(.body)
                            Text("在公众号文章最末尾追加爱范儿分割线、关注底卡与二维码")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("公众号文章版式组件 (仅复制公众号生效)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前存储路径")
                            .font(.subheadline.weight(.medium))
                        Text(Lark2PadHistoryManager.shared.currentFolderURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)

                        HStack(spacing: 12) {
                            Button("选择 iCloud / 本地文件夹...") {
                                Lark2PadHistoryManager.shared.selectFolder()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            if !Lark2PadHistoryManager.shared.customFolderPath.isEmpty {
                                Button("恢复默认路径") {
                                    Lark2PadHistoryManager.shared.resetToDefaultFolder()
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                        }
                        .padding(.top, 2)
                    }
                } header: {
                    Text("30 天转换历史与 iCloud 同步目录")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
