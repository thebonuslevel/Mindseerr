import SwiftUI

// MARK: - Adding a service

/// Asks for a Sonarr, Radarr or qBittorrent address and sign-in, checks them, then hands back the service.
struct AddArrServiceView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (ArrService) -> Void

    @State private var kind: ArrKind = .radarr
    @State private var name = ""
    @State private var address = ""
    @State private var apiKey = ""
    @State private var username = ""
    @State private var password = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        // Scrolls, so the longer clients' forms and hints never run off the bottom of the screen.
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            Text("Add a Download Service")
                .font(.largeTitle).bold()
            Text("Connect Sonarr and Radarr to see what's downloading for each Seerr request. qBittorrent, Deluge, Transmission and SABnzbd work on their own, reading progress straight from the client, and alongside Sonarr and Radarr they add pause, resume and cancel.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 1300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)   // wrap onto as many lines as it needs

            Picker("Service", selection: $kind) {
                ForEach(ArrKind.allCases) { option in
                    Text(option.name).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 1000)

            VStack(alignment: .leading, spacing: 16) {
                TextField("Name (optional), like \(kind.name) 4K", text: $name)
                TextField("Address, like http://192.168.1.10:\(kind.defaultPortText)", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                if kind.usesAPIKey {
                    TextField("API key", text: $apiKey)
                        .textContentType(.password)
                } else if kind.isDownloadClient {
                    if kind.usesUsername {
                        TextField(kind == .transmission ? "Username (if it has one)" : "Web UI username", text: $username)
                            .textContentType(.username)
                    }
                    SecureField(kind == .transmission ? "Password (if it has one)" : "Web UI password", text: $password)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(maxWidth: 1000)

            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 1300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 1300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 30) {
                Button(action: save) {
                    Label("Test & Save", systemImage: "checkmark.circle")
                }
                .disabled(checking || address.trimmed.isEmpty || !hasCredentials)

                Button("Cancel", role: .cancel) { dismiss() }

                if checking {
                    ProgressView()
                    Text("Connecting to \(kind.name)…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 50)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .themedBackground()
    }

    /// Sonarr and Radarr need an API key; qBittorrent and Deluge a password; Transmission only if it has one set.
    private var hasCredentials: Bool {
        kind.usesAPIKey ? !apiKey.trimmed.isEmpty : (!kind.requiresPassword || !password.isEmpty)
    }

    private var hint: String {
        switch kind {
        case .sonarr, .radarr:
            return """
            The API key is in \(kind.name) under Settings → General → Security.

            If \(kind.name) uses a URL base, include it in the address, like http://nas:\(kind.defaultPortText)/\(kind.rawValue).
            """
        case .qbittorrent:
            return """
            Use the address and sign-in of qBittorrent's Web UI (Tools → Options → Web UI).

            Add the same qBittorrent that Sonarr and Radarr use, and its torrents are matched to their downloads. Without them, its unfinished torrents are matched to titles by release name.
            """
        case .deluge:
            return """
            Use the address of Deluge's Web UI and its password (the default is “deluge”).

            The Web UI has to be connected to a daemon under Connection Manager.
            """
        case .transmission:
            return """
            Use Transmission's address, like http://192.168.1.10:9091.

            Enter a username and password only if you turned RPC authentication on.
            """
        case .sabnzbd:
            return """
            The API key is in SABnzbd under Config → General → Security. Use the full API key, not the NZB key.

            Add the same SABnzbd that Sonarr and Radarr use, and its downloads are matched to their requests. Without them, its downloads are matched to titles by name.
            """
        }
    }

    private func save() {
        guard let url = ArrService.normalizedURL(from: address) else {
            error = String(localized: "Enter the \(kind.name) server's address, like http://192.168.1.10:\(kind.defaultPortText).")
            return
        }
        let service = ArrService(kind: kind,
                                 name: name.trimmed.isEmpty ? kind.name : name.trimmed,
                                 baseURL: url,
                                 apiKey: kind.usesAPIKey ? apiKey.trimmed : "",
                                 username: kind.usesUsername ? username.trimmed : nil,
                                 password: kind.isDownloadClient && !kind.usesAPIKey ? password : nil)
        Task {
            checking = true
            error = nil
            defer { checking = false }
            do {
                if kind.isDownloadClient {
                    _ = try await TorrentClients.make(for: service).checkConnection()
                } else {
                    _ = try await ArrClient.checkConnection(service)
                }
                onSave(service)
                dismiss()
            } catch {
                self.error = AppState.friendly(error)
            }
        }
    }
}

// MARK: - A download

/// One active download, with the Seerr request it belongs to when there is one.
struct DownloadRow: View {
    @Environment(AppState.self) private var app
    let download: ArrDownload
    let request: MediaRequest?
    /// Asks the Admin screen to confirm and cancel this download.
    let onCancel: () -> Void

    @State private var detail: MediaDetail?
    /// Whether the title (not the pause or cancel button) has focus, which lights up the whole panel.
    @State private var titleFocused = false
    @FocusState private var plainFocused: Bool
    @Environment(\.appTheme) private var theme
    /// Sonarr v3 doesn't report TMDB IDs, so fall back to the matched request's title.
    private var route: MediaRoute? { download.route ?? request?.route }

    var body: some View {
        // One panel holds the title and its buttons; selecting the title opens it, and the buttons sit inside the panel.
        HStack(spacing: 20) {
            if let route {
                NavigationLink(value: route) { content }
                    .buttonStyle(DownloadLinkStyle(isFocused: $titleFocused))
            } else {
                // Still focusable, so the list can be scrolled with the remote.
                content
                    .padding(12)
                    .focusable()
                    .focused($plainFocused)
                    .onChange(of: plainFocused) { _, on in titleFocused = on }
            }
            DownloadControlButtons(downloads: [download], onCancel: onCancel)
        }
        .padding(14)
        .background(titleFocused ? theme.highlight.opacity(0.3) : Color.primary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: titleFocused)
        .focusSection()
        .task(id: route) {
            if let route { detail = try? await app.api.detail(for: route) }
        }
    }

    private var content: some View {
        HStack(spacing: 30) {
            PosterImage(url: TMDBImage.url(detail?.posterPath, size: .poster), title: download.title)
                .frame(width: 80, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                Text(detail?.displayTitle ?? download.title)
                    .font(.headline)
                    .lineLimit(1)
                // Which season / episode, on its own line so it stands out.
                if let label = download.episodeLabel {
                    Text(label)
                        .font(.callout).fontWeight(.semibold)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: download.progress)
                    .frame(maxWidth: 800)
                HStack(spacing: 16) {
                    Text(download.phase.label)
                        .foregroundStyle(download.phase.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    Text("\(Int((download.progress * 100).rounded()))%")
                    if let timeLeft = download.timeLeftText { Text(timeLeft) }
                }
                .font(.caption)
                .monospacedDigit()
                if let message = download.message, download.phase.isProblem {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let request {
            parts.append("Requested by \(request.requestedBy?.name ?? "someone")")
        } else {
            parts.append("Not requested through Seerr")
        }
        parts.append(download.serviceName)
        return parts.joined(separator: "  ·  ")
    }
}

/// The look of a title inside a download panel: no platter of its own. It reports whether it has focus, and the
/// panel around it lights up as a whole.
struct DownloadLinkStyle: ButtonStyle {
    @Binding var isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        FocusReporter(isFocused: $isFocused) { configuration.label.padding(12) }
    }

    private struct FocusReporter<Content: View>: View {
        @Binding var isFocused: Bool
        @ViewBuilder let content: Content
        @Environment(\.isFocused) private var focused

        var body: some View {
            content.onChange(of: focused) { _, on in isFocused = on }
        }
    }
}

/// A compact progress line for a request row whose title is downloading.
struct DownloadProgressLine: View {
    let download: ArrDownload
    var barWidth: CGFloat = 300
    /// Name the Sonarr/Radarr server, for places that don't already say where it's from.
    var showsService = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Sonarr downloads lead with the season / episode they cover.
            if let label = download.episodeLabel {
                Text(label)
                    .font(.caption).fontWeight(.semibold)
                    .lineLimit(1)
            }
            HStack(spacing: 16) {
                ProgressView(value: download.progress)
                    .frame(width: barWidth)
                Text(text)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(download.phase.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
    }

    private var text: String {
        var parts = ["\(download.phase.label) \(Int((download.progress * 100).rounded()))%"]
        if let timeLeft = download.timeLeftText { parts.append(timeLeft) }
        if showsService { parts.append(download.serviceName) }
        return parts.joined(separator: " · ")
    }
}

/// A status tag for a Sonarr/Radarr download, showing its actual state ("Downloading", "Paused", …)
/// in a color that matches it.
struct DownloadPhaseBadge: View {
    let phase: ArrDownload.Phase

    var body: some View {
        Pill(text: LocalizedStringKey(phase.label), color: color)
    }

    private var color: Color {
        switch phase {
        case .downloading: return Color(red: 0.36, green: 0.66, blue: 0.47) // soft green
        case .importing: return .blue
        case .queued, .delayed: return .gray
        case .paused: return Color(red: 0.80, green: 0.62, blue: 0.20)      // muted amber
        case .warning: return .orange
        case .failed: return .red
        case .other: return .gray
        }
    }
}

// MARK: - Controls

/// Pause/resume and cancel buttons for one title's downloads. Pause only shows when Mindseerr can control the
/// torrent (it's on a connected qBittorrent); cancel always works through Sonarr/Radarr and asks the caller to confirm.
struct DownloadControlButtons: View {
    @Environment(AppState.self) private var app
    let downloads: [ArrDownload]
    let onCancel: () -> Void

    @State private var pausing = false
    @State private var notice: String?

    private var paused: Bool { downloads.allSatisfy { $0.phase == .paused } }

    var body: some View {
        HStack(spacing: 20) {
            if app.downloads.canPause(downloads) {
                Button {
                    guard !pausing else { return }
                    pausing = true
                    Task {
                        defer { pausing = false }
                        do { try await app.downloads.togglePause(downloads) } catch { notice = AppState.friendly(error) }
                    }
                } label: {
                    if pausing {
                        ProgressView()
                    } else {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                    }
                }
                .accessibilityLabel(paused ? "Resume download" : "Pause download")
            }
            if app.downloads.canCancel(downloads) {
                Button(action: onCancel) {
                    Image(systemName: "slash.circle")
                }
                .accessibilityLabel("Cancel download")
            }
        }
        .fixedSize()
        .alert("Download", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }
}
