#!/usr/bin/env python3
"""F06 real UI/root gateway sockets with a synthetic loopback PKCE issuer.

Reuses the recovered F05 fixture's CLI/socket lifecycle, not another UI or
credential manager. Never contacts OpenAI/CPA or uses ambient provider keys.
All private files, runtime state and logs are in the attached worktree's build.
"""

import argparse
import base64
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import sys
import tempfile
from types import SimpleNamespace
from urllib.parse import parse_qs, urlencode, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("f06_f05_fixture", ROOT / "scripts/smoke-account-ui.py")
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)
ACCOUNTS = ["synthetic-codex-one", "synthetic-codex-two"]
MODELS = ["gpt-5.5", "gpt-5.4"]
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
PRIVATE = [f"synthetic-private-codex-{field}-{n}" for n in (1, 2)
           for field in ("access", "refresh", "rotated-access", "rotated-refresh", "code")]
local.SECRETS.extend(PRIVATE)


def b64(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def token(field, n):
    return f"synthetic-private-codex-{field}-{n}"


def slot(state, n):
    return state / ("runtime-" + b64(json.dumps(
        ["codex", "oauth", ACCOUNTS[n - 1]], separators=(",", ":")).encode()) + ".json")


def closed(port):
    with socket.socket() as probe:
        return probe.connect_ex(("127.0.0.1", port)) != 0


def kimi_cancel_regression(f):
    """Safe phase evidence for the parent-reported F05 entered-poll cancel."""
    f.admin("replace")
    f.provider.phase("blocked-poll")
    f.login()
    local.wait(f.provider.polled.is_set, label="real Kimi blocked poll entry")
    before = f.status()["login"]
    status, _, body = f.api("/api/cancel", {"account": local.ACCOUNT})
    after = f.status()["login"]
    # These fields are coordinator-owned public phases/errors, not grants,
    # private record bytes, callback values or provider response bodies.
    evidence = {"before": before, "cancel_status": status, "after": after,
                "error": body.get("error"), "polls": f.provider.counts["poll"]}
    assert status == 200, f"F05 entered-poll cancellation failed: {evidence}"
    assert before == "waiting" and after == "cancelled", evidence
    saved = json.loads(f.slot.read_text())
    assert saved["access_token"] == local.ADMIN_ACCESS
    assert saved["refresh_token"] == local.ADMIN_REFRESH
    f.provider.release.set()
    return evidence


class Upstream(local.Upstream):
    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path != "/oauth/authorize":
            return super().do_GET()
        fields = parse_qs(parsed.query)
        n = self.server.codex_identity
        assert fields["client_id"] == [CLIENT_ID]
        assert fields["scope"] == ["openid email profile offline_access"]
        assert fields["response_type"] == ["code"]
        assert fields["code_challenge_method"] == ["S256"]
        assert fields["prompt"] == ["login"]
        assert fields["id_token_add_organizations"] == ["true"]
        assert fields["codex_cli_simplified_flow"] == ["true"]
        assert "code_verifier" not in fields
        assert slot(self.server.state, n).exists(), "S5 reservation must precede issuer I/O"
        code = token("code", n)
        self.server.codes[code] = (fields["code_challenge"][0], fields["redirect_uri"][0], n)
        location = fields["redirect_uri"][0] + "?" + urlencode({
            "state": fields["state"][0], "code": code,
        })
        self.server.counts["authorize"] += 1
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()

    def do_POST(self):
        if self.path not in ("/oauth/token", "/backend-api/codex/responses"):
            return super().do_POST()
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/oauth/token":
            fields = parse_qs(raw.decode())
            assert fields["client_id"] == [CLIENT_ID]
            if fields["grant_type"] == ["refresh_token"]:
                n = next(n for n in (1, 2) if fields["refresh_token"] == [token("refresh", n)])
                self.server.counts["codex_refresh"] += 1
                return self.reply(200, {
                    "access_token": token("rotated-access", n),
                    "refresh_token": token("rotated-refresh", n), "expires_in": 3600,
                })  # Omitted ID token must preserve trusted routing metadata.
            assert fields["grant_type"] == ["authorization_code"]
            code = fields["code"][0]
            challenge, redirect, n = self.server.codes.pop(code)
            verifier = fields["code_verifier"][0]
            self.server.private_ephemeral.add(verifier)
            assert 43 <= len(verifier) <= 128
            assert b64(hashlib.sha256(verifier.encode()).digest()) == challenge
            assert fields["redirect_uri"] == [redirect]
            self.server.counts["exchange"] += 1
            self.server.exchange_entered.set()
            if self.server.codex_mode == "blocked":
                self.server.release.wait(30)
            claims = {"https://api.openai.com/auth": {"chatgpt_account_id": ACCOUNTS[n - 1]}}
            return self.reply(200, {
                "access_token": token("access", n), "refresh_token": token("refresh", n),
                "expires_in": 1, "token_type": "Bearer",
                "id_token": "synthetic." + b64(json.dumps(claims).encode()) + ".not-a-signature",
            })
        payload = json.loads(raw)
        n = MODELS.index(payload["model"]) + 1
        assert self.headers.get("Authorization") == "Bearer " + token("rotated-access", n)
        assert self.headers.get("Chatgpt-Account-Id") == ACCOUNTS[n - 1]
        assert payload["stream"] is True
        self.server.counts["responses"] += 1
        base = {"id": f"resp_f06_{n}", "object": "response", "model": payload["model"], "output": []}
        frames = "".join(
            f"event: {event}\ndata: " + json.dumps({
                "type": event, "sequence_number": sequence,
                "response": dict(base, status=status),
            }) + "\n\n"
            for sequence, event, status in [
                (0, "response.created", "in_progress"), (1, "response.completed", "completed"),
            ]
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(frames)))
        self.end_headers()
        self.wfile.write(frames)


