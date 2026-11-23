#!/usr/bin/env python3
"""Publish a built place to an existing Roblox experience with Open Cloud.

Reads credentials from the environment (set by GitHub Actions secrets/variables):
  ROBLOX_API_KEY      Open Cloud API key (secret — never printed)
  ROBLOX_UNIVERSE_ID  the experience's Universe ID
  ROBLOX_PLACE_ID     the place to overwrite (usually the start place)

Steps:
  1. Privacy guard — reads the experience's visibility and refuses to publish to
     a PUBLIC experience unless --allow-public is given. If visibility can't be
     read, it also refuses unless --allow-public is given.
  2. Upload — Assets API (PATCH /assets/v1/assets/{placeId}), which runs as an
     async operation that is polled until it finishes. If the key lacks the
     "assets" permission, falls back to the Place Publishing API
     (POST /universes/v1/{universeId}/places/{placeId}/versions), which answers
     synchronously with the new version number.
  3. Writes a summary (and the direct links) to $GITHUB_STEP_SUMMARY.

Usage:
  python3 scripts/publish.py --place-file build/TumbleCircuit.rbxl [--version-type Published|Saved]
                             [--method auto|assets|legacy] [--allow-public]

Exit codes: 0 published, 1 failed, 2 refused by the privacy guard, 3 bad configuration.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

DEFAULT_BASE = "https://apis.roblox.com"
USER_AGENT = "tumble-circuit-deploy/1.0"
POLL_INTERVAL = float(os.environ.get("ROBLOX_POLL_INTERVAL", "2"))
POLL_TIMEOUT = float(os.environ.get("ROBLOX_POLL_TIMEOUT", "300"))


class PublishError(Exception):
    pass


class HttpResult:
    def __init__(self, status: int, body: bytes):
        self.status = status
        self.body = body

    def json(self):
        try:
            return json.loads(self.body.decode("utf-8") or "null")
        except (ValueError, UnicodeDecodeError):
            return None

    def text(self, limit: int = 600) -> str:
        text = self.body.decode("utf-8", errors="replace").strip()
        return text if len(text) <= limit else text[:limit] + "…"


def log(message: str):
    print(message, flush=True)


def request(method: str, url: str, api_key: str, body: bytes | None = None, content_type: str | None = None,
            timeout: float = 120) -> HttpResult:
    headers = {"x-api-key": api_key, "User-Agent": USER_AGENT, "Accept": "application/json"}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return HttpResult(response.status, response.read())
    except urllib.error.HTTPError as exc:
        return HttpResult(exc.code, exc.read() or b"")
    except urllib.error.URLError as exc:
        raise PublishError(f"network error calling {method} {url}: {exc.reason}") from None


def multipart(fields: list[tuple[str, str, bytes, str | None]]) -> tuple[bytes, str]:
    """fields: (name, content_type, data, filename)."""
    boundary = "----TumbleCircuit" + uuid.uuid4().hex
    chunks = []
    for name, content_type, data, filename in fields:
        disposition = f'form-data; name="{name}"'
        if filename:
            disposition += f'; filename="{filename}"'
        chunks.append(f"--{boundary}\r\n".encode())
        chunks.append(f"Content-Disposition: {disposition}\r\n".encode())
        chunks.append(f"Content-Type: {content_type}\r\n\r\n".encode())
        chunks.append(data)
        chunks.append(b"\r\n")
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def place_content_type(path: str) -> str:
    return "application/xml" if path.lower().endswith(".rbxlx") else "application/octet-stream"


def check_visibility(base: str, api_key: str, universe_id: str, allow_public: bool) -> str:
    result = request("GET", f"{base}/cloud/v2/universes/{universe_id}", api_key)
    if result.status == 200 and isinstance(result.json(), dict):
        data = result.json()
        visibility = str(data.get("visibility", "VISIBILITY_UNSPECIFIED"))
        name = data.get("displayName") or "(unnamed)"
        log(f"Experience: {name} — visibility {visibility}")
        if visibility == "PRIVATE":
            return visibility
        if allow_public:
            log("WARNING: experience is not PRIVATE; continuing because --allow-public was given.")
            return visibility
        raise SystemExit(_refuse(
            f"The experience is {visibility}, not PRIVATE. Publishing now would update a game other people can "
            "join. Make it Private in Creator Hub, or re-run the workflow with 'allow_public' ticked if you "
            "really mean to publish publicly."
        ))
    if allow_public:
        log(f"WARNING: could not read experience visibility (HTTP {result.status}); continuing because "
            "--allow-public was given.")
        return "UNKNOWN"
    hint = ""
    if result.status in (401, 403):
        hint = " Check that the API key is valid and that its Accepted IP Addresses include 0.0.0.0/0."
    elif result.status == 404:
        hint = " Check ROBLOX_UNIVERSE_ID (it is the experience/universe ID, not the place ID)."
    raise SystemExit(_refuse(
        f"Could not confirm the experience is private (HTTP {result.status}: {result.text(200)}).{hint} "
        "Nothing was published."
    ))


def _refuse(message: str) -> int:
    log(f"REFUSED: {message}")
    write_summary(["### ⛔ Deploy refused", "", message])
    return 2


def publish_assets(base: str, api_key: str, place_id: str, path: str, data: bytes, published: bool):
    payload = json.dumps({"assetId": int(place_id), "assetType": "Place", "published": published}).encode()
    body, content_type = multipart([
        ("request", "application/json", payload, None),
        ("fileContent", place_content_type(path), data, os.path.basename(path)),
    ])
    result = request("PATCH", f"{base}/assets/v1/assets/{place_id}", api_key, body, content_type, timeout=300)
    if result.status in (401, 403, 404):
        return None, result  # permission/endpoint problem: let the caller fall back
    if result.status >= 300:
        raise PublishError(f"Assets API upload failed (HTTP {result.status}): {result.text()}")
    response = result.json() or {}
    if response.get("done") and "response" in response:
        return response, result
    operation_path = response.get("path") or ""
    operation_id = response.get("operationId") or operation_path.rsplit("/", 1)[-1]
    if not operation_id:
        raise PublishError(f"Assets API did not return an operation: {result.text()}")
    log(f"Upload accepted (operation {operation_id}); waiting for Roblox to process it…")
    deadline = time.monotonic() + POLL_TIMEOUT
    attempt = 0
    while True:
        attempt += 1
        poll = request("GET", f"{base}/assets/v1/operations/{operation_id}", api_key)
        if poll.status == 429:
            time.sleep(min(10, POLL_INTERVAL * 2))
            continue
        if poll.status >= 300:
            raise PublishError(f"Polling operation failed (HTTP {poll.status}): {poll.text()}")
        state = poll.json() or {}
        if state.get("done"):
            if "error" in state and state["error"]:
                err = state["error"]
                raise PublishError(f"Roblox rejected the place: {err.get('code', '')} {err.get('message', '')}".strip())
            return state, poll
        if time.monotonic() > deadline:
            raise PublishError(f"Timed out after {POLL_TIMEOUT:.0f}s waiting for operation {operation_id}")
        if attempt % 5 == 0:
            log(f"  still processing… ({attempt} checks)")
        time.sleep(POLL_INTERVAL)


def publish_legacy(base: str, api_key: str, universe_id: str, place_id: str, path: str, data: bytes,
                   version_type: str):
    url = f"{base}/universes/v1/{universe_id}/places/{place_id}/versions?versionType={version_type}"
    result = request("POST", url, api_key, data, place_content_type(path), timeout=300)
    if result.status >= 300:
        hint = ""
        if result.status in (401, 403):
            hint = (" The API key needs the 'universe-places' permission with Write for this experience, "
                    "and its Accepted IP Addresses must include 0.0.0.0/0.")
        elif result.status == 404:
            hint = " Check ROBLOX_UNIVERSE_ID and ROBLOX_PLACE_ID belong to the same experience."
        elif result.status == 409:
            hint = " The place may be open in a Team Create session; close it and retry."
        raise PublishError(f"Place Publishing API failed (HTTP {result.status}): {result.text()}{hint}")
    body = result.json() or {}
    version = body.get("versionNumber")
    if version is None:
        raise PublishError(f"Place Publishing API answered without a version number: {result.text()}")
    return version


def write_summary(lines: list[str]):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Publish a place file with Roblox Open Cloud")
    parser.add_argument("--place-file", required=True)
    parser.add_argument("--version-type", choices=["Published", "Saved"], default="Published")
    parser.add_argument("--method", choices=["auto", "assets", "legacy"], default="auto")
    parser.add_argument("--allow-public", action="store_true")
    args = parser.parse_args(argv)

    api_key = os.environ.get("ROBLOX_API_KEY", "").strip()
    universe_id = os.environ.get("ROBLOX_UNIVERSE_ID", "").strip()
    place_id = os.environ.get("ROBLOX_PLACE_ID", "").strip()
    base = os.environ.get("ROBLOX_API_BASE", DEFAULT_BASE).rstrip("/")

    missing = [name for name, value in (("ROBLOX_API_KEY secret", api_key), ("ROBLOX_UNIVERSE_ID variable", universe_id),
                                        ("ROBLOX_PLACE_ID variable", place_id)) if not value]
    if missing:
        log("Missing configuration: " + ", ".join(missing) + ". See docs/SETUP.md.")
        write_summary(["### ⚠️ Deploy not configured", "", "Missing: " + ", ".join(missing) + ". See docs/SETUP.md."])
        return 3
    if not universe_id.isdigit() or not place_id.isdigit():
        log("ROBLOX_UNIVERSE_ID and ROBLOX_PLACE_ID must be numbers (copy them from Creator Hub).")
        return 3
    if universe_id == place_id:
        log("WARNING: Universe ID and Place ID are identical — they are usually different numbers. Continuing.")
    if not os.path.isfile(args.place_file):
        log(f"Place file not found: {args.place_file}")
        return 3
    with open(args.place_file, "rb") as f:
        data = f.read()
    if len(data) == 0:
        log("Place file is empty")
        return 3
    log(f"Place file: {args.place_file} ({len(data):,} bytes) → universe {universe_id}, place {place_id} "
        f"[{args.version_type}]")

    check_visibility(base, api_key, universe_id, args.allow_public)

    published = args.version_type == "Published"
    method_used = None
    version = None
    try:
        if args.method in ("auto", "assets"):
            state, result = publish_assets(base, api_key, place_id, args.place_file, data, published)
            if state is not None:
                response = state.get("response") or {}
                version = response.get("revisionId")
                method_used = "Assets API (async operation)"
            elif args.method == "assets":
                raise PublishError(f"Assets API refused the upload (HTTP {result.status}): {result.text()}")
            else:
                log(f"Assets API not available for this key (HTTP {result.status}); "
                    "falling back to the Place Publishing API.")
        if method_used is None:
            version = publish_legacy(base, api_key, universe_id, place_id, args.place_file, data, args.version_type)
            method_used = "Place Publishing API"
    except PublishError as exc:
        log(f"FAILED: {exc}")
        write_summary(["### ❌ Deploy failed", "", str(exc)])
        return 1

    game_url = f"https://www.roblox.com/games/{place_id}"
    hub_url = f"https://create.roblox.com/dashboard/creations/experiences/{universe_id}/overview"
    state_word = "published" if published else "saved (not live)"
    log(f"SUCCESS: version {version} {state_word} via {method_used}")
    log(f"Play (app):            {game_url}")
    log(f"Play in Browser (Hub): {hub_url}")
    write_summary([
        f"### ✅ Tumble Circuit {state_word}",
        "",
        f"- Version: **{version}** via {method_used}",
        f"- Play in the Roblox app: {game_url}",
        f"- Play in Browser (Chrome on Android): open {hub_url} and tap **Play in Browser**",
        "- The experience stays private: only you (and anyone you add as a collaborator) can join.",
    ])
    return 0


if __name__ == "__main__":
    sys.exit(main())
