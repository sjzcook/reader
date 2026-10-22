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
        // 先做迁移，再建目录，否则空目录会挡住「旧数据是否存在」的判断
        migrateLegacyLibraryIfNeeded()
        _ = libraryIndexURL
        _ = booksURL
        _ = coversURL
        _ = inboxURL
        removeLegacyExtractedBooks()
    }

    /// App Group 是否可用（未签名 / 自签名重签的包通常拿不到）。
    /// 拿不到时书库会退到沙盒 Documents，App 自己照常能用，
    /// 只有分享扩展没法把文件递过来。
    static var isSharedContainerAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil
    }

    /// 把「无 App Group 时期」写在沙盒 Documents 里的书库搬进共享容器。
    ///
    /// 场景：先用未签名包装了一批书（落在 Documents），后来换成了带 App Group
    /// 的正式签名，容器路径变了，不迁移的话书架会突然变空。
    /// 只做复制，不删原件，出问题还能回退。
    static func migrateLegacyLibraryIfNeeded() {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return
        }
        let fm = FileManager.default
        let legacy = documentsURL.appendingPathComponent("Library", isDirectory: true)
        let target = group.appendingPathComponent("Library", isDirectory: true)

        guard fm.fileExists(atPath: legacy.appendingPathComponent("library.json").path),
              !fm.fileExists(atPath: target.appendingPathComponent("library.json").path)
        else { return }

        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            let destination = target.appendingPathComponent(item.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.copyItem(at: item, to: destination)
        }
        DebugLog.info("已把沙盒书库迁移到共享容器：\(items.count) 项")
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
