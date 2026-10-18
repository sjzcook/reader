import Foundation
import Combine
import SwiftUI

/// 全局设置的持久化封装。刻意使用 UserDefaults 而不是 @AppStorage，
/// 这样同一个 key 可以被多个视图共享，也方便在启动时统一读写。
@MainActor
final class SettingsStore: ObservableObject {

    @Published var engine: ReaderEngineKind {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    @Published var appearance: AppearanceSettings {
        didSet { saveAppearance() }
    }

    /// 导入后是否自动打开
    @Published var openAfterImport: Bool {
        didSet { defaults.set(openAfterImport, forKey: Keys.openAfterImport) }
    }

    /// 分享扩展导入成功时是否震动/提示（扩展内无法控制，这里用于主 App 提示）
    @Published var showImportToast: Bool {
        didSet { defaults.set(showImportToast, forKey: Keys.showToast) }
    }

    private let defaults: UserDefaults
    /// App Group 内共享的 UserDefaults，扩展与主 App 都要能读到引擎设置。
    private let sharedDefaults: UserDefaults?

    private enum Keys {
        static let engine = "reader.engine"
        static let appearance = "reader.appearance"
        static let openAfterImport = "reader.openAfterImport"
        static let showToast = "reader.showImportToast"
        static let pendingImportCount = "reader.pendingImportCount"
    }

    init() {
        sharedDefaults = UserDefaults(suiteName: FileManager.appGroupIdentifier)
        let store = sharedDefaults ?? .standard
        defaults = store

        let raw = store.string(forKey: Keys.engine) ?? ReaderEngineKind.readium.rawValue
        engine = ReaderEngineKind(rawValue: raw) ?? .readium

        if let data = store.data(forKey: Keys.appearance),
           let decoded = try? JSONDecoder().decode(AppearanceSettings.self, from: data) {
            appearance = decoded
        } else {
            appearance = .default
        }

        openAfterImport = store.object(forKey: Keys.openAfterImport) as? Bool ?? true
        showImportToast = store.object(forKey: Keys.showToast) as? Bool ?? true
    }

    private func saveAppearance() {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        defaults.set(data, forKey: Keys.appearance)
    }

    // MARK: - 分享扩展的交接

    /// 分享扩展每成功导入一本，计数 +1；主 App 回到前台后据此刷新书库。
    static func markPendingImport() {
        let store = UserDefaults(suiteName: FileManager.appGroupIdentifier) ?? .standard
        let count = store.integer(forKey: Keys.pendingImportCount)
        store.set(count + 1, forKey: Keys.pendingImportCount)
    }

    /// 取出并清零待处理计数。
    static func consumePendingImports() -> Int {
        let store = UserDefaults(suiteName: FileManager.appGroupIdentifier) ?? .standard
        let count = store.integer(forKey: Keys.pendingImportCount)
        if count > 0 { store.set(0, forKey: Keys.pendingImportCount) }
        return count
    }
}
