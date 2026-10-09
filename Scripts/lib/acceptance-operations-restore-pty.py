#!/usr/bin/env python3
"""Run the local restore operation through a bounded, real PTY.

The restore command deliberately refuses pipes. This helper is repository
owned so acceptance exercises the same interactive prompt without embedding
the digest in a shell heredoc or weakening the command's terminal check.
"""

import argparse
import os
import pty
import selectors
import signal
import sys
import time

MAX_OUTPUT_BYTES = 1024 * 1024
GROUP_TEARDOWN_FAILED = 125
CONTROL_SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)


def group_state(pid: int):
    """Return True when present, False when absent, or None when unprobeable."""

    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # EPERM is evidence that the group may still exist, never evidence of
        # absence. Callers must fail closed until killpg returns ESRCH.
        return None


def terminate_and_reap_group(pid: int) -> bool:
    """Stop the PTY child and every process it launched, with a hard bound."""

    leader_reaped = False

    def reap_leader() -> None:
        nonlocal leader_reaped
        if leader_reaped:
            return
        try:
            waited, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            # Another bounded owner may have reaped the leader already. The
            # process group still needs probing and, when necessary, killing.
            leader_reaped = True
        else:
            leader_reaped = waited == pid

    try:
        os.killpg(pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    deadline = time.monotonic() + 1.0
    state = group_state(pid)
    while time.monotonic() < deadline and (not leader_reaped or state is not False):
        reap_leader()
        time.sleep(0.05)
        state = group_state(pid)
    if state is not False:
        try:
            os.killpg(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        deadline = time.monotonic() + 1.0
        state = group_state(pid)
        while time.monotonic() < deadline and state is not False:
            reap_leader()
            time.sleep(0.05)
            state = group_state(pid)
        if state is not False:
            return False
    if not leader_reaped:
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    return group_state(pid) is False


def ensure_group_empty(pid: int) -> bool:
    """Reap a detached foreground-command child group even after success."""

    deadline = time.monotonic() + 0.25
    state = group_state(pid)
    while state is not False and time.monotonic() < deadline:
        time.sleep(0.05)
        state = group_state(pid)
    if state is False:
        return True
    try:
        os.killpg(pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return group_state(pid) is False
    deadline = time.monotonic() + 0.5
    state = group_state(pid)
    while state is not False and time.monotonic() < deadline:
        time.sleep(0.05)
        state = group_state(pid)
    if state is not False:
        try:
            os.killpg(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            return group_state(pid) is False
        deadline = time.monotonic() + 0.5
        state = group_state(pid)
        while state is not False and time.monotonic() < deadline:
            time.sleep(0.05)
            state = group_state(pid)
    return state is False


def append_output(output: bytearray, chunk: bytes) -> bool:
    """Keep both live and post-exit PTY drains within one fixed ceiling."""

    if len(output) + len(chunk) > MAX_OUTPUT_BYTES:
        return False
    output.extend(chunk)
    sys.stdout.buffer.write(chunk)
    sys.stdout.buffer.flush()
    return True


def drain_available(fd: int, output: bytearray) -> bool:
    """Drain bytes already queued by a command whose leader just exited."""

    while True:
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            return True
        except OSError:
            return True
        if not chunk:
            return True
        if not append_output(output, chunk):
            return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout-seconds", type=float, default=60.0)
    parser.add_argument("--digest", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command or args.command[0] != "--":
        parser.error("a command after -- is required")
    command = args.command[1:]

    # pty.fork() creates the owned process group before the parent installs
    # Python handlers. Block the control signals across that fork boundary so
    # a signal cannot kill the parent in the setup window. The child restores
    # normal dispositions and an unblocked mask immediately before exec.
    blocked_signals = set(CONTROL_SIGNALS)
    signal.pthread_sigmask(signal.SIG_BLOCK, blocked_signals)
    try:
        pid, fd = pty.fork()
    except BaseException:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, blocked_signals)
        raise
    if pid == 0:
        for signum in CONTROL_SIGNALS:
            signal.signal(signum, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, blocked_signals)
        os.execvp(command[0], command)

    selector = None
    deadline = time.monotonic() + args.timeout_seconds
    output = bytearray()
    sent = False
    status = None
    interrupted_signal = None

    def request_interrupt(signum: int, _frame: object) -> None:
        # Signal handlers only record intent.  Group teardown performs waits
        # and bounded polling outside the async-signal context.
        nonlocal interrupted_signal
        interrupted_signal = signum

    def teardown_result(fallback_status: int) -> int:
        try:
            group_absent = terminate_and_reap_group(pid)
        except BaseException:
            group_absent = False
        return fallback_status if group_absent else GROUP_TEARDOWN_FAILED

    try:
        # Install the handlers before any other fallible parent-side setup.
        # Every later setup, I/O, and prompt-write failure is covered by the
        # same bounded group teardown path.
        signal.signal(signal.SIGINT, request_interrupt)
        signal.signal(signal.SIGTERM, request_interrupt)
        signal.signal(signal.SIGHUP, request_interrupt)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, blocked_signals)
        os.set_blocking(fd, False)
        selector = selectors.DefaultSelector()
        selector.register(fd, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            if interrupted_signal is not None:
                return_code = 128 + interrupted_signal
                return teardown_result(return_code)
            for key, _ in selector.select(max(0.05, min(0.25, deadline - time.monotonic()))):
                try:
                    chunk = os.read(key.fd, 4096)
                except BlockingIOError:
                    continue
                except OSError:
                    chunk = b""
                if not chunk:
                    selector.unregister(key.fd)
                    break
                if not append_output(output, chunk):
                    return teardown_result(1)
                if not sent and b"Type the exact backup digest to restore:" in output:
                    os.write(fd, (args.digest + "\n").encode("ascii"))
                    sent = True
            if interrupted_signal is not None:
                return_code = 128 + interrupted_signal
                return teardown_result(return_code)
            waited, code = os.waitpid(pid, os.WNOHANG)
            if waited == pid:
                status = code
                if not drain_available(fd, output):
                    return teardown_result(1)
                break
        if status is None:
            return teardown_result(124)
        if not ensure_group_empty(pid):
            return GROUP_TEARDOWN_FAILED
    except BaseException:
        return teardown_result(1)
    finally:
        if selector is not None:
            selector.close()
        try:
            os.close(fd)
        except OSError:
            pass
    if not sent or b"state=restored" not in output:
        return 1
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
