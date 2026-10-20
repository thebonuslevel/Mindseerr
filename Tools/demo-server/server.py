#!/usr/bin/env python3
"""Stand-in Seerr + Sonarr + Radarr server with invented content, for README screenshots.

    python3 server.py [port] [art dir]     (defaults: 8765, /tmp/oppdemo/img)

Then launch a Debug build with MINDSEERR_DEMO=http://127.0.0.1:<port>. Almost read-only: anything that
would change data (approve, request, delete...) is refused. The exceptions are the download controls,
which only change in-memory state: pausing/resuming or deleting a torrent on the fake qBittorrent, Deluge or
Transmission (all three show the same torrents; pick one with MINDSEERR_DEMO_SERVICES) and removing a
download from the Sonarr/Radarr queue. Restart the server to reset them.
"""
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
ART = sys.argv[2] if len(sys.argv) > 2 else "/tmp/oppdemo/img"
CATALOG = json.load(open(os.path.join(HERE, "catalog.json")))
TITLES = {t["id"]: t for t in CATALOG["titles"]}
USERS = {int(k): v for k, v in CATALOG["users"].items()}
MEDIA_STATUS = {"pending": 2, "processing": 3, "available": 5}
PEOPLE = ["Ada Morrow", "Felix Okafor", "June Halloway", "Ravi Castellan", "Odette Brandt", "Silas Wren",
          "Mina Calder", "Tobias Reyes", "Clara Vance", "Hugo Lindqvist", "Ines Marlowe", "Dex Adebayo"]
ROLES = ["The Keeper", "Captain Hale", "Dr. Ivers", "Nell", "The Stranger", "Marta", "Young Tom", "Inspector Rook"]

# Radarr/Sonarr as Seerr lists them: a standard and a 4K server of each.
SERVICES = {
    "radarr": [
        {"id": 0, "name": "Radarr", "is4k": False, "isDefault": True, "activeProfileId": 4, "activeDirectory": "/data/movies"},
        {"id": 1, "name": "Radarr 4K", "is4k": True, "isDefault": True, "activeProfileId": 5, "activeDirectory": "/data/movies-4k"},
    ],
    "sonarr": [
        {"id": 0, "name": "Sonarr", "is4k": False, "isDefault": True, "activeProfileId": 4, "activeDirectory": "/data/tv",
         "activeLanguageProfileId": 1},
        {"id": 1, "name": "Sonarr 4K", "is4k": True, "isDefault": True, "activeProfileId": 5, "activeDirectory": "/data/tv-4k",
         "activeLanguageProfileId": 1},
    ],
}
PROFILES = [{"id": 1, "name": "Any"}, {"id": 3, "name": "HD-720p"}, {"id": 4, "name": "HD-1080p"}, {"id": 5, "name": "Ultra-HD"}]

# Names handed out as cast and crew, so a person's own page says the same name (their ids aren't tied to the list order).
PERSON_NAMES = {}

def credits(t):
    n = t["id"] % len(PEOPLE)
    order = PEOPLE[n:] + PEOPLE[:n]
    cast = [{"id": 100 + i, "name": name, "character": ROLES[(i + t["id"]) % len(ROLES)], "order": i, "profilePath": None}
            for i, name in enumerate(order[:8])]
    crew = [{"id": 200 + n, "name": order[8], "job": "Director", "department": "Directing", "profilePath": None},
            {"id": 201 + n, "name": order[9], "job": "Screenplay", "department": "Writing", "profilePath": None},
            {"id": 202 + n, "name": order[10], "job": "Producer", "department": "Production", "profilePath": None},
            {"id": 203 + n, "name": order[11], "job": "Original Music Composer", "department": "Sound", "profilePath": None}]
    for member in cast + crew:
        PERSON_NAMES[member["id"]] = member["name"]
    return {"cast": cast, "crew": crew}

def user(uid):
    return {"id": uid, "displayName": USERS[uid], "permissions": 2 if uid == 1 else 32}

def download_status(t):
    """What Seerr reports for a title Sonarr or Radarr is downloading (media.downloadStatus), the way Seerr shapes it."""
    d = t.get("download")
    if not d or t["id"] in CANCELLED or d["service"] not in ("sonarr", "radarr"):
        return None
    size = 4.2e9 if d["service"] == "radarr" else 1.1e9
    status = "paused" if f"dl{t['id']}" in PAUSED else ("downloading" if d["status"] == "paused" else d["status"])
    base = {"externalId": t["id"], "mediaType": t["type"], "size": size, "sizeLeft": size * (1 - d["progress"]),
            "status": status, "timeLeft": d.get("timeleft") or "00:00:00", "title": f"{t['title']}.{t['year']}.2160p.WEB-DL"}
    if t["type"] == "movie":
        return [base]
    return [{**base, "externalId": t["id"] * 100 + i, "episode": {"seasonNumber": sn, "episodeNumber": ep}}
            for i, (sn, ep) in enumerate(d["episodes"])]

