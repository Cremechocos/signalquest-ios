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
STATE_ROOT = ROOT
PROFILE_QA_ENABLED = False
PROFILE_SCENARIO = "profile-origin"
LAYERS = ("antennas", "speedtests", "coverage", "community-sites", "custom-sites")
SCENARIOS = ("baseline", "empty", "error-all", "error-one", "partial", "invalid-json",
             "wrong-tile", "legacy-degraded", "out-of-order", "out-of-order-b-error", PROFILE_SCENARIO)
SAFE_QUERY = {"market", "operator", "marketCode", "operatorKey", "north", "south", "east", "west",
              "zoom", "lightweight", "only", "full", "days", "limit", "offset", "detail", "bands",
              "band", "withAzimuth", "includeObserved", "friendsOnly", "technologies", "bandMatch"}
LOCK = threading.Lock()
SEQUENCE = 0
EVENTS = []
PROFILE_EVENTS = []

# Public city-centre coordinates, with wholly invented sites and elevations.
# None of these points represents a user, a reported antenna or actual terrain.
PROFILE_POINTS = {
    "grenoble-address": (45.1915, 5.7278),
    "grenoble-device": (45.1877, 5.7243),
    "paris-address": (48.85837, 2.29448),
    "paris-device": (48.8566, 2.3522),
    "official-antenna": (45.188, 5.7129),
    "custom-antenna": (45.189, 5.715),
}
PROFILE_OFFICIAL_ID = "qa-profile-official-grenoble"
PROFILE_CUSTOM_ID = "qa-profile-custom-grenoble"
PROFILE_SEARCHES = {"qa grenoble": "grenoble", "qa paris": "paris", "qa antenne": "antenna",
                    "qa custom": "custom", "qa unresolved": "unresolved"}


def profile_search_case(query):
    # Never retain free-form search strings, even on the dedicated QA server.
    return PROFILE_SEARCHES.get(query.get("q", [""])[0].strip().lower(), "unrecognized")


def profile_places(query):
    selected = profile_search_case(query)
    if selected not in ("grenoble", "paris"):
        return {"places": []}
    lat, lng = PROFILE_POINTS[selected + "-address"]
    title = "QA Grenoble — Place Grenette" if selected == "grenoble" else "QA Paris — Champ-de-Mars"
    return {"places": [{"id": "qa-place-" + selected, "name": title,
                        "subtitle": "SYNTHETIC ADDRESS / ADRESSE SYNTHETIQUE",
                        "latitude": lat, "longitude": lng}]}


def profile_antenna(custom=False):
    lat, lng = PROFILE_POINTS["custom-antenna" if custom else "official-antenna"]
    return {"id": PROFILE_CUSTOM_ID if custom else PROFILE_OFFICIAL_ID,
            "siteId": "QA-CUSTOM-GRENOBLE" if custom else "QA-OFFICIAL-GRENOBLE",
            "latitude": lat, "longitude": lng, "lat": lat, "lng": lng,
            "operators": ["ORANGE"], "operator": "ORANGE", "technologies": ["4G"],
            "bands": [3], "azimuts": [60, 180, 300], "height": 32,
            "supportNature": "Pylône synthétique", "radioSystems": ["LTE 1800"],
            "address": "SYNTHETIQUE — SITE DE RECETTE GRENOBLE", "photoCount": 0}


def profile_site_in_query(site, query, tile=None):
    if query.get("market", ["FR"])[0] != "FR" or query.get("operator", ["ALL"])[0] not in ("ALL", "ORANGE"):
        return False
    if tile is not None:
        return tile_for(site["lat"], site["lng"], tile["z"]) == tile
    if all(key in query for key in ("north", "south", "east", "west")):
        return (float(query["south"][0]) <= site["lat"] <= float(query["north"][0]) and
                float(query["west"][0]) <= site["lng"] <= float(query["east"][0]))
    return True


