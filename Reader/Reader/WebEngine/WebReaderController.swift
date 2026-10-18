import SwiftUI
import UIKit
import WebKit

/// 自研阅读引擎。
///
/// 架构：
/// - 每章一个 `WKWebView`，CSS 多栏让内容横向铺满一个「超宽画布」；
/// - WebView 每屏宽的页面容器（窄 strip）里横向滚动，滚动一屏 = 翻一页；
/// - 翻到章末再翻 → 切下一章；章首往回翻 → 上一章末页。
///
/// 这样做的好处：不需要自己算分页符，字号/边距一改重新加载即有正确的栏宽，
/// 代价是每次外观变化要重载当前章。
@MainActor
final class WebReaderController: UIViewController {

    // MARK: - 依赖

    private let model: EPUBContentModel
    private let initialChapter: Int
    private let initialFragment: String?
    private let initialRatio: Double
    /// 位置变化回调：(章节, 章内比例, 页码, 本章页数)
    var onProgress: ((_ chapter: Int, _ ratio: Double, _ page: Int, _ pages: Int, _ fragment: String?) -> Void)?
    /// 中间区域点击
    var onCenterTap: (() -> Void)?
    /// 外部链接
    var onExternalURL: ((URL) -> Void)?

    // MARK: - 状态

    private var currentIndex: Int
    private var currentAppearance: AppearanceSettings
    private var webView: WKWebView?
    private let strip = UIScrollView()
    private var isReady = false
    private var loadedSize: CGSize = .zero
    private var pendingRatio: Double?
    private var pendingFragment: String?
    private var lastRatio: Double = 0

