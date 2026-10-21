import SwiftUI

// The web app's tokens (src/app/globals.css), after Arc (uiarc.dev): neutral surfaces,
// hairline borders, one accent spent on what is selected or active. Two vocabularies,
// as on the web: the Arc role names (surface, foreground, border…) for new work, and the
// short names the views grew up with (bg, text, line…), mapped onto those roles.
// The oklch values on the web are converted to sRGB here. Light first, then paper, dark.
struct Palette {
    /// The mark: a navy pen stroke and a red spark (white and a brighter red in the dark).
    let logoInk, logoRed: Color

    // MARK: Arc roles
    let background, surface, surfaceRaised, surfaceMuted, sidebar: Color
    let foreground, textSecondary, textMuted: Color
    let border, borderSubtle, borderStrong: Color
    /// The accent: neutral ink by default, or the hue picked in Settings → Appearance.
    var accent, accentStrong, accentSubtle, accentForeground: Color
    /// The empty part of a meter, a switch that's off, "other" in a chart.
    let controlTrack: Color
    /// Status colours mean status: done, needs attention, failed. Never decoration.
    let success, successSubtle, warning, warningSubtle, danger, dangerSubtle: Color
    let hover: Color
    /// Chart series, told apart by lightness as well as hue.
    let series: [Color]
    /// A quick note keeps its colour as a small dot.
    let noteYellow, notePink, noteBlue, noteGreen: Color
    let stickyYellow, stickyPink, stickyBlue, stickyGreen: Color
    let boardRed, boardRedInk, boardAmber, boardAmberInk, boardGreen, boardGreenInk: Color
    /// Mix ratios the board uses to tint columns, cards and labels.
    let boardColMix, boardCardMix, boardLabelMix: Double
    /// Floating layers only (menus, popovers, the composer); cards rest on a border.
    let shadow: Color
    let shadowStrong: Color

    // MARK: The short names

    var bg: Color { background }
    var panel: Color { surfaceMuted }
    var text: Color { foreground }
    var muted: Color { textSecondary }
    var faint: Color { textMuted }
    var line: Color { border }
    var ok: Color { success }
    var finA: Color { series[1] }
    var finB: Color { series[4] }
    var finC: Color { series[0] }
    var finD: Color { series[2] }
    var finE: Color { series[3] }
    var finRest: Color { controlTrack }

    static let light = Palette(
        logoInk: .hex(0x0F0B4C), logoRed: .hex(0xE53437),
        background: .hex(0xFFFFFF), surface: .hex(0xFFFFFF), surfaceRaised: .hex(0xFFFFFF),
        surfaceMuted: .hex(0xF7F7F7), sidebar: .hex(0xFBFBFB),
        foreground: .hex(0x0F0F0F), textSecondary: .hex(0x525252), textMuted: .hex(0x696969),
        border: .hex(0xE6E6E6), borderSubtle: .hex(0xF0F0F0), borderStrong: .hex(0xC7C7C7),
        accent: .hex(0x2E2E2E), accentStrong: .hex(0x1B1B1B),
        accentSubtle: Color.hex(0x2E2E2E).opacity(0.07), accentForeground: .white,
        controlTrack: .hex(0xDCDCDC),
        success: .hex(0x007329), successSubtle: Color.hex(0x25984D).opacity(0.12),
        warning: .hex(0x975200), warningSubtle: Color.hex(0xF0B135).opacity(0.22),
        danger: .hex(0xC51D28), dangerSubtle: Color.hex(0xDE3B3D).opacity(0.1),
        hover: Color.hex(0x0F0F0F).opacity(0.045),
        series: [.hex(0x2E2E2E), .hex(0x4081D2), .hex(0xE9B452), .hex(0xCCDCF2), .hex(0x46B68C)],
        noteYellow: .hex(0xEBC75E), notePink: .hex(0xF39098), noteBlue: .hex(0x70B4DC), noteGreen: .hex(0x7CC58C),
        stickyYellow: .hex(0xFBF3DB), stickyPink: .hex(0xFBE4E4),
        stickyBlue: .hex(0xE7F3F8), stickyGreen: .hex(0xEDF3EC),
        boardRed: .hex(0xE03E3E), boardRedInk: .hex(0xB42D1F),
        boardAmber: .hex(0xDFAB01), boardAmberInk: .hex(0x85600D),
        boardGreen: .hex(0x4DAB6D), boardGreenInk: .hex(0x2B6B45),
        boardColMix: 0.06, boardCardMix: 0.0, boardLabelMix: 0.22,
        shadow: Color.black.opacity(0.045), shadowStrong: Color.black.opacity(0.105)
    )

