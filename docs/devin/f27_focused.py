#!/usr/bin/env python3
"""Run gleam test on a hash-recorded current-source dependency closure.

Only the F27 and existing F23/F24/wire regressions are discovered. No root
overlays or stubs, provider calls or ambient credentials. Generated verification
files live only under build/f27; source files are copied byte-for-byte.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TESTS = (
    "devin_catalog_test", "devin_chat_projection_test",
    "devin_messages_projection_test", "devin_wire_test",
)
IMPORT = re.compile(r"^import ([a-zA-Z0-9_/]+)", re.MULTILINE)


def main():
    output = ROOT / "build/f27"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="focused-", dir=output) as temporary:
        target = Path(temporary)
        inputs = {}

        def copy(path):
            relative = path.relative_to(ROOT)
            destination = target / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
            inputs[str(relative)] = hashlib.sha256(path.read_bytes()).hexdigest()

        pending = list(TESTS)
        copied = set()
        while pending:
            module = pending.pop()
            if module in copied:
                continue
            copied.add(module)
            matches = [base / f"{module}.gleam" for base in (ROOT / "src", ROOT / "test")]
            matches = [path for path in matches if path.is_file()]
            if not matches:
                # Declared public dependencies use the unchanged manifest.
                continue
            assert len(matches) == 1, "ambiguous project module"
            path = matches[0]
            copy(path)
            pending.extend(IMPORT.findall(path.read_text()))

        # Native functions use actual current namespaced FFI, never substitute
        # adapters. Copy FFI inputs, not runtime state or request plans.
        for path in (ROOT / "src").glob("*.erl"):
            copy(path)
        for filename in (
            "mimic_devin_f27_catalog_test_ffi.erl",
            "mimic_devin_chat_projection_test_ffi.erl",
            "mimic_devin_f24_messages_test_ffi.erl",
        ):
            copy(ROOT / "test" / filename)
        copy(ROOT / "test/mimic_test.gleam")
        copy(ROOT / "gleam.toml")
        copy(ROOT / "manifest.toml")
        for path in (ROOT / "vendor").rglob("*"):
            if path.is_file() and "build" not in path.relative_to(ROOT / "vendor").parts:
                copy(path)
        (target / "build").mkdir(exist_ok=True)
        shutil.copytree(ROOT / "build/packages", target / "build/packages")
        receipt = output / "focused-inputs.json"
        receipt.write_text(json.dumps({
            "synthetic": True, "scope": "current_source_focused_dependency_closure",
            "tests": TESTS, "inputs": inputs,
        }, sort_keys=True, indent=2) + "\n")
        # Serialize this with parent gates. No shell expansion/command assembly.
        environment = {**os.environ, "ERL_FLAGS": "+S 2:2 +A 2"}
        process = subprocess.Popen([os.environ.get("GLEAM", "gleam"), "test"],
                                   cwd=target, env=environment, start_new_session=True)
        try:
            code = process.wait(timeout=120)
            assert code == 0, f"focused gleam test exited {code}"
        finally:
            # A failed/timeout compiler leader must not leave its BEAM child
            # holding loopback listeners or the parent's serialized gate slot.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            if process.poll() is None:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
    assert not target.exists(), "generated focused project survived cleanup"
    print(json.dumps({"slice": "F27", "scope": "focused_gleam_test",
                      "inputs": str(receipt.relative_to(ROOT)),
                      "generated_project_removed": True, "synthetic": True}))


if __name__ == "__main__":
    main()
