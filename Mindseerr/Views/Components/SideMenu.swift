import SwiftUI

/// The app's sections, in menu order.
enum AppSection: Hashable, CaseIterable, Identifiable {
    case discover, search, watchlists, activity, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .discover: return "Discover"
        case .search: return "Search"
        case .watchlists: return "Watchlists"
        case .activity: return "Activity"
        case .settings: return "Settings"
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
    /// Set while focus is anywhere in the menu, so the content can lean on it.
    @FocusState private var focused: AppSection?
    @State private var pendingSwitch: Task<Void, Never>?
    @State private var lastSwitch = Date.distantPast

    static let collapsedWidth: CGFloat = 108
    private let expandedWidth: CGFloat = 400

    private var expanded: Bool { focused != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image("CthulhuMark")
                    .resizable().scaledToFit()
                    .frame(width: 64, height: 64)
                if expanded {
                    Text("Mindseerr").font(.title3).fontWeight(.bold).lineLimit(1)
                }
            }
            .padding(.leading, 20)   // the same distance from the edge as the rows' logos (8 outside + 12 inside)
            .padding(.bottom, 24)
            .accessibilityHidden(true)

            ForEach(AppSection.allCases) { section in
                Button {
                    // Clicking opens the section and takes the cursor straight to its first item.
                    pendingSwitch?.cancel()
                    lastSwitch = .distantPast
                    selection = section
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))   // let the page build first
                        onLeave()
                    }
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
        // Resting on a section for a moment switches to it (so moving quickly past one doesn't rebuild its page).
        // Moving out into the page sends the cursor to its first item.
        .onChange(of: focused) { old, new in
            pendingSwitch?.cancel()
            if let new {
                guard new != selection else { return }
                pendingSwitch = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, focused == new else { return }
                    lastSwitch = Date()
                    selection = new
                }
            } else if old != nil {
                // A page that has just appeared can grab focus for itself (Search's keyboard does). That isn't the user
                // moving right, so give the cursor back to the menu instead of stranding it in the new page.
                if Date().timeIntervalSince(lastSwitch) < 0.8 {
                    Task {
                        try? await Task.sleep(for: .milliseconds(60))
                        focused = selection
                    }
                } else {
                    onLeave()
                }
            }
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