    private lazy var panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))

    private static let messageHandler = "reader"
    /// 内部链接使用的自定义 scheme，避免 WKWebView 直接跳转（会丢掉我们的状态）
    static let internalScheme = "reader-internal"

    init(model: EPUBContentModel, appearance: AppearanceSettings, chapter: Int, fragment: String?, ratio: Double) {
        self.model = model
        self.currentAppearance = appearance
        self.initialFragment = fragment
        self.initialRatio = ratio
        let clamped = max(0, min(chapter, max(model.chapters.count - 1, 0)))
        self.initialChapter = clamped
        self.currentIndex = clamped
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = currentAppearance.theme.uiBackground

        strip.frame = view.bounds
        strip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        strip.showsHorizontalScrollIndicator = false
        strip.showsVerticalScrollIndicator = false
        strip.isPagingEnabled = true
        strip.bounces = false
        strip.contentInsetAdjustmentBehavior = .never
        strip.delegate = self
        strip.backgroundColor = currentAppearance.theme.uiBackground
        view.addSubview(strip)

        panGesture.delegate = self
        panGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(panGesture)

        tapGesture.delegate = self
        tapGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGesture)

        pendingRatio = initialRatio > 0 ? initialRatio : nil
        pendingFragment = initialFragment
        loadChapter(at: currentIndex, ratio: pendingRatio, fragment: pendingFragment)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isReady, loadedSize != view.bounds.size else { return }
        // 旋转或分屏导致尺寸变化：栏宽变了，必须重排，尽量保持章内位置
        reload(keepingRatio: lastRatio)
    }

    /// 外观设置变化：重载当前章并保持位置。
    func apply(_ appearance: AppearanceSettings) {
        currentAppearance = appearance
        view.backgroundColor = appearance.theme.uiBackground
        strip.backgroundColor = appearance.theme.uiBackground
        reload(keepingRatio: lastRatio)
    }

    private func reload(keepingRatio ratio: Double) {
        loadChapter(at: currentIndex, ratio: ratio, fragment: nil)
    }

    // MARK: - 加载

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(WeakScriptMessageHandler(delegate: self), name: Self.messageHandler)
        config.userContentController = controller
        // 本地文件之间允许互相读取（图片、字体、CSS）
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.preferences.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let web = WKWebView(frame: strip.bounds, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.showsHorizontalScrollIndicator = false
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // 内层横向滚动必须自己处理，才能「滚一屏翻一页」；
        // 宽度由 updateStripContentSize() 撑到「页数 × 屏宽」，让 CSS 多栏铺开。
        web.scrollView.isPagingEnabled = currentAppearance.isScrolling ? false : true
        web.scrollView.bounces = false
        return web
    }

    private func loadChapter(at index: Int, ratio: Double?, fragment: String?) {
        guard model.chapters.indices.contains(index) else { return }
        currentIndex = index
        isReady = false
        pendingRatio = ratio
        pendingFragment = fragment
        loadedSize = view.bounds.size

        let chapter = model.chapters[index]
        let appearance = currentAppearance

        guard let html = ReaderWebAssets.loadChapter(at: chapter.fileURL) else {
            showError("无法读取章节：\(chapter.title)")
            return
        }

        let document = ReaderWebAssets.document(
            chapterHTML: html,
            baseURL: model.contentDirectory,
            appearance: appearance,
            viewportWidth: view.bounds.width,
            rtl: model.pageProgressionRTL,
            fragment: fragment
        )

        let web: WKWebView
        if let existing = webView {
            web = existing
        } else {
            web = makeWebView()
            webView = web
        }

        web.frame = CGRect(origin: .zero, size: view.bounds.size)
        web.scrollView.isPagingEnabled = appearance.isScrolling ? false : true
        rebuildStrip(with: web)

        // 用 UTF-8 写临时文件再 loadFileURL 不现实（会破坏相对路径解析），
        // 直接 loadHTMLString 并指定 baseURL，相对资源会基于 baseURL 解析。
        web.loadHTMLString(document, baseURL: model.contentDirectory)
    }

    /// 把 WebView 挂到 strip 上。
    ///
    /// 关键：WebView 的宽度必须等于「本章总页数 × 屏宽」。
    /// 只有 WebView 布局宽度这么宽，`column-width: 100vw` 才会把整章内容铺成 N 列；
    /// 而它内部的 scrollView 始终只有一屏宽，所以一次水平翻页正好一列。
    private func rebuildStrip(with web: WKWebView) {
        strip.subviews.forEach { $0.removeFromSuperview() }
        strip.contentSize = view.bounds.size
        strip.setContentOffset(.zero, animated: false)
        web.frame = CGRect(origin: .zero, size: view.bounds.size)
        strip.addSubview(web)
    }

    /// 章节加载完成后，按「内容宽度 / 屏宽」算出页数，
    /// 把 WebView 与 strip 一起撑到「页数 × 屏宽」。
    private func updateStripContentSize() {
        guard let web else { return }
        let viewport = max(view.bounds.width, 1)
        let height = max(view.bounds.height, 1)
        let layoutWidth = web.scrollView.contentSize.width
        let pages = max(1, Int((layoutWidth / viewport).rounded()))

        let totalSize = CGSize(width: viewport * CGFloat(pages), height: height)
        if web.frame.size != totalSize {
            web.frame = CGRect(origin: .zero, size: totalSize)
        }
        strip.contentSize = totalSize
        DebugLog.info("章节 \(currentIndex) 共 \(pages) 页（内容宽 \(Int(layoutWidth))）")
    }

    /// 章内定位。`ratio >= 1` 表示要落在本章最后一页。
    private func seek(ratio: Double) {
        let pages = numberOfStripPages
        let clamped = min(max(ratio, 0), 1)
        // ratio 0 对应第 1 页，ratio 1 对应最后一页
        let page = Int((clamped * Double(pages - 1)).rounded())
        strip.setContentOffset(
            CGPoint(x: CGFloat(page) * view.bounds.width, y: 0),
            animated: false
        )
    }

    private func showError(_ message: String) {
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = currentAppearance.theme.uiForeground
        label.frame = view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }

    // MARK: - 翻页

    func goForward() {
        if strip.contentOffset.x >= strip.contentSize.width - strip.bounds.width - 2 {
            // 章末 → 下一章
            guard currentIndex + 1 < model.chapters.count else { return }
            loadChapter(at: currentIndex + 1, ratio: 0, fragment: nil)
        } else {
            let next = min(strip.contentOffset.x + strip.bounds.width, strip.contentSize.width - strip.bounds.width)
            strip.setContentOffset(CGPoint(x: next, y: 0), animated: true)
        }
    }

    func goBackward() {
        if strip.contentOffset.x <= 2 {
            guard currentIndex > 0 else { return }
            loadChapter(at: currentIndex - 1, ratio: 1, fragment: nil)
        } else {
            strip.setContentOffset(
                CGPoint(x: max(0, strip.contentOffset.x - strip.bounds.width), y: 0),
                animated: true
            )
        }
    }

    private var numberOfStripPages: Int {
        let viewport = max(view.bounds.width, 1)
        return max(1, Int((strip.contentSize.width / viewport).rounded()))
    }

    /// 目录跳转（href 可能带锚点）
    func jump(to href: String) {
        guard let found = model.chapter(for: href) else { return }
        loadChapter(at: found.chapter.index, ratio: nil, fragment: found.fragment)
    }

    func jump(toChapter index: Int) {
        loadChapter(at: index, ratio: 0, fragment: nil)
    }

    /// 内部链接（相对路径或 #锚点）
    private func handleInternalLink(_ href: String) {
        // 纯锚点：同一章内跳。用居中滚动，CSS 多栏下能落到正确的列上。
        if href.hasPrefix("#") {
            let fragment = String(href.dropFirst())
            if let web = webView {
                let script = """
                (function(){
                    var frag = \(Self.jsLiteral(fragment));
                    var el = document.getElementById(frag)
                        || document.querySelector('[name="' + frag + '"]');
                    if (!el) { return; }
                    el.scrollIntoView({ block: 'nearest', inline: 'start', behavior: 'instant' });
                    window.__readerReport && window.__readerReport();
                })();
                """
                web.evaluateJavaScript(script)
            }
            return
        }
        guard let found = model.chapter(for: href) else { return }
        loadChapter(at: found.chapter.index, ratio: nil, fragment: found.fragment)
    }

    private static func jsLiteral(_ value: String) -> String {
        ReaderWebAssets.jsLiteral(value)
    }

    // MARK: - 手势

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        let ratio = point.x / max(view.bounds.width, 1)
        if ratio < 0.22 {
            goBackward()
        } else if ratio > 0.78 {
            goForward()
        } else {
            onCenterTap?()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // 滚动模式下，纵向拖动和横向拖动都交给 WebView 自己处理
        guard !currentAppearance.isScrolling else { return }
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        guard abs(translation.x) > abs(translation.y) * 1.4 else { return }
        guard abs(translation.x) > 60 || abs(velocity.x) > 800 else { return }
        if translation.x < 0 { goForward() } else { goBackward() }
    }

    // MARK: - 进度

    private func report() {
        if currentAppearance.isScrolling {
            reportScrolling()
            return
        }
        let viewport = max(view.bounds.width, 1)
        let pages = max(1, Int((strip.contentSize.width / viewport).rounded()))
        let page = min(pages, Int((strip.contentOffset.x / viewport).rounded()) + 1)
        let ratio = pages <= 1 ? 0 : Double(page - 1) / Double(pages - 1)
        lastRatio = ratio
        onProgress?(currentIndex, ratio, page, pages, nil)
    }

    /// 滚动模式下没有「页」的概念，用纵向可滚距离折算章内比例，
    /// 页码留空（`page`/`pages` 都为 1，界面上会隐藏页码）。
    private func reportScrolling() {
        guard let web = webView else { return }
        let scroller = web.scrollView
        let maxOffset = max(0, scroller.contentSize.height - scroller.bounds.height)
        let offset = max(0, min(scroller.contentOffset.y, maxOffset))
        let ratio = maxOffset > 1 ? Double(offset / maxOffset) : 0
        lastRatio = ratio
        onProgress?(currentIndex, ratio, 1, 1, nil)
    }
}

