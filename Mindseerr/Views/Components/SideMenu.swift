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

/// The side menu: every section with its logo and name while it has focus, and only the logos otherwise.
struct SideMenu: View {
    @Environment(\.appTheme) private var theme
    @Binding var selection: AppSection
    /// Called when focus moves out of the menu into the page.
    var onLeave: () -> Void = {}
    /// Called when the section that's already showing is selected again, to send it back to its top level.
    var onReselect: () -> Void = {}
    /// Set while focus is anywhere in the menu, so the content can lean on it.
    @FocusState private var focused: AppSection?

    static let collapsedWidth: CGFloat = 108
    private let expandedWidth: CGFloat = 400

    /// Settings > Look and Feel > Menu. Off keeps the menu as logos only, even while it has focus.
    static let expandsKey = "menuExpandsOnFocus"
    @AppStorage(SideMenu.expandsKey) private var expandsOnFocus = true

    private var expanded: Bool { focused != nil && expandsOnFocus }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image("CthulhuMark")
                    .resizable().scaledToFit()
                    .frame(width: 64, height: 64)
                if expanded {
                    Image("MindseerrWordmark")
                        .resizable().scaledToFit()
                        .frame(height: 48)
                }
            }
            .padding(.leading, 20)   // the same distance from the edge as the rows' logos (8 outside + 12 inside)
            .padding(.bottom, 24)
            .accessibilityHidden(true)

            ForEach(AppSection.allCases) { section in
                Button {
                    if section == selection { onReselect() } else { selection = section }
                } label: {
                    MenuRowLabel(section: section, selected: section == selection, expanded: expanded)
                }
                .buttonStyle(MenuRowStyle(selected: section == selection, expanded: expanded))
                .focused($focused, equals: section)
                .accessibilityLabel(section.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 70)
        .frame(width: expanded ? expandedWidth : Self.collapsedWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            // Fully clear while collapsed. Opened, it's a blurred panel with only a light tint of the theme color.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(theme.background.opacity(0.3))
                .opacity(expanded ? 1 : 0)
                .ignoresSafeArea()
        }
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
    }
}

/// A menu row: no platter while collapsed (the logo is the control), a rounded highlight when expanded.
private struct MenuRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.appTheme) private var theme
    let selected: Bool
    let expanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .foregroundStyle(focused && expanded ? theme.background : .primary)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(focused ? (expanded ? theme.highlight : theme.highlight.opacity(0.25))
                                  : (selected && expanded ? Color.primary.opacity(0.12) : .clear))
            )
            .scaleEffect(focused ? 1.04 : 1)
            .padding(.horizontal, 8)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct MenuRowLabel: View {
    @Environment(\.isFocused) private var focused
    let section: AppSection
    let selected: Bool
    let expanded: Bool

    var body: some View {
        HStack(spacing: 18) {
            SectionLogo(section: section, selected: selected && !expanded, onHighlight: focused && expanded)
            if expanded {
                Text(section.title).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
            }
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
