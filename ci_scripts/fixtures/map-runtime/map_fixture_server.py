#!/usr/bin/env python3
"""Local map transport fixture. Never proxies traffic and never logs credentials.

--check and --set-scenario do not start a server. HTTP execution is opt-in.
Responses are selected when a request arrives, before any configured delay.
"""
import argparse
import copy
import json
import math
from pathlib import Path
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent
LAYERS = ("antennas", "speedtests", "coverage", "community-sites", "custom-sites")
SCENARIOS = ("baseline", "empty", "error-all", "error-one", "partial", "invalid-json",
             "wrong-tile", "legacy-degraded", "out-of-order", "out-of-order-b-error")
SAFE_QUERY = {"market", "operator", "marketCode", "operatorKey", "north", "south", "east", "west",
              "zoom", "lightweight", "only", "full", "days", "limit", "offset", "detail", "bands",
              "band", "withAzimuth", "includeObserved", "friendsOnly", "technologies", "bandMatch"}
LOCK = threading.Lock()
SEQUENCE = 0
EVENTS = []

# Deliberately synthetic city-centre grids for the native international recipe.
MARKET_GRIDS = {
    "CA": (45.5019, -73.5674, "BELL", 2),
    "DROM": (-20.8823, 55.4504, "SRR", 7),
    "BE": (50.4669, 4.86746, "PROXIMUS_BE", 7),
    "CH": (46.948, 7.4474, "SWISSCOM_CH", 7),
    "DE": (52.52, 13.405, "TELEKOM_DE", 7),
    "US": (40.7128, -74.006, "ATT_US", 2),
    "BA": (43.8563, 18.4131, "BH_MOBILE_BA", 7),
}


def tile_for(lat, lng, z):
    n = 2 ** z
    return {"z": z, "x": min(n - 1, int((lng + 180) / 360 * n)),
            "y": min(n - 1, int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n))}


def grid():
    # Fixed synthetic positions, never derived from a device or live response.
    positions = [("NW", 45.190, 5.7089), ("NE", 45.190, 5.7169), ("C", 45.188, 5.7129),
                 ("SW", 45.186, 5.7089), ("SE", 45.186, 5.7169)]
    return [{"key": f"{op}-{label}", "lat": lat + shift, "lng": lng + shift,
             "operator": op, "tech": "4G", "band": 3, "source": "coverage",
             "downloadMbps": 120 + i * 40, "rsrp": -75 - i * 5}
            for op, shift in [("ORANGE", 0), ("SFR", 0.0003)]
            for i, (label, lat, lng) in enumerate(positions)] + [
        {"key": "ORANGE-IOS", "lat": 45.188, "lng": 5.7144, "operator": "ORANGE",
         "tech": "5G", "band": 78, "source": "ios", "downloadMbps": 600, "rsrp": None}]


def select_points(query, tile=None):
    market = query.get("market", ["FR"])[0]
    if market == "FR":
        points = json.loads((ROOT / "points.json").read_text())
    elif market in MARKET_GRIDS:
        lat, lng, op, band = MARKET_GRIDS[market]
        points = [{"key": f"{market}-{op}-{label}", "market": market,
                   "lat": lat + dy, "lng": lng + dx, "operator": op,
                   "tech": "4G", "band": band, "source": "coverage", "downloadMbps": 200, "rsrp": -85}
                  for label, dy, dx in [("NW", .002, -.004), ("NE", .002, .004), ("C", 0, 0),
                                        ("SW", -.002, -.004), ("SE", -.002, .004)]]
    else:
        points = []
    operator = query.get("operator", ["ALL"])[0]
    if operator != "ALL":
        points = [p for p in points if p["operator"] == operator]
    bands = {b for v in query.get("band", []) + query.get("bands", []) for b in v.split(",")}
    if bands:
        points = [p for p in points if str(p["band"]) in bands]
    techs = set(query.get("technologies", [""])[0].split(",")) - {""}
    if techs:
        points = [p for p in points if p["tech"] in techs]
    if tile is not None:
        points = [p for p in points if tile_for(p["lat"], p["lng"], tile["z"]) == tile]
    elif all(k in query for k in ("north", "south", "east", "west")):
        points = [p for p in points if float(query["south"][0]) <= p["lat"] <= float(query["north"][0])
                  and float(query["west"][0]) <= p["lng"] <= float(query["east"][0])]
    return points


