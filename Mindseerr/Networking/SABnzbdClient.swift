import Foundation

/// Talks to SABnzbd's HTTP API (`/api`), signing in with the API key. Its downloads are NZBs, so an NZB's ID
/// (`SABnzbd_nzo_...`) stands in for the torrent hash: it is also the ID Sonarr and Radarr keep for the download.
struct SABnzbdClient: TorrentClient {
    private let service: ArrService
    private let session = TorrentHTTP.session()

    init(service: ArrService) {
        self.service = service
    }

    // MARK: - Reading

    func checkConnection() async throws -> String {
        // The queue needs the API key (the version doesn't), so reading it proves the key works.
        _ = try await call(["mode": "queue", "limit": "1"])
        let version = try? await call(["mode": "version"])
        return version?["version"] as? String ?? "SABnzbd"
    }

    func torrents() async throws -> [TorrentInfo] {
        let root = try await call(["mode": "queue"])
        guard let queue = root["queue"] as? [String: Any], let slots = queue["slots"] as? [[String: Any]] else {
            throw TorrentHTTP.confused(service)
        }
        let allPaused = queue["paused"] as? Bool == true
        return slots.compactMap { slot in
            guard let id = slot["nzo_id"] as? String else { return nil }
            let state = slot["status"] as? String ?? "Unknown"
            let progress = min(max((Double(slot["percentage"] as? String ?? "") ?? 0) / 100, 0), 1)
            return TorrentInfo(hash: id.lowercased(), name: slot["filename"] as? String ?? id, progress: progress,
                               phase: Self.phase(of: state, queuePaused: allPaused),
                               state: state, secondsLeft: Self.seconds(from: slot["timeleft"] as? String),
                               isFinished: false)
        }
    }

    private static func phase(of state: String, queuePaused: Bool) -> ArrDownload.Phase {
        switch state {
        case "Paused": return .paused
        case "Queued": return queuePaused ? .paused : .queued
        case "Failed": return .failed
        case "Downloading": return queuePaused ? .paused : .downloading
        case "Fetching", "Grabbing", "Propagating": return .other(state)
        case "Verifying", "Repairing", "Extracting", "Moving", "Running": return .importing
        default: return .downloading
        }
    }

    /// SABnzbd writes the time left as "H:MM:SS" (with a leading days field for long ones).
    private static func seconds(from text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let total = parts.reduce(0) { $0 * 60 + $1 }   // good for H:MM:SS and MM:SS
        let seconds = parts.count == 4 ? ((parts[0] * 24 + parts[1]) * 60 + parts[2]) * 60 + parts[3] : total
        return seconds > 0 ? seconds : nil
    }

    // MARK: - Controlling

    func pause(hash: String) async throws {
        _ = try await call(["mode": "queue", "name": "pause", "value": Self.nzoID(hash)])
    }

    func resume(hash: String) async throws {
        _ = try await call(["mode": "queue", "name": "resume", "value": Self.nzoID(hash)])
    }

    func delete(hash: String) async throws {
        _ = try await call(["mode": "queue", "name": "delete", "value": Self.nzoID(hash), "del_files": "1"])
    }

    /// The app keeps IDs lowercased; SABnzbd's own start with a capitalized "SABnzbd".
    private static func nzoID(_ id: String) -> String {
        let prefix = "sabnzbd_nzo_"
        guard id.lowercased().hasPrefix(prefix) else { return id }
        return "SABnzbd_nzo_" + id.dropFirst(prefix.count)
    }

    // MARK: - Plumbing

    /// One API call. SABnzbd answers `{"status": false, "error": ...}` for a bad key or request.
    private func call(_ query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(url: service.baseURL.appendingPathComponent("api"), resolvingAgainstBaseURL: false)
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items += [URLQueryItem(name: "output", value: "json"), URLQueryItem(name: "apikey", value: service.apiKey)]
        components?.queryItems = items
        guard let url = components?.url else { throw TorrentHTTP.unreachable(service) }

        let data: Data
        let status: Int
        do {
            let (body, response) = try await session.data(from: url)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch let error as URLError where error.code != .cancelled {
            throw TorrentHTTP.unreachable(service)
        }
        guard status == 200 else {
            throw APIError(status: status, message: String(localized: "\(service.name) returned error \(status)."))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TorrentHTTP.confused(service)
        }
        if let message = object["error"] as? String {
            if message.localizedCaseInsensitiveContains("api key") {
                throw APIError(status: 401, message: String(localized: "\(service.name) rejected the API key. Copy it again from Config → General in SABnzbd."))
            }
            throw APIError(status: 0, message: String(localized: "\(service.name) said: \(message)"))
        }
        return object
    }
}