def profile_response_for(path, query):
    headers = {"Cache-Control": "no-store"}
    if path == "/__qa/profile/places":
        return 200, profile_places(query), headers, 0
    if path in ("/api/antennas/quick-search", "/api/antennas/search"):
        case = profile_search_case(query)
        sites = [profile_antenna(custom=case == "custom")] if case in ("antenna", "custom") else []
        return 200, {"antennas": sites}, headers, 0
    if path in (f"/api/android/map/antenna/{PROFILE_OFFICIAL_ID}", f"/api/android/map/antenna/{PROFILE_CUSTOM_ID}"):
        body = profile_antenna(custom=path.endswith(PROFILE_CUSTOM_ID))
        body.update(bands=["LTE 1800"], sectors=[60, 180, 300], photosCount=0,
                    validationsCount=0, speedtestsCount=0)
        return 200, body, headers, 0
    if path == "/api/antennas":
        site = profile_antenna()
        return 200, {"antennas": [site] if profile_site_in_query(site, query) else []}, headers, 0
    if path == "/api/custom-sites":
        site = profile_antenna(custom=True)
        marker = {"id": site["id"], "lat": site["lat"], "lng": site["lng"], "name": site["siteId"],
                  "type": "PYLONE", "description": "SYNTHETIC QA SITE", "operatorKey": "ORANGE",
                  "photoCount": 0, "radio": {"operatorName": "ORANGE", "technology": "4G"}}
        return 200, {"sites": [marker] if profile_site_in_query(site, query) else []}, headers, 0
    match = re.fullmatch(r"/api/android/map/tiles/(antennas|speedtests|coverage|community-sites|custom-sites)/(\d+)/(\d+)/(\d+)", path)
    if match:
        layer, z, x, y = match.groups()
        tile = {"z": int(z), "x": int(x), "y": int(y)}
        if not 0 <= tile["z"] <= 20 or not all(0 <= tile[key] < 2 ** tile["z"] for key in ("x", "y")):
            return 400, {"error": "Invalid synthetic tile"}, headers, 0
        body = tile_payload(layer, tile, [])
        if layer in ("antennas", "custom-sites"):
            site = profile_antenna(custom=layer == "custom-sites")
            if profile_site_in_query(site, query, tile):
                if layer == "custom-sites":
                    site = {"id": site["id"], "lat": site["lat"], "lng": site["lng"], "name": site["siteId"],
                            "type": "PYLONE", "operatorKey": "ORANGE", "photoCount": 0,
                            "radio": {"operatorName": "ORANGE", "technology": "4G"}}
                body["markers"] = [site]
        return 200, body, headers, 0
    return None


def profile_point_tag(point):
    # Tags only: never persist coordinates supplied by an app/device.
    for tag, (lat, lng) in PROFILE_POINTS.items():
        if abs(point["lat"] - lat) <= 0.00015 and abs(point["lon"] - lng) <= 0.00015:
            return tag
    return "intermediate-or-unrecognized"