def tile_payload(layer, tile, points, mode="baseline"):
    payload = {"tile": tile.copy()}
    array_name = "points" if layer == "coverage" else "markers"
    payload[array_name] = []
    if layer != "custom-sites":
        payload["clusters"] = []
    if mode == "empty":
        points = []
    # The extra IOS sample exists only in coverage, so every other layer has 5 per operator.
    if layer != "coverage":
        points = [p for p in points if p["source"] != "ios"]
    for p in points:
        item = {"id": f"qa-{layer}-{p['key']}", "lat": p["lat"], "lng": p["lng"]}
        if layer == "antennas":
            item.update(operator=p["operator"], operators=[p["operator"]], technologies=[p["tech"]],
                        bands=[p["band"]], address=f"SYNTHETIQUE {p['key']}", azimuts=[60, 180, 300])
        elif layer == "speedtests":
            item.update(downloadMbps=p["downloadMbps"], operator=p["operator"], tech=p["tech"], band=p["band"])
        elif layer == "coverage":
            item.update(rsrp=p["rsrp"], tech=p["tech"], band=p["band"], source=p["source"])
        elif layer == "community-sites":
            item.update(operatorKey=p["operator"], marketCode=p.get("market", "FR"), candidateKind="community_probable")
        else:
            item.update(operatorKey=p["operator"], name=f"SYNTHETIQUE {p['key']}", photoCount=0)
        payload[array_name].append(item)
    # A fixture cluster is an explicit aggregation, with one group per source.
    if layer in ("antennas", "coverage") and tile["z"] < 11 and payload[array_name]:
        for source in sorted({p.get("source", "coverage") for p in payload[array_name]}):
            group = [p for p in payload[array_name] if p.get("source", "coverage") == source]
            payload["clusters"].append({"id": f"qa-cluster-{layer}-{tile['z']}-{tile['x']}-{tile['y']}-{source}",
                "lat": sum(p["lat"] for p in group) / len(group), "lng": sum(p["lng"] for p in group) / len(group),
                "count": len(group), "source": source, "tech": "5G" if source == "ios" else "4G",
                "avgRsrp": None if source == "ios" else -85})
        payload[array_name] = []
    if layer == "speedtests":
        payload["stats"] = {"returnedCount": len(payload[array_name]), "hasMore": False,
                            "truncated": mode == "partial"}
    if layer == "coverage":
        payload["stats"] = {"sampleCount": len(points), "returnedCount": len(payload[array_name]),
                            "hasMore": False, "truncated": mode == "partial"}
    if mode == "wrong-tile":
        payload["tile"]["x"] = (tile["x"] + 1) % 2 ** tile["z"]
    if mode == "legacy-degraded":
        payload[array_name] = []
        if "clusters" in payload:
            payload["clusters"] = []
        payload["degraded"] = True
    return payload


