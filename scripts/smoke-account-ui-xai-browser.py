#!/usr/bin/env python3
"""F07 real isolated browser, actual served UI and synthetic loopback issuer.

Uses the actual configured root gateway, never CPA/provider endpoints. Private
operator capabilities and privacy sentinels use stdin, not browser argv/logs.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


f07 = load("f07_browser_fixture", ROOT / "scripts/smoke-account-ui-xai.py")
tools = load("f07_existing_browser_tools", ROOT / "scripts/smoke-account-ui-browser.py")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser-executable")
    parser.add_argument("--browser-socket-dir", type=Path,
                        help="explicit short private socket directory for deep composed snapshots")
    parser.add_argument("--root-command", default=f07.local.DEFAULT_ROOT)
    args = parser.parse_args()
    executable = args.browser_executable or tools.default_executable()
    output = ROOT / "build/account-ui-f07/browser-proof"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="browser-", dir=output.parent) as raw:
        directory = Path(raw)
        directory.chmod(0o700)
        f = f07.Fixture(directory, argparse.Namespace(
            root_command=args.root_command, ui_command=f07.local.DEFAULT_UI, root_ui=True))
        home, temp = directory / "home", directory / "tmp"
        home.mkdir(mode=0o700)
        temp.mkdir(mode=0o700)
        config = directory / "browser.json"
        config.write_text("{}")
        sockets = args.browser_socket_dir or ROOT / "build/ab-f07"
        sockets.mkdir(mode=0o700, exist_ok=True)
        env = {
            "PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(temp),
            "XDG_CONFIG_HOME": str(home), "XDG_CACHE_HOME": str(home / "cache"),
            "AGENT_BROWSER_CONFIG": str(config),
            "AGENT_BROWSER_SESSION": format(os.getpid(), "x"),
            "AGENT_BROWSER_SOCKET_DIR": str(sockets),
            "AGENT_BROWSER_ALLOWED_DOMAINS": "127.0.0.1",
            "AGENT_BROWSER_EXECUTABLE_PATH": executable, "AGENT_BROWSER_PLUGINS": "[]",
            "AGENT_BROWSER_RESTORE_SAVE": "never", "AGENT_BROWSER_DOWNLOAD_PATH": str(temp),
        }
        private, transcript = [], []

        def browser(*command, data=None, record=True):
            completed = subprocess.run(["agent-browser", *command], cwd=ROOT, env=env,
                input=data, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=40)
            f07.local.clean(completed.stdout)
            assert not any(secret.encode() in completed.stdout for secret in private)
            detail = re.sub(r"https?://[^\s\"']+", "<local URL withheld>",
                            completed.stdout.decode())
            assert completed.returncode == 0, f"agent-browser {command[0]} failed: {detail}"
            if record:
                transcript.append(f"$ agent-browser {' '.join(command)}\n{completed.stdout.decode()}")
            return completed.stdout.decode()

        def snapshot(name):
            tree = browser("snapshot", "-i")
            (output / f"{name}.txt").write_text(tree)
            browser("screenshot", str(output / f"{name}.png"), "--full")
            return tree

        try:
            f.start_ui()
            browser("open", f"http://127.0.0.1:{f.ui_port}")
            assert "Unlock session" in snapshot("locked")
            bootstrap = f.bootstrap.read_text()
            private.append(bootstrap)
            browser("batch", "--bail", data=json.dumps([
                ["fill", "#bootstrap", bootstrap], ["click", "#unlock-submit"],
                ["wait", "--text", "Log in to Grok"],
            ]).encode(), record=False)
            assert not f.bootstrap.exists()
            assert snapshot("unlocked").count("Log in to Grok") == 2
            f.prepare(1)
            browser("click", "#accounts article:first-child button")
            browser("wait", "--text", "Open Grok verification")
            snapshot("waiting")
            browser("wait", "--fn", """(() => {
              const a=document.querySelector('.verification a');
              return a && a.target==='_blank' && a.rel.includes('noreferrer')
                && a.rel.includes('noopener') && a.referrerPolicy==='no-referrer';
            })()""")
            cancelled_attempt = f.attempt_sequence
            f.expect_peer_close()
            browser("click", "#accounts article:first-child button:nth-of-type(2)")
            browser("wait", "--text", "Login: cancelled")
            f.confirm_cancel(cancelled_attempt, "one")
            browser("wait", "--fn", "document.querySelector('.verification') === null")
            assert not f07.slot(f.state, 1).exists()
            snapshot("cancelled")
            f.prepare(1)
            browser("click", "#accounts article:first-child button")
            browser("wait", "--text", "Open Grok verification")
            fresh = snapshot("second-waiting")
            link = re.search(r'link "Open Grok verification" \[ref=(e\d+)\]', fresh)
            assert link, "served verification link missing from the fresh accessibility tree"
            browser("click", "@" + link.group(1), "--new-tab", record=False)
            f07.local.wait(lambda: f.authorized[1], label="real browser verification")
            browser("tab", "t1")
            browser("wait", "--text", "Login: stored")
            browser("wait", "--fn", "document.querySelector('.verification') === null")
            snapshot("stored")
            f.start_gateway()
            f.request(1)
            f.request(1, "responses/compact")
            assert f.counts["refresh"] == 1 and f.counts["proxy"] == 1 and f.counts["api"] == 1
            assert not f07.slot(f.state, 2).exists()
            browser("set", "viewport", "390", "844")
            browser("wait", "--fn", "document.documentElement.scrollWidth <= window.innerWidth")
            snapshot("mobile")
            report = json.loads(browser("a11y", "--json"))
            (output / "axe.json").write_text(json.dumps(report, indent=2))
            assert report["success"] and report["data"]["counts"]["violations"] == 0
            # A public synthetic marker, NOT the credential values. Do not
            # inject actual provider/client tokens into the browser even to
            # check for their absence. Exact output checks stay in Python.
            privacy = browser("eval", "--stdin", data=b"""JSON.stringify({
                clear: !document.documentElement.outerHTML.includes('synthetic-private'),
                emptyStorage: localStorage.length===0 && sessionStorage.length===0,
                emptyCookie: document.cookie==='',
                emptyBootstrap: document.getElementById('bootstrap').value===''
            })""", record=False)
            assert privacy.count("true") == 4
            browser("find", "role", "button", "click", "--name", "End operator session")
            browser("wait", "--text", "Restart the operator UI")
            assert "Log in to Grok" not in snapshot("ended")
            assert browser("errors").strip() in ("", "No errors")
            assert browser("console").strip() in ("", "No console messages")
            assert not f.errors, (
                "synthetic boundary violations: " + json.dumps(f.errors)
                + "; route counters: " + json.dumps(f.route_counts)
                + "; matched cancellation closes: " + json.dumps(f.peer_closes)
                + "; confirmed attempts: " + json.dumps(sorted(f.confirmed_peer_closes)))
            (output / "transcript.txt").write_text("\n\n".join(transcript))
        finally:
            try:
                browser("close", record=False)
            finally:
                f.close()
    print("PASS F07 synthetic real browser: device UI/cancel/verification/S5/refresh/API+proxy/privacy/mobile/axe")


if __name__ == "__main__":
    main()
