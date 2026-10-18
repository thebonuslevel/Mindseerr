import SwiftUI
import TVServices

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var confirmSignOut = false
    @State private var showAbout = false
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .gloam
    @State private var topShelfOn = TopShelfCache.isEnabled
    @State private var notifyOn = DownloadNotifications.isEnabled
    @State private var shelfSection = TopShelfCache.section

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        LabeledContent("Appearance", value: theme.name)
                    }
                    // Selecting the row flips it, like a switch.
                    Button {
                        topShelfOn.toggle()
                    } label: {
                        LabeledContent("Top Shelf", value: topShelfOn ? "On" : "Off")
                    }
                    NavigationLink {
                        TopShelfSectionView()
                    } label: {
                        LabeledContent("Top Shelf Shows", value: shelfSection.title)
                    }
                } header: {
                    Text("Look and Feel")
                } footer: {
                    Text("Shows titles from a section of Discover above the apps when Mindseerr is in the top row of the Home Screen. Choose which section under Top Shelf Shows. When off, the Mindseerr banner shows instead.")
                }
                Section {
                    // Selecting the row flips it, like a switch.
                    Button {
                        notifyOn.toggle()
                    } label: {
                        LabeledContent("Download Finished", value: notifyOn ? "On" : "Off")
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Shows a banner on any screen when a download for one of your requests finishes. tvOS doesn't allow banners while an app is closed, so it appears while Mindseerr is open.")
                }
                // Info rows are buttons that do nothing, so they take focus and get the themed cursor. That
                // lets the remote step up through them to the tab bar after scrolling down.
                Section("Account") {
                    infoRow("Signed in as", app.user?.name ?? "—")
                    if let method = app.signInMethod {
                        infoRow("Signed in with", method)
                    }
                    infoRow("Can manage requests", app.user?.canManageRequests == true ? "Yes" : "No")
                    if let email = app.user?.email, !email.isEmpty {
                        infoRow("Email", email)
                    }
                }
                Section("Server") {
                    infoRow("Address", app.serverURL?.absoluteString ?? "—")
                    infoRow("Seerr version", app.serverVersion ?? "—")
                }
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                    Button("Change Server") { Task { await app.changeServer() } }
                }
                Section {
                    // The logo opens the About page. A Button (not a NavigationLink) so the row gets no
                    // full-width focus platter; LogoLinkLabel draws a small outline instead.
                    Button { showAbout = true } label: {
                        LogoLinkLabel()
                    }
                    .buttonStyle(BareButtonStyle())
                    .listRowBackground(Color.clear)
                }
            }
            .themedBackground()
            // The choice is made on a pushed page; pick it up when coming back.
            .onAppear { shelfSection = TopShelfCache.section }
            .navigationDestination(isPresented: $showAbout) { AboutView() }
            .confirmationDialog("Sign out of Seerr?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .task { await app.refreshServerVersion() }
        .onChange(of: notifyOn) { _, on in DownloadNotifications.isEnabled = on }
        .onChange(of: topShelfOn) { _, on in
            TopShelfCache.isEnabled = on
            TVTopShelfContentProvider.topShelfContentDidChange() // ask tvOS to redraw it now
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        Button {} label: {
            LabeledContent(title, value: value)
        }
        .buttonStyle(ThemedButtonStyle(subdued: true))
    }
}

/// Its own page for choosing the app's theme.
struct AppearanceView: View {
    @Environment(AppState.self) private var app
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .gloam
    @FocusState private var highlighted: AppTheme?

    var body: some View {
        List {
            Section("Theme") {
                ForEach(AppTheme.allCases) { option in
                    Button {
                        theme = option
                    } label: {
                        HStack {
                            Text(option.name)
                            Spacer()
                            if option == theme {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .focused($highlighted, equals: option)
                }
            }
        }
        .themedBackground()
        .navigationTitle("Appearance")
        // Preview whichever theme is highlighted; selecting one saves it.
        .onChange(of: highlighted) { _, option in app.previewTheme = option }
        .onDisappear { app.previewTheme = nil }
    }
}

/// The logo at the bottom of Settings. While focused it grows 6% and gets an outline in the theme's
/// highlight color that follows the logo's own contour.
struct LogoLinkLabel: View {
    var height: CGFloat = 320

    @Environment(\.isFocused) private var focused
    @Environment(\.appTheme) private var theme

    private let outlineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            if focused {
                // A tinted silhouette of the logo copied around its edge makes an outline that hugs the shape.
                ForEach(0..<24, id: \.self) { step in
                    let angle = Double(step) / 24 * 2 * .pi
                    logo(tinted: true)
                        .offset(x: cos(angle) * outlineWidth, y: sin(angle) * outlineWidth)
                }
            }
            logo(tinted: false)
        }
        .padding(16)
        .scaleEffect(focused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("About Mindseerr")
    }

    private func logo(tinted: Bool) -> some View {
        Image("CthulhuMark")
            .renderingMode(tinted ? .template : .original)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(tinted ? AnyShapeStyle(theme.highlight) : AnyShapeStyle(.primary))
    }
}

/// Draws only the label, with no cursor, so a view can show its own focus look.
struct BareButtonStyle: ButtonStyle {
    /// Off for views that only need focus, not a press.
    var pressable = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed && pressable ? 0.85 : 1)
    }
}

/// Its own page for choosing which Discover section the Top Shelf shows.
struct TopShelfSectionView: View {
    @Environment(AppState.self) private var app
    @State private var chosen = TopShelfCache.section
    @State private var loading: TopShelfCache.Section?

    var body: some View {
        List {
            Section {
                ForEach(TopShelfCache.Section.allCases) { option in
                    Button { choose(option) } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if loading == option {
                                ProgressView()
                            } else if option == chosen {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } footer: {
                Text("The Top Shelf shows the first titles of the section you pick, as of the last time Mindseerr loaded it. Open Discover now and then to keep it fresh.")
            }
        }
        .themedBackground()
        .navigationTitle("Top Shelf Shows")
    }

    private func choose(_ option: TopShelfCache.Section) {
        chosen = option
        TopShelfCache.section = option
        Task {
            // A section is only saved once Discover has loaded it, so fetch it now if it hasn't been.
            if TopShelfCache.load(option).isEmpty || option == .suggested && app.suggestions.items.isEmpty {
                loading = option
                defer { loading = nil }
                if option == .suggested {
                    await app.suggestions.refresh(api: app.api, userId: app.user?.id)
                } else if let section = DiscoverSection(rawValue: option.rawValue),
                          let response = try? await app.api.discover(section, page: 1) {
                    MediaRowModel.saveForTopShelf(response.results.filter { $0.route != nil }, section: option)
                }
            }
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
    }
}
