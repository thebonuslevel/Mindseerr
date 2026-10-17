import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var confirmSignOut = false
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .abyss

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Signed in as", value: app.user?.name ?? "—")
                    if let method = app.signInMethod {
                        LabeledContent("Signed in with", value: method)
                    }
                    LabeledContent("Can manage requests", value: app.user?.canManageRequests == true ? "Yes" : "No")
                    if let email = app.user?.email, !email.isEmpty {
                        LabeledContent("Email", value: email)
                    }
                }
                Section("Server") {
                    LabeledContent("Address", value: app.serverURL?.absoluteString ?? "—")
                    LabeledContent("Seerr version", value: app.serverVersion ?? "—")
                }
                Section {
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        LabeledContent("Appearance", value: theme.name)
                    }
                }
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                    Button("Change Server") { Task { await app.changeServer() } }
                }
            }
            .themedBackground()
            .navigationTitle("Settings")
            .confirmationDialog("Sign out of Seerr?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .task { await app.refreshServerVersion() }
    }
}

/// Its own page for choosing the app's theme.
struct AppearanceView: View {
    @Environment(AppState.self) private var app
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .abyss
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
