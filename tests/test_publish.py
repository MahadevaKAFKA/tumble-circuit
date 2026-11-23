#!/usr/bin/env python3
"""Tests for scripts/publish.py against a local fake Open Cloud server.

Scenarios: async Assets API success with polling, operation error, fallback to
the Place Publishing API when the key lacks the assets permission, privacy
guard refusals (public experience, unreadable visibility), --allow-public,
missing configuration, and that the API key is never printed.

Usage: python3 tests/test_publish.py
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import publish  # noqa: E402

API_KEY = "test-key-SHOULD-NEVER-APPEAR-IN-LOGS"
UNIVERSE = "1111"
PLACE = "2222"


class FakeCloud:
    def __init__(self):
        self.visibility = "PRIVATE"
        self.visibility_status = 200
        self.assets_status = 200
        self.operation_error = None
        self.polls_before_done = 2
        self.polls = 0
        self.legacy_status = 200
        self.requests = []
        self.last_upload = None

    def handler(self):
        cloud = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, status, payload):
                body = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _auth_ok(self):
                return self.headers.get("x-api-key") == API_KEY

            def do_GET(self):
                cloud.requests.append(("GET", self.path))
                if not self._auth_ok():
                    return self._send(401, {"message": "bad key"})
                if self.path == f"/cloud/v2/universes/{UNIVERSE}":
                    if cloud.visibility_status != 200:
                        return self._send(cloud.visibility_status, {"message": "nope"})
                    return self._send(200, {"path": f"universes/{UNIVERSE}", "displayName": "Tumble Test",
                                            "visibility": cloud.visibility})
                if self.path == "/assets/v1/operations/op-123":
                    cloud.polls += 1
                    if cloud.polls < cloud.polls_before_done:
                        return self._send(200, {"path": "operations/op-123", "done": False})
                    if cloud.operation_error:
                        return self._send(200, {"path": "operations/op-123", "done": True,
                                                "error": cloud.operation_error})
                    return self._send(200, {"path": "operations/op-123", "done": True,
                                            "response": {"path": f"assets/{PLACE}", "revisionId": "7",
                                                         "isPublished": True}})
                return self._send(404, {"message": "not found"})

            def do_PATCH(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                cloud.requests.append(("PATCH", self.path))
                if not self._auth_ok():
                    return self._send(401, {"message": "bad key"})
                if self.path == f"/assets/v1/assets/{PLACE}":
                    if cloud.assets_status != 200:
                        return self._send(cloud.assets_status, {"message": "insufficient scope"})
                    cloud.last_upload = (self.headers.get("Content-Type"), body)
                    return self._send(200, {"path": "operations/op-123", "done": False})
                return self._send(404, {"message": "not found"})

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                cloud.requests.append(("POST", self.path))
                if not self._auth_ok():
                    return self._send(401, {"message": "bad key"})
                if self.path.startswith(f"/universes/v1/{UNIVERSE}/places/{PLACE}/versions"):
                    if cloud.legacy_status != 200:
                        return self._send(cloud.legacy_status, {"message": "forbidden"})
                    cloud.last_upload = (self.headers.get("Content-Type"), body)
                    return self._send(200, {"versionNumber": 42})
                return self._send(404, {"message": "not found"})

        return Handler


@contextlib.contextmanager
def fake_server(cloud: FakeCloud):
    server = ThreadingHTTPServer(("127.0.0.1", 0), cloud.handler())
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()


def run(cloud: FakeCloud, *args, env_overrides=None):
    place = tempfile.NamedTemporaryFile(suffix=".rbxl", delete=False)
    place.write(b"<roblox>fake place</roblox>")
    place.close()
    summary = tempfile.NamedTemporaryFile(suffix=".md", delete=False)
    summary.close()
    with fake_server(cloud) as base:
        env = {
            "ROBLOX_API_KEY": API_KEY,
            "ROBLOX_UNIVERSE_ID": UNIVERSE,
            "ROBLOX_PLACE_ID": PLACE,
            "ROBLOX_API_BASE": base,
            "GITHUB_STEP_SUMMARY": summary.name,
        }
        env.update(env_overrides or {})
        saved = {k: os.environ.get(k) for k in env}
        os.environ.update({k: v for k, v in env.items() if v is not None})
        for k, v in env.items():
            if v is None:
                os.environ.pop(k, None)
        publish.POLL_INTERVAL = 0.01
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                try:
                    code = publish.main(["--place-file", place.name, *args])
                except SystemExit as exc:
                    code = exc.code
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
    with open(summary.name, encoding="utf-8") as f:
        summary_text = f.read()
    os.unlink(place.name)
    os.unlink(summary.name)
    output = out.getvalue()
    assert API_KEY not in output, "API key leaked into output"
    assert API_KEY not in summary_text, "API key leaked into step summary"
    return code, output, summary_text


def test_assets_success():
    cloud = FakeCloud()
    code, out, summary = run(cloud)
    assert code == 0, out
    assert "version 7 published via Assets API" in out, out
    assert cloud.polls >= 2, "operation was not polled until done"
    content_type, body = cloud.last_upload
    assert content_type.startswith("multipart/form-data; boundary="), content_type
    assert b'name="request"' in body and b'"published": true' in body and b'"assetType": "Place"' in body
    assert b'name="fileContent"' in body and b"application/octet-stream" in body
    assert f"https://www.roblox.com/games/{PLACE}" in summary


def test_saved_version():
    cloud = FakeCloud()
    code, out, _ = run(cloud, "--version-type", "Saved")
    assert code == 0, out
    assert b'"published": false' in cloud.last_upload[1]


def test_operation_error_fails():
    cloud = FakeCloud()
    cloud.operation_error = {"code": "INVALID_ARGUMENT", "message": "bad place"}
    code, out, summary = run(cloud)
    assert code == 1, out
    assert "bad place" in out and "Deploy failed" in summary


def test_fallback_to_legacy():
    cloud = FakeCloud()
    cloud.assets_status = 403
    code, out, _ = run(cloud)
    assert code == 0, out
    assert "falling back" in out and "version 42" in out, out
    assert any(m == "POST" and "versionType=Published" in p for m, p in cloud.requests)


def test_legacy_permission_error_hint():
    cloud = FakeCloud()
    cloud.assets_status = 403
    cloud.legacy_status = 403
    code, out, _ = run(cloud)
    assert code == 1 and "universe-places" in out, out


def test_public_refused():
    cloud = FakeCloud()
    cloud.visibility = "PUBLIC"
    code, out, summary = run(cloud)
    assert code == 2, out
    assert not any(m in ("PATCH", "POST") for m, _ in cloud.requests), "uploaded despite public experience"
    assert "refused" in summary.lower()


def test_public_allowed_with_flag():
    cloud = FakeCloud()
    cloud.visibility = "PUBLIC"
    code, out, _ = run(cloud, "--allow-public")
    assert code == 0, out


def test_unknown_visibility_refused():
    cloud = FakeCloud()
    cloud.visibility_status = 403
    code, out, _ = run(cloud)
    assert code == 2 and "0.0.0.0/0" in out, out
    assert not any(m in ("PATCH", "POST") for m, _ in cloud.requests)


def test_missing_config():
    cloud = FakeCloud()
    code, out, summary = run(cloud, env_overrides={"ROBLOX_API_KEY": None})
    assert code == 3 and "ROBLOX_API_KEY" in out, out
    assert not cloud.requests


def test_bad_ids():
    cloud = FakeCloud()
    code, out, _ = run(cloud, env_overrides={"ROBLOX_PLACE_ID": "abc"})
    assert code == 3, out


def main() -> int:
    tests = [(name, fn) for name, fn in globals().items() if name.startswith("test_") and callable(fn)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"  ok   {name}")
        except AssertionError as exc:
            failed += 1
            print(f"  FAIL {name}: {exc}")
    print(f"\npublish script: {len(tests) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
