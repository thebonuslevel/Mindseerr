import Foundation

/// Talks to Transmission through its RPC (`/transmission/rpc`). It signs requests with HTTP Basic (when a
/// username and password are set) and a session ID header that Transmission hands out on the first request.
actor TransmissionClient: TorrentClient {
    private let service: ArrService
    private let session = TorrentHTTP.session()
    private var sessionID: String?

    init(service: ArrService) {
        self.service = service
    }

    /// The RPC address: the one the user gave if it already ends in `rpc`, otherwise `/transmission/rpc` on it.
    private var rpcURL: URL {
        service.baseURL.path.hasSuffix("rpc") ? service.baseURL
            : service.baseURL.appendingPathComponent("transmission").appendingPathComponent("rpc")
    }

    // MARK: - Reading

    func checkConnection() async throws -> String {
        let arguments = try await call("session-get", [:])
        return arguments["version"] as? String ?? "Transmission"
    }

    func torrents() async throws -> [TorrentInfo] {
        let fields = ["hashString", "name", "percentDone", "status", "eta", "error", "errorString"]
        let arguments = try await call("torrent-get", ["fields": fields])
        guard let list = arguments["torrents"] as? [[String: Any]] else { throw TorrentHTTP.confused(service) }
        return list.compactMap { torrent in
            guard let hash = torrent["hashString"] as? String else { return nil }
            let progress = min(max(torrent["percentDone"] as? Double ?? 0, 0), 1)
            let status = torrent["status"] as? Int ?? 0
            let failed = (torrent["error"] as? Int ?? 0) != 0
            let eta = torrent["eta"] as? Int
            // 0 stopped, 1 waiting to check, 2 checking, 3 waiting to download, 4 downloading, 5 waiting to seed, 6 seeding
            let phase: ArrDownload.Phase
            switch status {
            case 0: phase = failed ? .failed : .paused
            case 1, 2: phase = .other("Checking")
            case 3: phase = .queued
            default: phase = failed ? .failed : .downloading
            }
            return TorrentInfo(hash: hash.lowercased(), name: torrent["name"] as? String ?? hash, progress: progress,
                               phase: failed ? .failed : phase,
                               state: failed ? (torrent["errorString"] as? String ?? "error") : "status \(status)",
                               secondsLeft: eta.flatMap { $0 > 0 ? $0 : nil },
                               isFinished: progress >= 1)
        }
    }

    // MARK: - Controlling

    func pause(hash: String) async throws {
        _ = try await call("torrent-stop", ["ids": [hash]])
    }

    func resume(hash: String) async throws {
        _ = try await call("torrent-start", ["ids": [hash]])
    }

    func delete(hash: String) async throws {
        _ = try await call("torrent-remove", ["ids": [hash], "delete-local-data": true])
    }

    // MARK: - Plumbing

    /// One RPC call. Transmission answers the first request (or an expired session ID) with a 409 and the ID
    /// to use, so the call is made again with it.
    private func call(_ method: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        var (data, status) = try await post(method, arguments)
        if status == 409 {
            (data, status) = try await post(method, arguments)
        }
        switch status {
        case 200: break
        case 401: throw APIError(status: 401, message: "\(service.name) rejected the username or password.")
        case 404: throw APIError(status: 404, message: "\(service.name) didn't recognize that address. Use Transmission's address, like http://192.168.1.10:9091.")
        case 403: throw APIError(status: 403, message: "\(service.name) refused the request. Check its RPC whitelist in settings.json.")
        default: throw APIError(status: status, message: "\(service.name) returned error \(status).")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TorrentHTTP.confused(service)
        }
        if let result = object["result"] as? String, result != "success" {
            throw APIError(status: 0, message: "\(service.name) said: \(result)")
        }
        return object["arguments"] as? [String: Any] ?? [:]
    }

    private func post(_ method: String, _ arguments: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "X-Transmission-Session-Id") }
        if let user = service.username, !user.isEmpty {
            let login = Data("\(user):\(service.password ?? "")".utf8).base64EncodedString()
            request.setValue("Basic \(login)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["method": method, "arguments": arguments])
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 409, let id = http?.value(forHTTPHeaderField: "X-Transmission-Session-Id") {
                sessionID = id
            }
            return (data, http?.statusCode ?? 0)
        } catch let error as URLError where error.code != .cancelled {
            throw TorrentHTTP.unreachable(service)
        }
    }
}
