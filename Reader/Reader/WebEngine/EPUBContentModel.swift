import Foundation
import EPUBKit

/// 自研引擎的书籍模型：把 EPUBKit 的解析结果整理成「可直接喂给 WebView」的形式。
///
/// EPUBKit 的 `EPUBSpineItem` 只有 `idref`，真正的文件路径要去 `manifest.items` 里查；
/// 路径是相对 OPF 所在目录（`contentDirectory`）的，这里统一转成绝对 `file://` URL，
/// 并把相对链接改写成原生可消费的形态。
final class EPUBContentModel {

    struct Chapter {
        /// 脊中的顺序（也是本书的章节序号）
        let index: Int
        /// 相对 contentDirectory 的原始 href，例如 "Text/chapter1.xhtml"
        let href: String
        /// 磁盘上的绝对路径
        let fileURL: URL
        /// 目录里显示的名字（NCX 的 label），没有就用文件名
        var title: String
    }

    let rootDirectory: URL
    let contentDirectory: URL
    let chapters: [Chapter]
    /// 规范化后的相对 href → 章节索引
    let indexByHref: [String: Int]
    /// 规范化后的相对 href → 对应的目录标题（NCX 里可能同一文件多个锚点）
    let tocEntries: [TOCEntry]

    let title: String
    let author: String
    let language: String
    let pageProgressionRTL: Bool

    // MARK: - 构造

    convenience init?(directory: URL) {
        guard let document = EPUBDocument(url: directory) else { return nil }
        self.init(document: document)
    }

    init(document: EPUBDocument) {
        rootDirectory = document.directory
        contentDirectory = document.contentDirectory

        var chapters: [Chapter] = []
        var indexByHref: [String: Int] = [:]
        var titlesByHref: [String: String] = [:]

        // 先收集 NCX 的 label，挂到对应文件上
        func collectLabels(_ toc: EPUBTableOfContents) {
            if let item = toc.item {
                let key = Self.normalize(href: item)
                if !key.isEmpty { titlesByHref[key] = toc.label }
            }
            toc.subTable?.forEach(collectLabels)
        }
        collectLabels(document.tableOfContents)

        // 再按 spine 顺序建立章节表
        for spineItem in document.spine.items {
            guard let manifestItem = document.manifest.items[spineItem.idref] else { continue }
            let href = manifestItem.path
            let key = Self.normalize(href: href)
            let fileURL = contentDirectory.appendingPathComponent(href)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            let fallback = (href as NSString).lastPathComponent
            let title = titlesByHref[key] ?? (fallback as NSString).deletingPathExtension
            let chapter = Chapter(index: chapters.count, href: href, fileURL: fileURL, title: title)
            chapters.append(chapter)
            indexByHref[key] = chapter.index
        }

        self.chapters = chapters
        self.indexByHref = indexByHref
        self.title = document.title ?? ""
        self.author = document.author ?? ""
        self.language = document.metadata.language ?? ""
        self.pageProgressionRTL = document.spine.pageProgressionDirection == .rightToLeft

        // 构造目录条目：优先用 NCX，解析不到就退化为脊顺序
        var entries: [TOCEntry] = []
        func walk(_ toc: EPUBTableOfContents, level: Int) {
            if let item = toc.item, let found = Self.lookup(href: item, chapters: chapters, indexByHref: indexByHref) {
                entries.append(TOCEntry(
                    id: "toc-\(entries.count)",
                    title: toc.label.trimmed.nonEmpty ?? found.chapter.title,
                    href: item,
                    level: level
                ))
            }
            toc.subTable?.forEach { walk($0, level: level + 1) }
        }
        walk(document.tableOfContents, level: 0)

        if entries.isEmpty {
            entries = chapters.map {
                TOCEntry(id: "toc-\($0.index)", title: $0.title, href: $0.href, level: 0)
            }
        }
        tocEntries = entries
    }

    // MARK: - 查询

    /// 去掉锚点、URL 编码和 "./" 前缀，得到可比较的相对路径。
    static func normalize(href: String) -> String {
        var value = href
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        value = value.removingPercentEncoding ?? value
        while value.hasPrefix("./") { value.removeFirst(2) }
        return value
    }

    /// 根据目录里的 href（可能带 #锚点）找到章节。
    func chapter(for href: String) -> (chapter: Chapter, fragment: String?)? {
        Self.lookup(href: href, chapters: chapters, indexByHref: indexByHref)
    }

    private static func lookup(
        href: String,
        chapters: [Chapter],
        indexByHref: [String: Int]
    ) -> (chapter: Chapter, fragment: String?)? {
        var clean = href
        var fragment: String?
        if let hash = clean.firstIndex(of: "#") {
            let raw = String(clean[clean.index(after: hash)...])
            fragment = raw.removingPercentEncoding ?? raw
            clean = String(clean[..<hash])
        }
        let key = normalize(href: clean)
        if let index = indexByHref[key], chapters.indices.contains(index) {
            return (chapters[index], fragment)
        }
        // 兜底：只比文件名
        let name = (key as NSString).lastPathComponent
        if let chapter = chapters.first(where: { ($0.href as NSString).lastPathComponent == name }) {
            return (chapter, fragment)
        }
        return nil
    }
}
