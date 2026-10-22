import Foundation

extension FileManager {

    /// App 与 Share Extension 共享的容器目录。
    /// 两者必须在 Xcode 中配置同一个 App Group，否则扩展写进去的文件主 App 看不到。
    static let appGroupIdentifier = "group.com.sjzcook.modureader"

    /// 共享容器根目录；未配置 App Group 时回退到 App 沙盒的 Documents。
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return url
        }
        return documentsURL
    }

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 书籍原始文件：`<container>/Library/Books/<id>.epub`
    static var booksURL: URL {
        ensure(containerURL.appendingPathComponent("Library/Books", isDirectory: true))
    }

    /// 封面缓存：`<container>/Library/Covers/<id>.jpg`
    static var coversURL: URL {
        ensure(containerURL.appendingPathComponent("Library/Covers", isDirectory: true))
    }

    /// 导入暂存：`<container>/Library/Inbox/`
    static var inboxURL: URL {
        ensure(containerURL.appendingPathComponent("Library/Inbox", isDirectory: true))
    }

    /// 书库索引文件。
    static var libraryIndexURL: URL {
        ensure(containerURL.appendingPathComponent("Library", isDirectory: true))
            .appendingPathComponent("library.json")
    }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// 启动时先把所有目录建好，避免各 Store 初始化时互相等待。
    static func prepareContainer() {
        _ = libraryIndexURL
        _ = booksURL
        _ = coversURL
        _ = inboxURL
        removeLegacyExtractedBooks()
    }

    /// 旧版本为了自研引擎会把 EPUB 解压一份到 `Library/Extracted/`，
    /// 现在阅读统一走 Readium，直接用原始 epub，这份缓存启动时清掉回收空间。
    static func removeLegacyExtractedBooks() {
        let legacy = containerURL.appendingPathComponent("Library/Extracted", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.removeItem(at: legacy)
        DebugLog.info("已清理旧版解压缓存")
    }
}
