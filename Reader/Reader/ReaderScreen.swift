import SwiftUI
import ReadiumShared
import ReadiumNavigator
import EPUBKit

/// 阅读页。根据设置里的引擎类型分派到两套实现，外面的工具栏、目录、外观面板共用。
struct ReaderScreen: View {

    let bookID: UUID
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var book: Book?
    @State private var loadError: String?

    var body: some View {
        ZStack {
            settings.appearance.theme.background.ignoresSafeArea()

            if let book {
                switch settings.engine {
                case .readium:
                    ReadiumReadingContainer(book: book, onClose: { dismiss() })
                case .epubkit:
                    WebReadingContainer(book: book, onClose: { dismiss() })
                }
            } else if let loadError {
                ReaderErrorView(message: loadError, onClose: { dismiss() })
            } else {
                ProgressView()
            }
        }
        .task {
            await load()
        }
        .preferredColorScheme(settings.appearance.theme == .dark ? .dark : .light)
    }

    private func load() async {
        guard book == nil, loadError == nil else { return }
        guard var found = library.book(id: bookID) else {
            loadError = "这本书已不在书库中"
            return
        }
        guard FileManager.default.fileExists(atPath: found.fileURL.path) else {
            loadError = "书籍文件丢失，可能已被清理"
            return
        }
        found.lastOpenedAt = Date()
        library.update(found)
        book = found
    }
}

// MARK: - Readium 版阅读容器

private struct ReadiumReadingContainer: View {

    let book: Book
    let onClose: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore

    @State private var engine = ReadiumEngine()
    @State private var publication: Publication?
    @State private var error: String?
    @State private var initialLocator: Locator?
    @State private var showChrome = true
    @State private var showTOC = false
    @State private var showAppearance = false
    @State private var toc: [TOCEntry] = []
    @State private var pendingLink: ReadiumShared.Link?
    @State private var progress: Double
    @State private var chapterTitle: String

    init(book: Book, onClose: @escaping () -> Void) {
        self.book = book
        self.onClose = onClose
        _progress = State(initialValue: book.progress)
        _chapterTitle = State(initialValue: book.title)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let publication {
                ReadiumReaderView(
                    publication: publication,
                    engine: engine,
                    appearance: settings.appearance,
                    initialLocator: initialLocator,
                    onLocationChange: { locator in
                        handleLocation(locator)
                    },
                    onCenterTap: { withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() } },
                    pendingLink: pendingLink
                )
                .ignoresSafeArea()
            } else if let error {
                ReaderErrorView(message: error, onClose: onClose)
            } else {
                ProgressView().tint(settings.appearance.theme.foreground)
            }

            if showChrome, publication != nil {
                ReaderChrome(
                    title: chapterTitle,
                    bookTitle: book.title,
                    progress: progress,
                    onBack: onClose,
                    onTOC: { showTOC = true },
                    onAppearance: { showAppearance = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            await open()
        }
        .sheet(isPresented: $showTOC) {
            TOCSheet(entries: toc, selectedID: nil) { entry in
                if let link = entry.link { pendingLink = link }
                showTOC = false
            }
        }
        .sheet(isPresented: $showAppearance) {
            AppearanceSheet(appearance: $settings.appearance)
        }
    }

    private func open() async {
        do {
            let opened = try await engine.open(book: book)
            toc = engine.tableOfContents(for: opened)
            initialLocator = engine.restoreLocator(for: book)
            publication = opened
        } catch {
            self.error = "Readium 引擎打不开这本书：\(error.localizedDescription)\n\n可以回到设置里切换为 EPUBKit 引擎再试。"
        }
    }

    private func handleLocation(_ locator: Locator) {
        if let total = locator.locations.totalProgression {
            progress = total
        }
        if let title = locator.title, !title.isEmpty {
            chapterTitle = title
        }
        // 节流保存在 MainActor 上直接写，量很小
        if var latest = library.book(id: book.id) {
            latest.progress = progress
            latest.readiumLocatorJSON = engine.encode(locator: locator)
            if progress >= 0.995 { latest.finishedAt = Date() }
            library.update(latest)
        }
    }
}

// MARK: - EPUBKit 版阅读容器

private struct WebReadingContainer: View {

    let book: Book
    let onClose: () -> Void
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore

