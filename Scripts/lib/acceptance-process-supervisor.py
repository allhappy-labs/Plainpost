#!/usr/bin/env python3
"""Own an acceptance child session and reap descendants that escape its PGID."""

import os
import signal
import subprocess
import sys
import time


POLL_SECONDS = 0.05
PRE_TERMINATION_SNAPSHOTS = 2
TERM_GRACE_SECONDS = 2.0
KILL_GRACE_SECONDS = 2.0


def process_identity(pid):
    """Return a stable process-start token for pid, or None if it is gone."""
    if pid <= 1:
        return None
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii") as stream:
            fields = stream.read().split()
        if len(fields) > 21:
            return ("proc", fields[21])
    except (FileNotFoundError, OSError, ValueError):
        pass
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart="],
            check=False,
            capture_output=True,
            text=True,
            timeout=0.2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    token = result.stdout.strip()
    return ("ps", token) if result.returncode == 0 and token else None


def descendants(root_pid):
    """Snapshot descendants using parent links, never command matching."""
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,ppid="],
            check=False,
            capture_output=True,
            text=True,
            timeout=0.2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode != 0:
        return []
    children = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        try:
            pid, parent = (int(value) for value in fields)
        except ValueError:
            continue
        children.setdefault(parent, []).append(pid)
    found = []
    pending = [root_pid]
    seen = {root_pid}
    while pending:
        parent = pending.pop()
        for child in children.get(parent, []):
            if child in seen:
                continue
            seen.add(child)
            found.append(child)
            pending.append(child)
    return found


def signal_if_owned(pid, identity, signum):
    if process_identity(pid) != identity:
        return
    try:
        os.kill(pid, signum)
    except (ProcessLookupError, PermissionError):
        pass


class Supervisor:
    def __init__(self, command):
        self.stop_requested = False
        self.child = subprocess.Popen(command, start_new_session=True)
        self.child_identity = process_identity(self.child.pid)
        self.remembered = {}

    def request_stop(self, _signum, _frame):
        self.stop_requested = True

    def remember_descendants(self):
        for pid in descendants(self.child.pid):
            identity = process_identity(pid)
            if identity is not None:
                self.remembered.setdefault(pid, identity)

    def signal_owned(self, signum):
        if self.child.poll() is None and (
            self.child_identity is None
            or process_identity(self.child.pid) == self.child_identity
        ):
            try:
                os.killpg(self.child.pid, signum)
            except (ProcessLookupError, PermissionError):
                pass
        for pid, identity in list(self.remembered.items()):
            signal_if_owned(pid, identity, signum)

    def remembered_processes_are_live(self):
        return any(
            process_identity(pid) == identity
            for pid, identity in self.remembered.items()
        )

    def reap_after_child_exit(self):
        """Bound cleanup for descendants that outlive a successful child."""
        if not self.remembered_processes_are_live():
            return None
        self.signal_owned(signal.SIGTERM)
        deadline = time.monotonic() + TERM_GRACE_SECONDS
        while time.monotonic() < deadline:
            if not self.remembered_processes_are_live():
                return True
            time.sleep(POLL_SECONDS)
        self.signal_owned(signal.SIGKILL)
        deadline = time.monotonic() + KILL_GRACE_SECONDS
        while time.monotonic() < deadline:
            if not self.remembered_processes_are_live():
                return True
            time.sleep(POLL_SECONDS)
        return False

    def prepare_for_stop(self):
        """Close the fork-discovery race before terminating the owned group."""
        snapshots = 0
        while snapshots < PRE_TERMINATION_SNAPSHOTS:
            self.remember_descendants()
            snapshots += 1
            if snapshots < PRE_TERMINATION_SNAPSHOTS and self.child.poll() is None:
                time.sleep(POLL_SECONDS)

    def run(self):
        while True:
            self.remember_descendants()
            child_status = self.child.poll()
            if self.stop_requested:
                self.prepare_for_stop()
                self.signal_owned(signal.SIGTERM)
                deadline = time.monotonic() + TERM_GRACE_SECONDS
                while time.monotonic() < deadline:
                    self.remember_descendants()
                    if self.child.poll() is not None and not any(
                        process_identity(pid) == identity
                        for pid, identity in self.remembered.items()
                    ):
                        return 143
                    time.sleep(POLL_SECONDS)
                self.signal_owned(signal.SIGKILL)
                deadline = time.monotonic() + KILL_GRACE_SECONDS
                while self.child.poll() is None or any(
                    process_identity(pid) == identity
                    for pid, identity in self.remembered.items()
                ):
                    if time.monotonic() >= deadline:
                        return 124
                    time.sleep(POLL_SECONDS)
                return 143
            if child_status is not None:
                self.remember_descendants()
                reaped = self.reap_after_child_exit()
                if reaped is not None:
                    return 125 if reaped else 124
                return child_status if child_status >= 0 else 128 - child_status
            time.sleep(POLL_SECONDS)


def main(argv):
    if len(argv) < 2 or argv[0] != "--":
        print("usage: acceptance-process-supervisor.py -- command [args...]", file=sys.stderr)
        return 2
    supervisor = Supervisor(argv[1:])
    signal.signal(signal.SIGTERM, supervisor.request_stop)
    signal.signal(signal.SIGINT, supervisor.request_stop)
    return supervisor.run()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
