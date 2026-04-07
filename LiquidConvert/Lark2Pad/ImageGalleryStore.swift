import Combine
import Foundation

struct ImageGalleryItem: Codable, Identifiable, Hashable {
    let id: UUID
    var url: String
    var filename: String
    var mimeType: String
    var byteCount: Int
    var source: String
    var uploadedAt: Date

    init(
        id: UUID = UUID(),
        url: String,
        filename: String,
        mimeType: String,
        byteCount: Int,
        source: String,
        uploadedAt: Date = .now
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.source = source
        self.uploadedAt = uploadedAt
    }
}

@MainActor
final class ImageGalleryStore: ObservableObject {
    static let shared = ImageGalleryStore()

    @Published private(set) var items: [ImageGalleryItem] = []

    private let userDefaultsKey = "lark2pad_image_gallery_items"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        load()
    }

    func recordUpload(
        url: String,
        filename: String,
        mimeType: String,
        byteCount: Int,
        source: String = "lark2pad"
    ) {
        if let index = items.firstIndex(where: { $0.url == url }) {
            items[index].filename = filename
            items[index].mimeType = mimeType
            items[index].byteCount = byteCount
            items[index].source = source
            items[index].uploadedAt = .now
        } else {
            items.insert(
                ImageGalleryItem(
                    url: url,
                    filename: filename,
                    mimeType: mimeType,
                    byteCount: byteCount,
                    source: source
                ),
                at: 0
            )
        }

        save()
    }

    func clear() {
        items = []
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            items = []
            return
        }

        do {
            items = try decoder.decode([ImageGalleryItem].self, from: data)
                .sorted { $0.uploadedAt > $1.uploadedAt }
        } catch {
            print("[ImageGalleryStore] ❌ 读取图库缓存失败: \(error.localizedDescription)")
            items = []
        }
    }

    private func save() {
        do {
            let data = try encoder.encode(items)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            print("[ImageGalleryStore] ❌ 保存图库缓存失败: \(error.localizedDescription)")
        }
    }
}
