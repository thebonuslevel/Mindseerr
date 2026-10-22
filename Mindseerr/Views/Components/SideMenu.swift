import SwiftUI

/// The app's sections, in menu order.
enum AppSection: Hashable, CaseIterable, Identifiable {
    case discover, search, watchlists, activity, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .discover: return String(localized: "Discover")
        case .search: return String(localized: "Search")
        case .watchlists: return String(localized: "Watchlists")
        case .activity: return String(localized: "Activity")
        case .settings: return String(localized: "Settings")
        }
    }

    /// The section's logo: a symbol drawn on a rounded badge in the theme's colors.
    var symbol: String {
        switch self {
        case .discover: return "sparkles.tv"
        case .search: return "magnifyingglass"
        case .watchlists: return "bookmark.fill"
        case .activity: return "arrow.down.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// A logo for a section: its symbol on a rounded badge.
struct SectionLogo: View {
    @Environment(\.appTheme) private var theme
    let section: AppSection
    var selected = false
    /// Drawn on the focused row's highlight, so the badge uses the dark color instead.
    var onHighlight = false
    var size: CGFloat = 64

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(selected || onHighlight ? theme.background : theme.highlight)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(onHighlight ? theme.background.opacity(0.14) : (selected ? theme.highlight : theme.highlight.opacity(0.18)))
            )
            .accessibilityHidden(true)
    }
}

/// The side menu. Collapsed, it's just each section's logo on a rounded badge, with no background. While it has focus it
/// opens into a floating rounded panel of frosted glass, with the logo and wordmark on top, each section's name, and the
/// focused row as a pill in the theme's highlight color.
struct SideMenu: View {
    @Environment(\.appTheme) private var theme
    @Binding var selection: AppSection
    /// Called when focus moves out of the menu into the page.
    var onLeave: () -> Void = {}
    /// Called when the section that's already showing is selected again, to send it back to its top level.
    var onReselect: () -> Void = {}
    /// Set while focus is anywhere in the menu, so the content can lean on it.
    @FocusState private var focused: AppSection?
    @Namespace private var menuSpace

    /// How far the collapsed menu reaches from the screen's left edge. Pages clear this much.
    static let collapsedWidth: CGFloat = 108
    private let panelInset: CGFloat = 24
    private let expandedPanelWidth: CGFloat = 430

    /// Settings > Look and Feel > Side Menu. Off keeps the menu as logos only, even while it has focus.
    static let expandsKey = "menuExpandsOnFocus"
    @AppStorage(SideMenu.expandsKey) private var expandsOnFocus = true

    private var expanded: Bool { focused != nil && expandsOnFocus }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 10 : 18) {
            HStack(spacing: 16) {
                Image("CthulhuMark")
                    .resizable().scaledToFit()
                    .frame(width: expanded ? 56 : 64, height: expanded ? 56 : 64)
                if expanded {
                    Image("MindseerrWordmark")
                        .resizable().scaledToFit()
                        .frame(height: 44)
                        .transition(.opacity)
                }
            }
            .padding(.leading, expanded ? 22 : 20)
            .padding(.top, expanded ? 22 : 0)
            .padding(.bottom, expanded ? 34 : 24)
            .accessibilityHidden(true)

            ForEach(AppSection.allCases.filter { $0 != .settings }) { row($0) }
            // Settings sits apart, at the bottom.
            Spacer(minLength: 0)
            row(.settings)
        }
        .padding(.horizontal, expanded ? 12 : 0)
        .padding(.bottom, expanded ? 22 : 40)
        .frame(width: expanded ? expandedPanelWidth : Self.collapsedWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { if expanded { panel } }
        .padding(.leading, expanded ? panelInset : 0)
        .padding(.top, expanded ? 36 : 70)
        .padding(.bottom, expanded ? 36 : 0)
        .frame(width: expanded ? panelInset + expandedPanelWidth : Self.collapsedWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.22), value: expanded)
        // A section opens only when it's selected. Moving out of the menu into the page sends the cursor to its first item.
        .onChange(of: focused) { old, new in
            if new == nil, old != nil { onLeave() }
        }
        // Right does what select does: sends the cursor to the page's first item.
        .onMoveCommand { direction in
            if direction == .right { onLeave() }
        }
        .focusSection()
        .focusScope(menuSpace)
    }

    private func row(_ section: AppSection) -> some View {
        Button {
            if section == selection { onReselect() } else { selection = section }
        } label: {
            MenuRowLabel(section: section, selected: section == selection, expanded: expanded)
        }
        .buttonStyle(MenuRowStyle(selected: section == selection, expanded: expanded))
        .focused($focused, equals: section)
        // Coming back from the page, the cursor lands on the section that's showing.
        .prefersDefaultFocus(section == selection, in: menuSpace)
        .accessibilityLabel(section.title)
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 52, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(theme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 52, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 52, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }
}

/// A menu row. Collapsed, there's no platter (the logo is the control). Expanded, a pill fills with the theme's
/// highlight color when focused, and a faint one marks the current section.
private struct MenuRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.appTheme) private var theme
    let selected: Bool
    let expanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(focused && expanded ? theme.background : .primary)
            .background(
                Capsule(style: .continuous)
                    .fill(expanded ? (focused ? theme.highlight : (selected ? Color.primary.opacity(0.14) : .clear)) : .clear)
            )
            .background(
                // Collapsed, the focused logo gets a soft highlight behind it.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(!expanded && focused ? theme.highlight.opacity(0.25) : .clear)
            )
            .scaleEffect(focused && !expanded ? 1.04 : 1)
            .padding(.horizontal, expanded ? 0 : 8)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct MenuRowLabel: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.isFocused) private var focused
    let section: AppSection
    let selected: Bool
    let expanded: Bool

    var body: some View {
        if expanded {
            HStack(spacing: 18) {
                Image(systemName: section.symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(focused ? theme.background : Color.primary)
                    .frame(width: 44, height: 44)
                Text(section.title).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .accessibilityHidden(true)
        } else {
            SectionLogo(section: section, selected: selected)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
        }
    }
}

extension View {
    /// For pages built on a `List`, which ignores the content margin the other pages use to clear the collapsed menu
    /// (it applies it only some of the time, so its rows jump and its section headers come and go). The page is pushed
    /// clear with padding instead, so a focused row's highlight doesn't run over the menu's icons.
    func clearsSideMenu() -> some View {
        padding(.leading, SideMenu.collapsedWidth - 40)
            .scrollClipDisabled()   // the focused row's highlight grows past the list's edge, into the padding
    }
}
