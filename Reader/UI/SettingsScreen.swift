import SwiftUI

/// 设置页：阅读引擎切换 + 外观 + 存储管理。整体采用液态玻璃卡片布局。
struct SettingsScreen: View {

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackdrop(theme: settings.appearance.theme, animated: false)

                ScrollView {
                    VStack(spacing: 24) {
                        engineSection
                        readingSection
                        storageSection
                        aboutSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .confirmationDialog("清空书库？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空全部书籍", role: .destructive) {
                    library.books.forEach(library.remove)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所有书籍文件与阅读进度都会被删除，操作无法撤销。")
            }
        }
    }

    // MARK: - 引擎

    private var engineSection: some View {
        let engines = ReaderEngineKind.allCases
        return GlassSection(
            "阅读引擎",
            footer: "两套引擎的解析与渲染方式不同，阅读进度分别保存。切换后重新打开书本即可生效。"
        ) {
            ForEach(engines.indices, id: \.self) { index in
                let engine = engines[index]
                GlassRow(showsDivider: index < engines.count - 1) {
                    EngineRow(
                        engine: engine,
                        isSelected: settings.engine == engine,
                        onSelect: {
                            withAnimation(.easeInOut(duration: 0.15)) { settings.engine = engine }
                        }
                    )
                }
            }
        }
    }

    // MARK: - 阅读

    private var readingSection: some View {
        GlassSection("阅读") {
            GlassRow {
                Toggle(isOn: $settings.openAfterImport) {
                    Text("导入后自动打开")
                        .font(.system(size: 15))
                }
                .tint(.accentColor)
            }

            GlassRow(showsDivider: false) {
                NavigationLink {
                    AppearanceSettingsScreen()
                } label: {
                    HStack(spacing: 8) {
                        Text("外观与排版")
                            .font(.system(size: 15))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Text("\(Int(settings.appearance.fontSize))pt · \(settings.appearance.theme.title)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        GlassSection(
            "存储",
            footer: "书籍保存在 App 的共享容器里，可在「文件」App → 我的 iPhone → 墨读 中查看。"
        ) {
            GlassRow {
                LabeledContent("书籍数量") {
                    Text("\(library.books.count) 本").foregroundStyle(.secondary)
                }
                .font(.system(size: 15))
            }

            GlassRow {
                LabeledContent("占用空间") {
                    Text(formattedSize).foregroundStyle(.secondary)
                }
                .font(.system(size: 15))
            }

            GlassRow(showsDivider: false) {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Text("清空书库")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(library.books.isEmpty)
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        GlassSection(
            "关于",
            footer: "两者均为 MIT 许可的开源项目，本项目在此基础上实现了书架与阅读界面。"
        ) {
            GlassRow {
                LabeledContent("版本") {
                    Text(appVersion).foregroundStyle(.secondary)
                }
                .font(.system(size: 15))
            }

            GlassRow {
                Link(destination: URL(string: "https://github.com/readium/swift-toolkit")!) {
                    HStack(spacing: 8) {
                        Text("Readium Swift Toolkit")
                            .font(.system(size: 15))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Text("3.11").font(.system(size: 14)).foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
            }

            GlassRow(showsDivider: false) {
                Link(destination: URL(string: "https://github.com/witekbobrowski/EPUBKit")!) {
                    HStack(spacing: 8) {
                        Text("EPUBKit")
                            .font(.system(size: 15))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Text("1.x").font(.system(size: 14)).foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private var formattedSize: String {
        let total = library.books.reduce(Int64(0)) { $0 + $1.fileSize }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// 单个引擎选项，带选中态与说明
struct EngineRow: View {
    let engine: ReaderEngineKind
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(engine.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(engine.badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill((isSelected ? Color.accentColor : Color.secondary).opacity(0.12))
                            )
                    }
                    Text(engine.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(engine.detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 设置页里的外观面板（与阅读器内的面板共用同一份绑定）
struct AppearanceSettingsScreen: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        AppearanceSheetContent(appearance: $settings.appearance)
            .navigationTitle("外观与排版")
            .navigationBarTitleDisplayMode(.inline)
    }
}
