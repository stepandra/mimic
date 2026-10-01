#!/usr/bin/env python3
"""F05 browser proof against real Mist and a loopback synthetic Kimi provider.

Uses an isolated agent-browser context, a private HOME/TMPDIR inside this
worktree, no inherited credentials/proxy/browser profile, and loopback-only
browser egress. This is not live OAuth or CPA evidence.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("f05_browser_fixture", ROOT / "scripts/smoke-account-ui.py")
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


def default_executable():
    mac = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    if mac.is_file():
        return str(mac)
    for name in ("chromium", "chromium-browser", "google-chrome"):
        if executable := shutil.which(name):
            return executable
    raise RuntimeError("explicit local browser executable required; no automatic installation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root-ui", action="store_true", help="After parent root dispatch admission")
    parser.add_argument("--root-command", default=local.DEFAULT_ROOT)
    parser.add_argument("--ui-command", default=local.DEFAULT_UI)
    parser.add_argument("--browser-executable")
    args = parser.parse_args()
    executable = args.browser_executable or default_executable()
    output = ROOT / "build/account-ui/browser-proof"
    output.mkdir(parents=True, exist_ok=True)
    scratch = ROOT / "build/account-ui/tmp"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="f05-browser-", dir=scratch) as raw:
        directory = Path(raw)
        directory.chmod(0o700)
        fixture = local.Fixture(directory, SimpleNamespace(
            root_command=args.root_command, ui_command=args.ui_command, root_ui=args.root_ui,
        ))
        home, browser_tmp = directory / "browser-home", directory / "browser-tmp"
        home.mkdir(mode=0o700)
        browser_tmp.mkdir(mode=0o700)
        browser_config = directory / "browser.json"
        browser_config.write_text("{}")
        # Darwin limits Unix socket paths to 103 bytes. A short directory in
        # this isolated checkout avoids moving the socket outside the worktree.
        sockets = ROOT / "build/ab"
        sockets.mkdir(mode=0o700, exist_ok=True)
        # Do not inherit ambient keys, proxies, provider plugins or browser state.
        env = {
            "PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(browser_tmp),
            "XDG_CONFIG_HOME": str(home), "XDG_CACHE_HOME": str(home / "cache"),
            "AGENT_BROWSER_CONFIG": str(browser_config),
            "AGENT_BROWSER_SESSION": "u",
            "AGENT_BROWSER_SOCKET_DIR": str(sockets),
            "AGENT_BROWSER_ALLOWED_DOMAINS": "127.0.0.1",
            "AGENT_BROWSER_EXECUTABLE_PATH": executable,
            "AGENT_BROWSER_PLUGINS": "[]",
            "AGENT_BROWSER_RESTORE_SAVE": "never",
            "AGENT_BROWSER_DOWNLOAD_PATH": str(browser_tmp),
        }
        secrets = []
        transcript = []

        def browser(*command, batch=None, record=True):
            completed = subprocess.run(
                ["agent-browser", *command], cwd=ROOT, env=env,
                input=None if batch is None else json.dumps(batch).encode(),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45,
            )
            local.clean(completed.stdout)
            assert not any(secret.encode() in completed.stdout for secret in secrets), \
                "private operator capability appeared in browser output"
            if completed.returncode:
                raise AssertionError(f"agent-browser {command[0]} failed: {completed.stdout.decode()}")
            if record:
                transcript.append(f"$ agent-browser {' '.join(command)}\n{completed.stdout.decode()}")
            return completed.stdout.decode()

        def snapshot(name):
            tree = browser("snapshot", "-i")
            (output / f"{name}.txt").write_text(tree)
            browser("screenshot", str(output / f"{name}.png"), "--full")
            return tree

        try:
            fixture.start_ui()
            origin = f"http://127.0.0.1:{fixture.ui_port}"
            browser("open", origin)
            locked = snapshot("locked")
            assert "Unlock session" in locked and "Log in to Kimi" not in locked
            code = fixture.bootstrap.read_text()
            secrets.append(code)
            # Private code travels over stdin, not argv, URL or a retained file.
            browser("batch", "--bail", batch=[
                ["fill", "#bootstrap", code], ["click", "#unlock-submit"],
                ["wait", "--text", "Log in to Kimi"],
            ], record=False)
            assert not fixture.bootstrap.exists()
            browser("wait", "--fn", "document.getElementById('bootstrap').value === ''")
            unlocked = snapshot("unlocked")
            assert "Log in to Kimi" in unlocked and "Unlock session" not in unlocked

            fixture.provider.phase("pending")
            browser("find", "role", "button", "click", "--name", "Log in to Kimi")
            browser("wait", "--text", "Login: waiting")
            waiting = snapshot("waiting")
            assert "Open Kimi verification" in waiting
            browser("wait", "--fn", """(() => {
              const a=document.querySelector('.verification a');
              return a && a.rel.includes('noreferrer') && a.rel.includes('noopener')
                && a.referrerPolicy==='no-referrer';
            })()""")
            browser("find", "role", "button", "click", "--name", "Cancel login")
            browser("wait", "--text", "Login: cancelled")
            browser("wait", "--fn", "document.querySelector('.verification') === null")
            snapshot("cancelled")
            assert not fixture.slot.exists()

            fixture.provider.phase("authorize")
            browser("find", "role", "button", "click", "--name", "Log in to Kimi")
            browser("wait", "--text", "Login: stored")
            browser("wait", "--fn", "document.querySelector('.verification') === null")
            stored = snapshot("stored")
            assert "Log in to Kimi" in stored and fixture.slot.exists()
            # One actual gateway runtime consumes and refreshes this browser grant.
            fixture.start_gateway()
            fixture.chat()
            assert fixture.provider.counts["refresh"] == 1
            saved = json.loads(fixture.slot.read_text())

            fixture.provider.phase("expire")
            polls = fixture.provider.counts["poll"]
            browser("find", "role", "button", "click", "--name", "Log in to Kimi")
            browser("wait", "--text", "Login: expired")
            browser("wait", "--fn", "document.querySelector('.verification') === null")
            snapshot("expired")
            assert fixture.provider.counts["poll"] == polls
            assert json.loads(fixture.slot.read_text())["access_token"] == saved["access_token"]

            browser("set", "viewport", "390", "844")
            browser("wait", "--fn", "document.documentElement.scrollWidth <= window.innerWidth")
            snapshot("mobile")
            browser("wait", "--fn", """(() => {
              const text=document.documentElement.outerHTML;
              return !/synthetic-private-/.test(text) && document.cookie===''
                && localStorage.length===0 && sessionStorage.length===0;
            })()""")
            audit = json.loads(browser("a11y", "--json"))
            (output / "accessibility.json").write_text(json.dumps(audit, indent=2))
            assert audit["success"] and audit["data"]["counts"]["violations"] == 0
            browser("find", "role", "button", "click", "--name", "End operator session")
            browser("wait", "--text", "Session ended.")
            ended = snapshot("ended")
            assert "Unlock session" in ended and "Log in to Kimi" not in ended
            errors = browser("errors")
            console = browser("console")
            assert "Error" not in errors and "synthetic-private-" not in console
            assert fixture.provider.reservation_before_io and fixture.provider.identity_ok and fixture.provider.auth_ok
            print(json.dumps({
                "result": "PASS", "axis": fixture.axis, "browser": "agent-browser/local Chrome",
                "synthetic_only": True, "live": "not performed",
                "unlock_start_cancel_finish_gateway_refresh_expiry_logout": True,
                "viewport": "390x844; no horizontal overflow",
                "actual_local_provider_counts": fixture.provider.counts,
                "artifacts": str(output.relative_to(ROOT)),
            }, indent=2))
        finally:
            try:
                browser("close")
            finally:
                (output / "browser.log").write_text("\n".join(transcript))
                fixture.close()


if __name__ == "__main__":
    main()
