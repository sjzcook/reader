import Foundation
import Combine
import SwiftUI

/// 书库：负责持久化（JSON 索引）与增删改查。
/// 用 `ObservableObject` 而不是 SwiftData，是为了让 Share Extension 能够
/// 直接写同一个索引文件，不必依赖主 App 的数据库容器。
@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var books: [Book] = []
    @Published var lastError: String?

    private let queue = DispatchQueue(label: "com.example.reader.library", qos: .userInitiated)

    init() {
        load()
    }

    // MARK: - 读取

    func load() {
        guard let data = try? Data(contentsOf: FileManager.libraryIndexURL) else {
            books = []
            return
        }
        do {
            books = try JSONDecoder.library.decode([Book].self, from: data)
        } catch {
            // 索引损坏时不让 App 崩掉，只清空列表并把原文件备份走。
            let backup = FileManager.libraryIndexURL.appendingPathExtension("corrupted")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: FileManager.libraryIndexURL, to: backup)
            books = []
            lastError = "书库索引损坏，已重置。"
        }
    }

    func reloadFromDisk() {
        load()
    }

    func book(id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    // MARK: - 写入

    func add(_ book: Book) {
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index] = book
        } else {
            books.insert(book, at: 0)
        }
        save()
    }

    func update(_ book: Book) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
        save()
    }

    func remove(_ book: Book) {
        books.removeAll { $0.id == book.id }
        try? FileManager.default.removeItem(at: book.fileURL)
        try? FileManager.default.removeItem(at: FileManager.coversURL.appendingPathComponent("\(book.id.uuidString).jpg"))
        save()
    }

    /// 书籍是否已经在书库中（用 identifier 或文件名判断，避免重复导入）。
    func contains(identifier: String?, fileName: String?) -> Bool {
        books.contains { book in
            if let identifier, !identifier.isEmpty, book.identifier == identifier { return true }
            if let fileName, book.fileName == fileName { return true }
            return false
        }
    }

    private func save() {
        let snapshot = books
        let url = FileManager.libraryIndexURL
        queue.async {
            do {
                let data = try JSONEncoder.library.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                DebugLog.error("保存书库失败: \(error)")
            }
        }
    }
}

// MARK: - 编解码约定

extension JSONDecoder {
    static var library: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var library: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

enum DebugLog {
    static func error(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[Reader] ❌", message())
        #endif
    }

    static func info(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[Reader] ℹ️", message())
        #endif
    }
}