def profile_post_response(path, data):
    metadata = {"kind": "terrain" if path == "/api/rf/terrain" else "clutter", "accepted": False,
                "pointCount": 0, "originTag": "unrecognized", "destinationTag": "unrecognized"}
    if not isinstance(data, dict) or set(data) != {"points"} or not isinstance(data["points"], list):
        return 400, {"error": "Invalid synthetic profile request"}, metadata
    points = data["points"]
    metadata["pointCount"] = len(points)
    if not 1 <= len(points) <= 512 or any(
        not isinstance(point, dict) or set(point) != {"lat", "lon"} or any(
            isinstance(point[key], bool) or not isinstance(point[key], (int, float)) or not math.isfinite(point[key])
            for key in ("lat", "lon")) for point in points
    ):
        return 400, {"error": "Invalid synthetic profile samples"}, metadata
    metadata.update(originTag=profile_point_tag(points[0]), destinationTag=profile_point_tag(points[-1]))
    if any(not (45.17 <= point["lat"] <= 45.21 and 5.69 <= point["lon"] <= 5.75) for point in points):
        # A forbidden Paris→Grenoble request is counted, but is never served as
        # plausible terrain and its submitted coordinates are never logged.
        return 422, {"error": "Profile samples outside the synthetic Grenoble fixture", "code": "QA_SYNTHETIC_AREA_ONLY"}, metadata
    metadata["accepted"] = True
    if path == "/api/rf/terrain":
        results = [{"elevation": round(212 + 12 * math.sin((point["lat"] - 45.188) * 160) +
                                        3 * math.cos((point["lon"] - 5.7129) * 100), 2)} for point in points]
    else:
        results = [{"buildingHeightM": 6 if math.sin((point["lon"] - 5.7129) * 600) > 0.75 else 0,
                    "buildingCount": 1 if math.sin((point["lon"] - 5.7129) * 600) > 0.75 else 0}
                   for point in points]
    return 200, {"results": results}, metadata

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
    if mode == PROFILE_SCENARIO and PROFILE_QA_ENABLED:
        profiled = profile_response_for(path, query)
        if profiled is not None:
            return profiled
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
        if entry.get("profile") is not None and entry.get("event") == "received":
            PROFILE_EVENTS.append(entry)
            del PROFILE_EVENTS[:-128]
        with (STATE_ROOT / "requests.ndjson").open("a") as output:
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
        if PROFILE_QA_ENABLED and urlsplit(self.path).path in ("/api/rf/terrain", "/api/rf/clutter"):
            self.profile_post()
            return
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
            if data["scenario"] == PROFILE_SCENARIO and not PROFILE_QA_ENABLED:
                raise ValueError()
            if any(not isinstance(layer, str) or layer not in LAYERS for layer in data["layers"]):
                raise ValueError()
            state = {"scenario": data["scenario"], "layers": data["layers"], "revision": str(uuid.uuid4()), "gridRevision": 2}
            with LOCK:
                temporary = STATE_ROOT / "scenario.json.tmp"
                temporary.write_text(json.dumps(state) + "\n")
                temporary.replace(STATE_ROOT / "scenario.json")
            self.json_response(200, state)
        except (ValueError, TypeError):
            self.json_response(400, {"error": "invalid-control"})

    def profile_post(self):
        global SEQUENCE
        path = urlsplit(self.path).path
        state = json.loads((STATE_ROOT / "scenario.json").read_text())
        if state.get("scenario") != PROFILE_SCENARIO or self.headers.get("Origin") is not None:
            self.json_response(403, {"error": "synthetic-profile-mode-required"})
            return
        length = self.headers.get("Content-Length", "")
        if (not length.isdecimal() or not 0 < int(length) <= 65536 or
                self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json"):
            self.json_response(400, {"error": "invalid-profile-request"})
            return
        try:
            data = json.loads(self.rfile.read(int(length)))
        except (ValueError, TypeError):
            data = None
        status, body, metadata = profile_post_response(path, data)
        with LOCK:
            SEQUENCE += 1
            request_id = f"map-fixture-{SEQUENCE:06d}"
        entry = {"requestId": request_id, "scenario": state, "path": path, "query": {},
                 "status": status, "delaySeconds": 0, "time": time.time(), "profile": metadata}
        record({**entry, "event": "received"})
        try:
            self.json_response(status, body)
            record({**entry, "event": "sent", "time": time.time()})
        except (BrokenPipeError, ConnectionResetError):
            record({**entry, "event": "client-disconnected", "time": time.time()})

    def do_GET(self):
        global SEQUENCE
        url = urlsplit(self.path)
        if url.path == "/__qa/profile/state":
            if not PROFILE_QA_ENABLED or self.headers.get("Origin") is not None or self.headers.get("X-SQ-QA") != "map-runtime-v1":
                self.json_response(403, {"error": "native-profile-qa-only"})
                return
            with LOCK:
                state = json.loads((STATE_ROOT / "scenario.json").read_text())
                events = [entry for entry in PROFILE_EVENTS if entry["scenario"].get("revision") == state.get("revision")]
                counters = {kind: sum(entry["profile"].get("kind") == kind for entry in events)
                            for kind in ("places", "search", "detail", "terrain", "clutter")}
                value = {"profileQARevision": 1, "state": state, "counters": counters, "events": events}
            self.json_response(200, value)
            return
        if url.path == "/__qa/state":
            with LOCK:
                value = {"state": json.loads((STATE_ROOT / "scenario.json").read_text()), "events": list(EVENTS)}
            self.json_response(200, value)
            return
        query = parse_qs(url.query)
        with LOCK:
            SEQUENCE += 1
            request_id = f"map-fixture-{SEQUENCE:06d}"
        state = json.loads((STATE_ROOT / "scenario.json").read_text())
        status, body, headers, delay = response_for(url.path, query, state)
        safe = {k: v for k, v in query.items() if k in SAFE_QUERY}
        profile_metadata = None
        if PROFILE_QA_ENABLED and state.get("scenario") == PROFILE_SCENARIO:
            # In this recipe even camera bounds are excluded from traces. Only
            # known fixture names and aggregate counts describe the test input.
            safe = {k: v for k, v in safe.items() if k not in ("north", "south", "east", "west")}
            if url.path == "/__qa/profile/places":
                profile_metadata = {"kind": "places", "queryCase": profile_search_case(query)}
            elif url.path in ("/api/antennas/quick-search", "/api/antennas/search"):
                profile_metadata = {"kind": "search", "queryCase": profile_search_case(query)}
            elif url.path in (f"/api/android/map/antenna/{PROFILE_OFFICIAL_ID}", f"/api/android/map/antenna/{PROFILE_CUSTOM_ID}"):
                profile_metadata = {"kind": "detail", "siteKind": "custom" if url.path.endswith(PROFILE_CUSTOM_ID) else "official"}
        # Tile / known route paths only; unsupported detail IDs are not persisted.
        safe_path = url.path if url.path in ("/api/social/map/snapshot", "/api/social/map/stream", "/api/android/markets",
                    "/api/antennas", "/api/map/photos", "/api/community-outages", "/api/map/planned-sites",
                    "/api/android/map/incidents", "/api/app/version-policy", "/api/coverage/points") or re.fullmatch(
                        r"/api/android/map/tiles/[a-z-]+/\d+/\d+/\d+", url.path) else "[unsupported-route]"
        if profile_metadata is not None:
            safe_path = url.path
        entry = {"requestId": request_id, "scenario": state, "path": safe_path, "query": safe,
                 "status": status, "delaySeconds": delay, "time": time.time()}
        if profile_metadata is not None:
            entry["profile"] = profile_metadata
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
    assert profile_places({"q": ["QA Grenoble"]})["places"][0]["id"] == "qa-place-grenoble"
    assert profile_places({"q": ["QA Paris"]})["places"][0]["id"] == "qa-place-paris"
    assert profile_places({"q": ["QA unresolved"]}) == {"places": []}
    assert profile_places({"q": ["unrecognized input is never retained"]}) == {"places": []}
    for tag in ("grenoble-address", "grenoble-device"):
        points = [{"lat": PROFILE_POINTS[key][0], "lon": PROFILE_POINTS[key][1]}
                  for key in (tag, "official-antenna")]
        for path in ("/api/rf/terrain", "/api/rf/clutter"):
            status, body, metadata = profile_post_response(path, {"points": points})
            assert status == 200 and len(body["results"]) == 2
            assert metadata["originTag"] == tag and metadata["destinationTag"] == "official-antenna"
            assert metadata["accepted"] is True
    outside = [{"lat": PROFILE_POINTS[key][0], "lon": PROFILE_POINTS[key][1]}
               for key in ("paris-device", "official-antenna")]
    assert profile_post_response("/api/rf/terrain", {"points": outside})[0] == 422
    assert profile_post_response("/api/rf/terrain", {"points": [{"lat": True, "lon": 5.7}]})[0] == 400
    print(f"PASS: {checked} tile payload structures across z4..16; {len(SCENARIOS) * len(LAYERS)} scenario/layer responses. No HTTP server or iOS process started. Native Swift decoding and painting remain unverified.")


def main():
    global STATE_ROOT, PROFILE_QA_ENABLED
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8769)
    parser.add_argument("--set-scenario", choices=SCENARIOS)
    parser.add_argument("--layers", nargs="+", choices=LAYERS, default=list(LAYERS))
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--profile-qa", action="store_true", help="Enable synthetic address/profile recipe only on dedicated port 8770")
    parser.add_argument("--state-dir", type=Path, help="Separate ignored state/log directory; default keeps the existing recipe paths")
    args = parser.parse_args()
    if args.profile_qa and (args.port != 8770 or args.state_dir is None):
        parser.error("--profile-qa requires --port 8770 and a dedicated --state-dir")
    if args.set_scenario == PROFILE_SCENARIO and not args.profile_qa:
        parser.error("profile-origin requires --profile-qa")
    PROFILE_QA_ENABLED = args.profile_qa
    if args.state_dir is not None:
        STATE_ROOT = args.state_dir.resolve()
        if args.profile_qa and STATE_ROOT == ROOT:
            parser.error("profile QA state must not share the legacy fixture directory")
        STATE_ROOT.mkdir(parents=True, exist_ok=True)
    if args.set_scenario:
        temporary = STATE_ROOT / "scenario.json.tmp"
        temporary.write_text(json.dumps({"scenario": args.set_scenario, "layers": args.layers, "gridRevision": 2}, indent=2) + "\n")
        temporary.replace(STATE_ROOT / "scenario.json")
        return
    if args.check:
        check()
        return
    if PROFILE_QA_ENABLED and not (STATE_ROOT / "scenario.json").exists():
        (STATE_ROOT / "scenario.json").write_text(json.dumps({"scenario": PROFILE_SCENARIO,
            "layers": list(LAYERS), "gridRevision": 2, "revision": str(uuid.uuid4())}) + "\n")
    print(f"Synthetic map fixture listening on http://127.0.0.1:{args.port}; no upstream proxy", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
