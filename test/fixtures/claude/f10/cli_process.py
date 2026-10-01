"""Synthetic F10 OS process primitive. No HTTP/protocol/assertion logic.

Run one argv-vector command in an owned process group; stdin EOF/stop or the
hard lifetime budget terminates that group. Preserve complete combined output.
Hard expiry is 124, never the child's graceful/TERM status. Unconfirmed cleanup
is 1. Only a controlled stdin stop/EOF can return the child's status.
"""
import os
import select
import signal
import subprocess
import sys
import threading
import time


def signal_group(pid, sig):
    try:
        os.killpg(pid, sig)
        return True
    except ProcessLookupError:
        return True
    except OSError:
        return False


def group_gone(pid):
    deadline = time.monotonic() + 2
    while True:
        try:
            os.killpg(pid, 0)
        except ProcessLookupError:
            return True
        except OSError:
            return False
        if time.monotonic() >= deadline:
            return False
        # Bounded condition polling, not an assumed cleanup/readiness delay.
        time.sleep(0.01)


def run(argv):
    try:
        process = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except OSError:
        return 1

    copy_failed = threading.Event()

    def copy_output():
        try:
            with process.stdout:
                while chunk := process.stdout.read1(65536):
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
        except Exception:
            copy_failed.set()

    reader = threading.Thread(target=copy_output, daemon=True)
    reader.start()
    expired = False
    controlled = False
    cleanup_ok = True
    status = 1
    try:
        # OS lifetime only. Readiness, provider state and assertions are Gleam.
        ready, _, _ = select.select([sys.stdin.buffer], [], [], 45)
        expired = not ready
        if ready:
            sys.stdin.buffer.readline()
            controlled = True  # Explicit stop and EOF, distinct from expiry.
    except (OSError, ValueError):
        cleanup_ok = False
    finally:
        # Signal the owned group before reaping even if the launcher exited.
        cleanup_ok = signal_group(process.pid, signal.SIGTERM) and cleanup_ok
        try:
            status = process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            cleanup_ok = signal_group(process.pid, signal.SIGKILL) and cleanup_ok
            try:
                status = process.wait(timeout=2)
            except (subprocess.TimeoutExpired, OSError):
                cleanup_ok = False
        except OSError:
            cleanup_ok = False
        # Output EOF and launcher exit cannot prove descendant cleanup. Kill
        # any remaining members of the owned group, including closed-output
        # TERM-resistant children; require group disappearance before success.
        cleanup_ok = signal_group(process.pid, signal.SIGKILL) and cleanup_ok
        cleanup_ok = group_gone(process.pid) and cleanup_ok
        reader.join(timeout=10)
        if reader.is_alive():
            reader.join(timeout=2)
            cleanup_ok = False

    if not cleanup_ok or copy_failed.is_set():
        return 1
    if expired:
        return 124
    if not controlled:
        return 1
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
