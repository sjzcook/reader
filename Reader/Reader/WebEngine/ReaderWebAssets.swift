import Foundation

/// 阅读用的 CSS 与 JS 注入。
///
/// 思路：让 WKWebView 直接渲染章节 XHTML（图片、字体、作者样式都能自然生效），
/// 再用「CSS 多栏 + 视口宽度」做分页：`column-width: 100vw` 把内容按屏切成横向列，
/// 水平滚动一屏即翻一页。
enum ReaderWebAssets {

    // MARK: - 样式

    static func styleSheet(appearance: AppearanceSettings, viewportWidth: CGFloat) -> String {
        let background = appearance.theme.backgroundColorHex
        let foreground = appearance.theme.textColorHex
        let viewport = max(1, viewportWidth)
        let side = max(10, viewport * appearance.pageMargin)
        let fontStack = appearance.fontFamily.map { "\"\($0)\"" } ?? "-apple-system, \"Songti SC\", serif"
        let align = appearance.justify ? "justify" : "left"
        // 关掉作者样式时，统一压平字体与颜色（背景一律透明，避免书里自带白底）
        let authorOverride = appearance.publisherStyles ? "" : """
            font-family: inherit !important;
            color: inherit !important;
            background-color: transparent !important;
            """

        // 分页模式：固定栏宽 = 一屏，内容横向铺成 N 列，列高锁死一屏。
        // 滚动模式：单列、纵向滚动，不设列宽也不锁高度。
        let pagination = appearance.isScrolling
            ? "overflow-x: hidden; overflow-y: auto; min-height: 100vh;"
            : """
              column-width: \(Int(viewport))px;
              column-gap: \(Int(side * 2))px;
              column-fill: auto;
              height: 100vh;
              overflow: hidden;
              """

        let avoidBreak = appearance.isScrolling
            ? ""
            : "p, li, blockquote, h1, h2, h3, h4, figure { break-inside: avoid-column; }"

        return """
        :root { color-scheme: \(appearance.theme == .dark ? "dark" : "light"); }
        html {
            background: \(background) !important;
            -webkit-text-size-adjust: none;
        }
        body {
            margin: 0 !important;
            padding: 0 \(Int(side))px !important;
            background: \(background) !important;
            color: \(foreground) !important;
            font-family: \(fontStack) !important;
            font-size: \(appearance.fontSize)px !important;
            line-height: \(appearance.lineHeight) !important;
            text-align: \(align);
            box-sizing: border-box;
            -webkit-hyphens: none;
            \(pagination)
        }
        body, body * { \(authorOverride) }
        p, div, li, blockquote {
            margin-top: 0 !important;
            margin-bottom: \(appearance.paragraphSpacing)em !important;
        }
        img, svg, video {
            max-width: 100% !important;
            height: auto !important;
            break-inside: avoid;
        }
        table, pre { max-width: 100% !important; }
        a {
            color: \(foreground) !important;
            text-decoration: underline;
            text-decoration-color: \(foreground)55;
        }
        h1, h2, h3, h4 { line-height: 1.35 !important; }
        ::selection { background: \(foreground)33; }
        \(avoidBreak)
        """
    }

    /// 正文完整 HTML：作者原始标记 + 我们的样式 + 辅助脚本。
    ///
    /// 必须用 `loadHTMLString` 才能注入脚本（`loadFileURL` 只能读到只读的 documentElement，
    /// 改不了 DOM）。相对资源之所以还能加载，是因为这层 HTML 是从磁盘读出来的，
    /// 里面的 `src` 已经被改写成绝对 `file://` 路径。
    static func document(
        chapterHTML: String,
        baseURL: URL,
        appearance: AppearanceSettings,
        viewportWidth: CGFloat,
        rtl: Bool,
        fragment: String?
    ) -> String {
        let css = styleSheet(appearance: appearance, viewportWidth: viewportWidth)
        let injected = """
        <style id="reader-style">\(css)</style>
        <script>\(helperScript(rtl: rtl, fragment: fragment))</script>
        """
        return HTMLInjector.inject(html: chapterHTML, injected: injected, absoluteBase: baseURL)
    }

