import SwiftUI
import UniformTypeIdentifiers

/// 书架首页。
struct LibraryScreen: View {

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var searchText = ""
    @State private var sort: SortOption = .recent
    @State private var isGrid = true
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var openedBook: Book?
    @State private var toast: String?
    @State private var isImporting = false
    @State private var pendingDelete: Book?

    enum SortOption: String, CaseIterable, Identifiable {
        case recent = "最近阅读"
        case added = "添加时间"
        case title = "书名"
        case author = "作者"
        var id: String { rawValue }
    }

    private var filteredBooks: [Book] {
        var result = library.books
        if !searchText.trimmed.isEmpty {
            let key = searchText.trimmed.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(key)
                || $0.author.lowercased().contains(key)
                || $0.publisher.lowercased().contains(key)
            }
        }
        switch sort {
        case .recent:
            result.sort { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        case .added:
            result.sort { $0.addedAt > $1.addedAt }
        case .title:
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            result.sort { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PageBackground()

                if filteredBooks.isEmpty {
                    EmptyLibraryView(isSearching: !searchText.trimmed.isEmpty) {
                        showImporter = true
                    }
                } else if isGrid {
                    gridContent
                } else {
                    listContent
                }

                if isImporting {
                    ImportOverlay()
                }
            }
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "搜索书名、作者")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("排序", selection: $sort) {
                            ForEach(SortOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        Divider()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { isGrid.toggle() }
                        } label: {
                            Label(isGrid ? "列表视图" : "网格视图",
                                  systemImage: isGrid ? "list.bullet" : "square.grid.2x2")
                        }
                    } label: {
                        glassBarIcon("ellipsis")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        glassBarIcon("plus")
                    }
                    Button {
                        showSettings = true
                    } label: {
                        glassBarIcon("gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsScreen()
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.epub],
                allowsMultipleSelection: true
            ) { result in
                handlePicked(result)
            }
            .fullScreenCover(item: $openedBook) { book in
                ReaderScreen(bookID: book.id)
                    .environmentObject(library)
                    .environmentObject(settings)
            }
            .confirmationDialog(
                "删除《\(pendingDelete?.title ?? "")》？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let book = pendingDelete { library.remove(book) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("文件与阅读进度都会一并删除，此操作无法撤销。")
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    ToastView(text: toast)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toast)
            .task {
                // 从分享扩展回来时刷新并提示
                let pending = SettingsStore.consumePendingImports()
                if pending > 0 {
                    library.reloadFromDisk()
                    flash("已从分享导入 \(pending) 本书")
                }
            }
        }
    }

    // MARK: - 内容

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104, maximum: 132), spacing: 22)],
                spacing: 26
            ) {
                ForEach(filteredBooks) { book in
                    BookCard(book: book)
                        .onTapGesture { openedBook = book }
                        .contextMenu {
                            Button {
                                openedBook = book
                            } label: {
                                Label("开始阅读", systemImage: "book")
                            }
                            Button {
                                pendingDelete = book
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
    }

    private var listContent: some View {
        List {
            ForEach(filteredBooks) { book in
                Button {
                    openedBook = book
                } label: {
                    BookRow(book: book)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .swipeActions {
                    Button(role: .destructive) {
                        pendingDelete = book
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 导入

    private func handlePicked(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            // 用常驻弹窗而不是 toast：早前用 2 秒 toast，报错一闪而过，
            // 用户只会觉得「选了文件没反应」。
            library.lastError = "选择文件失败：\(error.localizedDescription)"
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task { await importAll(urls, using: ImportService.shared) }
        }
    }

    @MainActor
    private func importAll(_ urls: [URL], using service: ImportService) async {
        isImporting = true
        var success = 0
        var duplicates = 0
        var failures: [String] = []
        var lastImported: Book?

        for url in urls {
            do {
                let result = try await service.importFromPicker(url: url, into: library)
                if result.wasDuplicate { duplicates += 1 } else { success += 1; lastImported = result.book }
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        isImporting = false

        if success > 0 {
            flash(duplicates > 0 ? "导入 \(success) 本，跳过 \(duplicates) 本重复" : "已导入 \(success) 本书")
        } else if duplicates > 0 {
            flash("这些书已在书库中")
        }
        if !failures.isEmpty {
            library.lastError = failures.count == 1
                ? failures[0]
                : "有 \(failures.count) 本书没能导入：\n" + failures.joined(separator: "\n")
        }
        if settings.openAfterImport, let book = lastImported, urls.count == 1, failures.isEmpty {
            // 文件选择器还在做消失动画时立刻 present 全屏视图会被系统丢掉，
            // 表现就是「选完文件什么都没发生」，等一帧再打开。
            try? await Task.sleep(nanoseconds: 400_000_000)
            openedBook = book
        }
    }

    private func flash(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == text { toast = nil }
        }
    }

    /// 导航栏图标。iOS 26 由系统玻璃承载，低版本自己套一层玻璃圆。
    @ViewBuilder
    private func glassBarIcon(_ name: String) -> some View {
        if #available(iOS 26.0, *) {
            Image(systemName: name)
        } else {
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .liquidGlassCircle(elevation: .low)
        }
    }
}

// MARK: - 背景

struct PageBackground: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        GlassBackdrop(theme: settings.appearance.theme)
    }
}

// MARK: - 书籍卡片

struct BookCard: View {
    let book: Book
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCover(book: book)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if book.progress > 0.001 {
                        ProgressBadge(text: book.readingProgressText, finished: book.progress >= 0.995)
                            .padding(6)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(settings.appearance.theme.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(book.author)
                    .font(.system(size: 11))
                    .foregroundStyle(settings.appearance.theme.foreground.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(9)
        .liquidGlass(cornerRadius: 22, elevation: .low, interactive: true, blendsBackdrop: false)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct BookCover: View {
    let book: Book

    var body: some View {
        ZStack {
            if let url = book.coverURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                GeneratedCover(title: book.title, author: book.author)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 5)
    }
}

/// 没有封面时，用书名生成一个稳定的渐变封面。
struct GeneratedCover: View {
    let title: String
    let author: String

    private var palette: [Color] {
        let palettes: [[UInt32]] = [
            [0x2E4057, 0x4A6C8C], [0x6B4226, 0x9C6B45], [0x354F52, 0x52796F],
            [0x3D314A, 0x6B5B7B], [0x7A3B2E, 0xB5654A], [0x1F3A5F, 0x2E5C8A],
            [0x4A3B32, 0x7D6455], [0x2C4A3B, 0x4F7A5E],
        ]
        let index = abs(title.hashValue) % palettes.count
        return palettes[index].map { Color(hex: $0) }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                // 书脊高光
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0.02), .black.opacity(0.12)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: geo.size.width * 0.13)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: max(11, geo.size.width * 0.115), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(5)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Text(author)
                        .font(.system(size: max(8, geo.size.width * 0.075)))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                .padding(.leading, geo.size.width * 0.2)
                .padding(.trailing, geo.size.width * 0.1)
                .padding(.vertical, geo.size.width * 0.1)
            }
        }
    }
}

struct ProgressBadge: View {
    let text: String
    let finished: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(finished ? Color(hex: 0x34C759).opacity(0.85) : Color.black.opacity(0.38))
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.6)
            )
    }
}

struct BookRow: View {
    let book: Book
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        HStack(spacing: 14) {
            BookCover(book: book)
                .frame(width: 48, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(settings.appearance.theme.foreground)
                    .lineLimit(1)
                Text(book.author)
                    .font(.caption)
                    .foregroundStyle(settings.appearance.theme.foreground.opacity(0.5))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(book.readingProgressText)
                    Text("·")
                    Text(book.fileSizeText)
                }
                .font(.caption2)
                .foregroundStyle(settings.appearance.theme.foreground.opacity(0.38))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 20, elevation: .low, interactive: true, blendsBackdrop: false)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - 空状态与加载遮罩

struct EmptyLibraryView: View {
    let isSearching: Bool
    let onAdd: () -> Void

    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: isSearching ? "magnifyingglass" : "books.vertical")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(settings.appearance.theme.foreground.opacity(0.45))
                .frame(width: 92, height: 92)
                .liquidGlassCircle(elevation: .low)

            Text(isSearching ? "没有找到匹配的书" : "书架还是空的")
                .font(.headline)
                .foregroundStyle(settings.appearance.theme.foreground.opacity(0.7))

            if !isSearching {
                Text("点右上角 + 从「文件」选择 EPUB，\n或在任何 App 里长按书文件 → 分享 → 导入到墨读")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(settings.appearance.theme.foreground.opacity(0.42))
                    .lineSpacing(3)

                Button(action: onAdd) {
                    Label("添加 EPUB 文件", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .liquidGlassCapsule(tint: Color.accentColor, elevation: .medium, interactive: true)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
    }
}

struct ImportOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.06).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("正在导入…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .liquidGlass(cornerRadius: 24, elevation: .high)
        }
        .transition(.opacity)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        GlassToast(text: text)
    }
}

// MARK: - 小工具

extension UTType {
    /// iOS 上 EPUB 的 UTI 是 `org.idpf.epub-container`，系统有时不一定能直接解析，
    /// 这里做一个带兜底的构造。
    static let epub: UTType = UTType(filenameExtension: "epub") ?? UTType(importedAs: "org.idpf.epub-container")
}
