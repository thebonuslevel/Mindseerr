import SwiftUI

/// What the request screen is for: the standard copy, or the separate 4K copy.
struct RequestTarget: Identifiable, Hashable {
    let is4k: Bool
    var id: Bool { is4k }
}

/// The full-screen request page for a series (pick seasons) or, for users who may choose request options,
/// a movie. With Advanced Requests it also offers the server, quality profile, root folder and (Sonarr)
/// language profile. Everything scrolls together, so the title and buttons move up as you go down.
struct RequestView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let detail: MediaDetail
    let type: MediaType
    let is4k: Bool
    let showsOptions: Bool
    /// The servers for this kind of request (standard or 4K), as Seerr lists them.
    let servers: [RequestServer]
    let onSubmit: ([Int]?, RequestOptions) -> Void

    @State private var selected: Set<Int>
    @State private var serverId: Int?
    @State private var serverDetails: RequestServerDetails?
    @State private var detailsError: String?
    @State private var profileId: Int?
    @State private var rootFolder: String?
    @State private var languageProfileId: Int?

    init(detail: MediaDetail, type: MediaType, is4k: Bool, showsOptions: Bool, servers: [RequestServer],
         onSubmit: @escaping ([Int]?, RequestOptions) -> Void) {
        self.detail = detail
        self.type = type
        self.is4k = is4k
        self.showsOptions = showsOptions
        self.servers = servers
        self.onSubmit = onSubmit
        _selected = State(initialValue: Set(detail.requestableSeasonNumbers(is4k: is4k)))
        _serverId = State(initialValue: (servers.first(where: \.isDefault) ?? servers.first)?.id)
    }

    private var open: [Int] { detail.requestableSeasonNumbers(is4k: is4k) }
    private var allSelected: Bool { !open.isEmpty && selected.count == open.count }
    private var server: RequestServer? { servers.first { $0.id == serverId } }
    private var quality: String { is4k ? String(localized: " in 4K", comment: "Appended to a request title: the 4K copy") : "" }

    private var requestTitle: String {
        guard type == .tv else { return "Request\(quality)" }
        return (selected.count == 1 ? String(localized: "Request 1 Season") : String(localized: "Request \(selected.count) Seasons")) + quality
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Request \(detail.displayTitle)\(quality)")
                        .font(.title2).bold()
                    if type == .tv {
                        Text("Choose the seasons to request. Seasons that are already requested or available\(is4k ? String(localized: " in 4K", comment: "Appended to a request title: the 4K copy") : "") are locked.")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 30) {
                    Button(action: submit) {
                        Label(requestTitle, systemImage: "plus.circle.fill")
                    }
                    .disabled(type == .tv && selected.isEmpty)

                    if type == .tv {
                        Button(allSelected ? "Deselect All" : "Select All") {
                            selected = allSelected ? [] : Set(open)
                        }
                        .disabled(open.isEmpty)
                    }

                    Button("Cancel", role: .cancel) { dismiss() }
                }
                .focusSection()

                if showsOptions { options }

                if type == .tv {
                    VStack(spacing: 16) {
                        ForEach(detail.regularSeasons) { season in
                            seasonRow(season)
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground()
        .task(id: serverId) { await loadServerDetails() }
    }

    // MARK: - Options

    @ViewBuilder
    private var options: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Request Options")
                .font(.headline)
            HStack(spacing: 24) {
                if servers.count > 1 {
                    optionMenu("Server", selection: $serverId, choices: servers.map { ($0.id, $0.name) })
                }
                if let details = serverDetails {
                    optionMenu("Quality", selection: $profileId, choices: details.profiles.map { ($0.id, $0.name) })
                    optionMenu("Root Folder", selection: $rootFolder,
                               choices: details.rootFolders.map { ($0.path, $0.label) },
                               shown: rootFolder.flatMap { path in details.rootFolders.first { $0.path == path }?.label })
                    if type == .tv, let languages = details.languageProfiles, !languages.isEmpty {
                        optionMenu("Language", selection: $languageProfileId, choices: languages.map { ($0.id, $0.name) })
                    }
                } else if detailsError == nil {
                    ProgressView()
                }
            }
            if let detailsError {
                Text(detailsError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .focusSection()
    }

    /// A tile showing the current choice; selecting it opens a menu with a checkmark on that choice.
    private func optionMenu<Value: Hashable>(_ title: String, selection: Binding<Value?>,
                                             choices: [(Value, String)], shown: String? = nil) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(choices, id: \.0) { choice in
                    Text(choice.1).tag(Optional(choice.0))
                }
            }
            .pickerStyle(.inline)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(shown ?? choices.first { $0.0 == selection.wrappedValue }?.1 ?? "Default")
                    .lineLimit(1)
            }
            .frame(minWidth: 220, alignment: .leading)
        }
        // Drawn with the themed cursor like every other button.
        .menuStyle(.button)
        .buttonStyle(ThemedButtonStyle())
    }

    private func loadServerDetails() async {
        guard showsOptions, let server else { return }
        serverDetails = nil
        detailsError = nil
        do {
            let details = try await app.api.requestServerDetails(for: type, serverId: server.id)
            serverDetails = details
            // Start from the server's own defaults, as Seerr does.
            profileId = details.profiles.first { $0.id == server.activeProfileId }?.id ?? details.profiles.first?.id
            rootFolder = details.rootFolders.first { $0.path == server.activeDirectory }?.path ?? details.rootFolders.first?.path
            languageProfileId = details.languageProfiles?.first { $0.id == server.activeLanguageProfileId }?.id
                ?? details.languageProfiles?.first?.id
        } catch {
            guard !Task.isCancelled else { return }
            detailsError = "Couldn't load this server's options, so Seerr's defaults will be used. \(AppState.friendly(error))"
        }
    }

    private func submit() {
        var options = RequestOptions(is4k: is4k)
        if showsOptions {
            options.serverId = serverId
            options.profileId = profileId
            options.rootFolder = rootFolder
            options.languageProfileId = languageProfileId
        }
        let seasons = type == .tv ? selected.sorted() : nil
        dismiss()
        onSubmit(seasons, options)
    }

    // MARK: - Seasons

    private func seasonRow(_ season: Season) -> some View {
        let number = season.seasonNumber
        let state = detail.state(ofSeason: number, is4k: is4k)
        let locked = state != .notRequested
        let isOn = selected.contains(number)

        return Button {
            if isOn { selected.remove(number) } else { selected.insert(number) }
        } label: {
            // Icon and text follow the button's colors, so they stay readable on the focus highlight.
            HStack(spacing: 28) {
                Image(systemName: locked ? "lock.fill" : (isOn ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(season.name ?? "Season \(number)")
                        .font(.headline)
                    if let count = season.episodeCount {
                        Text(count == 1 ? "1 episode" : "\(count) episodes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 20)
                if let label = state.label {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(locked)
    }
}