    @State private var model: EPUBContentModel?
    @State private var error: String?
    @State private var showChrome = true
    @State private var showTOC = false
    @State private var showAppearance = false
    @State private var progress: Double
    @State private var chapterTitle: String
    @State private var chapterIndex: Int
    @State private var pageText: String = ""
    @State private var pendingHref: String?
    /// 打开时应该落在哪一章 / 章内哪个位置。只作为控制器的起点，之后由控制器自己维护。
    private let initialChapterIndex: Int
    private let initialRatio: Double
    /// 用于在切换外观时把新设置推给控制器
    @State private var appearanceToken = UUID()

    init(book: Book, onClose: @escaping () -> Void) {
        self.book = book
        self.onClose = onClose
        _progress = State(initialValue: book.progress)
        _chapterTitle = State(initialValue: book.title)
        _chapterIndex = State(initialValue: book.chapterIndex)
        initialChapterIndex = book.chapterIndex
        initialRatio = book.chapterProgression
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let model {
                WebReaderRepresentable(
                    model: model,
                    appearance: settings.appearance,
                    chapter: initialChapterIndex,
                    fragment: book.fragment,
                    ratio: initialRatio,
                    showChrome: showChrome,
                    onProgress: { chapter, ratio, page, pages in
                        handleProgress(chapter: chapter, ratio: ratio, page: page, pages: pages, model: model)
                    },
                    onCenterTap: { withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() } },
                    onExternalURL: { url in
                        UIApplication.shared.open(url)
                    },
                    pendingHref: pendingHref,
                    appearanceToken: appearanceToken
                )
                .ignoresSafeArea()
            } else if let error {
                ReaderErrorView(message: error, onClose: onClose)
            } else {
                ProgressView().tint(settings.appearance.theme.foreground)
            }

