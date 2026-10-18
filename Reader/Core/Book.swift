import Foundation
import EPUBKit

/// 阅读引擎类型。用户可以在设置里切换，书架和阅读器都依赖这个枚举。
enum ReaderEngineKind: String, Codable, CaseIterable, Identifiable {
    /// Readium Swift Toolkit：成熟的分页引擎，排版与交互接近商业阅读器。
    case readium
    /// EPUBKit + WKWebView：EPUBKit 负责解析，自己实现渲染与分页。
    case epubkit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readium: return "Readium 引擎"
        case .epubkit: return "EPUBKit 引擎"
        }
    }

    var subtitle: String {
        switch self {
        case .readium: return "Readium Swift Toolkit · 专业排版"
        case .epubkit: return "EPUBKit + 自研渲染 · 轻量可控"
        }
    }

    var detail: String {
        switch self {
        case .readium:
            return "使用 Readium 3.11 的 EPUBNavigatorViewController。分页、字体、主题由成熟的 Readium CSS 驱动，对复杂排版（竖排、注音、固定版式）兼容性最好。"
        case .epubkit:
            return "用 EPUBKit 解析 OPF/NCX，再用 WKWebView + CSS 多栏自行分页。代码完全可控、依赖更轻，适合二次开发排版逻辑。"
        }
    }

    var badge: String {
        switch self {
        case .readium: return "推荐"
        case .epubkit: return "轻量"
        }
    }
}

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
    /// 当前章节在脊（spine）里的索引。
    var chapterIndex: Int
    /// 章节内部锚点（元素 id 或片段），用于精确恢复。
    var fragment: String?
    /// Readium 引擎用的 `Locator` JSON；两套引擎各自保存，互不干扰。
    var readiumLocatorJSON: String?
    /// 章节内的比例位置，自研引擎用做兜底恢复。
    var chapterProgression: Double
    /// 已翻到的页码。
    var lastPage: Int
    var totalPages: Int

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
            chapterIndex: 0,
            fragment: nil,
            readiumLocatorJSON: nil,
            chapterProgression: 0,
            lastPage: 0,
            totalPages: 0,
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
            chapterIndex: 0,
            fragment: nil,
            readiumLocatorJSON: nil,
            chapterProgression: 0,
            lastPage: 0,
            totalPages: 0,
            lastOpenedAt: nil,
            finishedAt: nil
        )
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { trimmed.isEmpty ? nil : trimmed }
}
