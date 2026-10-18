#!/usr/bin/env python3
"""Stand-in Seerr + Sonarr + Radarr server with invented content, for README screenshots.

    python3 server.py [port] [art dir]     (defaults: 8765, /tmp/oppdemo/img)

Then launch a Debug build with MINDSEERR_DEMO=http://127.0.0.1:<port>. Almost read-only: anything that
would change data (approve, request, delete...) is refused. The exceptions are the download controls,
which only change in-memory state: pausing/resuming or deleting a torrent on the fake qBittorrent and removing
a download from the Sonarr/Radarr queue. Restart the server to reset them.
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

def credits(t):
    n = t["id"] % len(PEOPLE)
    order = PEOPLE[n:] + PEOPLE[:n]
    cast = [{"id": 100 + i, "name": name, "character": ROLES[(i + t["id"]) % len(ROLES)], "order": i, "profilePath": None}
            for i, name in enumerate(order[:8])]
    crew = [{"id": 200 + n, "name": order[8], "job": "Director", "department": "Directing", "profilePath": None},
            {"id": 201 + n, "name": order[9], "job": "Screenplay", "department": "Writing", "profilePath": None},
            {"id": 202 + n, "name": order[10], "job": "Producer", "department": "Production", "profilePath": None},
            {"id": 203 + n, "name": order[11], "job": "Original Music Composer", "department": "Sound", "profilePath": None}]
    return {"cast": cast, "crew": crew}

def user(uid):
    return {"id": uid, "displayName": USERS[uid], "permissions": 2 if uid == 1 else 32}

def media_info(t):
    status = MEDIA_STATUS.get(t.get("status"))
    if status is None:
        return None
    info = {"id": t["id"], "tmdbId": t["id"], "tvdbId": t.get("tvdb"), "status": status}
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
                      "status": MEDIA_STATUS.get(t["status"], 1)},
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

        # A fake qBittorrent: sign-in, version and the torrents behind the queues' downloadIds.
        if p.startswith("/qbittorrent/api/v2/"):
            action = p[len("/qbittorrent/api/v2/"):]
            if action == "auth/login":
                return self.send_text("Ok.")
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
                ids = set(json.loads(body or "{}").get("ids", []))
                for record in queue(service)["records"]:
                    if record["id"] in ids:
                        tid = (record.get("movie") or record.get("series"))["tmdbId"]
                        CANCELLED.add(tid)
                return self.send_json({})
        self.send_json({"message": "This is a read-only demo server."}, 403)
    do_DELETE = do_PUT = do_POST

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        p = url.path.rstrip("/")

        if p == "/qbittorrent/api/v2/app/version":
            return self.send_text("v5.0.1")
        if p == "/qbittorrent/api/v2/torrents/info":
            return self.send_json(torrents())

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
        if p == "/auth/me": return self.send_json(user(1))
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
        for kind in ("movie", "tv"):
            if p.startswith(f"/{kind}/"):
                t = TITLES.get(int(p.split("/")[2]))
                return self.send_json(detail(t)) if t and t["type"] == kind else self.send_json({"message": "not found"}, 404)
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
