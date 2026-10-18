> 本文件是 XcodeGen 的**替代校验器**说明。
> 项目在 Windows 上开发，无法运行真正的 `xcodegen generate`（原因见 README「构建环境」）。
> 下面这个脚本用 Python 复刻 XcodeGen 对 `project.yml` 的处理逻辑，**提前暴露配置错误**，
> 避免到了 Mac 上才发现 yml 写错。

# 用法

```bash
python tools/check_project.py
```

输出示例：

```
[OK]   顶层键齐全：name / targets
[OK]   Reader 依赖 4 个包 + 1 个 target
[OK]   ShareExtension 的 NSExtensionActivationRule 语法平衡
[WARN] Reader 的 Info.plist 未声明 UISupportedInterfaceOrientations~ipad（仅 iPhone，可忽略）
```

# 它检查什么

| 检查项 | 说明 |
| --- | --- |
| YAML 可解析 | 用纯标准库（不引入 PyYAML）解析，能过说明缩进没炸 |
| target 结构 | 每个 target 必须有 `type` / `platform` / `sources` |
| 源目录存在 | `sources[].path` 指向的目录必须在磁盘上 |
| excludes 生效 | 声明的排除项不能把源目录排空 |
| 引用文件存在 | `CODE_SIGN_ENTITLEMENTS`、`INFOPLIST_FILE` 指向的文件必须存在 |
| 包依赖合法 | `package:` 名字必须在顶层 `packages:` 里定义 |
| target 依赖合法 | `target:` 名字必须是已声明的 target |
| Info.plist 关键键 | 主 App 需要 `CFBundleDisplayName`、`CFBundleDocumentTypes`、`CFBundleURLTypes` |
| 扩展激活规则 | `NSExtensionActivationRule` 的括号/`.@count` 必须配对 |
| Entitlements | App Group 标识符在两个 entitlements 里必须一致 |
| bundle id 一致性 | 扩展 id 必须以主 App id 为前缀 |

# 它**不**检查什么

- 不生成 `.xcodeproj`（那是真正的 XcodeGen 的活，需要 macOS 或 Linux + Swift）
- 不校验 SPM 包版本是否真实存在（网络）
- 不替代真正的编译
