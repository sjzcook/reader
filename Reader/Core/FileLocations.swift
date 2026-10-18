import Foundation

extension FileManager {

    /// App 与 Share Extension 共享的容器目录。
    /// 两者必须在 Xcode 中配置同一个 App Group，否则扩展写进去的文件主 App 看不到。
    static let appGroupIdentifier = "group.com.example.reader"

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

    /// 解压后的书籍：`<container>/Library/Extracted/<id>/`
    static var extractedURL: URL {
        ensure(containerURL.appendingPathComponent("Library/Extracted", isDirectory: true))
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
        _ = extractedURL
        _ = coversURL
        _ = inboxURL
    }
}