def media_info(t):
    status = MEDIA_STATUS.get(t.get("status"))
    if status is None:
        return None
    info = {"id": t["id"], "tmdbId": t["id"], "tvdbId": t.get("tvdb"), "status": status, "downloadStatus": download_status(t) or []}
    if t["type"] == "tv":
        if t["status"] == "available":
            info["seasons"] = [{"seasonNumber": n, "status": 5} for n in range(1, len(t["seasons"]) + 1)]
        else:
            info["seasons"] = [{"seasonNumber": n, "status": status} for n in t.get("requestSeasons", [])]
    return info

def result(t):
    r = {"id": t["id"], "mediaType": t["type"], "posterPath": f"/p{t['id']}.png", "backdropPath": f"/b{t['id']}.png",
         "overview": t["overview"], "voteAverage": t["vote"], "mediaInfo": media_info(t)}
    if t["type"] == "movie":
        r.update(title=t["title"], releaseDate=f"{t['year']}-05-01")
    else:
        r.update(name=t["title"], firstAirDate=f"{t['year']}-03-01")
    return r

def detail(t):
    d = result(t)
    d.update(tagline=t["tagline"], genres=[{"id": i, "name": g} for i, g in enumerate(t["genres"])],
             relatedVideos=[{"key": f"demo{t['id']}", "name": "Official Trailer", "type": "Trailer", "site": "YouTube"}],
             credits=credits(t))
    if t["type"] == "tv":
        d["createdBy"] = [{"id": 300 + t["id"], "name": PEOPLE[(t["id"] + 5) % len(PEOPLE)], "profilePath": None}]
    if t["type"] == "movie":
        d["runtime"] = t["runtime"]
    else:
        d["numberOfSeasons"] = len(t["seasons"])
        d["seasons"] = [{"id": t["id"] * 10 + n, "seasonNumber": n, "name": f"Season {n}", "episodeCount": c}
                        for n, c in enumerate(t["seasons"], start=1)]
    return d

def requests():
    out = []
    dated = [t for t in CATALOG["titles"] if t.get("requestedBy")]
    for i, t in enumerate(dated):
        status = 1 if t.get("pendingRequest") else (5 if t["status"] == "available" else 2)
        out.append({
            "id": i + 1, "status": status, "is4k": False,
            "createdAt": f"2026-10-{16 - i % 14:02d}T18:00:00.000Z",
            "media": {"id": t["id"], "tmdbId": t["id"], "tvdbId": t.get("tvdb"), "mediaType": t["type"],
                      "status": MEDIA_STATUS.get(t["status"], 1), "downloadStatus": download_status(t) or []},
            "seasons": [{"id": i * 10 + n, "seasonNumber": n, "status": status} for n in t.get("requestSeasons", [])],
            "requestedBy": user(t["requestedBy"]),
        })
    return out

def request_filter(req, name):
    if name == "pending": return req["status"] == 1
    if name == "processing": return req["status"] == 2 and req["media"]["status"] != 5
    if name == "failed": return req["status"] == 4
    if name == "available": return req["media"]["status"] == 5
    return True

# Download controls (in memory): torrents that are paused, and titles taken out of the queues.
PAUSED = {f"dl{t['id']}" for t in CATALOG["titles"] if (t.get("download") or {}).get("status") == "paused"}
CANCELLED = set()

def queue(service):
    records, rid = [], 1
    for t in CATALOG["titles"]:
        d = t.get("download")
        if not d or d["service"] != service or t["id"] in CANCELLED:
            continue
        d = {**d}
        if f"dl{t['id']}" in PAUSED:
            d["status"] = "paused"
        elif d["status"] == "paused":
            d["status"] = "downloading"
        size = 4.2e9 if service == "radarr" else 1.1e9
        base = {"title": f"{t['title']}.{t['year']}.2160p.WEB-DL", "size": size, "sizeleft": size * (1 - d["progress"]),
                "timeleft": d["timeleft"], "status": d["status"], "trackedDownloadStatus": "ok",
                "trackedDownloadState": d.get("state", "downloading"), "downloadId": f"DL{t['id']}"}
        if service == "radarr":
            records.append({**base, "id": rid, "movie": {"title": t["title"], "tmdbId": t["id"]}}); rid += 1
        else:
            for season, episode in d["episodes"]:
                records.append({**base, "id": rid, "seasonNumber": season,
                                "series": {"title": t["title"], "tvdbId": t["tvdb"], "tmdbId": t["id"]},
                                "episode": {"seasonNumber": season, "episodeNumber": episode}}); rid += 1
    return {"page": 1, "pageSize": 200, "totalRecords": len(records), "records": records}

