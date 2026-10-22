import Foundation
import UIKit
import EPUBKit
import ReadiumShared
import ReadiumStreamer

/// 导入结果
struct ImportResult {
    let book: Book
    let wasDuplicate: Bool
}

enum ImportError: LocalizedError {
    case notEPUB
    case unreadable(String)
    case empty
    case copyFailed(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .notEPUB: return "这不是 EPUB 文件（扩展名不是 .epub）"
        case .unreadable(let name): return "无法读取文件：\(name)"
        case .empty: return "文件是空的（0 字节）"
        case .copyFailed(let reason): return "写入书库失败：\(reason)"
        case .parseFailed(let reason): return "解析 EPUB 失败：\(reason)"
        }
    }
}

/// 从 EPUB 里读出来的展示信息。
/// 全部是可选的：读不出来就用书名兜底，不允许因为元数据缺失而拒绝导入。
struct EPUBSummary {
    var title: String?
    var author: String?
    var publisher: String?
    var language: String?
    var identifier: String?
    var version: String = ""
    var cover: UIImage?
}

/// 导入管线。
///
/// 三条入口最终都汇到 `importFile(at:)`：
/// 1. 书架「添加」按钮 → 系统文件选择器（`.fileImporter`）
/// 2. 分享扩展导入后留下的 Inbox 文件 → `importStagedFile(at:)`
/// 3. 其它 App 通过 URL Scheme / 文件打开方式递过来的 URL → `onOpenURL` → `importFile`
///
/// 设计原则（重要）：
/// - **先把文件复制进书库，再解析元数据**。复制成功就算导入成功，
///   元数据解析失败只影响书名/封面，不影响这本书能不能打开。
///   以前是「解析必须先成功」，EPUBKit 的解析器很严格（要求 `spine@toc`
///   且能找到 NCX/NAV 文件），大量正常 EPUB 3 文件会解析失败，
///   结果就是「选了文件却什么都没进书架，也打不开」。
/// - 元数据优先用 Readium 读，和阅读引擎完全同一套解析器，避免
///   「导入说不行、阅读其实能打开」的不一致。
/// - 外部 URL（尤其来自其它 App 的 `file://`）大多是临时授权，
///   必须在 security-scoped 访问期内立刻复制到自己的目录，否则稍后再读会失败。
@MainActor
final class ImportService {

    static let shared = ImportService()

    private let parsingQueue = DispatchQueue(label: "com.example.reader.import", qos: .userInitiated)

    /// 与阅读器同源的解析器，只用来读元数据与封面。
    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener

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

    // MARK: - 对外入口

    /// 系统文件选择器返回的 URL。
    func importFromPicker(url: URL, into store: LibraryStore) async throws -> ImportResult {
        try await importFile(at: url, into: store)
    }

    /// 导入一个已经可自由读取的本地文件（分享扩展写入 Inbox 的文件），完成后删除源文件。
    func importStagedFile(at url: URL, into store: LibraryStore) async throws -> ImportResult {
        defer { try? FileManager.default.removeItem(at: url) }
        return try await importFile(at: url, into: store)
    }

    /// 从任意 URL（含 URL Scheme 参数里的文件 URL）导入。
    func importFromExternalURL(_ url: URL, into store: LibraryStore) async throws -> ImportResult {
        try await importFile(at: url, into: store)
    }

