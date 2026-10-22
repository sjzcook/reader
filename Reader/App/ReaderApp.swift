import SwiftUI

@main
struct ReaderApp: App {

    @StateObject private var settings: SettingsStore
    @StateObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 两个 Store 的初始化会读写 App Group 目录，先把目录建好
        FileManager.prepareContainer()
        _settings = StateObject(wrappedValue: SettingsStore())
        _library = StateObject(wrappedValue: LibraryStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .task {
                    // 消化分享扩展留在 Inbox 里的文件
                    await LibraryIngest.drainInbox(into: library)
                }
                .onOpenURL { url in
                    handleIncoming(url)
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    if SettingsStore.consumePendingImports() > 0 {
                        library.reloadFromDisk()
                    }
                    Task { await LibraryIngest.drainInbox(into: library) }
                }
        }
    }

    // MARK: - 外部打开

    private func handleIncoming(_ url: URL) {
        // modu://import?path=<percent-encoded file URL>
        if url.scheme?.lowercased() == "modu" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let value = components?.queryItems?.first(where: { $0.name == "path" })?.value,
               let fileURL = URL(string: value) {
                stageThenImport(fileURL)
            }
            return
        }

        // 系统「用其他应用打开」递过来的文件
        if url.isFileURL, url.pathExtension.lowercased() == "epub" {
            stageThenImport(url)
        }
    }

    /// 外部文件 URL 的授权只在回调期间有效，先同步复制到 Inbox，再慢慢入库。
    private func stageThenImport(_ fileURL: URL) {
        do {
            let staged = try ImportService.shared.stage(fileURL)
            Task { await importExternal(staged) }
        } catch {
            library.lastError = error.localizedDescription
        }
    }

    private func importExternal(_ stagedURL: URL) async {
        do {
            let result = try await ImportService.shared.importStagedFile(at: stagedURL, into: library)
            if result.wasDuplicate {
                DebugLog.info("书库中已有：\(result.book.title)")
            } else if settings.openAfterImport {
                library.autoOpenBookID = result.book.id
            }
        } catch {
            library.lastError = error.localizedDescription
        }
    }
}

/// 把分享扩展写进 Inbox 的文件导入书库。
@MainActor
enum LibraryIngest {

    static func drainInbox(into library: LibraryStore) async {
        let inbox = FileManager.inboxURL
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        let candidates = files.filter { $0.pathExtension.lowercased() == "epub" }
        guard !candidates.isEmpty else { return }

        for file in candidates {
            do {
                _ = try await ImportService.shared.importStagedFile(at: file, into: library)
            } catch {
                DebugLog.error("Inbox 导入失败 \(file.lastPathComponent)：\(error.localizedDescription)")
                // 保留文件便于用户排查，但超过 7 天的清掉，避免无限堆积
                if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let date = values.contentModificationDate,
                   Date().timeIntervalSince(date) > 7 * 86_400 {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        SettingsStore.consumePendingImports()
    }
}

/// 根视图：集中处理导入失败提示
struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        LibraryScreen()
            // 界面配色跟随阅读主题，玻璃与文字才能保持一致的对比度
            .preferredColorScheme(settings.appearance.theme == .dark ? .dark : .light)
            .alert(
                "导入失败",
                isPresented: Binding(
                    get: { library.lastError != nil },
                    set: { if !$0 { library.lastError = nil } }
                )
            ) {
                Button("好", role: .cancel) { library.lastError = nil }
            } message: {
                Text(library.lastError ?? "")
            }
    }
}
