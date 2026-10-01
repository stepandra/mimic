#!/usr/bin/env python3
"""F06 isolated agent-browser proof of the shared Kimi/Codex operator page.

Only the explicit synthetic loopback issuer, callback and root gateway run.
Bootstrap and private privacy assertions travel via stdin, never argv.
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
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


f06 = load("f06_browser_fixture", ROOT / "scripts/smoke-account-ui-codex.py")
f05_browser = load("f05_browser_tools", ROOT / "scripts/smoke-account-ui-browser.py")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser-executable")
    parser.add_argument("--root-command", default=f06.local.DEFAULT_ROOT)
    args = parser.parse_args()
    executable = args.browser_executable or f05_browser.default_executable()
    output = ROOT / "build/account-ui-f06/browser-proof"
    output.mkdir(parents=True, exist_ok=True)
    scratch = ROOT / "build/account-ui-f06/tmp"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="browser-", dir=scratch) as raw:
        directory = Path(raw)
        directory.chmod(0o700)
        f = f06.Fixture(directory, SimpleNamespace(root_command=args.root_command,
                         ui_command=f06.local.DEFAULT_UI, root_ui=True))
        home, temp = directory / "home", directory / "tmp"
        home.mkdir(mode=0o700)
        temp.mkdir(mode=0o700)
        config = directory / "browser.json"
        config.write_text("{}")
        sockets = ROOT / "build/ab-f06"
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
        private = []
        transcript = []

        def browser(*command, data=None, record=True):
            try:
                completed = subprocess.run(["agent-browser", *command], cwd=ROOT, env=env,
                    input=data, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
            except subprocess.TimeoutExpired:
                raise AssertionError(f"agent-browser {command[0]} timed out; "
                                     f"synthetic boundary counts {f.provider.counts}") from None
            f06.local.clean(completed.stdout)
            assert not any(secret.encode() in completed.stdout for secret in private), \
                "private operator capability escaped into browser output"
            if completed.returncode:
                detail = re.sub(r"https?://[^\s\"']+", "<local URL withheld>",
                                completed.stdout.decode())
                raise AssertionError(f"agent-browser {command[0]} failed: {detail}; "
                                     f"synthetic boundary counts {f.provider.counts}")
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
                ["wait", "--text", "Log in to Codex"],
            ]).encode(), record=False)
            assert not f.bootstrap.exists()
            tree = snapshot("unlocked")
            assert tree.count("Log in to Codex") == 2 and "Log in to Kimi" in tree
            browser("click", "#accounts article:nth-child(2) button")
            browser("wait", "--text", "Open Codex login")
            snapshot("waiting")
            browser("wait", "--fn", """(() => {
              const a=document.querySelector('.verification a');
              return a && a.target==='_blank' && a.rel.includes('noreferrer')
                && a.rel.includes('noopener') && a.referrerPolicy==='no-referrer'
                && !a.href.includes('code_verifier');
            })()""")
            browser("click", "#accounts article:nth-child(2) button:nth-of-type(2)")
            browser("wait", "--text", "Login: cancelled")
            browser("wait", "--fn", "document.querySelector('.verification') === null")
            assert not f06.slot(f.state, 1).exists()
            snapshot("cancelled")

            browser("click", "#accounts article:nth-child(2) button")
            browser("wait", "--text", "Open Codex login")
            fresh = snapshot("second-waiting")
            link = re.search(r'link "Open Codex login" \[ref=(e\d+)\]', fresh)
            assert link, "pending Codex login link missing from the fresh accessibility tree"
            browser("click", "@" + link.group(1), "--new-tab", record=False)
            f06.local.wait(f.provider.exchange_entered.is_set, label="browser redirect/callback/exchange")
            browser("tab", "t1")
            browser("wait", "--text", "Login: stored")
            browser("wait", "--fn", "document.querySelector('.verification') === null")
            snapshot("stored")
            f.start_gateway()
            f.responses(1)
            assert f.provider.counts["codex_refresh"] == 1
            assert not f06.slot(f.state, 2).exists()

            # A second provider still uses this exact session/UI/store.
            f.provider.phase("authorize")
            browser("find", "role", "button", "click", "--name", "Log in to Kimi")
            browser("wait", "--text", "Open Kimi verification")
            snapshot("kimi-waiting")
            browser("wait", "--fn", """document.querySelector('#accounts article:first-child')
              .textContent.includes('Login: stored')""")
            f.chat()
            assert f.provider.counts["refresh"] == 1
            snapshot("both-stored")
            browser("set", "viewport", "390", "844")
            browser("wait", "--fn", "document.documentElement.scrollWidth <= window.innerWidth")
            snapshot("mobile")
            report = json.loads(browser("a11y", "--json"))
            (output / "axe.json").write_text(json.dumps(report, indent=2))
            assert report["success"] and report["data"]["counts"]["violations"] == 0
            checks = json.dumps([*f06.local.SECRETS, *f.provider.private_ephemeral])
            # Private strings in this assertion are sent via stdin and never
            # enter DOM, client storage, browser argv or the retained transcript.
            privacy = browser("eval", "--stdin", data=f"""JSON.stringify({{
                clear: {checks}.every(s=>!document.documentElement.outerHTML.includes(s)),
                emptyStorage: localStorage.length===0 && sessionStorage.length===0,
                emptyCookie: document.cookie==='',
                emptyBootstrap: document.getElementById('bootstrap').value===''
            }})""".encode(), record=False)
            assert privacy.count("true") == 4
            browser("find", "role", "button", "click", "--name", "End operator session")
            browser("wait", "--text", "Restart the operator UI")
            snapshot("ended")
            assert "Log in to Codex" not in browser("snapshot", "-i")
            assert browser("errors").strip() in ("", "No errors")
            assert browser("console").strip() in ("", "No console messages")
            (output / "transcript.txt").write_text("\n\n".join(transcript))
        finally:
            try:
                browser("close", record=False)
            finally:
                f.close()
    print("PASS F06 real isolated Chrome: Codex link/PKCE/callback/gateway/refresh; Kimi regression; privacy/mobile/axe")


if __name__ == "__main__":
    main()
