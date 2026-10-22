import Foundation
import EPUBKit

/// 一本已导入的书。
struct Book: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var author: String
    var publisher: String
    var language: String
    var identifier: String
    var fileName: String
    var fileSize: Int64
    var addedAt: Date
    /// 书籍自身声明的 EPUB 版本，例如 "3.0" / "2.0"。
    var epubVersion: String
    var hasCover: Bool

    // MARK: - 阅读进度
    /// 0...1 的总进度。
    var progress: Double
    /// Readium `Locator` 的 JSON，用于精确恢复上次阅读位置。
    var readiumLocatorJSON: String?

    var lastOpenedAt: Date?
    var finishedAt: Date?

    var fileURL: URL {
        FileManager.booksURL.appendingPathComponent(fileName)
    }

    var coverURL: URL? {
        guard hasCover else { return nil }
        let url = FileManager.coversURL.appendingPathComponent("\(id.uuidString).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var readingProgressText: String {
        if progress <= 0.001 { return "未开始" }
        if progress >= 0.995 { return "已读完" }
        return "\(Int(progress * 100))%"
    }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    static func placeholder(url: URL) -> Book {
        Book(
            id: UUID(),
            title: url.deletingPathExtension().lastPathComponent,
            author: "未知作者",
            publisher: "",
            language: "",
            identifier: "",
            fileName: url.lastPathComponent,
            fileSize: 0,
            addedAt: Date(),
            epubVersion: "",
            hasCover: false,
            progress: 0,
            readiumLocatorJSON: nil,
            lastOpenedAt: nil,
            finishedAt: nil
        )
    }
}

extension Book {
    init(from document: EPUBDocument, fileURL: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        self.init(
            id: UUID(),
            title: document.title?.trimmed.nonEmpty ?? fileURL.deletingPathExtension().lastPathComponent,
            author: document.author?.trimmed.nonEmpty ?? "未知作者",
            publisher: document.publisher?.trimmed.nonEmpty ?? "",
            language: document.metadata.language?.trimmed.nonEmpty ?? "",
            identifier: document.metadata.identifier?.trimmed.nonEmpty ?? "",
            fileName: fileURL.lastPathComponent,
            fileSize: size,
            addedAt: Date(),
            epubVersion: "",
            hasCover: false,
            progress: 0,
            readiumLocatorJSON: nil,
            lastOpenedAt: nil,
            finishedAt: nil
        )
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { trimmed.isEmpty ? nil : trimmed }
}