class Fixture(local.Fixture):
    def __init__(self, directory, args):
        super().__init__(directory, args)
        self.callback_port = local.free_port()
        self.provider.RequestHandlerClass = Upstream
        self.provider.codex_identity = 1
        self.provider.codex_mode = "authorize"
        self.provider.codes = {}
        self.provider.private_ephemeral = set()
        self.provider.exchange_entered = __import__("threading").Event()
        self.provider.counts.update(authorize=0, exchange=0, codex_refresh=0, responses=0)
        settings = json.loads(self.config.read_text())
        origin = f"http://127.0.0.1:{self.provider.server_port}"
        settings["accounts"] += [{
            "provider": "codex", "auth_mode": "oauth", "id": account,
            "origin": origin, "models": [model],
            "oauth": {
                "authorize_url": origin + "/oauth/authorize", "token_url": origin + "/oauth/token",
                "redirect_uri": f"http://127.0.0.1:{self.callback_port}/auth/callback",
            },
        } for account, model in zip(ACCOUNTS, MODELS)]
        settings["codex_catalog"] = {"models": [{
            "slug": model, "context_window": 272000,
            "supported_reasoning_levels": [{"effort": "medium"}],
            "default_reasoning_level": "medium", "input_modalities": ["text"],
            "prefer_websockets": False, "use_responses_lite": False,
        } for model in MODELS]}
        self.config.write_text(json.dumps(settings))
        # No ambient credential/proxy/plugin variables are inherited by the VMs.
        self.env = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"],
                    "TMPDIR": str(directory), "ERL_FLAGS": "+S 2:2 +A 2"}

    def row(self, n):
        status, _, body = self.api("/api/status")
        assert status == 200
        return next(a for a in body["accounts"] if a["id"] == ACCOUNTS[n - 1])

    def codex_phase(self, n, phase):
        value = local.wait(lambda: (value if (value := self.row(n))["login"] == phase else None),
                           label=f"Codex {n} {phase}")
        if phase != "waiting":
            assert "authorization_url" not in value
        return value

    def begin_codex(self, n):
        self.provider.codex_identity = n
        self.provider.exchange_entered.clear()
        self.provider.release.clear()
        assert self.api("/api/login", {"account": ACCOUNTS[n - 1]})[0] == 202
        url = self.codex_phase(n, "waiting")["authorization_url"]
        state = parse_qs(urlsplit(url).query)["state"][0]
        self.provider.private_ephemeral.add(state)
        assert len(state) == 43
        assert "code_verifier" not in url
        assert "authorization_url" not in self.row(3 - n)
        return url

    def authorize(self, url):
        parsed = urlsplit(url)
        conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=10)
        try:
            conn.request("GET", parsed.path + "?" + parsed.query)
            response = conn.getresponse()
            assert response.status == 302
            location = response.getheader("Location")
            response.read()
        finally:
            conn.close()
        return self.callback(location)

    def callback(self, location):
        parsed = urlsplit(location)
        assert parsed.hostname == "127.0.0.1" and parsed.port == self.callback_port
        try:
            return self.http(parsed.port, "GET", parsed.path + "?" + parsed.query)[0]
        except (OSError, http.client.HTTPException):
            return 0

    def responses(self, n, expected=200):
        status, _, body = self.http(self.gateway_port, "POST", "/v1/responses", {
            "model": MODELS[n - 1], "input": "synthetic F06 usable configured grant",
        }, {"Authorization": "Bearer " + local.CLIENT, "Content-Type": "application/json"})
        if expected == 200:
            assert status == 200, "UI grant is not usable by the configured Codex gateway"
            assert json.loads(body)["id"] == f"resp_f06_{n}"
        else:
            assert status != 200

    def admin_codex(self, n, delete=False):
        if delete:
            self.command(["providers", "credential", "delete", str(self.config), ACCOUNTS[n - 1]])
        else:
            grant = local.private(self.directory / "codex-admin.json", json.dumps({
                "access_token": "synthetic-private-admin-access",
                "refresh_token": "synthetic-private-admin-refresh",
                "expires_at_ms": 9_000_000_000_000, "chatgpt_account_id": ACCOUNTS[n - 1],
            }))
            self.command(["providers", "credential", "import", str(self.config), ACCOUNTS[n - 1], grant])

    def close(self):
        super().close()
        local.wait(lambda: closed(self.callback_port), label="callback listener cleanup")
        for path in self.logs:
            raw = path.read_bytes()
            assert not any(secret.encode() in raw for secret in self.provider.private_ephemeral), \
                "private OAuth state/verifier escaped into VM logs"


