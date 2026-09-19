#!/usr/bin/env python3
"""Synthetic delayed feed/SSE on loopback; other routes use the isolated recipe.

Never forwards to production. Logs contain only fixture query identifiers.
"""
import http.client
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

lock = threading.Lock()
state = {"live": False, "epoch": 0, "connections": 0, "events": []}


def item(identifier, text):
    return {"id": identifier, "kind": "post", "text": text,
            "author": {"id": "qa-author", "name": "Recette", "badges": []},
            "visibility": "public", "status": "published", "isMine": False,
            "attachments": [], "hashtags": [], "reactions": []}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, value, status=200):
        raw = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        if urlsplit(self.path).path == "/__qa/feed/control":
            if self.headers.get("X-SQ-QA") != "feed-runtime-v1" or self.headers.get("Origin"):
                self.reply({"error": "fixture control denied"}, 403)
                return
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length < 2048:
                self.reply({"error": "invalid control"}, 400)
                return
            value = json.loads(self.rfile.read(length))
            with lock:
                if value.get("reset"):
                    state.update(live=False, events=[])
                if "live" in value:
                    state["live"] = value["live"] is True
                if value.get("disconnect") or value.get("reset"):
                    state["epoch"] += 1
            self.reply({"ok": True})
            return
        self.forward()

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/__qa/feed/state":
            with lock:
                snapshot = {**state, "events": state["events"][-200:]}
            self.reply(snapshot)
            return
        if url.path == "/api/social/feed/stream":
            self.stream()
            return
        if url.path != "/api/social/feed":
            self.forward()
            return
        query = parse_qs(url.query)
        tag = query.get("hashtag", [""])[0]
        ranking = query.get("ranking", [""])[0]
        key = tag if tag in ("alpha", "beta") else "recent" if ranking == "latest" else "old"
        with lock:
            live = state["live"]
            state["events"].append({"kind": "received", "key": key, "time": time.time()})
        if key in ("old", "alpha"):
            time.sleep(5)
        posts = [item("qa-feed-" + key, "RECETTE " + key.upper())]
        if live and key == "beta":
            posts.append(item("qa-feed-new", "NOUVELLE RECETTE BETA"))
        try:
            self.reply({"items": posts, "nextCursor": None, "stories": [], "suggestedUsers": [],
                        "trendingHashtags": [{"tag": tag, "postCount": 1} for tag in ("alpha", "beta")]})
            with lock:
                state["events"].append({"kind": "sent", "key": key, "time": time.time()})
        except (BrokenPipeError, ConnectionResetError):
            with lock:
                state["events"].append({"kind": "cancelled", "key": key, "time": time.time()})

    def stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        with lock:
            state["connections"] += 1
            epoch = state["epoch"]
        previous = None
        try:
            for _ in range(600):
                with lock:
                    live, current_epoch = state["live"], state["epoch"]
                if current_epoch != epoch:
                    return
                if live != previous:
                    payload = {"items": [item("qa-global-one", "GLOBAL"), item("qa-global-two", "GLOBAL") ]}
                    self.wfile.write(("event: snapshot\ndata: " + json.dumps(payload) + "\n\n").encode())
                    previous = live
                else:
                    self.wfile.write(b": heartbeat\n\n")
                self.wfile.flush()
                time.sleep(.25)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def forward(self):
        connection = http.client.HTTPConnection("127.0.0.1", 49141, timeout=35)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length) if length else None
            headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection")}
            headers["Host"] = "127.0.0.1:49141"
            connection.request(self.command, self.path, body, headers)
            result = connection.getresponse()
            if result.getheader("Content-Type", "").startswith("text/event-stream"):
                self.send_response(result.status)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                while line := result.readline():
                    self.wfile.write(line)
                    self.wfile.flush()
                return
            data = result.read()
            self.send_response(result.status)
            for k, v in result.getheaders():
                if k.lower() not in ("connection", "transfer-encoding", "content-length"):
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        finally:
            connection.close()


if __name__ == "__main__":
    print("Synthetic feed fixture on loopback:8772; fallback loopback:49141", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8772), Handler).serve_forever()