def response_for(path, query, state):
    mode = state.get("scenario", "baseline")
    target_layers = state.get("layers", list(LAYERS))
    headers = {"Cache-Control": "no-store"}
    tile_match = re.fullmatch(r"/api/android/map/tiles/(antennas|speedtests|coverage|community-sites|custom-sites)/(\d+)/(\d+)/(\d+)", path)
    if tile_match:
        layer, z, x, y = tile_match.groups()
        tile = {"z": int(z), "x": int(x), "y": int(y)}
        if not 0 <= tile["z"] <= 20 or not all(0 <= tile[k] < 2 ** tile["z"] for k in ("x", "y")):
            return 400, {"error": "Invalid synthetic tile"}, headers, 0
        active = layer in target_layers
        # Consistent single failure: the tile containing the fixed center at the requested z.
        center_tile = tile_for(45.188, 5.7129, tile["z"])
        fails = active and (mode == "error-all" or (mode == "error-one" and tile == center_tile)
                           or (mode == "out-of-order-b-error" and query.get("operator") == ["SFR"]))
        delay = 8 if active and mode.startswith("out-of-order") and query.get("operator") == ["ORANGE"] else 0
        if fails:
            headers["Retry-After"] = "15"  # APIClient surfaces >3s rather than automatic retry.
            return 503, {"error": "SYNTHETIQUE donnees indisponibles", "code": "DATABASE_UNAVAILABLE"}, headers, delay
        if active and mode == "invalid-json":
            return 200, b'{"tile":', headers, delay
        body = tile_payload(layer, tile, select_points(query, tile), mode if active else "baseline")
        bands = sorted({int(b) for v in query.get("band", []) + query.get("bands", []) for b in v.split(",") if b.isdigit() and int(b) > 0})
        if layer == "coverage" and bands:
            body["stats"]["appliedBandFilter"] = {"version": 1, "bands": bands, "match": "any"}
        return 200, body, headers, delay
    if path == "/api/social/map/snapshot":
        return 401, {"code": "UNAUTHORIZED", "error": "Connexion requise"}, headers, 0
    if path == "/api/social/map/stream":
        headers["Content-Type"] = "text/event-stream"
        return 200, b'event: snapshot\ndata: {"friends":[]}\n\n', headers, 0
    if path == "/api/android/markets":
        # Explicitly keep the versioned bundled market registry authoritative.
        return 200, {"markets": []}, headers, 0
    if path == "/api/app/version-policy":
        return 200, {"minVersionCode": 1, "recommendedVersionCode": 1}, headers, 0
    if path in ("/api/android/map/incidents", "/api/map/planned-sites"):
        return 200, {"sites": []}, headers, 0
    if path == "/api/community-outages":
        return 200, {"outages": [], "hasMore": False}, headers, 0
    if path == "/api/map/photos":
        return 200, {"photos": []}, headers, 0
    if path == "/api/coverage/points":
        return 503, {"error": "Synthetic fallback unavailable", "code": "DATABASE_UNAVAILABLE"}, {**headers, "Retry-After": "15"}, 0
    if path == "/api/antennas":
        # Match terminal antenna errors; otherwise bbox fallback could hide tile injection.
        if mode in ("error-all", "error-one", "invalid-json", "wrong-tile", "legacy-degraded", "out-of-order-b-error") and "antennas" in target_layers:
            return 503, {"error": "Synthetic fallback unavailable", "code": "DATABASE_UNAVAILABLE"}, {**headers, "Retry-After": "15"}, 0
        points = [] if mode == "empty" and "antennas" in target_layers else select_points(query)
        antennas = [{"id": f"qa-antennas-{p['key']}", "lat": p["lat"], "lng": p["lng"],
                     "operators": [p["operator"]], "technologies": [p["tech"]], "bands": [p["band"]],
                     "address": f"SYNTHETIQUE {p['key']}"} for p in points if p["source"] != "ios"]
        return 200, {"antennas": antennas}, headers, 0
    return 404, {"error": "Route not provided by synthetic map fixture", "code": "QA_ROUTE_NOT_IMPLEMENTED"}, headers, 0