    /// 把外部递进来的文件**同步**复制到 Inbox，返回可长期读取的本地路径。
    ///
    /// 用途：`onOpenURL` 给的 `file://` 是临时授权，出了回调就可能失效，
    /// 必须当场复制，不能丢到异步任务里再读。
    func stage(_ url: URL) throws -> URL {
        let inbox = FileManager.inboxURL
        let destination = inbox.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        try copyBytes(from: url, to: destination)
        guard (byteSize(of: destination) ?? 0) > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.empty
        }
        return destination
    }

    // MARK: - 核心

    func importFile(at url: URL, into store: LibraryStore) async throws -> ImportResult {
        let originalName = url.lastPathComponent

        // 1. 先把字节搬进书库。整个导入只有这一步是强制的。
        let destination = try copyIntoLibrary(from: url, originalName: originalName)

        // 2. 元数据（失败则回退文件名，不抛错）
        let summary = await readSummary(at: destination, originalName: originalName)

        // 3. 去重：同一个 identifier 视为同一本。
        if let identifier = summary.identifier?.trimmed.nonEmpty,
           let existing = store.books.first(where: { $0.identifier == identifier }) {
            try? FileManager.default.removeItem(at: destination)
            DebugLog.info("书库中已有：\(existing.title)")
            return ImportResult(book: existing, wasDuplicate: true)
        }

        // 4. 入库
        var book = makeBook(summary, fileName: destination.lastPathComponent, originalName: originalName)
        if let cover = summary.cover {
            book.hasCover = await saveCover(image: cover, id: book.id)
        }
        store.add(book)
        DebugLog.info("导入成功：\(book.title)（\(book.fileSizeText)）")
        return ImportResult(book: book, wasDuplicate: false)
    }

    // MARK: - 文件搬运

    /// 把外部文件复制到 `<Books>/<uuid>.epub`。
    private func copyIntoLibrary(from source: URL, originalName: String) throws -> URL {
        let ext = source.pathExtension.lowercased()
        if !ext.isEmpty, ext != "epub" {
            throw ImportError.notEPUB
        }

        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ImportError.unreadable(originalName)
        }

        let destination = FileManager.booksURL.appendingPathComponent("\(UUID().uuidString).epub")
        try copyBytes(from: source, to: destination)

        let size = byteSize(of: destination) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.empty
        }
        return destination
    }

    /// 三层降级复制。文件提供器（iCloud Drive、第三方网盘）各有各的脾气，
    /// 单靠一种方式总会有读不到的情况。
    private func copyBytes(from source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)

        // 1. NSFileCoordinator：iCloud / 文件提供器要求协调读取
        var coordinationError: NSError?
        var accessorError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            do {
                try FileManager.default.copyItem(at: readableURL, to: destination)
            } catch {
                accessorError = error
            }
        }
        if coordinationError == nil, accessorError == nil, FileManager.default.fileExists(atPath: destination.path) {
            return
        }
        DebugLog.error("协调读取失败，改用直接复制：\(coordinationError?.localizedDescription ?? accessorError?.localizedDescription ?? "-")")

        // 2. 直接复制
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            if FileManager.default.fileExists(atPath: destination.path) { return }
        } catch {
            DebugLog.error("直接复制失败：\(error.localizedDescription)")
        }

        // 3. 读成 Data 再写（个别文件提供器只肯给流）
        try? FileManager.default.removeItem(at: destination)
        if let data = try? Data(contentsOf: source), !data.isEmpty {
            do {
                try data.write(to: destination, options: .atomic)
                return
            } catch {
                throw ImportError.copyFailed(error.localizedDescription)
            }
        }

        let reason = coordinationError?.localizedDescription
            ?? accessorError?.localizedDescription
            ?? "文件提供器没有返回可读取的内容"
        throw ImportError.unreadable("\(source.lastPathComponent)：\(reason)")
    }

    private func byteSize(of url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    // MARK: - 元数据

    private func makeBook(_ summary: EPUBSummary, fileName: String, originalName: String) -> Book {
        let fallbackTitle = (originalName as NSString).deletingPathExtension.trimmed.nonEmpty ?? "未命名"
        return Book(
            id: UUID(),
            title: summary.title?.trimmed.nonEmpty ?? fallbackTitle,
            author: summary.author?.trimmed.nonEmpty ?? "未知作者",
            publisher: summary.publisher?.trimmed.nonEmpty ?? "",
            language: summary.language?.trimmed.nonEmpty ?? "",
            identifier: summary.identifier?.trimmed.nonEmpty ?? "",
            fileName: fileName,
            fileSize: byteSize(of: FileManager.booksURL.appendingPathComponent(fileName)) ?? 0,
            addedAt: Date(),
            epubVersion: summary.version,
            hasCover: false,
            progress: 0,
            readiumLocatorJSON: nil,
            lastOpenedAt: nil,
            finishedAt: nil
        )
    }

    private func readSummary(at url: URL, originalName: String) async -> EPUBSummary {
        if let summary = await readSummaryWithReadium(at: url) {
            return summary
        }
        DebugLog.error("Readium 读取元数据失败，尝试 EPUBKit：\(originalName)")
        if let summary = await readSummaryWithEPUBKit(at: url) {
            return summary
        }
        DebugLog.error("元数据全部解析失败，用文件名兜底：\(originalName)")
        return EPUBSummary()
    }

    /// 与阅读器同源的解析，最不容易出现「导入失败但能阅读」的落差。
    private func readSummaryWithReadium(at url: URL) async -> EPUBSummary? {
        guard let fileURL = FileURL(url: url) else {
            DebugLog.error("FileURL 构造失败：\(url.path)")
            return nil
        }

        let asset: Asset
        switch await assetRetriever.retrieve(url: fileURL) {
        case .success(let value):
            asset = value
        case .failure(let error):
            DebugLog.error("Readium 读取资源失败：\(String(describing: error))")
            return nil
        }

        let publication: Publication
        switch await publicationOpener.open(asset: asset, allowUserInteraction: false) {
        case .success(let value):
            publication = value
        case .failure(let error):
            DebugLog.error("Readium 打开失败：\(String(describing: error))")
            return nil
        }

        var summary = EPUBSummary()
        let metadata = publication.metadata
        summary.title = metadata.title
        summary.author = metadata.authors.map(\.name).joined(separator: "、")
        summary.publisher = metadata.publishers.map(\.name).joined(separator: "、")
        summary.language = metadata.languages.first
        summary.identifier = metadata.identifier

        if case .success(let image) = await publication.cover() {
            summary.cover = image
        }
        return summary
    }

    /// 兜底解析：EPUBKit 很严格，只把它当备胎用。
    private func readSummaryWithEPUBKit(at url: URL) async -> EPUBSummary? {
        await withCheckedContinuation { (continuation: CheckedContinuation<EPUBSummary?, Never>) in
            parsingQueue.async {
                guard let document = EPUBDocument(url: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                var summary = EPUBSummary()
                summary.title = document.title
                summary.author = document.author
                summary.publisher = document.publisher
                summary.language = document.metadata.language
                summary.identifier = document.metadata.identifier
                summary.version = Self.readVersion(at: document.directory)
                if let coverURL = document.cover, let image = UIImage(contentsOfFile: coverURL.path) {
                    summary.cover = image
                }
                continuation.resume(returning: summary)
            }
        }
    }

    private func saveCover(image: UIImage, id: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            parsingQueue.async {
                // 封面不需要原始分辨率，长边压到 1000pt 足够，省空间也更快。
                let scaled = image.scaledDown(maxDimension: 1000)
                guard let data = scaled.jpegData(compressionQuality: 0.85) else {
                    continuation.resume(returning: false)
                    return
                }
                let destination = FileManager.coversURL.appendingPathComponent("\(id.uuidString).jpg")
                do {
                    try data.write(to: destination, options: .atomic)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - 元数据辅助

    /// 从 OPF 的 `<package version="3.0">` 读出版本号，仅用于展示。
    private static func readVersion(at directory: URL) -> String {
        guard
            let container = try? Data(contentsOf: directory.appendingPathComponent("META-INF/container.xml")),
            let opfPath = OPFInspector.fullPath(in: container),
            let opf = try? Data(contentsOf: directory.appendingPathComponent(opfPath)),
            let version = OPFInspector.version(in: opf)
        else { return "" }
        return version
    }
}

extension UIImage {
    func scaledDown(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let ratio = maxDimension / longest
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// 极轻量的 XML 属性提取，避免为了读一个 version 再引一个 XML 依赖。
enum OPFInspector {
    static func fullPath(in containerXML: Data) -> String? {
        attribute("full-path", in: containerXML)
    }

    static func version(in opfXML: Data) -> String? {
        attribute("version", in: opfXML)
    }

    private static func attribute(_ name: String, in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        // 匹配形如 version="3.0" 或 full-path="OEBPS/content.opf"
        let pattern = name + "\\s*=\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }
}
