import SwiftUI
import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    static let storageKey = "resonaAppearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "日间纸韵"
        case .dark: return "夜间黑胶"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum Theme {
    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return hex(isDark ? dark : light, alpha: alpha)
        })
    }

    // Scheme A: Warm Studio (Day Paper / Vinyl Night)
    static let paper = dynamic(light: 0xF6F3EC, dark: 0x121110)
    static let sidebar = dynamic(light: 0xEDE9DF, dark: 0x191815)
    static let surface = dynamic(light: 0xFCFBF8, dark: 0x22201C)
    static let surfaceElevated = dynamic(light: 0xF1EDE4, dark: 0x292621)
    static let selected = dynamic(light: 0xE8E3D6, dark: 0x2C2924)
    static let border = dynamic(light: 0xE2DDD1, dark: 0x302D27)
    static let borderSubtle = dynamic(light: 0xECE8DE, dark: 0x26231E)
    static let ink = dynamic(light: 0x1C1D1A, dark: 0xF3EFE7)
    static let secondary = dynamic(light: 0x4B4E46, dark: 0xB6AFA3)
    static let muted = dynamic(light: 0x595C53, dark: 0x958F83)
    static let accent = dynamic(light: 0xA43C17, dark: 0xEA7E55)
    static let accentFill = dynamic(light: 0xB54720, dark: 0xB84922)
    static let accentOn = Color(nsColor: hex(0xFCFBF8))
    static let sage = dynamic(light: 0xE4EADB, dark: 0x222A1F)
    static let sageInk = dynamic(light: 0x2B3A22, dark: 0xC2D6B0)
    static let playerBar = dynamic(light: 0xFCFBF8, dark: 0x191815, alpha: 0.96)
    static let ok = dynamic(light: 0x3E602C, dark: 0x8DB56D)
    static let listeningStart = dynamic(light: 0xECE8DE, dark: 0x1B1A16)
    static let listeningEnd = dynamic(light: 0xF3EAE1, dark: 0x1D1612)
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    return "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
}