    /// Light, on warm paper: cream pages, ink-brown text.
    static let paper = Palette(
        // The mark keeps its light colours on paper.
        logoInk: .hex(0x0F0B4C), logoRed: .hex(0xE53437),
        background: .hex(0xFDF9F1), surface: .hex(0xFFFCF8), surfaceRaised: .hex(0xFFFCF8),
        surfaceMuted: .hex(0xF5F0E5), sidebar: .hex(0xF9F4EA),
        foreground: .hex(0x2D251C), textSecondary: .hex(0x5B4D40), textMuted: .hex(0x6F6053),
        border: .hex(0xE6DFD1), borderSubtle: .hex(0xEFEADF), borderStrong: .hex(0xC7BCAA),
        accent: .hex(0x443428), accentStrong: .hex(0x2F2115),
        accentSubtle: Color.hex(0x5C412C).opacity(0.09), accentForeground: .white,
        controlTrack: .hex(0xDED6C9),
        success: .hex(0x007329), successSubtle: Color.hex(0x25984D).opacity(0.12),
        warning: .hex(0x975200), warningSubtle: Color.hex(0xF0B135).opacity(0.22),
        danger: .hex(0xC51D28), dangerSubtle: Color.hex(0xDE3B3D).opacity(0.1),
        hover: Color.hex(0x5C412C).opacity(0.06),
        series: [.hex(0x443428), .hex(0x4081D2), .hex(0xE9B452), .hex(0xE2D6BE), .hex(0x46B68C)],
        noteYellow: .hex(0xEBC75E), notePink: .hex(0xF39098), noteBlue: .hex(0x70B4DC), noteGreen: .hex(0x7CC58C),
        stickyYellow: .hex(0xF6ECC8), stickyPink: .hex(0xF6E0D6),
        stickyBlue: .hex(0xE4EDEA), stickyGreen: .hex(0xE8EED8),
        boardRed: .hex(0xC9503E), boardRedInk: .hex(0xA43A2A),
        boardAmber: .hex(0xC99A2E), boardAmberInk: .hex(0x80601A),
        boardGreen: .hex(0x5E9A63), boardGreenInk: .hex(0x366A3D),
        boardColMix: 0.07, boardCardMix: 0.0, boardLabelMix: 0.24,
        shadow: Color(red: 90/255, green: 70/255, blue: 30/255).opacity(0.06),
        shadowStrong: Color(red: 90/255, green: 70/255, blue: 30/255).opacity(0.12)
    )

    static let dark = Palette(
        logoInk: .hex(0xFFFBF7), logoRed: .hex(0xEE1923),
        background: .hex(0x141414), surface: .hex(0x191919), surfaceRaised: .hex(0x1F1F1F),
        surfaceMuted: .hex(0x232323), sidebar: .hex(0x171717),
        foreground: .hex(0xF2F2F2), textSecondary: .hex(0xB7B7B7), textMuted: .hex(0x959595),
        border: .hex(0x2B2B2B), borderSubtle: .hex(0x222222), borderStrong: .hex(0x484848),
        accent: .hex(0xE4E4E4), accentStrong: .hex(0xF5F5F5),
        accentSubtle: Color.hex(0xE4E4E4).opacity(0.1), accentForeground: .hex(0x141414),
        controlTrack: .hex(0x353535),
        success: .hex(0x56D57B), successSubtle: Color.hex(0x37BB62).opacity(0.16),
        warning: .hex(0xFDBE45), warningSubtle: Color.hex(0xF0B135).opacity(0.16),
        danger: .hex(0xFF8079), dangerSubtle: Color.hex(0xFF5F5B).opacity(0.16),
        hover: Color.white.opacity(0.06),
        series: [.hex(0xE8E8E8), .hex(0x589AED), .hex(0xE9B452), .hex(0x49596E), .hex(0x4DBC92)],
        noteYellow: .hex(0xEBC75E), notePink: .hex(0xF39098), noteBlue: .hex(0x70B4DC), noteGreen: .hex(0x7CC58C),
        stickyYellow: .hex(0x3A3326), stickyPink: .hex(0x3D2828),
        stickyBlue: .hex(0x22323B), stickyGreen: .hex(0x253129),
        boardRed: .hex(0xC4554D), boardRedInk: .hex(0xF08A7F),
        boardAmber: .hex(0xC29343), boardAmberInk: .hex(0xE3B35A),
        boardGreen: .hex(0x4F9768), boardGreenInk: .hex(0x7CC596),
        boardColMix: 0.09, boardCardMix: 0.16, boardLabelMix: 0.55,
        shadow: Color.black.opacity(0.3), shadowStrong: Color.black.opacity(0.4)
    )

    var finSeries: [Color] { [finA, finB, finC, finD, finE] }

    /// CSS `color-mix(in srgb, <color> <pct>, var(--bg))`, which the board uses for tints.
    func mix(_ color: Color, _ ratio: Double) -> Color { color.mixed(with: bg, ratio: 1 - ratio) }

    /// This palette with an accent hue from Settings → Appearance. Neutral keeps the
    /// theme's own ink.
    func with(accent choice: AccentChoice, dark: Bool) -> Palette {
        guard let hue = choice.hue(dark: dark) else { return self }
        var out = self
        out.accent = hue.accent
        out.accentStrong = hue.strong
        out.accentSubtle = hue.subtle
        out.accentForeground = hue.foreground
        return out
    }
}

