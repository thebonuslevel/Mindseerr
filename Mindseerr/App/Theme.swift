import SwiftUI

/// A look for the whole app, chosen in Settings. Add a case here to offer another theme.
enum AppTheme: String, CaseIterable, Identifiable {
    /// Mud: a near-black brown behind everything, pastel tan-brown for highlights.
    case sludge
    /// Slime: a near-black swamp green behind everything, pastel slime green for highlights.
    case bile
    /// Dusk blue: a near-black navy behind everything, pastel sky blue for highlights.
    case gloam
    /// The logo's palette: its deep purple outline behind everything, its lavender for highlights.
    case despair
    /// The logo's tentacles: their deep magenta tips darkened behind everything, their pink softened to pastel for highlights.
    case rage
    /// True black (#000000) so OLED pixels switch fully off behind the UI.
    case abyss
    /// Ash: a near-black neutral grey behind everything, pastel silver-grey for highlights.
    case smoke
    /// Fog: a warm off-white behind everything, dark slate ink for highlights. The only light theme.
    case mist

    static let storageKey = "appearance.theme"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sludge: return "Sludge"
        case .bile: return "Bile"
        case .gloam: return "Gloam"
        case .despair: return "Despair"
        case .rage: return "Rage"
        case .abyss: return "Abyss"
        case .smoke: return "Smoke"
        case .mist: return "Mist"
        }
    }

    /// Fills the screen behind every page.
    var background: Color {
        switch self {
        case .sludge: return Color(hex: 0x1F140B)  // mud brown, darkened
        case .bile: return Color(hex: 0x0E1F0B)    // slime green, darkened
        case .gloam: return Color(hex: 0x0A1428)   // dusk navy, darkened
        case .despair: return Color(hex: 0x1A0A2C) // logo outline
        case .rage: return Color(hex: 0x2A0818)    // tentacle tips (#A81E66), darkened
        case .abyss: return .black
        case .smoke: return Color(hex: 0x1C1C1E)   // neutral charcoal grey
        case .mist: return Color(hex: 0xF2F0EB)    // warm off-white
        }
    }

    /// Light or dark system controls and text, regardless of the Apple TV's own appearance setting.
    var colorScheme: ColorScheme {
        switch self {
        case .abyss, .despair, .rage, .bile, .sludge, .gloam, .smoke: return .dark
        case .mist: return .light
        }
    }

    /// Fill behind the focused button (the cursor). Text stays the theme's primary color everywhere else.
    var highlight: Color {
        switch self {
        case .sludge: return Color(hex: 0xDDBF9E)  // pastel tan-brown
        case .bile: return Color(hex: 0xBEF09A)    // pastel slime green
        case .gloam: return Color(hex: 0x9CC8F4)   // pastel sky blue
        case .despair: return Color(hex: 0xB8A8E0) // logo head lavender
        case .rage: return Color(hex: 0xF4A0BE)    // tentacle pink (#E4549C), pastel
        case .abyss: return .white                    // matches the system focus look
        case .smoke: return Color(hex: 0xC4C6CC)   // pastel silver-grey
        case .mist: return Color(hex: 0x2B2F36)    // dark slate ink
        }
    }
}

private extension Color {
    /// A color from a 0xRRGGBB value.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension EnvironmentValues {
    @Entry var appTheme: AppTheme = .gloam
}

private struct ThemeBackground: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content.background(theme.background.ignoresSafeArea())
    }
}

extension View {
    /// The current theme's background behind this view, edge to edge.
    func themedBackground() -> some View {
        modifier(ThemeBackground())
    }

    /// Applies a theme to this view and everything inside it.
    /// Always the same view structure, so switching themes keeps navigation and focus where they are.
    func appTheme(_ theme: AppTheme) -> some View {
        environment(\.appTheme, theme)
            .preferredColorScheme(theme.colorScheme)
            // Buttons that don't pick their own style get the themed cursor.
            .buttonStyle(ThemedButtonStyle())
    }
}

// MARK: - Themed cursor

/// tvOS has no setting for the focus highlight's color, so buttons draw their own: a rounded fill in the
/// theme's highlight color while focused, with the label switching to the theme's dark background color.
struct ThemedButtonStyle: ButtonStyle {
    /// Show a faint fill while not focused, like a standard tvOS button. Off for text-only buttons such as section titles.
    var idleFill = true
    /// Quieter look for rows that only show information: a fainter fill and dimmed text until focused.
    var subdued = false
    /// Off for rows that are only there to be scrolled to: they still highlight when focused, but don't react to a press.
    var pressable = true

    func makeBody(configuration: Configuration) -> some View {
        ThemedButtonBody(configuration: configuration, idleFill: idleFill, subdued: subdued, pressable: pressable)
    }
}

private struct ThemedButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let idleFill: Bool
    let subdued: Bool
    let pressable: Bool

    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.appTheme) private var theme

    private let horizontalPadding: CGFloat = 32

    var body: some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 16)
            .foregroundStyle(focused ? AnyShapeStyle(theme.background) : subdued ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(focused ? theme.highlight : idleFill ? Color.primary.opacity(subdued ? 0.05 : 0.12) : .clear)
            )
            // Text-only buttons keep their text aligned with the content around them.
            .padding(.leading, idleFill ? 0 : -horizontalPadding)
            .scaleEffect(configuration.isPressed && pressable ? 0.97 : focused ? 1.06 : 1,
                         // Text-only buttons (section titles) grow from their left edge, so the text stays lined up with what's below.
                         anchor: idleFill ? .center : .leading)
            .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 18, y: 10)
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.15), value: focused)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