    /// 读取章节文件。编码优先 UTF-8，失败退回 GB18030（部分中文 EPUB 会用）。
    static func loadChapter(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - 脚本

    /// 辅助脚本：接管链接、汇报位置、处理锚点。
    static func helperScript(rtl: Bool, fragment: String?) -> String {
        let direction = rtl ? "-1" : "1"
        let anchor = jsLiteral(fragment)
        return """
        (function () {
            var DIRECTION = \(direction);
            var PENDING_ANCHOR = \(anchor);

            function metrics() {
                var scroller = document.scrollingElement || document.documentElement;
                var viewport = window.innerWidth;
                var maxScroll = Math.max(0, scroller.scrollWidth - viewport);
                var offset = DIRECTION > 0 ? scroller.scrollLeft : (maxScroll - scroller.scrollLeft);
                return {
                    maxScroll: maxScroll,
                    pages: Math.max(1, Math.round((maxScroll + viewport) / viewport)),
                    page: Math.round(offset / viewport) + 1,
                    ratio: maxScroll > 0 ? Math.min(1, Math.max(0, offset / maxScroll)) : 0
                };
            }

            function report() {
                var m = metrics();
                window.webkit.messageHandlers.reader.postMessage({
                    type: 'position', ratio: m.ratio, page: m.page, pages: m.pages
                });
            }

            window.__readerReport = report;

            // 拦截链接：外链交给原生打开，内链转成自定义 scheme 交给原生处理。
            // 注意正则首尾都不要加减号，否则会被 Swift 当成字符串插值的结束。
            document.addEventListener('click', function (event) {
                var anchor = event.target.closest ? event.target.closest('a[href]') : null;
                if (!anchor) { return; }
                var href = anchor.getAttribute('href') || '';
                if (/(https?|mailto|tel):/i.test(href)) {
                    event.preventDefault();
                    window.webkit.messageHandlers.reader.postMessage({ type: 'external', href: href });
                } else if (!href.startsWith('#')) {
                    event.preventDefault();
                    window.webkit.messageHandlers.reader.postMessage({ type: 'internal', href: href });
                }
            }, true);

            function seekToAnchor() {
                if (!PENDING_ANCHOR) { return; }
                var el = document.getElementById(PENDING_ANCHOR)
                    || document.querySelector('[name="' + PENDING_ANCHOR + '"]');
                if (!el) { return; }
                var scroller = document.scrollingElement || document.documentElement;
                var viewport = window.innerWidth;
                var maxScroll = Math.max(0, scroller.scrollWidth - viewport);
                var left = el.getBoundingClientRect().left + scroller.scrollLeft;
                var position = Math.max(0, Math.min(maxScroll, left - 4));
                scroller.scrollLeft = DIRECTION > 0 ? position : (maxScroll - position);
            }

            function start() {
                seekToAnchor();
                // 多栏布局需要一次布局才能算出 scrollWidth，用 rAF 等它稳定
                requestAnimationFrame(function () {
                    seekToAnchor();
                    requestAnimationFrame(report);
                });
            }

            if (document.readyState === 'complete') {
                start();
            } else {
                window.addEventListener('load', start);
            }

            var timer = null;
            window.addEventListener('scroll', function () {
                if (timer) { clearTimeout(timer); }
                timer = setTimeout(report, 160);
            }, { passive: true });
        })();
        """
    }

    /// 把 Swift 可选字符串转成可安全嵌入 JS 的字面量。
    static func jsLiteral(_ value: String?) -> String {
        guard let value else { return "null" }
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "'": escaped += "\\'"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}

/// 把附加的 style/script 注入到章节 HTML 的 `<head>` 里，
/// 同时把相对的 `href`/`src` 改写成绝对 `file://` URL。
enum HTMLInjector {

    static func inject(html: String, injected: String, absoluteBase: URL) -> String {
        var output = html

        // 1. 注入到 </head> 之前；没有 head 就补一个
        if let range = output.range(of: "</head>", options: .caseInsensitive) {
            output.insert(contentsOf: injected, at: range.lowerBound)
        } else if let range = output.range(of: "<body", options: .caseInsensitive) {
            output.insert(contentsOf: "<head>\(injected)</head>", at: range.lowerBound)
        } else {
            output = "<head>\(injected)</head>" + output
        }

        // 2. 改写相对链接。样式与脚本里内联的 url(...) 不处理，那属于少数情况。
        output = absolutize(in: output, attribute: "href", base: absoluteBase)
        output = absolutize(in: output, attribute: "src", base: absoluteBase)
        return output
    }

    private static func absolutize(in html: String, attribute: String, base: URL) -> String {
        let pattern = "(<[^>]*?\\s\(attribute)\\s*=\\s*)([\"'])(?!#|data:|javascript:|mailto:|tel:|https?:|//|file:)([^\"']+)\\2"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = 0
        for match in matches {
            let full = match.range
            let value = ns.substring(with: match.range(at: 3))
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            // 拆掉查询串与锚点，拼绝对路径后再补回去
            var path = value
            var suffix = ""
            if let index = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                suffix = String(path[index...])
                path = String(path[..<index])
            }
            let decoded = path.removingPercentEncoding ?? path
            let absolute = base.appendingPathComponent(decoded).absoluteString

            result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            result += ns.substring(with: match.range(at: 1))
            result += ns.substring(with: match.range(at: 2))
            result += absolute + suffix
            result += ns.substring(with: match.range(at: 2))
            cursor = full.location + full.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
