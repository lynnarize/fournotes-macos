import SwiftUI

// The Notion-like neutral palette from the web app (src/app/globals.css),
// token for token. Light values first, dark second.
struct Palette {
    /// The mark: a navy pen stroke and a red spark (white and a brighter red in the dark).
    let logoInk, logoRed: Color
    let bg, panel, text, muted, faint, line, hover: Color
    let accent, danger, ok: Color
    let stickyYellow, stickyPink, stickyBlue, stickyGreen: Color
    let boardRed, boardRedInk, boardAmber, boardAmberInk, boardGreen, boardGreenInk: Color
    /// Mix ratios the board uses to tint columns, cards and labels.
    let boardColMix, boardCardMix, boardLabelMix: Double
    let finA, finB, finC, finD, finE, finRest: Color
    let shadow: Color
    let shadowStrong: Color

    static let light = Palette(
        logoInk: .hex(0x0F0B4C), logoRed: .hex(0xE53437),
        bg: .hex(0xFFFFFF), panel: .hex(0xF7F7F5), text: .hex(0x37352F),
        muted: .hex(0x6B6A66), faint: .hex(0x8C8983), line: .hex(0xE9E9E7),
        hover: Color(red: 55/255, green: 53/255, blue: 47/255).opacity(0.06),
        accent: .hex(0x2383E2), danger: .hex(0xE03E3E), ok: .hex(0x0F7B6C),
        stickyYellow: .hex(0xFBF3DB), stickyPink: .hex(0xFBE4E4),
        stickyBlue: .hex(0xE7F3F8), stickyGreen: .hex(0xEDF3EC),
        boardRed: .hex(0xE03E3E), boardRedInk: .hex(0xB42D1F),
        boardAmber: .hex(0xDFAB01), boardAmberInk: .hex(0x85600D),
        boardGreen: .hex(0x4DAB6D), boardGreenInk: .hex(0x2B6B45),
        boardColMix: 0.06, boardCardMix: 0.0, boardLabelMix: 0.22,
        finA: .hex(0x8B7CF0), finB: .hex(0x6FD08A), finC: .hex(0x37352F),
        finD: .hex(0xF0A93B), finE: .hex(0x5AA9E6), finRest: .hex(0xE6E5E1),
        shadow: Color.black.opacity(0.06), shadowStrong: Color.black.opacity(0.06)
    )

    static let dark = Palette(
        logoInk: .hex(0xFFFBF7), logoRed: .hex(0xEE1923),
        bg: .hex(0x191919), panel: .hex(0x202020), text: .hex(0xE6E6E4),
        muted: .hex(0xAAA9A5), faint: .hex(0x8A8984), line: .hex(0x2F2F2F),
        hover: Color.white.opacity(0.06),
        accent: .hex(0x529CCA), danger: .hex(0xFF7369), ok: .hex(0x4DAB9A),
        stickyYellow: .hex(0x3A3326), stickyPink: .hex(0x3D2828),
        stickyBlue: .hex(0x22323B), stickyGreen: .hex(0x253129),
        boardRed: .hex(0xC4554D), boardRedInk: .hex(0xF08A7F),
        boardAmber: .hex(0xC29343), boardAmberInk: .hex(0xE3B35A),
        boardGreen: .hex(0x4F9768), boardGreenInk: .hex(0x7CC596),
        boardColMix: 0.09, boardCardMix: 0.16, boardLabelMix: 0.55,
        finA: .hex(0xB8A9FF), finB: .hex(0xA6EC9F), finC: .hex(0xF2F2F0),
        finD: .hex(0xF5C26B), finE: .hex(0x7CC4F5), finRest: .hex(0x333333),
        shadow: Color.black.opacity(0.4), shadowStrong: Color.black.opacity(0.3)
    )

