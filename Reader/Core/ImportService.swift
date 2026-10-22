import Foundation
import EPUBKit
import UIKit

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
        case .notEPUB: return "这不是有效的 EPUB 文件"
        case .unreadable(let name): return "无法读取文件：\(name)"
        case .empty: return "文件是空的"
        case .copyFailed(let reason): return "写入书库失败：\(reason)"
        case .parseFailed(let reason): return "解析 EPUB 失败：\(reason)"
        }
    }
}

/// 导入管线。
///
/// 三条入口最终都汇到 `importFile(at:)`：
/// 1. 书架「添加」按钮 → 系统文件选择器（`.fileImporter`）
/// 2. 分享扩展导入后留下的 Inbox 文件 → `importStagedFile(at:)`
/// 3. 其它 App 通过 URL Scheme / 文件打开方式递过来的 URL → `onOpenURL` → `stage` + `importFile`
///
/// 关键点：外部 URL（尤其来自其它 App 的 `file://`）大多是临时授权，
/// 必须在 security-scoped 访问期内立刻复制到自己的目录，否则稍后再读会失败。
@MainActor
final class ImportService {

    static let shared = ImportService()

    private let parsingQueue = DispatchQueue(label: "com.example.reader.import", qos: .userInitiated)

    // MARK: - 对外入口

    /// 系统文件选择器返回的 URL。
    func importFromPicker(url: URL, into store: LibraryStore) async throws -> ImportResult {
        let staged = try stage(url)
        defer { try? FileManager.default.removeItem(at: staged) }
        return try await importFile(at: staged, into: store)
    }

    /// 导入一个已经可自由读取的本地文件（分享扩展写入 Inbox 的文件），完成后删除源文件。
    func importStagedFile(at url: URL, into store: LibraryStore) async throws -> ImportResult {
        defer { try? FileManager.default.removeItem(at: url) }
        return try await importFile(at: url, into: store)
    }

    /// 从任意 URL（含 URL Scheme 参数里的文件 URL）导入。
    func importFromExternalURL(_ url: URL, into store: LibraryStore) async throws -> ImportResult {
        let staged = try stage(url)
        defer { try? FileManager.default.removeItem(at: staged) }
        return try await importFile(at: staged, into: store)
    }

    // MARK: - 核心

    func importFile(at url: URL, into store: LibraryStore) async throws -> ImportResult {
        guard url.pathExtension.lowercased() == "epub" else { throw ImportError.notEPUB }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw ImportError.empty }

        // 1. 先解析拿元数据。EPUBKit 会解压到临时目录；解析失败直接报错，
        //    不会在书库里留下垃圾文件。
        let parsed = try await parseEPUB(at: url)

        // 2. 去重：同一个 identifier 视为同一本。
        if let identifier = parsed.document.metadata.identifier?.trimmed.nonEmpty,
           let existing = store.books.first(where: { $0.identifier == identifier }) {
            return ImportResult(book: existing, wasDuplicate: true)
        }

        // 3. 拷贝进书库。文件名用 UUID，规避中文、重名、特殊字符。
        let destination = FileManager.booksURL.appendingPathComponent("\(UUID().uuidString).epub")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }

        var book = Book(from: parsed.document, fileURL: destination)
        book.epubVersion = parsed.version

        // 4. 封面：EPUBKit 已把书解压到临时目录，直接抄封面出来。
        if let coverSource = parsed.document.cover {
            book.hasCover = await saveCover(from: coverSource, id: book.id)
        }

        store.add(book)
        DebugLog.info("导入成功：\(book.title)")
        return ImportResult(book: book, wasDuplicate: false)
    }

    // MARK: - 文件搬运

    /// 把文件选择器返回的安全作用域 URL 复制到 Inbox。
    /// 使用 NSFileCoordinator 读取文件提供器（iCloud Drive 等）提供的文件，
    /// 避免直接 Data(contentsOf:) 在某些文件提供器场景下读不到内容或一次性占用大量内存。
    func stage(_ url: URL) throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var name = url.lastPathComponent
        if !name.lowercased().hasSuffix(".epub") { name += ".epub" }

        let inbox = FileManager.inboxURL
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        } catch {
            throw ImportError.copyFailed("无法创建导入目录：\\(error.localizedDescription)")
        }

        let destination = inbox.appendingPathComponent("\\(UUID().uuidString)-\\(name)")
        var coordinationError: NSError?
        var copyError: Error?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            do {
                let values = try readableURL.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size > 0 else {
                    throw ImportError.empty
                }
                try FileManager.default.copyItem(at: readableURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let error = coordinationError {
            throw ImportError.unreadable("\\(url.lastPathComponent)：\\(error.localizedDescription)")
        }
        if let error = copyError {
            if let importError = error as? ImportError { throw importError }
            throw ImportError.copyFailed(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw ImportError.copyFailed("文件提供器未返回可读取的 EPUB 文件")
        }
        return destination
    }

    // MARK: - 后台任务

    struct ParsedEPUB {
        let document: EPUBDocument
        let version: String
    }

    private func parseEPUB(at url: URL) async throws -> ParsedEPUB {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        return try await withCheckedThrowingContinuation { continuation in
            parsingQueue.async {
                guard let document = EPUBDocument(url: url) else {
                    continuation.resume(throwing: ImportError.parseFailed("文件结构不符合 EPUB 规范"))
                    return
                }
                let version = Self.readVersion(at: document.directory)
                continuation.resume(returning: ParsedEPUB(document: document, version: version))
            }
        }
    }

    private func saveCover(from source: URL, id: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            parsingQueue.async {
                guard let image = UIImage(contentsOfFile: source.path) else {
                    continuation.resume(returning: false)
                    return
                }
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