            if showChrome, model != nil {
                ReaderChrome(
                    title: chapterTitle,
                    bookTitle: book.title,
                    progress: progress,
                    pageText: pageText,
                    onBack: onClose,
                    onTOC: { showTOC = true },
                    onAppearance: { showAppearance = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task { load() }
        .onChange(of: settings.appearance) { _ in
            appearanceToken = UUID()
        }
        .sheet(isPresented: $showTOC) {
            TOCSheet(entries: model?.tocEntries ?? [], selectedID: nil) { entry in
                pendingHref = entry.href
                showTOC = false
            }
        }
        .sheet(isPresented: $showAppearance) {
            AppearanceSheet(appearance: $settings.appearance)
        }
    }

    private func load() {
        guard model == nil else { return }
        // 优先用导入时缓存好的解压目录，其次把 epub 重新解压
        let extracted = FileManager.extractedURL.appendingPathComponent(book.id.uuidString)
        if FileManager.default.fileExists(atPath: extracted.appendingPathComponent("META-INF/container.xml").path),
           let cached = EPUBContentModel(directory: extracted) {
            model = cached
            chapterTitle = cached.chapters[safe: book.chapterIndex]?.title ?? book.title
            return
        }
        if let fresh = EPUBContentModel(directory: book.fileURL) {
            model = fresh
            chapterTitle = fresh.chapters[safe: book.chapterIndex]?.title ?? book.title
        } else {
            error = "EPUBKit 解析失败。这本书可能使用了加密或非标准的 EPUB 结构，建议切换到 Readium 引擎。"
        }
    }

    private func handleProgress(chapter: Int, ratio: Double, page: Int, pages: Int, model: EPUBContentModel) {
        chapterIndex = chapter
        let total = Double(model.chapters.count)
        progress = total > 0 ? (Double(chapter) + ratio) / total : 0
        chapterTitle = model.chapters[safe: chapter]?.title ?? book.title
        pageText = pages > 1 ? "\(page)/\(pages)" : ""

        if var latest = library.book(id: book.id) {
            latest.progress = progress
            latest.chapterIndex = chapter
            latest.chapterProgression = ratio
            latest.lastPage = page
            latest.totalPages = pages
            if progress >= 0.995 { latest.finishedAt = Date() }
            library.update(latest)
        }
    }
}

// MARK: - 通用 UI 组件

/// 阅读器顶部/底部工具栏
struct ReaderChrome: View {
    let title: String
    let bookTitle: String
    let progress: Double
    var pageText: String = ""
    let onBack: () -> Void
    let onTOC: () -> Void
    let onAppearance: () -> Void

    @EnvironmentObject private var settings: SettingsStore

    private var foreground: SwiftUI.Color { settings.appearance.theme.foreground }
    private var backgroundColor: SwiftUI.Color { settings.appearance.theme.background }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                Spacer()
                VStack(spacing: 2) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(bookTitle)
                        .font(.caption2)
                        .opacity(0.55)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onAppearance) {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, 8)
            .foregroundStyle(foreground)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                HStack {
                    Button(action: onTOC) {
                        Label("目录", systemImage: "list.bullet")
                            .font(.footnote)
                    }
                    Spacer()
                    Text(pageText.isEmpty ? "\(Int(progress * 100))%" : "\(pageText) · \(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .opacity(0.6)
                }
                .foregroundStyle(foreground)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(foreground.opacity(0.12))
                        Capsule()
                            .fill(foreground.opacity(0.55))
                            .frame(width: max(4, geo.size.width * progress))
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .padding(.top, 6)
        .background(
            LinearGradient(
                colors: [backgroundColor.opacity(0.97), backgroundColor.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(foreground.opacity(0.10))
                .frame(height: 0.5)
        }
    }
}

struct ReaderErrorView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.closed")
                .font(.system(size: 40))
                .opacity(0.35)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .opacity(0.75)
            Button("返回书架", action: onClose)
                .buttonStyle(.borderedProminent)
        }
        .padding(36)
    }
}

/// 目录面板
struct TOCSheet: View {
    let entries: [TOCEntry]
    let selectedID: String?
    let onSelect: (TOCEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    Text("这本书没有提供目录")
                        .foregroundStyle(.secondary)
                } else {
                    List(entries) { entry in
                        Button {
                            onSelect(entry)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                if entry.level > 0 {
                                    Rectangle()
                                        .fill(.clear)
                                        .frame(width: CGFloat(entry.level) * 12)
                                }
                                Text(entry.title)
                                    .font(entry.level == 0 ? .body : .callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                if entry.id == selectedID {
                                    Image(systemName: "smallcircle.filled.circle")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// 外观设置面板：字号、行距、主题、字体、边距、翻页方式
struct AppearanceSheet: View {
    @Binding var appearance: AppearanceSettings

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AppearanceSheetContent(appearance: $appearance)
                .navigationTitle("阅读设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 外观设置的具体表单。阅读器弹窗与设置页共用。
struct AppearanceSheetContent: View {
    @Binding var appearance: AppearanceSettings

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("主题") {
                Picker("主题", selection: $appearance.theme) {
                    ForEach(AppearanceSettings.ThemeKind.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("字号与排版") {
                Stepper(value: $appearance.fontSize, in: 12...32, step: 1) {
                    HStack {
                        Text("字号")
                        Spacer()
                        Text("\(Int(appearance.fontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("行距")
                        Spacer()
                        Text(String(format: "%.2f", appearance.lineHeight))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $appearance.lineHeight, in: 1.2...2.4, step: 0.05)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("段间距")
                        Spacer()
                        Text(String(format: "%.2f em", appearance.paragraphSpacing))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $appearance.paragraphSpacing, in: 0...1.5, step: 0.05)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("页边距")
                        Spacer()
                        Text("\(Int(appearance.pageMargin * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $appearance.pageMargin, in: 0.02...0.18, step: 0.01)
                }
            }

            Section("字体") {
                Picker("字体", selection: $appearance.fontFamily) {
                    ForEach(AppearanceSettings.fontChoices, id: \.name) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .pickerStyle(.navigationLink)
            }

            Section {
                Toggle("使用书籍自带排版", isOn: $appearance.publisherStyles)
                Toggle("两端对齐", isOn: $appearance.justify)
                Toggle("滚动阅读（不分页）", isOn: $appearance.isScrolling)
            } header: {
                Text("排版选项")
            } footer: {
                Text("关闭「自带排版」后，字体、字号、行距才会完全生效。固定版式 EPUB 不受这些设置影响。")
            }

            Section {
                Picker("阅读引擎", selection: $settings.engine) {
                    ForEach(ReaderEngineKind.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                Text(settings.engine.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("引擎")
            } footer: {
                Text("切换引擎后重新打开本书生效。进度按引擎分别保存。")
            }
        }
    }
}

// MARK: - 工具

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
