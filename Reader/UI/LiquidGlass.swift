import SwiftUI

// MARK: - 阴影层级

/// 玻璃面板的悬浮层级，决定投影强度。
enum GlassElevation {
    case low
    case medium
    case high

    func shadowOpacity(isDark: Bool) -> Double {
        switch self {
        case .low: return isDark ? 0.26 : 0.06
        case .medium: return isDark ? 0.34 : 0.09
        case .high: return isDark ? 0.42 : 0.14
        }
    }

    var radius: CGFloat {
        switch self {
        case .low: return 10
        case .medium: return 18
        case .high: return 28
        }
    }

    var offsetY: CGFloat {
        switch self {
        case .low: return 4
        case .medium: return 8
        case .high: return 14
        }
    }
}

// MARK: - 玻璃表面

/// 自绘的液态玻璃底面：磨砂 + 淡染色 + 釉面高光 + 边缘反光。
/// iOS 26 及以上会优先使用系统原生的 Liquid Glass（见 `LiquidGlassModifier`）。
struct GlassSurface<S: InsettableShape>: View {

    var shape: S
    var tint: Color?
    var elevation: GlassElevation = .medium
    /// 是否真的对背景做磨砂。卡片数量多时关掉可以省不少 GPU。
    var blendsBackdrop: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            // 磨砂底：让背后的书封与光晕透上来
            if blendsBackdrop {
                shape.fill(.ultraThinMaterial)
            }
            // 极淡的底色，保证文字对比度
            shape.fill(baseFill)
            // 可选染色
            if let tint {
                shape.fill(tint.opacity(isDark ? 0.30 : 0.16))
            }
            // 釉面高光：从左上斜向扫过，模拟液体表面的折射
            shape.fill(sheenGradient)
                .blendMode(.plusLighter)
            // 一像素边缘反光
            shape.strokeBorder(rimGradient, lineWidth: 1)
        }
        .compositingGroup()
        .shadow(
            color: .black.opacity(elevation.shadowOpacity(isDark: isDark)),
            radius: elevation.radius,
            x: 0,
            y: elevation.offsetY
        )
        .shadow(color: .black.opacity(isDark ? 0.20 : 0.04), radius: 2, x: 0, y: 1)
    }

    private var baseFill: Color {
        if blendsBackdrop {
            return isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.28)
        }
        return isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.70)
    }

    private var sheenGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(isDark ? 0.16 : 0.50), location: 0),
                .init(color: .white.opacity(isDark ? 0.03 : 0.10), location: 0.42),
                .init(color: .clear, location: 0.85),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var rimGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(isDark ? 0.42 : 0.85), location: 0),
                .init(color: .white.opacity(isDark ? 0.05 : 0.22), location: 0.5),
                .init(color: .white.opacity(isDark ? 0.26 : 0.58), location: 1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 修饰器

struct LiquidGlassModifier<S: InsettableShape>: ViewModifier {

    var shape: S
    var tint: Color?
    var elevation: GlassElevation
    var interactive: Bool
    var blendsBackdrop: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // 系统原生液态玻璃：带真实的折射、透镜与动态高光
            content.glassEffect(nativeEffect, in: shape)
        } else {
            legacyGlass(content)
        }
        #else
        legacyGlass(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var nativeEffect: Glass {
        var glass = Glass.regular
        if let tintColor = tint {
            glass = glass.tint(tintColor)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
    #endif

    private func legacyGlass(_ content: Content) -> some View {
        content.background {
            GlassSurface(
                shape: shape,
                tint: tint,
                elevation: elevation,
                blendsBackdrop: blendsBackdrop
            )
        }
    }
}

extension View {

    /// 圆角矩形液态玻璃背景。
    func liquidGlass(
        cornerRadius: CGFloat = 22,
        tint: Color? = nil,
        elevation: GlassElevation = .medium,
        interactive: Bool = false,
        blendsBackdrop: Bool = true
    ) -> some View {
        modifier(LiquidGlassModifier(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            elevation: elevation,
            interactive: interactive,
            blendsBackdrop: blendsBackdrop
        ))
    }

    /// 胶囊形液态玻璃背景。
    func liquidGlassCapsule(
        tint: Color? = nil,
        elevation: GlassElevation = .medium,
        interactive: Bool = false
    ) -> some View {
        modifier(LiquidGlassModifier(
            shape: Capsule(style: .continuous),
            tint: tint,
            elevation: elevation,
            interactive: interactive
        ))
    }

    /// 圆形液态玻璃背景。
    func liquidGlassCircle(
        tint: Color? = nil,
        elevation: GlassElevation = .medium,
        interactive: Bool = true
    ) -> some View {
        modifier(LiquidGlassModifier(
            shape: Circle(),
            tint: tint,
            elevation: elevation,
            interactive: interactive
        ))
    }

    /// 弹窗（sheet）的玻璃背景。iOS 16.4 之前返回原样式。
    @ViewBuilder
    func glassSheetBackground(cornerRadius: CGFloat = 28) -> some View {
        if #available(iOS 16.4, *) {
            self
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(cornerRadius)
        } else {
            self
        }
    }
}

// MARK: - 背景光晕

/// 玻璃需要有东西可以「透」出来才好看，这一层负责铺柔和的彩色光晕。
struct GlassBackdrop: View {

    var theme: AppearanceSettings.ThemeKind = .light
    var animated: Bool = true

    @State private var drift = false

    var body: some View {
        ZStack {
            theme.background

            GeometryReader { proxy in
                let size = proxy.size
                let span = max(size.width, size.height) * 1.1

                ZStack {
                    orb(theme.glassOrbs[0], diameter: span * 0.95,
                        at: CGPoint(x: size.width * 0.10, y: size.height * 0.08))
                    orb(theme.glassOrbs[1], diameter: span * 0.85,
                        at: CGPoint(x: size.width * 1.00, y: size.height * 0.24))
                    orb(theme.glassOrbs[2], diameter: span * 0.9,
                        at: CGPoint(x: size.width * 0.32, y: size.height * 0.96))
                }
                .blur(radius: 70)
                .scaleEffect(animated && drift ? 1.06 : 0.94)
                .animation(
                    animated ? .easeInOut(duration: 18).repeatForever(autoreverses: true) : nil,
                    value: drift
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { drift = true }
    }

    private func orb(_ spec: GlassOrb, diameter: CGFloat, at point: CGPoint) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [spec.color.opacity(spec.opacity), spec.color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .position(point)
    }
}

struct GlassOrb {
    var color: Color
    var opacity: Double
}

extension AppearanceSettings.ThemeKind {

    /// 背景光晕配色，随阅读主题变化。
    var glassOrbs: [GlassOrb] {
        switch self {
        case .light:
            return [
                GlassOrb(color: Color(hex: 0x8FB4FF), opacity: 0.42),
                GlassOrb(color: Color(hex: 0xC9B0FF), opacity: 0.34),
                GlassOrb(color: Color(hex: 0x8CE7D2), opacity: 0.30),
            ]
        case .sepia:
            return [
                GlassOrb(color: Color(hex: 0xE9B888), opacity: 0.36),
                GlassOrb(color: Color(hex: 0xEFA89E), opacity: 0.26),
                GlassOrb(color: Color(hex: 0xE3C795), opacity: 0.32),
            ]
        case .dark:
            return [
                GlassOrb(color: Color(hex: 0x39508F), opacity: 0.55),
                GlassOrb(color: Color(hex: 0x1F6363), opacity: 0.45),
                GlassOrb(color: Color(hex: 0x4B2F73), opacity: 0.48),
            ]
        }
    }
}

// MARK: - 通用组件

/// 玻璃圆形图标按钮（用在悬浮工具栏上）。
struct GlassIconButton: View {

    let systemImage: String
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .liquidGlassCircle(elevation: .medium)
    }
}

/// 设置页的一段玻璃卡片，带标题与说明文字。
struct GlassSection<Content: View>: View {

    let title: String?
    let footer: String?
    let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }

            VStack(spacing: 0) {
                content
            }
            .liquidGlass(cornerRadius: 24, elevation: .low)

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
    }
}

/// 玻璃卡片里的一行内容，可选底部分隔线。
struct GlassRow<Content: View>: View {

    let showsDivider: Bool
    let content: Content

    init(showsDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsDivider = showsDivider
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 0.5)
                    .padding(.leading, 16)
            }
        }
    }
}

/// 玻璃提示条（Toast）。
struct GlassToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .liquidGlassCapsule(elevation: .high)
    }
}
