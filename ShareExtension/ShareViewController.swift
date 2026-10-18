import UIKit
import UniformTypeIdentifiers

/// 分享扩展：在「文件」「Safari」「微信」等任意 App 里，
/// 对 epub 文件选「分享 → 导入到墨读」，即可进书库。
///
/// 职责边界（很重要）：
/// 扩展**只做一件事**——把用户分享的文件安全地复制进 App Group 共享容器的 Inbox 目录。
/// 解析 EPUB、去重、生成封面、写入索引全部由主 App 在回到前台时完成。
///
/// 为什么不在这里解析：扩展进程内存上限很小（通常 120MB），
/// 且随时可能被系统杀掉。如果把「解析 + 写索引」放在扩展里做一半被终止，
/// 书库就会出现有记录没文件、或有文件没记录的脏数据。
///
/// UI 用 UIKit 手写，不引 SwiftUI：扩展冷启动更快，包体更小。
final class ShareViewController: UIViewController {

    private let card = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let doneButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        Task { await receive() }
    }

    // MARK: - UI

    private func buildUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.18)

        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        iconView.image = UIImage(systemName: "book.closed")
        iconView.tintColor = .label
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)

        titleLabel.text = "正在加入书架"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        detailLabel.text = "读取文件中…"
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        spinner.startAnimating()

        doneButton.setTitle("完成", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        doneButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        doneButton.isHidden = true

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, detailLabel, spinner, doneButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 296),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),

            iconView.heightAnchor.constraint(equalToConstant: 34),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: - 接收

    private func receive() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        guard !providers.isEmpty else {
            finish(with: .failure("没有收到文件"))
            return
        }
        guard InboxStore.containerURL != nil else {
            finish(with: .failure("无法访问共享空间\n请检查 App Group 配置"))
            return
        }

        var saved = 0
        var skipped = 0

        for provider in providers {
            do {
                let destination = try await copy(from: provider)
                if InboxStore.isLikelyEPUB(destination) {
                    saved += 1
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    skipped += 1
                }
            } catch {
                skipped += 1
            }
        }

        if saved > 0 {
            InboxStore.markPendingImport(count: saved)
            finish(with: .success(saved, skipped: skipped))
        } else {
            finish(with: .failure("没有可导入的 EPUB 文件"))
        }
    }

    /// 从 NSItemProvider 取文件并复制进 Inbox。
    private func copy(from provider: NSItemProvider) async throws -> URL {
        let typeID = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .epub) == true
        } ?? provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .data) == true
        }
        guard let typeID else { throw ShareExtensionError.unsupported }

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                // 兜底：某些来源（例如网页里的下载链接）只给 in-place 文件
                guard let url else {
                    if provider.hasItemConformingToTypeIdentifier(typeID) {
                        provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, itemError in
                            if let itemError {
                                continuation.resume(throwing: itemError)
                            } else if let data = item as? Data {
                                do {
                                    let destination = try InboxStore.write(data: data, preferredName: provider.suggestedName)
                                    continuation.resume(returning: destination)
                                } catch {
                                    continuation.resume(throwing: error)
                                }
                            } else {
                                continuation.resume(throwing: ShareExtensionError.unreadable)
                            }
                        }
                    } else {
                        continuation.resume(throwing: ShareExtensionError.unreadable)
                    }
                    return
                }
                // 这个临时 URL 在闭包返回后立即失效，必须同步复制
                do {
                    let destination = try InboxStore.copy(from: url, preferredName: provider.suggestedName)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 收尾

    private enum Outcome {
        case success(Int, skipped: Int)
        case failure(String)
    }

    private func finish(with outcome: Outcome) {
        spinner.stopAnimating()
        switch outcome {
        case .success(let count, let skipped):
            iconView.image = UIImage(systemName: "checkmark.circle.fill")
            iconView.tintColor = .systemGreen
            titleLabel.text = "已加入书架"
            detailLabel.text = skipped > 0
                ? "共 \(count) 本，已跳过 \(skipped) 个不支持的文件\n打开「墨读」即可阅读"
                : "打开「墨读」即可阅读"
            // 让用户看到成功状态，再自动关闭；点「完成」可立即关闭
            doneButton.isHidden = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.close()
            }
        case .failure(let message):
            iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
            iconView.tintColor = .systemOrange
            titleLabel.text = "没能导入"
            detailLabel.text = message
            doneButton.isHidden = false
        }
    }

    @objc private func close() {
        guard let context = extensionContext else { return }
        // 有编辑器时用它提交附件，否则直接结束请求
        context.completeRequest(returningItems: [], completionHandler: nil)
    }
}

// MARK: - 共享常量

/// 主 App 与扩展必须保持一致
enum AppGroup {
    static let identifier = "group.com.example.reader"
}

enum ShareExtensionError: LocalizedError {
    case unsupported
    case unreadable
    case storageUnavailable
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: return "不支持这种文件类型"
        case .unreadable: return "读取文件失败"
        case .storageUnavailable: return "无法访问共享空间"
        case .copyFailed: return "复制失败，可能是存储空间不足"
        }
    }
}

/// Inbox 读写。目录结构与主 App 的 `FileManager.inboxURL` 完全一致。
enum InboxStore {

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
    }

    static var libraryURL: URL {
        (containerURL ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Library", isDirectory: true)
    }

    static var inboxURL: URL {
        let url = libraryURL.appendingPathComponent("Inbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// 把文件复制进 Inbox。命名规则与主 App 的 ImportService.stage 一致：
    /// `<uuid>-<原始文件名>.epub`
    static func copy(from source: URL, preferredName: String?) throws -> URL {
        guard containerURL != nil else { throw ShareExtensionError.storageUnavailable }

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let name = sanitize(preferredName ?? source.lastPathComponent)
        let destination = inboxURL.appendingPathComponent("\(UUID().uuidString)-\(name)")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw ShareExtensionError.copyFailed
        }
        return destination
    }

    static func write(data: Data, preferredName: String?) throws -> URL {
        guard containerURL != nil else { throw ShareExtensionError.storageUnavailable }
        guard !data.isEmpty else { throw ShareExtensionError.unreadable }
        let name = sanitize(preferredName ?? "book.epub")
        let destination = inboxURL.appendingPathComponent("\(UUID().uuidString)-\(name)")
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ShareExtensionError.copyFailed
        }
        return destination
    }

    /// 文件名清洗：去掉路径分隔符与非法字符，统一补上 .epub 后缀。
    private static func sanitize(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        name = name.components(separatedBy: illegal).joined(separator: "-")
        if name.isEmpty { name = "book" }
        if !name.lowercased().hasSuffix(".epub") {
            name = (name as NSString).deletingPathExtension + ".epub"
        }
        // 防止超长文件名
        if name.count > 120 {
            let base = (name as NSString).deletingPathExtension
            name = String(base.prefix(110)) + ".epub"
        }
        return name
    }

    /// 轻量校验：EPUB 本质是 ZIP，开头必须是 "PK\x03\x04"。
    static func isLikelyEPUB(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let header = handle.readData(ofLength: 4)
        guard header.count == 4 else { return false }
        // "PK\x03\x04"
        return header[0] == 0x50 && header[1] == 0x4B
    }

    static func markPendingImport(count: Int) {
        let defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        let key = "reader.pendingImportCount"
        defaults.set(defaults.integer(forKey: key) + count, forKey: key)
    }
}
