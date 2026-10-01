"""Synthetic F10 OS-lifecycle regressions; no gateway/provider substitution.

Fault injection forces select's expiry result AFTER a real child acknowledges
signal-handler readiness. The clock test instead uses the unmodified 45s select
budget with stdin held open. No production CLI flags, sleeps or live endpoints.
"""
import io
import os
from pathlib import Path
import runpy
import select
import signal
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("cli_process.py")
REAL_SELECT = select.select
REAL_POPEN = subprocess.Popen
REAL_THREAD = threading.Thread


class Output:
    def __init__(self, marker=b"READY\n"):
        self.buffer = self
        self.data = io.BytesIO()
        self.ready = threading.Event()
        self.marker = marker

    def write(self, chunk):
        self.data.write(chunk)
        if self.marker in self.data.getvalue():
            self.ready.set()

    def flush(self):
        pass


def group_exists(pid):
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False


class CliProcessTest(unittest.TestCase):
    def invoke(self, cause, graceful=True, descendants=False, unknown=False,
               large_output=False):
        output = Output(b"END\n" if large_output else b"READY\n")
        children = []
        child = """
import os, signal, subprocess, sys
"""
        if graceful:
            child += """
def stop(*_):
    print("GRACEFUL_STOP", flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
"""
        if descendants:
            # The descendant deliberately closes inherited output and ignores
            # TERM. Output EOF/launcher exit alone cannot prove group cleanup.
            child += """
r, w = os.pipe()
code = ("import os, signal; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "os.write(" + str(w) + ", b'R'); signal.pause()")
descendant = subprocess.Popen(
    [sys.executable, "-u", "-c", code], pass_fds=(w,),
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL)
os.close(w)
assert os.read(r, 1) == b"R"
os.close(r)
print("DESCENDANT_PID=" + str(descendant.pid), flush=True)
"""
        child += 'print("STDERR_RETAINED", file=sys.stderr, flush=True)\n'
        child += 'print("READY", flush=True)\n'
        if large_output:
            child += 'print("x" * 70000 + "\\nEND", flush=True)\n'
        child += "while True: signal.pause()\n"
        r, w = os.pipe()
        started = time.monotonic()
        exited = None
        residue = None

        def spawn(*args, **kwargs):
            process = REAL_POPEN(*args, **kwargs)
            children.append(process)
            return process

        def select_boundary(read, write, error, timeout):
            self.assertEqual(timeout, 45)
            self.assertTrue(output.ready.wait(10), "real child readiness missing")
            if cause == "expiry":
                return [], [], []  # Fault injection; NOT a measured timeout.
            return REAL_SELECT(read, write, error, timeout)

        def reader(*args, **kwargs):
            thread = REAL_THREAD(*args, **kwargs)
            if unknown:
                # Fault injection: completed copy cannot be confirmed by the
                # primitive. Never leave an actual live thread for this case.
                thread.is_alive = lambda: True
            return thread

        try:
            if cause == "stop":
                os.write(w, b"stop\n")
            if cause in ("stop", "eof"):
                os.close(w)
                w = None
            with os.fdopen(r, "rb") as stdin:
                with mock.patch.object(sys, "argv", [
                    str(SCRIPT), sys.executable, "-u", "-c", child
                ]), mock.patch.object(sys, "stdin", mock.Mock(buffer=stdin)), \
                        mock.patch.object(sys, "stdout", output), \
                        mock.patch.object(subprocess, "Popen", spawn), \
                        mock.patch.object(select, "select", select_boundary), \
                        mock.patch.object(threading, "Thread", reader):
                    try:
                        runpy.run_path(str(SCRIPT), run_name="__main__")
                    except SystemExit as error:
                        exited = error.code
            residue = any(group_exists(p.pid) for p in children)
        finally:
            if w is not None:
                os.close(w)
            # Test-owned emergency cleanup on RED must not leave a real orphan.
            # Residue was recorded BEFORE this and still fails the assertion.
            for process in children:
                if group_exists(process.pid):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            data = output.data.getvalue()
            print(f"F10 lifecycle {cause=} {graceful=} {descendants=} "
                  f"{unknown=} wrapper_exit={exited} "
                  f"child_exits={[p.returncode for p in children]} "
                  f"group_residue={residue} "
                  f"elapsed_seconds={time.monotonic() - started:.3f}")
            sys.stdout.flush()
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        self.assertIn(b"STDERR_RETAINED\n", data)
        self.assertIn(b"READY\n", data)
        self.assertFalse(residue, "owned descendants remained after helper exit")
        if large_output:
            self.assertIn(b"x" * 70000 + b"\nEND\n", data)
        return exited, time.monotonic() - started

    def test_explicit_stop(self):
        self.assertEqual(self.invoke("stop")[0], 0)

    def test_eof(self):
        self.assertEqual(self.invoke("eof")[0], 0)

    def test_fault_injected_expiry_child_zero(self):
        self.assertEqual(self.invoke("expiry")[0], 124)

    def test_fault_injected_expiry_child_sigterm(self):
        self.assertEqual(self.invoke("expiry", graceful=False)[0], 124)

    def test_unknown_cleanup_failure(self):
        self.assertEqual(self.invoke("stop", unknown=True)[0], 1)

    def test_no_descendants_after_launcher_zero_and_output_eof(self):
        self.assertEqual(self.invoke("stop", descendants=True)[0], 0)

    def test_complete_output_retained(self):
        self.assertEqual(self.invoke("expiry", large_output=True)[0], 124)

    def test_real_45_second_lifetime_expiry(self):
        status, elapsed = self.invoke("clock")
        self.assertEqual(status, 124)
        self.assertGreaterEqual(elapsed, 45)
        self.assertLess(elapsed, 65)


if __name__ == "__main__":
    unittest.main()
