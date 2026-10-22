import SwiftUI

/// 设置页：外观、存储与关于。整体采用液态玻璃卡片布局。
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
            footer: "阅读渲染由 Readium 提供，EPUB 元数据解析与封面提取由 EPUBKit 提供；两者均为开源项目。"
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
                        Text("Readium · 阅读渲染")
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
                        Text("EPUBKit · 导入解析")
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

/// 设置页里的外观面板（与阅读器内的面板共用同一份绑定）
struct AppearanceSettingsScreen: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        AppearanceSheetContent(appearance: $settings.appearance)
            .navigationTitle("外观与排版")
            .navigationBarTitleDisplayMode(.inline)
    }
}