// MARK: - WKScriptMessageHandler

extension WebReaderController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            message.name == Self.messageHandler,
            let body = message.body as? [String: Any],
            let type = body["type"] as? String
        else { return }

        switch type {
        case "position":
            report()
        case "internal":
            if let href = body["href"] as? String { handleInternalLink(href) }
        case "external":
            if let value = body["href"] as? String, let url = URL(string: value) { onExternalURL?(url) }
        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebReaderController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        // 多栏布局在 load 之后还要一次布局才有正确的 scrollWidth
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let web = self.webView else { return }
            self.updateStripContentSize()

            if let ratio = self.pendingRatio, ratio > 0.001 {
                self.seek(ratio: ratio)
            }
            self.pendingRatio = nil
            self.pendingFragment = nil
            self.report()

            // 锚点由 JS 在 load 阶段处理；这里再确认一次页数
            web.evaluateJavaScript("window.__readerReport && window.__readerReport();")
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        switch url.scheme?.lowercased() {
        case "http", "https":
            if navigationAction.navigationType == .linkActivated {
                onExternalURL?(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        case "about", "file", "data", "blob":
            decisionHandler(.allow)
        default:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLog.error("章节加载失败: \(error.localizedDescription)")
    }
}

// MARK: - 滚动同步

extension WebReaderController: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === strip { report() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === strip { report() }
    }
}

// MARK: - 手势代理

extension WebReaderController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 只把横向拖动当作翻页，纵向交给 WebView 内部滚动
        guard gestureRecognizer === panGesture, let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y)
    }
}

// MARK: - 避免 WKUserContentController 强引用控制器

final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
