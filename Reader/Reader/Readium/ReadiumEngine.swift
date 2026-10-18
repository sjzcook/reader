import SwiftUI
import UIKit
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator

/// Readium 引擎的封装。
///
/// 职责：
/// - 打开/缓存 `Publication`
/// - 把 App 的 `AppearanceSettings` 翻译成 `EPUBPreferences`
/// - 通过 `NavigatorDelegate` 回传阅读位置
@MainActor
final class ReadiumEngine {

    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener

    /// 同一本书重复打开时复用，避免每次都重新解析。
    private var cache: [UUID: Publication] = [:]

    init() {
        let client = DefaultHTTPClient()
        let retriever = AssetRetriever(httpClient: client)
        assetRetriever = retriever
        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: client,
                assetRetriever: retriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
    }

    // MARK: - 打开

    func open(book: Book) async throws -> Publication {
        if let cached = cache[book.id] { return cached }

        guard let fileURL = FileURL(url: book.fileURL) else {
            throw ReadiumEngineError.invalidURL
        }

        let asset: Asset
        switch await assetRetriever.retrieve(url: fileURL) {
        case .success(let retrieved):
            asset = retrieved
        case .failure(let error):
            throw ReadiumEngineError.asset(error)
        }

        switch await publicationOpener.open(asset: asset, allowUserInteraction: true) {
        case .success(let publication):
            cache[book.id] = publication
            return publication
        case .failure(let error):
            throw ReadiumEngineError.opening(error)
        }
    }

    func evict(bookID: UUID) {
        cache[bookID] = nil
    }

    /// 章节目录（层级扁平化，便于侧边栏列表展示）
    func tableOfContents(for publication: Publication) -> [TOCEntry] {
        func walk(_ links: [Link], level: Int) -> [TOCEntry] {
            links.flatMap { link -> [TOCEntry] in
                let entry = TOCEntry(
                    id: "\(level)-\(link.href.string)-\(link.title ?? "")",
                    title: link.title?.trimmed.nonEmpty ?? "未命名章节",
                    href: link.href.string,
                    level: level,
                    link: link
                )
                return [entry] + walk(link.children, level: level + 1)
            }
        }
        return walk(publication.tableOfContents, level: 0)
    }

    /// 恢复上次阅读位置。
    func restoreLocator(for book: Book) -> Locator? {
        guard
            let json = book.readiumLocatorJSON,
            let data = json.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            let locator = try? Locator(json: value, warnings: nil)
        else { return nil }
        return locator
    }

    /// 把 Locator 序列化成可持久化的字符串。
    func encode(locator: Locator) -> String? {
        try? locator.jsonString()
    }

    /// 定位 Locator 对应的章节目录项（用于工具栏显示章节名）
    func title(for locator: Locator, in toc: [TOCEntry]) -> String? {
        let href = locator.href.string
        return toc.first { entry in
            href.hasSuffix(entry.href) || entry.href.hasSuffix(href)
        }?.title
    }

    // MARK: - 外观设置 → Readium 偏好

    func preferences(from appearance: AppearanceSettings) -> EPUBPreferences {
        var prefs = EPUBPreferences()

        switch appearance.theme {
        case .light: prefs.theme = .light
        case .sepia: prefs.theme = .sepia
        case .dark: prefs.theme = .dark
        }

        // Readium 的 fontSize 是「相对基准字号的倍率」，1.0 约等于 16pt。
        prefs.fontSize = max(0.6, appearance.fontSize / 16.0)
        prefs.lineHeight = appearance.lineHeight
        // Readium 的 pageMargins 取值区间约为 0...10，这里把 0...0.2 映射过去。
        prefs.pageMargins = appearance.pageMargin * 10
        prefs.paragraphSpacing = appearance.paragraphSpacing
        prefs.publisherStyles = appearance.publisherStyles
        prefs.scroll = appearance.isScrolling
        prefs.columnCount = appearance.twoColumns ? .two : .one
        prefs.textAlign = appearance.justify ? .justify : .start
        prefs.fontFamily = appearance.fontFamily.map { FontFamily(rawValue: $0) }
        // Readium 的 Color 只接受不带 # 的十六进制或 UIColor，这里统一走 UIColor。
        switch appearance.theme {
        case .light:
            prefs.backgroundColor = Color(uiColor: UIColor.white)
            prefs.textColor = Color(uiColor: UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        case .sepia:
            prefs.backgroundColor = Color(uiColor: UIColor(red: 0.98, green: 0.957, blue: 0.91, alpha: 1))
            prefs.textColor = Color(uiColor: UIColor(red: 0.23, green: 0.196, blue: 0.157, alpha: 1))
        case .dark:
            prefs.backgroundColor = Color(uiColor: UIColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 1))
            prefs.textColor = Color(uiColor: UIColor(red: 0.847, green: 0.847, blue: 0.847, alpha: 1))
        }

        return prefs
    }
}

enum ReadiumEngineError: LocalizedError {
    case invalidURL
    case asset(ReadError)
    case opening(PublicationOpenError)
    case navigatorUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "书籍文件路径无效"
        case .asset(let error): return "无法读取书籍：\(String(describing: error))"
        case .opening(let error): return "无法打开书籍：\(String(describing: error))"
        case .navigatorUnavailable: return "阅读引擎初始化失败，可尝试在设置中切换为 EPUBKit 引擎"
        }
    }
}

/// 目录条目（两套引擎共用的展示模型）
struct TOCEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let href: String
    let level: Int
    /// Readium 的 Link，用于直接跳转；自研引擎不使用。
    let link: Link?

    static func == (lhs: TOCEntry, rhs: TOCEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(id: String, title: String, href: String, level: Int, link: Link? = nil) {
        self.id = id
        self.title = title
        self.href = href
        self.level = level
        self.link = link
    }
}
