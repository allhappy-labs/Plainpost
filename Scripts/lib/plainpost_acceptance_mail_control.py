"""Typed control surface for the local acceptance mail peer."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
from pathlib import Path

try:
    from . import plainpost_acceptance_mail_state as state
except ImportError:  # direct execution from the fixture image
    import plainpost_acceptance_mail_state as state

PROTOCOLS = state.PROTOCOLS
PHASES = state.PHASES
FAULTS = state.FAULTS
RESULT_CLASSES = state.RESULT_CLASSES
ACTIONS = state.ACTIONS


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="bounded acceptance mail control")
    root.add_argument("--root", default=os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_ROOT", "/var/lib/plainpost"))
    commands = root.add_subparsers(dest="operation", required=True)
    arm = commands.add_parser("arm-fault")
    arm.add_argument("name", choices=FAULTS)
    arm.add_argument("occurrence", type=int)
    arm.add_argument("result_class", choices=RESULT_CLASSES)
    barrier = commands.add_parser("phase")
    barrier.add_argument("protocol", choices=PROTOCOLS)
    barrier.add_argument("phase", choices=PHASES)
    barrier.add_argument("occurrence", type=int)
    barrier.add_argument("action", choices=ACTIONS)
    barrier.add_argument("--delay-ms", type=int, default=0)
    wait = commands.add_parser("wait-phase")
    wait.add_argument("protocol", choices=PROTOCOLS)
    wait.add_argument("phase", choices=PHASES)
    wait.add_argument("occurrence", type=int)
    wait.add_argument("--timeout-ms", type=int, default=30000)
    release = commands.add_parser("wait-phase-release")
    release.add_argument("protocol", choices=PROTOCOLS)
    release.add_argument("phase", choices=PHASES)
    release.add_argument("occurrence", type=int)
    release.add_argument("--timeout-ms", type=int, default=30000)
    show = commands.add_parser("status")
    postcondition = commands.add_parser("postcondition", aliases=["assert-postcondition"])
    postcondition.add_argument("--expectation-file", required=True)
    commands.add_parser("reset-uidvalidity")
    commands.add_parser("append-matrix-message")
    return root


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    if not 1 <= getattr(arguments, "occurrence", 1) <= 1000:
        parser().error("occurrence must be between 1 and 1000")
    if getattr(arguments, "operation", "") == "phase" and not 0 <= arguments.delay_ms <= 30000:
        parser().error("delay must be between 0 and 30000 milliseconds")
    if getattr(arguments, "operation", "") == "phase" and arguments.action == "delay" and arguments.delay_ms <= 0:
        parser().error("delay action requires delay-ms greater than zero")
    if getattr(arguments, "operation", "") == "phase" and arguments.action != "delay" and arguments.delay_ms != 0:
        parser().error("delay-ms is only valid for delay action")
    if getattr(arguments, "operation", "") in {"wait-phase", "wait-phase-release"} and not 0 <= arguments.timeout_ms <= 30000:
        parser().error("timeout must be between 0 and 30000 milliseconds")
    state.configure_root(Path(arguments.root))
    state.initialize(repair=arguments.operation in {"status", "wait-phase", "wait-phase-release", "postcondition", "assert-postcondition"})
    if arguments.operation == "arm-fault":
        state.arm_fault(arguments.name, arguments.occurrence, arguments.result_class)
        result = {"operation": "arm-fault", "name": arguments.name, "occurrence": arguments.occurrence, "result_class": arguments.result_class}
    elif arguments.operation == "phase":
        state.set_phase_action(arguments.protocol, arguments.phase, arguments.occurrence, arguments.action, arguments.delay_ms)
        result = {"operation": "phase", "protocol": arguments.protocol, "phase": arguments.phase, "occurrence": arguments.occurrence, "action": arguments.action, "delay_ms": arguments.delay_ms}
    elif arguments.operation == "wait-phase":
        result = state.wait_for_phase(arguments.protocol, arguments.phase, arguments.occurrence, arguments.timeout_ms)
    elif arguments.operation == "wait-phase-release":
        result = state.wait_for_phase_release(arguments.protocol, arguments.phase, arguments.occurrence, arguments.timeout_ms)
    elif arguments.operation == "status":
        snapshot = state.read()
        result = {
            "uidValidity": snapshot["uidValidity"],
            "nextUID": snapshot["nextUID"],
            "message_count": len(snapshot["messages"]),
            "messages": [
                {"uid": item["uid"], "flags": [flag for flag in item.get("flags", []) if flag in state.MESSAGE_FLAGS], "label_digest": hashlib.sha256(json.dumps(item.get("labels", []), sort_keys=True).encode()).hexdigest(), "raw_digest": hashlib.sha256(item.get("raw", "").encode()).hexdigest()}
                for item in snapshot["messages"]
            ],
            "delivery_count": len(snapshot["deliveries"]),
            "deliveries": [{"delivery_id": item["delivery_id"], "canonical_digest": item["canonical_digest"], "message_id_digest": hashlib.sha256(item["message_id"].encode()).hexdigest(), "tls_active": item["tls_active"], "authenticated": item["authenticated"], "envelope_sender_digest": hashlib.sha256(item["envelope_sender"].encode()).hexdigest(), "envelope_recipient_count": len(item["envelope_recipients"])} for item in snapshot["deliveries"]],
            "faults": snapshot["faults"],
            "phases": snapshot["phases"],
            "phase_counters": snapshot["phase_counters"],
            "observations": snapshot["observations"],
            "observation_count": len(snapshot["observations"]),
        }
    elif arguments.operation in {"postcondition", "assert-postcondition"}:
        path = Path(arguments.expectation_file)
        try:
            if path.parent != Path(arguments.root) or not stat.S_ISREG(path.stat().st_mode) or stat.S_IMODE(path.stat().st_mode) != 0o600:
                raise ValueError("postcondition expectation must be a mode-0600 regular file under the fixture root")
            expected = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            parser().error(str(error))
        try:
            result = state.assert_postcondition(expected)
        except state.PostconditionMismatch as error:
            print(f"postcondition-category={error.category}")
            return 2
        except (TypeError, ValueError) as error:
            parser().error(str(error))
    elif arguments.operation == "reset-uidvalidity":
        current = state.read()["uidValidity"]
        if current >= 0xFFFFFFFF:
            parser().error("uidvalidity reset exceeded the fixed bound")
        state.replace({"uidValidity": current + 1})
        result = {"operation": "reset-uidvalidity", "uidValidity": current + 1}
    elif arguments.operation == "append-matrix-message":
        assigned: list[int] = []
        def append(current: dict) -> None:
            uid = int(current["nextUID"])
            current["nextUID"] = uid + 1
            current.setdefault("messages", []).append({
                "uid": uid,
                "flags": [],
                "labels": ["INBOX"],
                "raw": "Message-ID: <imap-matrix-transition@example.test>\r\nFrom: acceptance@example.test\r\nTo: recipient@example.test\r\nSubject: IMAP matrix transition\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nIMAP matrix transition body\r\n",
            })
            assigned.append(uid)
        state.transaction(append)
        result = {"operation": "append-matrix-message", "uid": assigned[0]}
    else:
        parser().error("unsupported operation")
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
