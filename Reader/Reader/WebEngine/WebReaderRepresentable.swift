import SwiftUI
import UIKit

/// 把 `WebReaderController` 包成 SwiftUI 视图。
///
/// 注意：控制器自己维护「当前在第几章」，SwiftUI 这边只在**首次创建**时告诉它起点，
/// 之后不再由 SwiftUI 反向驱动章节，否则目录跳转、翻章都会被覆盖回旧章节。
struct WebReaderRepresentable: UIViewControllerRepresentable {
    let model: EPUBContentModel
    let appearance: AppearanceSettings
    /// 起始章节（只有 makeUIViewController 时生效）
    let chapter: Int
    let fragment: String?
    /// 起始章内比例 0...1（只有 makeUIViewController 时生效）
    let ratio: Double
    let showChrome: Bool

    var onProgress: (_ chapter: Int, _ ratio: Double, _ page: Int, _ pages: Int) -> Void
    var onCenterTap: () -> Void
    var onExternalURL: (URL) -> Void
    var pendingHref: String?
    /// 外观变化令牌：值一变就重新下发新外观
    var appearanceToken: UUID

    func makeUIViewController(context: Context) -> WebReaderController {
        let controller = WebReaderController(
            model: model,
            appearance: appearance,
            chapter: chapter,
            fragment: fragment,
            ratio: ratio
        )
        controller.onCenterTap = onCenterTap
        controller.onExternalURL = onExternalURL
        controller.onProgress = { [weak coordinator = context.coordinator] chapter, ratio, page, pages, _ in
            coordinator?.parent.onProgress(chapter, ratio, page, pages)
        }
        context.coordinator.controller = controller
        context.coordinator.lastAppearanceToken = appearanceToken
        context.coordinator.lastHref = pendingHref
        return controller
    }

    func updateUIViewController(_ controller: WebReaderController, context: Context) {
        context.coordinator.parent = self
        controller.onCenterTap = onCenterTap
        controller.onExternalURL = onExternalURL

        // 外观变化：重新应用（会按保持位置的方式重排当前章）
        if context.coordinator.lastAppearanceToken != appearanceToken {
            context.coordinator.lastAppearanceToken = appearanceToken
            controller.apply(appearance)
        }

        // 目录跳转
        if let href = pendingHref, href != context.coordinator.lastHref {
            context.coordinator.lastHref = href
            controller.jump(to: href)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: WebReaderRepresentable
        weak var controller: WebReaderController?
        var lastAppearanceToken: UUID?
        var lastHref: String?

        init(parent: WebReaderRepresentable) {
            self.parent = parent
        }
    }
}
