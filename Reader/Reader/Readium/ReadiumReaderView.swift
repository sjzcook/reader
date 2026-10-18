import SwiftUI
import UIKit
import ReadiumShared
import ReadiumNavigator

/// Readium 导航器的 SwiftUI 容器。
///
/// 注意：这里不能把 `publication` 等参数捕获进构造闭包并放到 `makeUIViewController` 里，
/// 否则 SwiftUI 每次重算 body 都会带上新闭包。改为在需要时从 `self` 读取。
struct ReadiumReaderView: UIViewControllerRepresentable {
    let publication: Publication
    let engine: ReadiumEngine
    let appearance: AppearanceSettings
    let initialLocator: Locator?

    /// 阅读位置变化
    var onLocationChange: (Locator) -> Void
    /// 点击正文中间区域（用于呼出/隐藏工具栏）
    var onCenterTap: () -> Void
    /// 需要跳转到的目录项
    var pendingLink: ReadiumShared.Link?

    func makeUIViewController(context: Context) -> ReaderHostController {
        let host = ReaderHostController()
        let coordinator = context.coordinator
        coordinator.host = host
        coordinator.parent = self
        host.configure(
            build: { [weak coordinator] in
                guard let coordinator else { throw ReadiumEngineError.navigatorUnavailable }
                return try coordinator.buildNavigator()
            },
            onAttach: { [weak coordinator] navigator in
                guard let coordinator, let host = coordinator.host else { return }
                host.mount(navigator)
                coordinator.attachObservers(to: navigator)
            }
        )
        return host
    }

    func updateUIViewController(_ controller: ReaderHostController, context: Context) {
        context.coordinator.parent = self
        controller.attachIfNeeded()
        controller.navigator?.submitPreferences(engine.preferences(from: appearance))

        if let link = pendingLink, link != context.coordinator.lastHandledLink {
            context.coordinator.lastHandledLink = link
            let navigator = controller.navigator
            Task { @MainActor in
                await navigator?.go(to: link)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    static func dismantleUIViewController(_ controller: ReaderHostController, coordinator: Coordinator) {
        coordinator.detachObservers()
    }

    // MARK: - 宿主控制器

    /// 纯容器：负责把导航器加为子控制器；创建失败时展示提示而不是崩溃。
    final class ReaderHostController: UIViewController {
        private(set) var navigator: EPUBNavigatorViewController?
        private var didBuild = false
        private var build: (() throws -> EPUBNavigatorViewController)?
        private var onAttach: ((EPUBNavigatorViewController) -> Void)?

        private let errorLabel = UILabel()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            errorLabel.numberOfLines = 0
            errorLabel.textAlignment = .center
            errorLabel.textColor = .secondaryLabel
            errorLabel.font = .systemFont(ofSize: 15)
            errorLabel.translatesAutoresizingMaskIntoConstraints = false
            errorLabel.isHidden = true
            view.addSubview(errorLabel)
            NSLayoutConstraint.activate([
                errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
                errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            ])
        }

        func configure(
            build: @escaping () throws -> EPUBNavigatorViewController,
            onAttach: @escaping (EPUBNavigatorViewController) -> Void
        ) {
            guard !didBuild else { return }
            self.build = build
            self.onAttach = onAttach
        }

        func attachIfNeeded() {
            guard !didBuild, let build else { return }
            didBuild = true
            do {
                let navigator = try build()
                self.navigator = navigator
                onAttach?(navigator)
            } catch {
                errorLabel.text = "Readium 引擎打开失败\n\(error.localizedDescription)\n\n可回到书架，在设置里切换为 EPUBKit 引擎。"
                errorLabel.isHidden = false
                DebugLog.error("Readium 初始化失败: \(error)")
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            attachIfNeeded()
        }

        func mount(_ navigation: EPUBNavigatorViewController) {
            addChild(navigation)
            navigation.view.frame = view.bounds
            navigation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(navigation.view)
            navigation.didMove(toParent: self)
        }
    }

    // MARK: - 代理与手势

    @MainActor
    final class Coordinator: NSObject, EPUBNavigatorDelegate {
        var parent: ReadiumReaderView
        weak var host: ReaderHostController?
        var lastHandledLink: ReadiumShared.Link?

        private var tapToken: InputObservableToken?
        private var directionalAdapter: DirectionalNavigationAdapter?

        init(parent: ReadiumReaderView) {
            self.parent = parent
        }

        /// 由宿主在布局时调用：构建导航器、挂载子控制器、绑定手势。
        func prepare() {
            host?.attachIfNeeded()
        }

        /// 构建导航器。只在首次挂载时调用一次。
        func buildNavigator() throws -> EPUBNavigatorViewController {
            let config = EPUBNavigatorViewController.Configuration(
                preferences: parent.engine.preferences(from: parent.appearance),
                contentInset: [
                    .compact: (top: 24, bottom: 24),
                    .regular: (top: 44, bottom: 44),
                ]
            )
            let navigator = try EPUBNavigatorViewController(
                publication: parent.publication,
                initialLocation: parent.initialLocator,
                config: config
            )
            navigator.delegate = self
            return navigator
        }

        func attachObservers(to navigator: EPUBNavigatorViewController) {
            // 1. 左右边缘点击 / 键盘方向键翻页。
            //    新版 API 是在初始化时把 navigator 传进去，再 bind 一次。
            let policy = DirectionalNavigationAdapter.PointerPolicy(
                types: [.touch],
                edges: .horizontal
            )
            let adapter = DirectionalNavigationAdapter(
                pointerPolicy: policy,
                keyboardPolicy: DirectionalNavigationAdapter.KeyboardPolicy(),
                animatedTransition: true,
                onNavigation: {} // 翻页时不做额外处理，交给 locationDidChange 保存进度
            )
            adapter.bind(to: navigator)
            directionalAdapter = adapter

            // 2. 中间区域点击 → 通知 SwiftUI 切换工具栏。
            //    tap 观察者收到的是 PointerEvent，坐标在 event.location 上。
            tapToken = navigator.addObserver(.tap { [weak self, weak navigator] event in
                guard let self, let navigator else { return false }
                let width = navigator.view.bounds.width
                let ratio = event.location.x / max(width, 1)
                guard ratio > 0.22, ratio < 0.78 else { return false }
                self.parent.onCenterTap()
                return true
            })
        }

        func detachObservers() {
            if let token = tapToken {
                host?.navigator?.removeObserver(token)
                tapToken = nil
            }
            directionalAdapter = nil
        }
        func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            parent.onLocationChange(locator)
        }

        func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
            DebugLog.error("Readium 导航错误: \\(error)")
        }

        func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {
            DebugLog.error("Readium 资源加载失败 \(href.string): \(error)")
        }
    }
}
