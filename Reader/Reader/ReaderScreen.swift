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
                .transition(.opacity)
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
            toc = await engine.tableOfContents(for: opened)
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
                .transition(.opacity)
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

/// 阅读器顶部/底部工具栏，改成悬浮的液态玻璃胶囊，正文会从玻璃后面透出来。
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

    private var progressText: String {
        pageText.isEmpty ? "\(Int(progress * 100))%" : "\(pageText) · \(Int(progress * 100))%"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                GlassIconButton(systemImage: "chevron.left", action: onBack)

                VStack(spacing: 1) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(bookTitle)
                        .font(.caption2)
                        .opacity(0.55)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .liquidGlassCapsule(elevation: .medium)

                GlassIconButton(systemImage: "textformat.size", action: onAppearance)
            }
            .padding(.horizontal, 14)

            Spacer(minLength: 0)

            VStack(spacing: 9) {
                HStack(spacing: 12) {
                    Button(action: onTOC) {
                        HStack(spacing: 5) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 12, weight: .semibold))
                            Text("目录")
                                .font(.footnote.weight(.medium))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Text(progressText)
                        .font(.caption.monospacedDigit())
                        .opacity(0.65)
                }

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
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .liquidGlass(cornerRadius: 26, elevation: .high)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
        .padding(.top, 4)
        .foregroundStyle(foreground)
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
            ZStack {
                GlassBackdrop(theme: settings.appearance.theme, animated: false)

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
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 7, leading: 18, bottom: 7, trailing: 18))
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
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
        .glassSheetBackground()
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
        .glassSheetBackground()
    }
}

/// 外观设置的具体表单。阅读器弹窗与设置页共用，统一使用玻璃卡片。
struct AppearanceSheetContent: View {
    @Binding var appearance: AppearanceSettings

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ZStack {
            GlassBackdrop(theme: appearance.theme, animated: false)

            ScrollView {
                VStack(spacing: 22) {
                    themeSection
                    typographySection
                    fontSection
                    optionsSection
                    engineSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var themeSection: some View {
        GlassSection("主题") {
            GlassRow(showsDivider: false) {
                Picker("主题", selection: $appearance.theme) {
                    ForEach(AppearanceSettings.ThemeKind.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var typographySection: some View {
        GlassSection("字号与排版") {
            GlassRow {
                Stepper(value: $appearance.fontSize, in: 12...32, step: 1) {
                    HStack {
                        Text("字号")
                            .font(.system(size: 15))
                        Spacer()
                        Text("\(Int(appearance.fontSize)) pt")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            sliderRow(
                title: "行距",
                value: $appearance.lineHeight,
                range: 1.2...2.4,
                step: 0.05,
                text: String(format: "%.2f", appearance.lineHeight)
            )

            sliderRow(
                title: "段间距",
                value: $appearance.paragraphSpacing,
                range: 0...1.5,
                step: 0.05,
                text: String(format: "%.2f em", appearance.paragraphSpacing),
                showsDivider: false
            )

            GlassRow {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("页边距")
                            .font(.system(size: 15))
                        Spacer()
                        Text("\(Int(appearance.pageMargin * 100))%")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $appearance.pageMargin, in: 0.02...0.18, step: 0.01)
                }
            }
        }
    }

    private var fontSection: some View {
        GlassSection("字体") {
            GlassRow(showsDivider: false) {
                HStack(spacing: 8) {
                    Text("字体")
                        .font(.system(size: 15))
                    Spacer(minLength: 0)
                    Picker("字体", selection: $appearance.fontFamily) {
                        ForEach(AppearanceSettings.fontChoices.indices, id: \.self) { index in
                            let choice = AppearanceSettings.fontChoices[index]
                            Text(choice.name).tag(choice.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
        }
    }

    private var optionsSection: some View {
        GlassSection(
            "排版选项",
            footer: "关闭「自带排版」后，字体、字号、行距才会完全生效。固定版式 EPUB 不受这些设置影响。"
        ) {
            GlassRow {
                Toggle("使用书籍自带排版", isOn: $appearance.publisherStyles)
                    .font(.system(size: 15))
                    .tint(.accentColor)
            }
            GlassRow {
                Toggle("两端对齐", isOn: $appearance.justify)
                    .font(.system(size: 15))
                    .tint(.accentColor)
            }
            GlassRow(showsDivider: false) {
                Toggle("滚动阅读（不分页）", isOn: $appearance.isScrolling)
                    .font(.system(size: 15))
                    .tint(.accentColor)
            }
        }
    }

    private var engineSection: some View {
        GlassSection(
            "引擎",
            footer: "切换引擎后重新打开本书生效。进度按引擎分别保存。"
        ) {
            GlassRow {
                HStack(spacing: 8) {
                    Text("阅读引擎")
                        .font(.system(size: 15))
                    Spacer(minLength: 0)
                    Picker("阅读引擎", selection: $settings.engine) {
                        ForEach(ReaderEngineKind.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            GlassRow(showsDivider: false) {
                Text(settings.engine.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        text: String,
        showsDivider: Bool = true
    ) -> some View {
        GlassRow(showsDivider: showsDivider) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.system(size: 15))
                    Spacer()
                    Text(text)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: value, in: range, step: step)
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