def exercise(f):
    f.start_gateway()  # The gateway must discover the UI grant, not be reseeded.
    f.responses(1, expected=503)
    f.start_ui()
    f.unlock()
    status, _, locked = f.http(f.ui_port, "POST", "/api/status", {})
    assert status == 403 and b"authorization_url" not in locked
    before = f.provider.counts["exchange"]
    bad = f.begin_codex(1)
    assert f.callback(f"http://127.0.0.1:{f.callback_port}/auth/callback?state=wrong&code=synthetic") == 400
    f.codex_phase(1, "callback_rejected")
    assert f.provider.counts["exchange"] == before and not slot(f.state, 1).exists()

    url = f.begin_codex(1)
    f.authorize(url)
    f.codex_phase(1, "stored")
    assert slot(f.state, 1).stat().st_mode & 0o777 == 0o600
    assert f.state.stat().st_mode & 0o777 == 0o700
    assert not slot(f.state, 2).exists()
    f.responses(1)
    assert f.provider.counts["codex_refresh"] == 1
    rotated = json.loads(slot(f.state, 1).read_text())
    f.responses(2, expected=503)
    f.stop(f.gateway)
    f.start_gateway()
    f.responses(1)
    assert f.provider.counts["codex_refresh"] == 1
    assert json.loads(slot(f.state, 1).read_text()) == rotated

    f.authorize(f.begin_codex(2))
    f.codex_phase(2, "stored")
    f.responses(2)
    assert f.provider.counts["codex_refresh"] == 2
    f.responses(1)  # Other account enrollment did not replace the first grant.
    assert json.loads(slot(f.state, 1).read_text()) == rotated

    for action in ("cancel", "replace", "delete"):
        f.provider.codex_mode = "blocked"
        f.authorize(f.begin_codex(1))
        local.wait(f.provider.exchange_entered.is_set, label="real blocked token exchange")
        f.codex_phase(1, "exchanging")
        if action == "cancel":
            assert f.api("/api/cancel", {"account": ACCOUNTS[0]})[0] == 200
        else:
            f.admin_codex(1, delete=action == "delete")
        expected = slot(f.state, 1).read_bytes() if slot(f.state, 1).exists() else None
        f.provider.release.set()
        f.codex_phase(1, "cancelled" if action == "cancel" else "installation_unconfirmed")
        actual = slot(f.state, 1).read_bytes() if slot(f.state, 1).exists() else None
        assert actual == expected
        local.wait(lambda: closed(f.callback_port), label="consumed callback listener")

    f.provider.codex_mode = "authorize"
    stale = f.begin_codex(1)
    old_cookie, old_csrf = f.cookie, f.csrf
    f.stop(f.ui)
    assert not slot(f.state, 1).exists(), "graceful restart must cancel first reservation"
    local.wait(lambda: closed(f.callback_port), label="stop callback cleanup")
    f.start_ui()
    assert f.api("/api/status", Cookie=old_cookie, **{"X-CSRF-Token": old_csrf})[0] == 401
    f.unlock()
    newer = f.begin_codex(1)
    old_state = parse_qs(urlsplit(stale).query)["state"][0]
    assert f.callback(f"http://127.0.0.1:{f.callback_port}/auth/callback?" + urlencode({
        "state": old_state, "code": "synthetic",
    })) == 400
    f.codex_phase(1, "callback_rejected")
    assert stale != newer and not slot(f.state, 1).exists()

    # Whole-VM loss retains the existing S5 fail-closed marker. There is no
    # TTL takeover: explicit admin deletion is required before a new login.
    f.begin_codex(1)
    os.killpg(f.ui.pid, signal.SIGKILL)
    f.ui.wait(timeout=10)
    local.wait(lambda: closed(f.callback_port), label="VM-loss listener cleanup")
    assert json.loads(slot(f.state, 1).read_text())["kind"] == "enrollment_pending"
    f.start_ui()
    f.unlock()
    assert f.api("/api/login", {"account": ACCOUNTS[0]})[0] == 409
    f.admin_codex(1, delete=True)
    f.authorize(f.begin_codex(1))
    f.codex_phase(1, "stored")
    evidence = kimi_cancel_regression(f)
    assert evidence["cancel_status"] == 200
    assert f.api("/api/logout")[0] == 200
    assert f.api("/api/status")[0] == 401
    return f.provider.counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root-command", default=local.DEFAULT_ROOT)
    parser.add_argument("--kimi-cancel-only", action="store_true",
                        help="Focused safe-phase reproduction of the inherited F05 race")
    args = parser.parse_args()
    scratch = ROOT / "build/account-ui-f06/tmp"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="codex-", dir=scratch) as raw:
        directory = Path(raw)
        directory.chmod(0o700)
        f = Fixture(directory, SimpleNamespace(root_command=args.root_command,
                    ui_command=local.DEFAULT_UI, root_ui=True))
        try:
            if args.kimi_cancel_only:
                f.start_ui()
                f.unlock()
                counts = kimi_cancel_regression(f)
            else:
                counts = exercise(f)
        finally:
            f.close()
    label = ("PASS F05 actual entered-poll cancellation regression" if args.kimi_cancel_only
             else "PASS F06 synthetic root UI + PKCE issuer + callback + root gateway")
    print(label, counts)


if __name__ == "__main__":
    main()
