import SwiftUI

// MARK: - Adding a service

/// Asks for a Sonarr or Radarr address and API key, checks them, then hands back the service.
struct AddArrServiceView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (ArrService) -> Void

    @State private var kind: ArrKind = .radarr
    @State private var name = ""
    @State private var address = ""
    @State private var apiKey = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Add Sonarr or Radarr")
                .font(.largeTitle).bold()
            Text("Connect the servers that download your requests to see what's downloading for each Seerr request.")
                .foregroundStyle(.secondary)

            Picker("Service", selection: $kind) {
                ForEach(ArrKind.allCases) { option in
                    Text(option.name).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 600)

            VStack(alignment: .leading, spacing: 20) {
                TextField("Name (optional), like \(kind.name) 4K", text: $name)
                TextField("Address, like http://192.168.1.10:\(kind.defaultPortText)", text: $address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                TextField("API key", text: $apiKey)
                    .textContentType(.password)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(maxWidth: 1000)

            Text("The API key is in \(kind.name) under Settings → General → Security. If \(kind.name) uses a URL base, include it in the address (like http://nas:\(kind.defaultPortText)/\(kind.rawValue)).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 1400, alignment: .leading)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 1400, alignment: .leading)
            }

            HStack(spacing: 30) {
                Button(action: save) {
                    Label("Test & Save", systemImage: "checkmark.circle")
                }
                .disabled(checking || address.trimmed.isEmpty || apiKey.trimmed.isEmpty)

                Button("Cancel", role: .cancel) { dismiss() }

                if checking {
                    ProgressView()
                    Text("Connecting to \(kind.name)…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .themedBackground()
    }

    private func save() {
        guard let url = ArrService.normalizedURL(from: address) else {
            error = "Enter the \(kind.name) server's address, like http://192.168.1.10:\(kind.defaultPortText)."
            return
        }
        let service = ArrService(kind: kind,
                                 name: name.trimmed.isEmpty ? kind.name : name.trimmed,
                                 baseURL: url,
                                 apiKey: apiKey.trimmed)
        Task {
            checking = true
            error = nil
            defer { checking = false }
            do {
                _ = try await ArrClient.checkConnection(service)
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

    @State private var detail: MediaDetail?

    /// Sonarr v3 doesn't report TMDB IDs, so fall back to the matched request's title.
    private var route: MediaRoute? { download.route ?? request?.route }

    var body: some View {
        Group {
            if let route {
                NavigationLink(value: route) { content }
            } else {
                // Still focusable, so the list can be scrolled with the remote.
                content
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    .focusable()
            }
        }
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
        Pill(text: phase.label, color: color)
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
