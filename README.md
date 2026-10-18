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

## 构建步骤

代码使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 描述工程结构。

```bash
# 1. 安装 XcodeGen（macOS）
brew install xcodegen

# 2. 生成 Xcode 工程
cd Reader        # 本仓库根目录
xcodegen generate

# 3. 打开工程
open Reader.xcodeproj
```

在 Xcode 里：

1. 选中 `Reader` 和 `ShareExtension` 两个 target → Signing & Capabilities →
   勾选 **Automatically manage signing** 并选择你的 **Team**。
2. 确认两个 target 的 **App Groups** capability 里都有 `group.com.example.reader`
   （entitlements 文件已带好，通常 Xcode 会自动注册到开发者账号；真机调试前需要在
   开发者后台把该 App Group 添加到你的 Team）。
3. 想改 bundle id / App Group：改 `project.yml` 与两个 `*.entitlements` 后重新
   `xcodegen generate`。

依赖（Readium、EPUBKit）通过 Swift Package Manager 在首次构建时自动拉取。

## 工程结构

```
project.yml                  # XcodeGen 描述：两个 target、依赖、Info.plist
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