// MARK: - Accent (Settings → Appearance)

/// The accent hues, as on the web (data-accent). Light values keep white text at 4.5:1
/// or better; dark values are lighter, for dark surfaces.
enum AccentChoice: String, CaseIterable, Codable {
    case neutral, blue, violet, green, coral, rose

    static let storageKey = "fournotes.accent"
    /// The choice saved in Settings, for windows that don't observe it (the edge dock).
    static var current: AccentChoice {
        AccentChoice(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .neutral
    }

    var label: String { rawValue == "neutral" ? "Neutral" : rawValue.capitalized }

    /// The swatch shown in Settings.
    var swatch: Color { hue(dark: false)?.accent ?? Palette.light.accent }

    func hue(dark: Bool) -> (accent: Color, strong: Color, subtle: Color, foreground: Color)? {
        switch (self, dark) {
        case (.neutral, _): return nil
        case (.blue, false): return (.hex(0x0562EF), .hex(0x074DB7), Color.hex(0x0562EF).opacity(0.1), .white)
        case (.violet, false): return (.hex(0x7747FF), .hex(0x5528CE), Color.hex(0x7747FF).opacity(0.1), .white)
        case (.green, false): return (.hex(0x087C54), .hex(0x06603F), Color.hex(0x0DB879).opacity(0.12), .white)
        case (.coral, false): return (.hex(0xD8433A), .hex(0xB92C27), Color.hex(0xF15F55).opacity(0.12), .white)
        case (.rose, false): return (.hex(0xC73580), .hex(0xAE2570), Color.hex(0xED4E9D).opacity(0.12), .white)
        case (.blue, true): return (.hex(0x6BA3FF), .hex(0xA4C7FF), Color.hex(0x6BA3FF).opacity(0.16), .hex(0x0B1424))
        case (.violet, true): return (.hex(0xA78BFF), .hex(0xC7B7FF), Color.hex(0xA78BFF).opacity(0.16), .hex(0x140D26))
        case (.green, true): return (.hex(0x53DCA6), .hex(0x93EFD0), Color.hex(0x53DCA6).opacity(0.14), .hex(0x08201A))
        case (.coral, true): return (.hex(0xFF9386), .hex(0xFFC1BA), Color.hex(0xFF9386).opacity(0.15), .hex(0x21110F))
        case (.rose, true): return (.hex(0xFF8BC5), .hex(0xFFC0DF), Color.hex(0xFF8BC5).opacity(0.15), .hex(0x250F1B))
        }
    }
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

    /// The palette for this choice under the scheme actually in effect, with the accent
    /// picked in Settings.
    func palette(for scheme: ColorScheme, accent: AccentChoice = .current) -> Palette {
        let base: Palette = scheme == .dark ? .dark : (self == .paper ? .paper : .light)
        return base.with(accent: accent, dark: scheme == .dark)
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
    @AppStorage(AccentChoice.storageKey) private var accentRaw = AccentChoice.neutral.rawValue
    @ViewBuilder var content: () -> Content

    var body: some View {
        let palette = (ThemeChoice(rawValue: themeRaw) ?? .system)
            .palette(for: scheme, accent: AccentChoice(rawValue: accentRaw) ?? .neutral)
        content()
            .environment(\.palette, palette)
            .tint(palette.accent)
    }
}

// MARK: - Type scale

enum FN {
    /// The web app sets text in Inter; on macOS the system font is the native match.
    /// Weights stay at regular and medium, as on the web: hierarchy comes from size and
    /// colour, not bold. Heavier weights asked for are drawn as medium.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: [.regular, .light, .thin, .ultraLight].contains(weight) ? weight : .medium)
    }
    /// Headings of 30pt and up (Geist on the web): regular weight. Pair with
    /// `.tracking(FN.displayTracking(size))` for the web's tight -0.03em.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular) }
    static func displayTracking(_ size: CGFloat) -> CGFloat { -0.03 * size }
    /// Kept for the views that still ask for it: the redesign has no serif, so this is
    /// the display face (medium below 30pt, where the serif marked a card's title).
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        size >= 30 ? display(size) : font(size, .medium)
    }
    static let title = display(34)
    static let sectionTitle = font(15, .medium)
    static let body = font(13)                // text-sm
    static let bodyMedium = font(13, .medium)
    static let small = font(12)               // text-xs
    static let tiny = font(11)

    /// Concentric corners, as on the web: a nested corner is the outer radius minus
    /// the padding between them. Controls 18, panels (cards) 26, surfaces 34.
    static let radiusControl: CGFloat = 18
    static let radiusPanel: CGFloat = 26
    static let radiusSurface: CGFloat = 34
    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8
    static let cardRadius: CGFloat = 26
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