def torrents():
    """The fake qBittorrent's torrents: one per download, named like a release so Mindseerr can match it to a title."""
    out = []
    for t in CATALOG["titles"]:
        d = t.get("download")
        if not d or t["id"] in CANCELLED:
            continue
        dotted = t["title"].replace("&", "and").replace(" ", ".")
        if t["type"] == "tv":
            season, episode = d["episodes"][0]
            tag = f"S{season:02d}E{episode:02d}" if len(d["episodes"]) == 1 else f"S{season:02d}"
            name = f"{dotted}.{tag}.1080p.WEB-DL.x265-DEMO"
        else:
            name = f"{dotted}.{t['year']}.1080p.WEB-DL.x265-DEMO"
        h = f"dl{t['id']}"
        if d["status"] == "completed":
            state = "uploading"
        elif h in PAUSED:
            state = "pausedDL"
        elif d["status"] == "queued":
            state = "queuedDL"
        else:
            state = "downloading"
        left = d.get("timeleft")
        eta = 8640000
        if left:
            hh, mm, ss = (int(x) for x in left.split(":"))
            eta = hh * 3600 + mm * 60 + ss
        out.append({"hash": h, "name": name, "progress": d["progress"], "state": state, "eta": eta})
    # Two torrents with no Seerr request behind them (one even names a real catalog title), which the app
    # should leave out of Active Downloads.
    out.append({"hash": "dl7001", "name": "Cinder.Bloom.2024.1080p.WEB-DL.x265-DEMO", "progress": 0.12,
                "state": "downloading", "eta": 3000})
    out.append({"hash": "dl7002", "name": "Unrequested.Documentary.2021.1080p.BluRay", "progress": 0.55,
                "state": "downloading", "eta": 900})
    return out

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_with(self, body, status=200, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def deluge(self, body):
        """A fake Deluge Web UI: password sign-in with a session cookie, then JSON-RPC calls."""
        call = json.loads(body or "{}")
        method, params, cid = call.get("method"), call.get("params", []), call.get("id")
        def ok(result, headers=None):
            return self.send_with({"result": result, "error": None, "id": cid}, headers=headers)
        if method == "auth.login":
            good = params and params[0] == "demo"
            return ok(bool(good), {"Set-Cookie": "_session_id=demo; path=/"} if good else None)
        if "_session_id=demo" not in self.headers.get("Cookie", ""):
            return self.send_with({"result": None, "error": {"message": "Not authenticated", "code": 1}, "id": cid})
        if method == "web.connected":
            return ok(True)
        if method == "daemon.get_version":
            return ok("2.1.1")
        if method == "web.update_ui":
            states = {"downloading": "Downloading", "pausedDL": "Paused", "queuedDL": "Queued", "uploading": "Seeding"}
            return ok({"torrents": {t["hash"]: {"name": t["name"], "progress": t["progress"] * 100,
                                                "state": states.get(t["state"], "Downloading"),
                                                "eta": 0 if t["eta"] >= 8640000 else t["eta"], "message": "OK"}
                                    for t in torrents()}})
        if method in ("core.pause_torrents", "core.pause_torrent"):
            PAUSED.update(params[0]); return ok(None)
        if method in ("core.resume_torrents", "core.resume_torrent"):
            PAUSED.difference_update(params[0]); return ok(None)
        if method == "core.remove_torrent":
            if params[0].startswith("dl"): CANCELLED.add(int(params[0][2:]))
            return ok(True)
        return self.send_with({"result": None, "error": {"message": "Unknown method", "code": 2}, "id": cid})

    def transmission(self, body):
        """A fake Transmission: Basic auth, the 409 session-id handshake, and the RPC calls Mindseerr makes."""
        import base64
        if self.headers.get("Authorization") != "Basic " + base64.b64encode(b"demo:demo").decode():
            self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers(); return
        if self.headers.get("X-Transmission-Session-Id") != "demo-session":
            return self.send_with({}, 409, {"X-Transmission-Session-Id": "demo-session"})
        call = json.loads(body or "{}")
        method, args = call.get("method"), call.get("arguments", {})
        def ok(arguments):
            return self.send_with({"result": "success", "arguments": arguments})
        if method == "session-get":
            return ok({"version": "4.0.5 (demo)"})
        if method == "torrent-get":
            statuses = {"downloading": 4, "pausedDL": 0, "queuedDL": 3, "uploading": 6}
            return ok({"torrents": [{"hashString": t["hash"], "name": t["name"], "percentDone": t["progress"],
                                     "status": statuses.get(t["state"], 4), "eta": -1 if t["eta"] >= 8640000 else t["eta"],
                                     "error": 0, "errorString": ""} for t in torrents()]})
        ids = args.get("ids", [])
        if method == "torrent-stop":
            PAUSED.update(ids); return ok({})
        if method == "torrent-start":
            PAUSED.difference_update(ids); return ok({})
        if method == "torrent-remove":
            for h in ids:
                if h.startswith("dl"): CANCELLED.add(int(h[2:]))
            return ok({})
        return self.send_with({"result": "method not recognized"})

    def send_text(self, text, status=200):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        url = urlparse(self.path)
        p = url.path.rstrip("/")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""

        if p.endswith("/deluge/json"):
            return self.deluge(body)
        if p.endswith("/transmission/rpc"):
            return self.transmission(body)

        # A fake qBittorrent: sign-in, version and the torrents behind the queues' downloadIds.
        if p.startswith("/qbittorrent/api/v2/"):
            action = p[len("/qbittorrent/api/v2/"):]
            if action == "auth/login":
                form = parse_qs(body)
                if form.get("username") != ["demo"] or form.get("password") != ["demo"]:
                    return self.send_text("Fails.")
                # Newer qBittorrent answers a good login with an empty 204 and a session cookie.
                self.send_response(204)
                self.send_header("Set-Cookie", "SID=demo; HttpOnly; path=/")
                self.end_headers()
                return
            if "SID=demo" not in self.headers.get("Cookie", ""):
                return self.send_text("Forbidden", 403)
            if action == "torrents/delete":
                for h in parse_qs(body).get("hashes", [""])[0].split("|"):
                    if h.startswith("dl") and h[2:].isdigit():
                        CANCELLED.add(int(h[2:]))
                return self.send_text("")
            if action in ("torrents/pause", "torrents/stop", "torrents/resume", "torrents/start"):
                hashes = {h for h in parse_qs(body).get("hashes", [""])[0].split("|") if h}
                if action in ("torrents/pause", "torrents/stop"):
                    PAUSED.update(hashes)
                else:
                    PAUSED.difference_update(hashes)
                return self.send_text("")
        # Taking a download out of a Sonarr/Radarr queue (what Cancel does).
        for service in ("sonarr", "radarr"):
            if p == f"/{service}/api/v3/queue/bulk" and self.command == "DELETE":
                print("queue/bulk", self.path, flush=True)  # shows removeFromClient and blocklist
                ids = set(json.loads(body or "{}").get("ids", []))
                for record in queue(service)["records"]:
                    if record["id"] in ids:
                        tid = (record.get("movie") or record.get("series"))["tmdbId"]
                        CANCELLED.add(tid)
                return self.send_json({})
        print("refused", self.command, p, body, flush=True)  # shows what the app tried to send
        self.send_json({"message": "This is a read-only demo server."}, 403)
    do_DELETE = do_PUT = do_POST

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        p = url.path.rstrip("/")

        if p.startswith("/qbittorrent/api/v2/") and "SID=demo" not in self.headers.get("Cookie", ""):
            return self.send_text("Forbidden", 403)
        if p == "/qbittorrent/api/v2/app/version":
            return self.send_text("v5.0.1")
        if p == "/qbittorrent/api/v2/torrents/info":
            return self.send_json(torrents())

        # Demo only: GET /__demo/finish/<tmdb id> takes a download out of every queue, as if it had finished,
        # so the app's "download finished" banner can be shown.
        if p.startswith("/__demo/finish/"):
            CANCELLED.add(int(os.path.basename(p)))
            return self.send_json({"finished": os.path.basename(p)})

        if p.startswith("/img/"):
            name = os.path.basename(p)
            path = os.path.join(ART, name)
            if not os.path.exists(path):
                return self.send_json({"message": "no art"}, 404)
            data = open(path, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            return self.wfile.write(data)

        for service in ("sonarr", "radarr"):
            if p == f"/{service}/api/v3/system/status":
                return self.send_json({"appName": service.capitalize(), "version": "4.0.0 (demo)"})
            if p == f"/{service}/api/v3/queue":
                return self.send_json(queue(service))

        if not p.startswith("/api/v1"):
            return self.send_json({"message": "not found"}, 404)
        p = p[len("/api/v1"):]

        if p == "/status": return self.send_json({"version": "2.7.0 (demo)"})
        if p == "/settings/public": return self.send_json({"mediaServerType": 1, "applicationTitle": "Seerr"})
        # DEMO_USER=<id> signs the demo in as a regular user (see USERS in catalog.json) instead of the admin.
        if p.startswith("/user/") and p.endswith("/quota"):
            # Movies have requests left; series are used up, so both states can be shown.
            return self.send_json({"movie": {"days": 7, "limit": 5, "used": 3, "remaining": 2, "restricted": False},
                                   "tv": {"days": 7, "limit": 2, "used": 2, "remaining": 0, "restricted": True}})
        if p == "/auth/me": return self.send_json(user(int(os.environ.get("DEMO_USER", 1))))
        if p in ("/discover/genreslider/movie", "/discover/genreslider/tv"):
            kind = "movie" if p.endswith("movie") else "tv"
            names = sorted({g for t in CATALOG["titles"] if t["type"] == kind for g in t["genres"]})
            return self.send_json([{"id": 100 + i, "name": n, "backdrops": []} for i, n in enumerate(names)])
        if p in ("/discover/movies", "/discover/tv") and any(k in q for k in ("genre", "studio", "network", "sortBy")):
            kind = "movie" if p.endswith("movies") else "tv"
            pool = [t for t in CATALOG["titles"] if t["type"] == kind]
            if "genre" in q:
                names = sorted({g for t in pool for g in t["genres"]})
                wanted = names[int(q["genre"]) - 100] if 0 <= int(q["genre"]) - 100 < len(names) else None
                pool = [t for t in pool if wanted in t["genres"]]
            elif "studio" in q or "network" in q:
                pool = [t for i, t in enumerate(pool) if (i + int(q.get("studio") or q.get("network"))) % 2 == 0]
            sort = q.get("sortBy", "popularity.desc")
            if sort.startswith("vote_average"): pool.sort(key=lambda t: -t["vote"])
            elif "date" in sort: pool.sort(key=lambda t: -t["year"])
            return self.send_json({"page": 1, "totalPages": 1, "totalResults": len(pool),
                                   "results": [result(t) for t in pool]})
        if p.lstrip("/") in CATALOG["sections"]:
            items = [result(TITLES[i]) for i in CATALOG["sections"][p.lstrip("/")]]
            page = int(q.get("page", 1))
            return self.send_json({"page": page, "totalPages": 1, "totalResults": len(items),
                                   "results": items if page == 1 else []})
        if p == "/search":
            term = q.get("query", "").lower()
            items = [result(t) for t in CATALOG["titles"] if term in t["title"].lower()]
            return self.send_json({"page": 1, "totalPages": 1, "totalResults": len(items), "results": items})
        for service in ("radarr", "sonarr"):
            if p == f"/service/{service}":
                return self.send_json(SERVICES[service])
            if p.startswith(f"/service/{service}/"):
                sid = int(p.split("/")[3])
                server = next((x for x in SERVICES[service] if x["id"] == sid), None)
                if not server:
                    return self.send_json({"message": "no such server"}, 404)
                folder = server["activeDirectory"]
                body = {"server": server, "profiles": PROFILES,
                        "rootFolders": [{"id": 1, "path": folder, "freeSpace": 3.2e12},
                                        {"id": 2, "path": folder + "-archive", "freeSpace": 9.8e11}], "tags": []}
                if service == "sonarr":
                    body["languageProfiles"] = [{"id": 1, "name": "English"}, {"id": 2, "name": "Original"}]
                return self.send_json(body)
        for kind in ("movie", "tv"):
            for related in ("recommendations", "similar"):
                if p.startswith(f"/{kind}/") and p.endswith(f"/{related}"):
                    tid = int(p.split("/")[2])
                    same = [x for x in CATALOG["titles"] if x["type"] == kind and x["id"] != tid]
                    shift = (tid + (0 if related == "recommendations" else 3)) % max(1, len(same))
                    picks = (same[shift:] + same[:shift])[:7]
                    return self.send_json({"page": 1, "totalPages": 1, "totalResults": len(picks),
                                           "results": [result(x) for x in picks]})
        if p.startswith("/tv/") and "/season/" in p:
            parts = p.split("/")
            t, n = TITLES.get(int(parts[2])), int(parts[4])
            if not t or n < 1 or n > len(t["seasons"]):
                return self.send_json({"message": "not found"}, 404)
            words = ["The Signal", "Low Tide", "Dead Reckoning", "Salt and Rust", "What the Lamp Saw", "Undertow", "The Long Quiet", "Last Light"]
            eps = [{"id": t["id"] * 1000 + n * 100 + e, "name": words[(e + n) % len(words)], "episodeNumber": e, "seasonNumber": n,
                    "runtime": 41 + e % 7,
                    "overview": f"Episode {e} of season {n}. A short demo summary that runs long enough to need a second line so the "
                                "list shows how overviews are trimmed when they are longer than the row can hold."}
                   for e in range(1, t["seasons"][n - 1] + 1)]
            return self.send_json({"id": t["id"] * 10 + n, "seasonNumber": n, "name": f"Season {n}", "episodes": eps})
        if p.startswith("/person/"):
            pid = int(p.split("/")[2])
            if p.endswith("/combined_credits"):
                ids = sorted(TITLES)
                mine = [TITLES[ids[(pid * 3 + i * 5) % len(ids)]] for i in range(9)]
                mine = list({t["id"]: t for t in mine}.values())
                return self.send_json({"cast": [result(t) for t in mine[:6]], "crew": [result(t) for t in mine[4:]]})
            name = PERSON_NAMES.get(pid) or PEOPLE[pid % len(PEOPLE)]
            return self.send_json({"id": pid, "name": name, "knownForDepartment": "Acting", "birthday": "1980-04-02",
                                   "placeOfBirth": "Portland, Oregon, USA",
                                   "biography": f"{name} is an invented performer from the demo catalog, known for atmospheric dramas and a quiet, "
                                                "unshowy style. This text only exists so the person page has something to show."})
        for kind in ("movie", "tv"):
            if p.startswith(f"/{kind}/") and p.endswith("/ratings"):
                tid = int(p.split("/")[2])
                critics, audience = 55 + tid * 7 % 45, 50 + tid * 11 % 48
                body = {"criticsScore": critics, "criticsRating": "Certified Fresh" if critics >= 75 else ("Fresh" if critics >= 60 else "Rotten")}
                if kind == "movie":
                    body.update(audienceScore=audience, audienceRating="Upright" if audience >= 60 else "Spilled")
                return self.send_json(body)
        for kind in ("movie", "tv"):
            if p.startswith(f"/{kind}/"):
                t = TITLES.get(int(p.split("/")[2]))
                return self.send_json(detail(t)) if t and t["type"] == kind else self.send_json({"message": "not found"}, 404)
        if p == "/media":
            avail = [t for t in CATALOG["titles"] if t.get("status") == "available"] + \
                    [t for t in CATALOG["titles"] if t.get("status") == "processing" and t["type"] == "tv"][:1]
            take, skip = int(q.get("take", 20)), int(q.get("skip", 0))
            items = [{"id": t["id"], "tmdbId": t["id"], "mediaType": t["type"], "status": 5} for t in avail[skip:skip + take]]
            return self.send_json({"pageInfo": {"pages": max(1, -(-len(avail) // take)), "pageSize": take, "results": len(avail),
                                                "page": skip // take + 1}, "results": items})
        if p == "/request/count":
            reqs = requests()
            count = lambda f: sum(request_filter(r, f) for r in reqs)
            return self.send_json({"total": len(reqs), "pending": count("pending"), "approved": count("processing"),
                                   "declined": 0, "processing": count("processing"), "available": count("available")})
        if p == "/request":
            reqs = [r for r in requests() if request_filter(r, q.get("filter", "all"))]
            if "requestedBy" in q:
                reqs = [r for r in reqs if r["requestedBy"]["id"] == int(q["requestedBy"])]
            skip, take = int(q.get("skip", 0)), int(q.get("take", 20))
            page_items = reqs[skip:skip + take]
            return self.send_json({"pageInfo": {"pages": max(1, -(-len(reqs) // take)), "pageSize": take,
                                                "results": len(reqs), "page": skip // take + 1},
                                   "results": page_items})
        return self.send_json({"message": f"demo server has no {p}"}, 404)

print(f"Demo server on http://127.0.0.1:{PORT} (art from {ART})")
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