def record(entry):
    with LOCK:
        EVENTS.append(entry)
        del EVENTS[:-512]
        with (ROOT / "requests.ndjson").open("a") as output:
            output.write(json.dumps(entry, sort_keys=True) + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def json_response(self, status, value):
        payload = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if self.path != "/__qa/scenario":
            self.json_response(404, {"error": "unknown-control"})
            return
        if self.headers.get("Origin") is not None or self.headers.get("X-SQ-QA") != "map-runtime-v1":
            self.json_response(403, {"error": "native-qa-only"})
            return
        length = self.headers.get("Content-Length", "")
        if not length.isdecimal() or not 0 < int(length) <= 2048 or self.headers.get("Content-Type") != "application/json":
            self.json_response(400, {"error": "invalid-control"})
            return
        try:
            data = json.loads(self.rfile.read(int(length)))
            if not isinstance(data, dict) or set(data) != {"scenario", "layers"}:
                raise ValueError()
            if data["scenario"] not in SCENARIOS or not isinstance(data["layers"], list) or not data["layers"]:
                raise ValueError()
            if any(not isinstance(layer, str) or layer not in LAYERS for layer in data["layers"]):
                raise ValueError()
            state = {"scenario": data["scenario"], "layers": data["layers"], "revision": str(uuid.uuid4()), "gridRevision": 2}
            with LOCK:
                temporary = ROOT / "scenario.json.tmp"
                temporary.write_text(json.dumps(state) + "\n")
                temporary.replace(ROOT / "scenario.json")
            self.json_response(200, state)
        except (ValueError, TypeError):
            self.json_response(400, {"error": "invalid-control"})

    def do_GET(self):
        global SEQUENCE
        url = urlsplit(self.path)
        if url.path == "/__qa/state":
            with LOCK:
                value = {"state": json.loads((ROOT / "scenario.json").read_text()), "events": list(EVENTS)}
            self.json_response(200, value)
            return
        query = parse_qs(url.query)
        with LOCK:
            SEQUENCE += 1
            request_id = f"map-fixture-{SEQUENCE:06d}"
        state = json.loads((ROOT / "scenario.json").read_text())
        status, body, headers, delay = response_for(url.path, query, state)
        safe = {k: v for k, v in query.items() if k in SAFE_QUERY}
        # Tile / known route paths only; unsupported detail IDs are not persisted.
        safe_path = url.path if url.path in ("/api/social/map/snapshot", "/api/social/map/stream", "/api/android/markets",
                    "/api/antennas", "/api/map/photos", "/api/community-outages", "/api/map/planned-sites",
                    "/api/android/map/incidents", "/api/app/version-policy", "/api/coverage/points") or re.fullmatch(
                        r"/api/android/map/tiles/[a-z-]+/\d+/\d+/\d+", url.path) else "[unsupported-route]"
        entry = {"requestId": request_id, "scenario": state, "path": safe_path, "query": safe,
                 "status": status, "delaySeconds": delay, "time": time.time()}
        if isinstance(body, dict):
            entry["responseCounts"] = {k: len(body[k]) for k in ("markers", "points", "clusters", "antennas") if isinstance(body.get(k), list)}
            entry["syntheticIDs"] = [item["id"] for k in ("markers", "points", "clusters", "antennas")
                                     for item in body.get(k, []) if isinstance(item, dict) and str(item.get("id", "")).startswith("qa-")]
        record({**entry, "event": "received"})
        time.sleep(delay)
        payload = body if isinstance(body, bytes) else json.dumps(body).encode()
        try:
            self.send_response(status)
            self.send_header("X-Request-Id", request_id)
            self.send_header("Content-Type", headers.pop("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(payload)))
            for name, value in headers.items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(payload)
            record({**entry, "event": "sent", "time": time.time(), "bytes": len(payload)})
        except (BrokenPipeError, ConnectionResetError):
            record({**entry, "event": "client-disconnected", "time": time.time()})


def check():
    points = json.loads((ROOT / "points.json").read_text())
    assert len(points) == len({p["key"] for p in points}) == 11
    checked = 0
    for z in range(4, 17):
        tiles = {tuple(tile_for(p["lat"], p["lng"], z).values()) for p in points}
        for layer in LAYERS:
            represented = 0
            for z, x, y in tiles:
                tile = {"z": z, "x": x, "y": y}
                selected = select_points({"operator": ["ORANGE"]}, tile)
                payload = tile_payload(layer, tile, selected)
                for key in (["points", "clusters"] if layer == "coverage" else ["markers"] if layer == "custom-sites" else ["markers", "clusters"]):
                    assert isinstance(payload[key], list)
                    for item in payload[key]:
                        assert item["id"] and -90 <= item["lat"] <= 90 and -180 <= item["lng"] <= 180
                assert payload["tile"] == tile
                represented += len(payload.get("points", payload.get("markers", []))) + sum(c["count"] for c in payload.get("clusters", []))
                checked += 1
            assert represented == (6 if layer == "coverage" else 5), (z, layer, represented)
    for scenario in SCENARIOS:
        for layer in LAYERS:
            center = tile_for(45.188, 5.7129, 14)
            status, body, headers, delay = response_for(f"/api/android/map/tiles/{layer}/14/{center['x']}/{center['y']}",
                {"operator": ["ORANGE"]}, {"scenario": scenario})
            assert status in (200, 503)
            assert delay == (8 if scenario.startswith("out-of-order") else 0)
            if scenario in ("error-all", "error-one"):
                assert status == 503 and headers["Retry-After"] == "15"
            elif scenario == "invalid-json":
                try:
                    json.loads(body)
                    raise AssertionError("Invalid JSON scenario decoded")
                except json.JSONDecodeError:
                    pass
            elif scenario == "wrong-tile":
                assert body["tile"] != center
            elif scenario == "partial" and layer in ("speedtests", "coverage"):
                assert body["stats"]["truncated"] is True
    print(f"PASS: {checked} tile payload structures across z4..16; {len(SCENARIOS) * len(LAYERS)} scenario/layer responses. No HTTP server or iOS process started. Native Swift decoding and painting remain unverified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8769)
    parser.add_argument("--set-scenario", choices=SCENARIOS)
    parser.add_argument("--layers", nargs="+", choices=LAYERS, default=list(LAYERS))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.set_scenario:
        temporary = ROOT / "scenario.json.tmp"
        temporary.write_text(json.dumps({"scenario": args.set_scenario, "layers": args.layers, "gridRevision": 2}, indent=2) + "\n")
        temporary.replace(ROOT / "scenario.json")
        return
    if args.check:
        check()
        return
    print(f"Synthetic map fixture listening on http://127.0.0.1:{args.port}; no upstream proxy", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
