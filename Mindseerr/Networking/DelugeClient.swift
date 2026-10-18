import Foundation

/// Talks to Deluge through its Web UI's JSON-RPC (`/json`). The Web UI has a password and no username. It
/// signs in with a session cookie, and has to be connected to a Deluge daemon before it can list torrents.
actor DelugeClient: TorrentClient {
    private let service: ArrService
    private let session = TorrentHTTP.session()
    private var signedIn = false
    private var requestID = 0

    init(service: ArrService) {
        self.service = service
    }

    // MARK: - Reading

    func checkConnection() async throws -> String {
        try await ensureReady()
        // Deluge 2 calls it daemon.get_version, Deluge 1.3 daemon.info.
        for method in ["daemon.get_version", "daemon.info"] {
            if let version = try? await rpc(method, []) as? String { return version }
        }
        return "Deluge"
    }

    func torrents() async throws -> [TorrentInfo] {
        let result = try await call("web.update_ui", [["name", "progress", "state", "eta", "message"], [String: String]()])
        guard let root = result as? [String: Any], let list = root["torrents"] as? [String: [String: Any]] else {
            throw TorrentHTTP.confused(service)
        }
        // Deluge returns a dictionary, so sort to keep the list from reshuffling on every refresh.
        return list.map { hash, fields in
            let state = fields["state"] as? String ?? "Unknown"
            // Deluge reports progress as 0...100.
            let progress = min(max((fields["progress"] as? Double ?? Double(fields["progress"] as? Int ?? 0)) / 100, 0), 1)
            let eta = (fields["eta"] as? Int) ?? (fields["eta"] as? Double).map(Int.init)
            return TorrentInfo(hash: hash.lowercased(), name: fields["name"] as? String ?? hash, progress: progress,
                               phase: Self.phase(of: state), state: state,
                               secondsLeft: eta.flatMap { $0 > 0 ? $0 : nil },
                               isFinished: state == "Seeding" || progress >= 1)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func phase(of state: String) -> ArrDownload.Phase {
        switch state {
        case "Paused": return .paused
        case "Queued": return .queued
        case "Error": return .failed
        case "Checking", "Allocating", "Moving": return .other(state)
        default: return .downloading
        }
    }

    // MARK: - Controlling

    func pause(hash: String) async throws {
        try await control(hash, "core.pause_torrents", fallback: "core.pause_torrent")
    }

    func resume(hash: String) async throws {
        try await control(hash, "core.resume_torrents", fallback: "core.resume_torrent")
    }

    func delete(hash: String) async throws {
        _ = try await call("core.remove_torrent", [hash, true])
    }

    /// Deluge 2 takes a list of torrents, Deluge 1.3 had a singular name for the same call.
    private func control(_ hash: String, _ method: String, fallback: String) async throws {
        do {
            _ = try await call(method, [[hash]])
        } catch let error as APIError where error.status == -1 {
            _ = try await call(fallback, [[hash]])
        }
    }

    // MARK: - Plumbing

    /// Signs in and connects the Web UI to a daemon, if either isn't done yet.
    private func ensureReady() async throws {
        if !signedIn {
            guard try await rpc("auth.login", [service.password ?? ""]) as? Bool == true else {
                throw APIError(status: 401, message: "\(service.name) rejected the password. It's the one for Deluge's Web UI (the default is “deluge”).")
            }
            signedIn = true
        }
        if try await rpc("web.connected", []) as? Bool != true {
            // The Web UI has to be attached to a daemon before it can list torrents.
            guard let hosts = try await rpc("web.get_hosts", []) as? [[Any]],
                  let hostID = hosts.first?.first as? String else {
                throw APIError(status: 0, message: "\(service.name) isn't connected to a Deluge daemon. Open its Web UI and choose one under Connection Manager.")
            }
            _ = try await rpc("web.connect", [hostID])
        }
    }

    /// A call that signs in first if needed, and once more if the session has expired.
    private func call(_ method: String, _ params: [Any]) async throws -> Any? {
        try await ensureReady()
        do {
            return try await rpc(method, params)
        } catch let error as APIError where error.status == 401 {
            signedIn = false
            try await ensureReady()
            return try await rpc(method, params)
        }
    }

    /// One JSON-RPC request. A Deluge error becomes an `APIError` (status 401 for "not authenticated",
    /// -1 for an unknown method).
    private func rpc(_ method: String, _ params: [Any]) async throws -> Any? {
        requestID += 1
        var request = URLRequest(url: service.baseURL.appendingPathComponent("json"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["method": method, "params": params, "id": requestID])

        let data: Data
        let status: Int
        do {
            let (body, response) = try await session.data(for: request)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch let error as URLError where error.code != .cancelled {
            throw TorrentHTTP.unreachable(service)
        }
        guard status == 200 else {
            throw APIError(status: status, message: status == 404
                ? "\(service.name) didn't recognize that address. Use Deluge's Web UI address, like http://192.168.1.10:8112."
                : "\(service.name) returned error \(status).")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TorrentHTTP.confused(service)
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown error"
            if message.localizedCaseInsensitiveContains("not authenticated") {
                throw APIError(status: 401, message: "\(service.name) signed us out. Try again.")
            }
            if message.localizedCaseInsensitiveContains("unknown method") || message.localizedCaseInsensitiveContains("has no attribute") {
                throw APIError(status: -1, message: "\(service.name): \(message)")
            }
            throw APIError(status: 0, message: "\(service.name) said: \(message)")
        }
        return object["result"]
    }
}
