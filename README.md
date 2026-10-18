# 墨读 ModuReader

一款用 Swift 编写的 iOS EPUB 阅读器（仅 iPhone），内置**两套阅读引擎**，可在设置中随时切换：

| 引擎 | 依赖 | 定位 |
|---|---|---|
| **Readium** | [readium/swift-toolkit](https://github.com/readium/swift-toolkit) `3.11.1`（~560★，BSD-3） | GitHub 上 star 最多的 Swift EPUB 框架，功能完整、渲染成熟 |
| **EPUBKit（自研渲染）** | [witekbobrowski/EPUBKit](https://github.com/witekbobrowski/EPUBKit) `1.x`（~320★，MIT） | star 最多的纯 EPUB 解析器；解析后由本项目用 WKWebView + CSS 多栏自行分页渲染 |

> EPUBKit 只负责解析，真正的排版分页是本项目自己实现的（`Reader/Reader/WebEngine/`），
> 因此把它命名为「自研引擎」。

## 功能

- **本地添加**：书架页 `+` 按钮调起系统文件选择器，支持一次多选
- **通过分享添加**：系统分享面板中出现「导入到墨读」，文件先落 App Group 共享目录，主 App 下次启动自动入库
- **其它入口**：`文件` App / 邮件 / 微信「用其他应用打开」直接交给本 App；`modu://import?path=<url>` URL Scheme
- 双引擎阅读：分页 / 滚动两种翻页方式，主题（白天 / 羊皮纸 / 夜间）、字号、行距、段间距、页边距、字体、两端对齐、书籍自带排版开关
- 目录跳转、阅读进度（含章内位置）自动记忆，两套引擎进度分别保存
- 封面提取、书库搜索、排序（最近 / 添加时间 / 书名 / 作者）、网格 / 列表切换
- 去重导入（EPUB identifier 或同名同大小文件）

## 构建环境：必须使用 macOS

**`xcodegen generate` 与 `xcodebuild` 都只能在 macOS 上运行**，虚拟机绕不过去：

| 方案 | 能否跑 xcodegen | 能否编译 iOS App | 说明 |
|---|---|---|---|
| Windows + 虚拟机装 macOS | ⚠️ 理论可行 | ❌（Apple Silicon 宿主除外） | 在 Intel/AMD 的 Windows 上装 macOS 虚拟机，违反 Apple EULA；而且没有 Metal 直通，Xcode 与模拟器基本不可用 |
| Linux + Docker `xcodegen` | ✅ 可以 | ❌ | 有社区维护的 xcodegen Linux 镜像，但只能生成 `.xcodeproj`，无法编译、无法签名 |
| 真实 Mac / Mac 租赁（MacStadium、MacinCloud） | ✅ | ✅ | 唯一完整可用的路径 |
| GitHub Actions `macos-15` runner | ✅ | ✅ | 免费额度 2000 分钟/月，最省事 |

所以本仓库采用「**Windows 上写代码 + 离线静态校验 → Mac/CI 上生成工程并编译**」的方式。

### Windows 上能做的校验

```bash
python tools/check_project.py            # 校验 project.yml
python tools/check_project.py --verbose  # 打印全部通过项
python tools/test_check_project.py       # 校验器自测（需 PyYAML，可选）
```

`check_project.py` 复刻了 XcodeGen 对 `project.yml` 的主要校验（源目录存在性、excludes 命中、
包/target 依赖合法性、entitlements 与 App Group、`NSExtensionActivationRule` 括号平衡、
PrincipalClass 对应类是否存在、bundle id 前缀一致性）。当前结果：**36 项通过，0 警告，0 失败**。

> 注意：它不生成 `.xcodeproj`，也不替代编译。

### 没有 Mac 时怎么拿到编译反馈

`.github/workflows/build.yml` 会在 GitHub 的 `macos-15` runner 上跑
`xcodegen generate` → `xcodebuild build`（不签名），并把编译错误写进 Actions 的
Job Summary、上传 `build.log` 与生成好的 `Reader.xcodeproj`。

push 到 GitHub 后到 Actions 页面看结果即可；公开仓库不消耗额度。

### 在 Mac 上生成工程

```bash
brew install xcodegen
cd Reader                # 本仓库根目录
xcodegen generate        # 产出 Reader.xcodeproj
open Reader.xcodeproj
```

在 Xcode 里：

1. 选中 `Reader` 和 `ShareExtension` 两个 target → Signing & Capabilities →
   勾选 **Automatically manage signing** 并选择你的 **Team**。
2. 确认两个 target 的 **App Groups** capability 里都有 `group.com.sjzcook.modureader`
   （当前工程使用 group.com.sjzcook.modureader；必须先在 Apple Developer → Certificates, Identifiers & Profiles → Identifiers 中创建该 App Group，并为 App ID 启用 App Groups。未签名 IPA 本身不能授予此权限，最终重新签名时也必须包含该组的 entitlement）。
3. 当前 Bundle ID：`com.sjzcook.modureader`（主 App）、`com.sjzcook.modureader.share`（分享扩展）；App Group：`group.com.sjzcook.modureader`。如使用自己的 Apple Developer Team，请在开发者后台注册对应 App IDs 和 App Group，并确保签名配置授权此 App Group。改标识符后需要重新生成并构建，已安装应用可能会被视为另一款应用。

依赖（Readium、EPUBKit）通过 Swift Package Manager 在首次构建时自动拉取。

## 工程结构

```
project.yml                  # XcodeGen 描述：两个 target、依赖、Info.plist
tools/
  check_project.py           # project.yml 离线校验（Windows 可用）
  test_check_project.py      # 校验器自测：手写 YAML 解析器 vs PyYAML
.github/workflows/build.yml  # macOS runner 上 xcodegen + xcodebuild
Reader/
  App/ReaderApp.swift        # @main、Inbox 消化、URL Scheme / 文件打开入口
  Core/
    FileLocations.swift      # App Group 容器目录约定（Books / Extracted / Covers / Inbox）
    Book.swift               # 书籍模型 + ReaderEngineKind（readium / epubkit）
    LibraryStore.swift       # 书库（JSON 索引 + 文件管理）
    SettingsStore.swift      # 设置（引擎、外观、导入行为），存共享 UserDefaults
    AppearanceSettings.swift # 外观模型（两套引擎共用）
    ImportService.swift      # EPUB 解析入库、封面提取、解压缓存、去重
  Reader/
    ReaderScreen.swift       # 阅读页外壳：工具栏、目录、外观面板（双引擎共用）
    Readium/                 # Readium 引擎封装（Publication、EPUBPreferences、Locator）
    WebEngine/               # 自研引擎：EPUBContentModel → HTML 注入 → WebReaderController
  UI/
    LibraryScreen.swift      # 书架
    SettingsScreen.swift     # 设置页
  Resources/
    Assets.xcassets          # AppIcon、AccentColor
    Reader.entitlements      # App Group
ShareExtension/
  ShareViewController.swift  # 分享扩展：只把文件拷进 App Group Inbox，解析留给主 App
  ShareExtension.entitlements
```

## 两套引擎的取舍

- **Readium**：开箱即用的完整渲染（CSS 支持好、固定版式、RTL、footnote 等都处理了），
  进度用 `Locator` 标准序列化。缺点是二进制体积更大、定制排版自由度受 Readium CSS 约束。
- **自研（EPUBKit + WKWebView）**：实现只有几百行，分页用 CSS 多栏 + 外层 paging
  scroll view，字号边距等设置即时生效，且完全掌控 DOM。代价是对复杂 EPUB
  （固定版式、内嵌 JS、SVG 外层包裹）支持有限，长章节首次分页略慢。

切换入口：阅读中点「字体」面板底部的引擎选择，或设置页 → 阅读引擎。切换后重新打开
当前书即生效。

## 分享导入的流转

1. 分享扩展把 EPUB **原样拷贝**到 App Group 的 `Library/Inbox/`（不做解析，几秒内完成），
   并在共享 UserDefaults 写入待处理计数。
2. 主 App 启动 / 回前台时扫描 Inbox：逐个解析、生成封面、搬进正式书库，然后删除收件文件。
3. 解析失败的文件保留 7 天后清理，避免丢书。

## 已知限制

- **代码尚未在真机/模拟器上编译过**（作者开发机为 Windows，无 Swift 工具链）。
  所有 Readium API 的签名均对照 [3.11.1 tag 源码](https://github.com/readium/swift-toolkit/tree/3.11.1)
  与官方文档逐个核验，但编译期错误仍可能存在，首次构建若报错多为小问题（缺失 import、
  可选解包），可按报错位置微调。
- 自研引擎不支持固定版式 EPUB（`mediaType="application/xhtml+xml"` 之外的 SVG 全页封面
  等极端情况会退化为普通流式排版），这类书请用 Readium 引擎打开。
- iOS 16.0+，仅 iPhone（`TARGETED_DEVICE_FAMILY: 1`）。