    /// Light, on warm paper: cream pages, ink-brown text, a terracotta accent.
    static let paper = Palette(
        // The mark keeps its light colours on paper.
        logoInk: .hex(0x0F0B4C), logoRed: .hex(0xE53437),
        bg: .hex(0xFBF6E8), panel: .hex(0xF4EDD9), text: .hex(0x3A3326),
        muted: .hex(0x6B624F), faint: .hex(0x857B66), line: .hex(0xE6DCC2),
        hover: Color(red: 58/255, green: 51/255, blue: 38/255).opacity(0.07),
        accent: .hex(0xB0582A), danger: .hex(0xC23B2C), ok: .hex(0x3F7A4E),
        stickyYellow: .hex(0xF6ECC8), stickyPink: .hex(0xF6E0D6),
        stickyBlue: .hex(0xE4EDEA), stickyGreen: .hex(0xE8EED8),
        boardRed: .hex(0xC9503E), boardRedInk: .hex(0xA43A2A),
        boardAmber: .hex(0xC99A2E), boardAmberInk: .hex(0x80601A),
        boardGreen: .hex(0x5E9A63), boardGreenInk: .hex(0x366A3D),
        boardColMix: 0.07, boardCardMix: 0.0, boardLabelMix: 0.24,
        finA: .hex(0x9A7FD6), finB: .hex(0x7DB88A), finC: .hex(0x3A3326),
        finD: .hex(0xE0A040), finE: .hex(0x6FA3C8), finRest: .hex(0xE6DCC2),
        shadow: Color(red: 90/255, green: 70/255, blue: 30/255).opacity(0.08),
        shadowStrong: Color(red: 90/255, green: 70/255, blue: 30/255).opacity(0.1)
    )

    var finSeries: [Color] { [finA, finB, finC, finD, finE] }

    /// CSS `color-mix(in srgb, <color> <pct>, var(--bg))`, which the board uses for tints.
    func mix(_ color: Color, _ ratio: Double) -> Color { color.mixed(with: bg, ratio: 1 - ratio) }
}

// MARK: - Theme preference (Settings -> Appearance: System / Light / Dark)

enum ThemeChoice: String, CaseIterable, Codable {
    case system, light, paper, dark
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .paper: return "Paper"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "monitor"
        case .light: return "today"
        case .paper: return "book"
        case .dark: return "moon"
        }
    }

    /// The palette for this choice under the scheme actually in effect.
    func palette(for scheme: ColorScheme) -> Palette {
        if scheme == .dark { return .dark }
        return self == .paper ? .paper : .light
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .paper: return .light
        case .dark: return .dark
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.light
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Resolves the palette from the effective color scheme and publishes it down the tree.
struct PaletteProvider<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("fournotes.theme") private var themeRaw = ThemeChoice.system.rawValue
    @ViewBuilder var content: () -> Content

    var body: some View {
        let palette = (ThemeChoice(rawValue: themeRaw) ?? .system).palette(for: scheme)
        content()
            .environment(\.palette, palette)
            .tint(palette.accent)
    }
}

// MARK: - Type scale

enum FN {
    /// The web app uses Open Sans; on macOS the system font is the native match.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Titles are set in the serif, as the first-run setup and Today are:
    /// New York, the system's own.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static let title = serif(34)
    static let sectionTitle = font(15, .semibold)
    static let body = font(13)                // text-sm
    static let bodyMedium = font(13, .medium)
    static let small = font(12)               // text-xs
    static let tiny = font(11)

    static let radius: CGFloat = 10
    static let radiusSmall: CGFloat = 6
    static let cardRadius: CGFloat = 12
    /// max-w-[1500px] from the web shell.
    static let maxContentWidth: CGFloat = 1500
}

// MARK: - Color helpers

extension Color {
    static func hex(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Linear sRGB blend, matching CSS `color-mix(in srgb, …)` closely enough for tints.
    func mixed(with other: Color, ratio: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let t = max(0, min(1, ratio))
        return Color(
            .sRGB,
            red: Double(a.redComponent) * (1 - t) + Double(b.redComponent) * t,
            green: Double(a.greenComponent) * (1 - t) + Double(b.greenComponent) * t,
            blue: Double(a.blueComponent) * (1 - t) + Double(b.blueComponent) * t,
            opacity: Double(a.alphaComponent) * (1 - t) + Double(b.alphaComponent) * t
        )
    }
}
