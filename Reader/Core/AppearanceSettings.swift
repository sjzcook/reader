import Foundation
import SwiftUI
import UIKit

/// 阅读外观设置，两台引擎共用同一份配置。
struct AppearanceSettings: Codable, Equatable {
    enum ThemeKind: String, Codable, CaseIterable, Identifiable {
        case light, sepia, dark
        var id: String { rawValue }

        var title: String {
            switch self {
            case .light: return "白天"
            case .sepia: return "羊皮纸"
            case .dark: return "夜间"
            }
        }

        /// 自研引擎用的配色
        var background: Color {
            switch self {
            case .light: return Color(hex: 0xFFFFFF)
            case .sepia: return Color(hex: 0xFAF4E8)
            case .dark: return Color(hex: 0x121212)
            }
        }

        var foreground: Color {
            switch self {
            case .light: return Color(hex: 0x1C1C1E)
            case .sepia: return Color(hex: 0x3B3228)
            case .dark: return Color(hex: 0xD8D8D8)
            }
        }

        /// 给 UIKit / WebKit 用的桥接颜色
        var uiBackground: UIColor {
            switch self {
            case .light: return UIColor(red: 1, green: 1, blue: 1, alpha: 1)
            case .sepia: return UIColor(red: 250 / 255, green: 244 / 255, blue: 232 / 255, alpha: 1)
            case .dark: return UIColor(red: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
            }
        }

        var uiForeground: UIColor {
            switch self {
            case .light: return UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
            case .sepia: return UIColor(red: 59 / 255, green: 50 / 255, blue: 40 / 255, alpha: 1)
            case .dark: return UIColor(red: 216 / 255, green: 216 / 255, blue: 216 / 255, alpha: 1)
            }
        }

        var backgroundColorHex: String {
            switch self {
            case .light: return "#FFFFFF"
            case .sepia: return "#FAF4E8"
            case .dark: return "#121212"
            }
        }

        var textColorHex: String {
            switch self {
            case .light: return "#1C1C1E"
            case .sepia: return "#3B3228"
            case .dark: return "#D8D8D8"
            }
        }
    }

    var theme: ThemeKind = .light
    /// 字号（点），两套引擎都会换算成各自的百分比。
    var fontSize: Double = 19
    /// 行距倍数。
    var lineHeight: Double = 1.7
    /// 段间距（em）。
    var paragraphSpacing: Double = 0.55
    /// 页边距（相对屏幕宽度的比例）。
    var pageMargin: Double = 0.06
    /// 是否使用书籍自带排版（关闭后才能应用字体/行距/间距）
    var publisherStyles: Bool = false
    /// 字体族名，nil 表示使用书籍原字体。
    var fontFamily: String?
    /// 翻页方式
    var isScrolling: Bool = false
    /// 分页模式下的双栏（仅横屏有效）
    var twoColumns: Bool = false
    /// 是否允许两端对齐
    var justify: Bool = true

    static let `default` = AppearanceSettings()

    var fontFamilyLabel: String { fontFamily ?? "原书字体" }
}

extension AppearanceSettings {
    /// 可选字体列表。iOS 自带，无需打包字体文件。
    static let fontChoices: [(id: String?, name: String)] = [
        (nil, "原书字体"),
        ("Songti SC", "宋体"),
        ("Kaiti SC", "楷体"),
        ("PingFang SC", "苹方"),
        ("Heiti SC", "黑体"),
        ("STFangsong", "仿宋"),
        ("Georgia", "Georgia"),
        ("Palatino", "Palatino"),
        ("Athelas", "Athelas"),
        ("Iowan Old Style", "Iowan Old Style"),
        ("OpenDyslexic", "OpenDyslexic（无障碍）"),
        ("IA Writer Duospace", "iA Writer Duospace"),
    ]
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
