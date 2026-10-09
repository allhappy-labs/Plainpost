"""Crash-consistent state authority for the acceptance mail peer.

The JSON files used by older acceptance scenarios remain compatibility
projections.  SQLite is the only authority: every protocol mutation takes a
single ``BEGIN IMMEDIATE`` transaction, and projections are written only
after commit.  This module intentionally uses only Python's standard library
so the pinned Alpine fixture image has no package installation step.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import sqlite3
import stat
import time
from pathlib import Path
from typing import Callable

os.umask(0o077)

ROOT = Path(os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_ROOT", "/var/lib/plainpost"))
DELIVERIES_PATH: Path | None = None
DB_NAME = "mail-state.sqlite3"
LOCK_NAME = "mail-state.lock"
TRANSACTION_LOCK_NAME = "mail-state-transaction.lock"
WAL_LOCK_NAME = "mail-state-wal.lock"
STATE_NAME = "mailbox.json"
DELIVERIES_NAME = "smtp-deliveries.jsonl"
CONTROL_NAME = "mail-control.json"
OBSERVATIONS_NAME = "mail-observations.jsonl"
# A provider startup can have several fixture processes opening the same WAL
# at once. Keep this bounded, but longer than one fsync/permission handoff.
WAL_OPEN_RETRY_ATTEMPTS = 20
WAL_OPEN_RETRY_DELAY_SECONDS = 0.1

TRANSACTION_BOUNDARIES = ("transaction-before-commit", "transaction-after-commit")
PROJECTION_TARGETS = ("mailbox", "deliveries", "control", "observations")
PROJECTION_BOUNDARIES = ("before-temp", "after-temp", "after-write", "after-replace", "after-fsync")
FAILPOINTS = TRANSACTION_BOUNDARIES + tuple(f"projection-{target}-{boundary}" for target in PROJECTION_TARGETS for boundary in PROJECTION_BOUNDARIES)
CONTROL_IDLE_LEASE_FIELDS = ("imap_idle_active_count", "imap_idle_active_inbox_count")
POSTCONDITION_MISMATCH_CATEGORIES = (
    "delivery-count", "delivery-identity", "delivery-security", "draft-state",
    "sent-state", "envelope", "content-security", "correlation",
)


class PostconditionMismatch(ValueError):
    """A fixed, privacy-safe authoritative postcondition failure class."""

    def __init__(self, category: str) -> None:
        if category not in POSTCONDITION_MISMATCH_CATEGORIES:
            raise ValueError("postcondition mismatch category is outside the fixed allowlist")
        self.category = category
        super().__init__(f"mail postcondition mismatch: {category}")

# One authority owns the protocol vocabulary. The control CLI imports these
# values instead of maintaining a second, potentially drifting allowlist.
PROTOCOLS = ("imap", "smtp", "provider", "controller")
PHASES = (
    "transaction", "projection", "transition", "append", "delivery", "reset", "activation",
    "authentication", "authentication-command", "tls-handshake", "recipient", "before-data", "after-354", "data", "final-reply",
    "quit", "acceptance-before-append", "sent-append", "catalog", "header-fetch", "body-fetch", "attachment-fetch", "mutation",
    "idle",
)
FAULTS = (
    "smtp-delivery", "imap-mutation", "provider-transition", "projection",
    "smtp-authentication", "smtp-recipient-451", "smtp-recipient-550", "imap-sent-append",
    "smtp-after-354", "smtp-mid-data", "smtp-final-reply", "smtp-quit-loss",
    "imap-catalog", "imap-authentication", "imap-header-fetch", "imap-body-fetch", "imap-attachment-fetch", "imap-truncated-literal",
)
RESULT_CLASSES = ("temporary", "unavailable", "disconnect", "accepted", "rejected", "truncated")
ACTIONS = ("pause", "resume", "disconnect", "continue", "delay")
OBSERVATION_KINDS = ("fault-fired", "phase-reached", "test-observation")
MAILBOXES = ("INBOX", "Sent", "Drafts", "Trash", "Archive", "All")
MESSAGE_FLAGS = ("\\Seen", "\\Answered", "\\Flagged", "\\Deleted", "\\Draft", "\\Recent")
TYPED_SMTP_FAULT_RESULTS = {
    "smtp-authentication": ("disconnect", "rejected"),
    "smtp-recipient-451": ("temporary", "disconnect"),
    "smtp-recipient-550": ("disconnect", "rejected"),
    "smtp-after-354": ("disconnect",),
    "smtp-mid-data": ("disconnect",),
    "smtp-final-reply": ("disconnect",),
    "smtp-quit-loss": ("disconnect",),
}
TYPED_IMAP_FAULT_RESULTS = {
    "imap-catalog": ("disconnect",),
    "imap-authentication": ("rejected", "disconnect"),
    "imap-sent-append": ("temporary", "unavailable", "disconnect"),
    "imap-header-fetch": ("disconnect",),
    "imap-body-fetch": ("disconnect",),
    "imap-attachment-fetch": ("disconnect",),
    "imap-truncated-literal": ("truncated",),
}
TYPED_FAULT_RESULTS = {
    **TYPED_SMTP_FAULT_RESULTS,
    **TYPED_IMAP_FAULT_RESULTS,
    "smtp-delivery": ("temporary", "unavailable", "disconnect", "accepted", "rejected"),
    "imap-mutation": ("temporary", "unavailable", "disconnect"),
    "provider-transition": ("temporary", "unavailable", "disconnect"),
    "projection": ("temporary", "unavailable", "disconnect"),
}


def canonical_source(value: bytes | str) -> bytes:
    """Return the RFC source used for cross-peer digesting.

    SMTP DATA may arrive with mixed line endings when driven by a fixture
    client.  The authority deliberately hashes one representation: every
    line ending is CRLF and the source has one terminal CRLF.
    """
    source = value.encode("utf-8") if isinstance(value, str) else bytes(value)
    source = source.replace(b"\r\n", b"\n").replace(b"\r", b"\n").replace(b"\n", b"\r\n")
    return source if source.endswith(b"\r\n") else source + b"\r\n"


def canonical_digest(value: bytes | str) -> str:
    return hashlib.sha256(canonical_source(value)).hexdigest()


def message_id(value: bytes | str) -> str:
    """Extract one bounded Message-ID from RFC headers without exposing data."""
    source = canonical_source(value)
    header_bytes = source.split(b"\r\n\r\n", 1)[0]
    current_name = ""
    current_value = ""
    found: list[str] = []
    for line in header_bytes.split(b"\r\n") + [b""]:
        if line[:1] in (b" ", b"\t") and current_name:
            current_value += " " + line.strip().decode("utf-8", "strict")
            continue
        if current_name == "message-id" and current_value:
            found.append(current_value)
        name, separator, raw = line.partition(b":")
        current_name = name.decode("ascii", "ignore").casefold() if separator else ""
        current_value = raw.strip().decode("utf-8", "strict") if separator else ""
    if len(found) != 1 or not re.fullmatch(r"<[^<>\s]+>", found[0]):
        raise ValueError("delivery must contain exactly one valid Message-ID")
    return found[0]


def _enum(value: str, choices: tuple[str, ...], label: str) -> str:
    if not isinstance(value, str) or value not in choices:
        raise ValueError(f"{label} is outside the fixed allowlist")
    lowered = value.casefold()
    if "@" in value or "token" in lowered or "password" in lowered or "secret" in lowered:
        raise ValueError(f"{label} resembles account or credential data")
    return value


def _occurrence(value: int) -> int:
    if not isinstance(value, int) or not 1 <= value <= 1000:
        raise ValueError("occurrence must be between 1 and 1000")
    return value


def failpoint(name: str) -> None:
    if os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_FAILPOINT") == name and name in FAILPOINTS:
        os._exit(97)


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def configure_root(root: Path | str) -> None:
    global ROOT, DELIVERIES_PATH
    ROOT = Path(root)
    DELIVERIES_PATH = None
    ROOT.mkdir(parents=True, exist_ok=True)
    _secure_dir(ROOT)


def _secure(path: Path) -> None:
    try:
        os.chmod(path, 0o600)
    except FileNotFoundError:
        pass


def _secure_dir(path: Path) -> None:
    try:
        os.chmod(path, 0o700)
    except FileNotFoundError:
        pass


def _open_lock(lock: Path) -> int:
    """Open only a regular lock file without following symlinks."""
    if not getattr(os, "O_NOFOLLOW", 0) and lock.is_symlink():
        raise OSError(f"acceptance mail lock must not be a symlink: {lock}")
    flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(lock, flags)
    except FileNotFoundError:
        descriptor = os.open(lock, flags | os.O_CREAT, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise OSError(f"acceptance mail lock is not a regular file: {lock}")
        os.fchmod(descriptor, 0o600)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _paths() -> tuple[Path, Path, Path, Path]:
    ROOT.mkdir(parents=True, exist_ok=True)
    _secure_dir(ROOT)
    db = Path(os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_STATE_DB", str(ROOT / DB_NAME)))
    if db.parent != ROOT:
        raise ValueError("acceptance mail state database must remain under fixture root")
    lock = ROOT / LOCK_NAME
    state = ROOT / STATE_NAME
    deliveries = DELIVERIES_PATH or ROOT / DELIVERIES_NAME
    descriptor = _open_lock(lock)
    os.close(descriptor)
    _secure(Path(str(db) + "-wal"))
    _secure(Path(str(db) + "-shm"))
    return db, lock, state, deliveries


def configure_delivery_path(path: Path | str) -> None:
    global DELIVERIES_PATH
    candidate = Path(path)
    if candidate.parent != ROOT:
        raise ValueError("acceptance mail delivery projection must remain under fixture root")
    DELIVERIES_PATH = candidate


def _legacy_state(state_path: Path) -> dict:
    try:
        value = json.loads(state_path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _enable_wal(
    execute: Callable[[str], object],
    *,
    sleep: Callable[[float], None] = time.sleep,
    paths_valid: Callable[[], bool] = lambda: True,
) -> None:
    """Enable WAL, retrying only transient cross-process opener races."""
    for attempt in range(WAL_OPEN_RETRY_ATTEMPTS):
        try:
            execute("PRAGMA journal_mode=WAL")
            return
        except sqlite3.OperationalError as error:
            message = str(error).lower()
            transient = "locked" in message or "unable to open database file" in message
            if not transient or not paths_valid() or attempt == WAL_OPEN_RETRY_ATTEMPTS - 1:
                raise
            sleep(WAL_OPEN_RETRY_DELAY_SECONDS)


def _connect() -> sqlite3.Connection:
    db, _, state_path, deliveries_path = _paths()
    wal_lock = None
    connection = None

    def open_connection() -> sqlite3.Connection:
        opened = None
        try:
            opened = sqlite3.connect(db, timeout=10, isolation_level=None)
            opened.row_factory = sqlite3.Row
            opened.execute("PRAGMA busy_timeout=10000")
            return opened
        except BaseException:
            if opened is not None:
                opened.close()
            raise

    try:
        # Read the persistent mode without taking the transition lock. Once
        # WAL is established, every protocol operation stays on this hot path.
        connection = open_connection()
        journal_mode = connection.execute("PRAGMA journal_mode").fetchone()[0]
    except BaseException:
        if connection is not None:
            connection.close()
        raise
    if str(journal_mode).casefold() != "wal":
        # Close the unlocked observation before entering the cold transition;
        # the fresh connection below rechecks the mode while holding the lock.
        connection.close()
        connection = None
        try:
            wal_lock = _open_lock(ROOT / WAL_LOCK_NAME)
            fcntl.flock(wal_lock, fcntl.LOCK_EX)
            connection = open_connection()
            journal_mode = connection.execute("PRAGMA journal_mode").fetchone()[0]
            if str(journal_mode).casefold() != "wal":
                _enable_wal(
                    connection.execute,
                    paths_valid=lambda: db.parent.is_dir()
                    and os.access(db.parent, os.R_OK | os.W_OK | os.X_OK)
                    and (not db.exists() or os.access(db, os.R_OK | os.W_OK)),
                )
        except BaseException:
            if wal_lock is not None:
                fcntl.flock(wal_lock, fcntl.LOCK_UN)
                os.close(wal_lock)
            if connection is not None:
                connection.close()
            raise
        fcntl.flock(wal_lock, fcntl.LOCK_UN)
        os.close(wal_lock)
        wal_lock = None
    try:
        connection.execute("PRAGMA synchronous=FULL")
        _secure(db)
        _secure(Path(str(db) + "-wal"))
        _secure(Path(str(db) + "-shm"))
        connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS messages (
            uid INTEGER PRIMARY KEY, flags TEXT NOT NULL, labels TEXT NOT NULL, raw TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS deliveries (
            delivery_id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_digest TEXT NOT NULL,
            message TEXT NOT NULL,
            created_at REAL NOT NULL,
            tls_active INTEGER NOT NULL DEFAULT 0,
            authenticated INTEGER NOT NULL DEFAULT 0,
            envelope_sender TEXT NOT NULL DEFAULT '',
            envelope_recipients TEXT NOT NULL DEFAULT '[]',
            canonical_digest TEXT NOT NULL DEFAULT '',
            message_id TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS faults (
            name TEXT PRIMARY KEY, occurrence INTEGER NOT NULL,
            result_class TEXT NOT NULL, consumed INTEGER NOT NULL DEFAULT 0,
            seen INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS phases (
            protocol TEXT NOT NULL, phase TEXT NOT NULL, occurrence INTEGER NOT NULL,
            action TEXT NOT NULL, delay_ms INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(protocol, phase, occurrence)
        );
        CREATE TABLE IF NOT EXISTS phase_counters (
            protocol TEXT NOT NULL, phase TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(protocol, phase)
        );
        CREATE TABLE IF NOT EXISTS observations (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL,
            protocol TEXT NOT NULL, phase TEXT NOT NULL, occurrence INTEGER NOT NULL,
            detail_digest TEXT NOT NULL
        );
        """
        )
    # Schema upgrades must be one serialized transaction.  Without this
    # boundary, concurrent fixture initializers can both inspect an old
    # schema and race through ALTER TABLE, producing duplicate-column errors
    # or a partially upgraded authority.
        connection.execute("BEGIN IMMEDIATE")
        try:
            connection.execute("ALTER TABLE faults ADD COLUMN seen INTEGER NOT NULL DEFAULT 0")
        except sqlite3.OperationalError as error:
            if "duplicate column name: seen" not in str(error):
                raise
        try:
            connection.execute("ALTER TABLE phases ADD COLUMN delay_ms INTEGER NOT NULL DEFAULT 0")
        except sqlite3.OperationalError as error:
            if "duplicate column name: delay_ms" not in str(error):
                raise
        delivery_columns = {
            row["name"] for row in connection.execute("PRAGMA table_info(deliveries)")
        }
        for name, definition in (
            ("tls_active", "INTEGER NOT NULL DEFAULT 0"),
            ("authenticated", "INTEGER NOT NULL DEFAULT 0"),
            ("envelope_sender", "TEXT NOT NULL DEFAULT ''"),
            ("envelope_recipients", "TEXT NOT NULL DEFAULT '[]'"),
            ("canonical_digest", "TEXT NOT NULL DEFAULT ''"),
            ("message_id", "TEXT NOT NULL DEFAULT ''"),
        ):
            if name not in delivery_columns:
                connection.execute(f"ALTER TABLE deliveries ADD COLUMN {name} {definition}")
        # Legacy rows remain private and are upgraded to the same canonical
        # digest authority on first open. Never copy the historical raw-source
        # digest: it may differ from the CRLF-normalized digest shared by
        # Swift and Python.
        legacy_rows = connection.execute(
            "SELECT delivery_id, message, canonical_digest, message_id FROM deliveries"
        ).fetchall()
        for row in legacy_rows:
            digest = canonical_digest(row["message"])
            parsed_id = row["message_id"]
            if not parsed_id:
                try:
                    parsed_id = message_id(row["message"])
                except (UnicodeDecodeError, ValueError):
                    parsed_id = ""
            if digest != row["canonical_digest"] or parsed_id != row["message_id"]:
                connection.execute(
                    "UPDATE deliveries SET canonical_digest=?, message_id=? WHERE delivery_id=?",
                    (digest, parsed_id, row["delivery_id"]),
                )
        recheck = connection.execute("PRAGMA index_list(deliveries)").fetchall()
        recheck_obsolete = []
        preserved_indexes = []
        for index in recheck:
            columns = [item["name"] for item in connection.execute(f"PRAGMA index_info({json.dumps(index['name'])})")]
            if index["unique"] and columns == ["message_digest"]:
                recheck_obsolete.append(index["name"])
            elif index["name"] and not index["name"].startswith("sqlite_autoindex"):
                sql = connection.execute("SELECT sql FROM sqlite_master WHERE type='index' AND name=?", (index["name"],)).fetchone()
                if sql and sql["sql"]:
                    preserved_indexes.append(sql["sql"])
        if recheck_obsolete:
            connection.execute("ALTER TABLE deliveries RENAME TO deliveries_legacy")
            connection.execute("CREATE TABLE deliveries (delivery_id INTEGER PRIMARY KEY AUTOINCREMENT, message_digest TEXT NOT NULL, message TEXT NOT NULL, created_at REAL NOT NULL, tls_active INTEGER NOT NULL DEFAULT 0, authenticated INTEGER NOT NULL DEFAULT 0, envelope_sender TEXT NOT NULL DEFAULT '', envelope_recipients TEXT NOT NULL DEFAULT '[]', canonical_digest TEXT NOT NULL DEFAULT '', message_id TEXT NOT NULL DEFAULT '')")
            connection.execute("INSERT INTO deliveries(delivery_id,message_digest,message,created_at,tls_active,authenticated,envelope_sender,envelope_recipients,canonical_digest,message_id) SELECT delivery_id,message_digest,message,created_at,tls_active,authenticated,envelope_sender,envelope_recipients,canonical_digest,message_id FROM deliveries_legacy")
            connection.execute("DROP TABLE deliveries_legacy")
            for sql in preserved_indexes:
                connection.execute(sql)
        connection.commit()
        if connection.execute("SELECT 1 FROM metadata WHERE key='initialized'").fetchone() is None:
            legacy = _legacy_state(state_path)
            connection.execute("BEGIN IMMEDIATE")
            try:
                if connection.execute("SELECT 1 FROM metadata WHERE key='initialized'").fetchone() is None:
                    connection.execute("INSERT INTO metadata(key,value) VALUES('initialized','1')")
                    connection.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('uidValidity',?)", (str(legacy.get("uidValidity", 1)),))
                    connection.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('nextUID',?)", (str(legacy.get("nextUID", 1)),))
                    for message in legacy.get("messages", []):
                        if isinstance(message, dict) and str(message.get("uid", "")).isdigit():
                            connection.execute(
                                "INSERT OR REPLACE INTO messages(uid,flags,labels,raw) VALUES(?,?,?,?)",
                                (int(message["uid"]), json.dumps(message.get("flags", [])), json.dumps(message.get("labels", [])), str(message.get("raw", ""))),
                            )
                    for line in deliveries_path.read_text(encoding="utf-8").splitlines() if deliveries_path.exists() else []:
                        try:
                            value = json.loads(line)
                            message = str(value.get("message", ""))
                        except json.JSONDecodeError:
                            continue
                        digest = canonical_digest(message)
                        try:
                            legacy_message_id = message_id(message)
                        except (UnicodeDecodeError, ValueError):
                            legacy_message_id = ""
                        connection.execute("INSERT INTO deliveries(message_digest,message,created_at,canonical_digest,message_id) VALUES(?,?,?,?,?)", (digest, message, time.time(), digest, legacy_message_id))
                connection.commit()
            except BaseException:
                connection.rollback()
                raise
        _secure(db)
        return connection
    except BaseException:
        connection.close()
        raise


def _snapshot(connection: sqlite3.Connection) -> dict:
    metadata = {row["key"]: row["value"] for row in connection.execute("SELECT key,value FROM metadata")}
    messages = []
    for row in connection.execute("SELECT uid,flags,labels,raw FROM messages ORDER BY uid"):
        messages.append({"uid": row["uid"], "flags": json.loads(row["flags"]), "labels": json.loads(row["labels"]), "raw": row["raw"]})
    deliveries = [
        {
            "delivery_id": row["delivery_id"],
            "message": row["message"],
            "message_digest": row["message_digest"],
            "canonical_digest": row["canonical_digest"],
            "message_id": row["message_id"],
            "tls_active": bool(row["tls_active"]),
            "authenticated": bool(row["authenticated"]),
            "envelope_sender": row["envelope_sender"],
            "envelope_recipients": json.loads(row["envelope_recipients"]),
        }
        for row in connection.execute("SELECT delivery_id,message_digest,message,canonical_digest,message_id,tls_active,authenticated,envelope_sender,envelope_recipients FROM deliveries ORDER BY delivery_id")
    ]
    faults = [dict(row) for row in connection.execute("SELECT name,occurrence,result_class,consumed,seen FROM faults ORDER BY name")]
    phases = [dict(row) for row in connection.execute("SELECT protocol,phase,occurrence,action,delay_ms FROM phases ORDER BY rowid")]
    phase_counters = [dict(row) for row in connection.execute("SELECT protocol,phase,count FROM phase_counters ORDER BY protocol,phase")]
    observations = [dict(row) for row in connection.execute("SELECT sequence,kind,protocol,phase,occurrence,detail_digest FROM observations ORDER BY sequence")]
    extras = {}
    try:
        extras = json.loads(metadata.get("extras", "{}"))
    except json.JSONDecodeError:
        pass
    return {
        **extras,
        "uidValidity": int(metadata.get("uidValidity", 1)),
        "nextUID": int(metadata.get("nextUID", 1)),
        "messages": messages,
        "deliveries": deliveries,
        "faults": faults,
        "phases": phases,
        "phase_counters": phase_counters,
        "observations": observations,
    }


def _validate_snapshot(state: dict) -> None:
    """Validate all externally writable fixed-vocabulary records."""
    for fault in state.get("faults", []):
        _enum(fault["name"], FAULTS, "fault name")
        _occurrence(fault["occurrence"])
        _enum(fault["result_class"], RESULT_CLASSES, "fault result class")
    for phase_record in state.get("phases", []):
        _enum(phase_record["protocol"], PROTOCOLS, "phase protocol")
        _enum(phase_record["phase"], PHASES, "phase name")
        _occurrence(phase_record["occurrence"])
        _enum(phase_record["action"], ACTIONS, "phase action")
    for counter in state.get("phase_counters", []):
        _enum(counter["protocol"], PROTOCOLS, "counter protocol")
        _enum(counter["phase"], PHASES, "counter phase")
        _occurrence(counter["count"])
    for observation in state.get("observations", []):
        _enum(observation["kind"], OBSERVATION_KINDS, "observation kind")
        if observation["kind"] == "fault-fired":
            if observation["phase"] == "":
                _enum(observation["protocol"], FAULTS, "fault observation name")
            else:
                _enum(observation["protocol"], PROTOCOLS, "fault observation protocol")
                _enum(observation["phase"], PHASES, "fault observation phase")
        else:
            _enum(observation["protocol"], PROTOCOLS, "observation protocol")
            _enum(observation["phase"], PHASES, "observation phase")
        _occurrence(observation["occurrence"])
        if not re.fullmatch(r"[0-9a-f]{64}", str(observation["detail_digest"])):
            raise ValueError("observation detail must be a SHA-256 digest")
    for message in state.get("messages", []):
        for flag in message.get("flags", []):
            _enum(flag, MESSAGE_FLAGS, "message flag")
        for label in message.get("labels", []):
            if label not in MAILBOXES:
                raise ValueError("mailbox label is outside the fixed allowlist")


def read() -> dict:
    connection = _connect()
    try:
        return _snapshot(connection)
    finally:
        connection.close()


def initialize(*, repair: bool = True) -> dict:
    """Open the authority and repair all compatibility projections on startup."""
    snapshot = read()
    if repair:
        repair_projections()
    return snapshot


def _replace(connection: sqlite3.Connection, state: dict) -> None:
    _validate_snapshot(state)
    connection.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('uidValidity',?)", (str(int(state.get("uidValidity", 1))),))
    connection.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('nextUID',?)", (str(int(state.get("nextUID", 1))),))
    extras = {key: value for key, value in state.items() if key not in {"uidValidity", "nextUID", "messages", "deliveries", "faults", "phases", "phase_counters", "observations"}}
    connection.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('extras',?)", (json.dumps(extras, sort_keys=True),))
    connection.execute("DELETE FROM messages")
    for message in state.get("messages", []):
        connection.execute(
            "INSERT INTO messages(uid,flags,labels,raw) VALUES(?,?,?,?)",
            (int(message["uid"]), json.dumps(message.get("flags", [])), json.dumps(message.get("labels", [])), str(message.get("raw", ""))),
        )


def _run_transaction(mutator: Callable[[sqlite3.Connection, dict], object], *, replace_state: bool = True, lock: bool = True) -> object:
    transaction_lock = None
    connection = None
    try:
        if lock:
            transaction_lock = _open_lock(ROOT / TRANSACTION_LOCK_NAME)
            fcntl.flock(transaction_lock, fcntl.LOCK_EX)
        connection = _connect()
        connection.execute("BEGIN IMMEDIATE")
        state = _snapshot(connection)
        result = mutator(connection, state)
        if replace_state:
            _replace(connection, state)
        failpoint("transaction-before-commit")
        connection.commit()
    except BaseException:
        if connection is not None:
            connection.rollback()
        raise
    finally:
        if connection is not None:
            connection.close()
        if transaction_lock is not None:
            fcntl.flock(transaction_lock, fcntl.LOCK_UN)
            os.close(transaction_lock)
    failpoint("transaction-after-commit")
    repair_projections()
    return result


def transaction(mutator: Callable[[dict], object]) -> dict:
    _run_transaction(lambda _connection, current: mutator(current))
    return read()


def replace(state: dict) -> None:
    transaction(lambda current: current.update(state))


def _write_projection(path: Path, content: str, target: str) -> None:
    temporary = path.with_name(path.name + ".tmp")
    failpoint(f"projection-{target}-before-temp")
    temporary.write_text(content, encoding="utf-8")
    _secure(temporary)
    failpoint(f"projection-{target}-after-temp")
    with temporary.open("rb") as stream:
        os.fsync(stream.fileno())
    failpoint(f"projection-{target}-after-write")
    os.replace(temporary, path)
    _secure(path)
    failpoint(f"projection-{target}-after-replace")
    _fsync_directory(path.parent)
    failpoint(f"projection-{target}-after-fsync")


def _control_projection(snapshot: dict) -> dict:
    """Project only fixed control observations, never arbitrary state extras."""
    projection = {
        "faults": snapshot["faults"],
        "phases": snapshot["phases"],
        "phase_counters": snapshot["phase_counters"],
    }
    for field in CONTROL_IDLE_LEASE_FIELDS:
        projection[field] = int(snapshot.get(field, 0))
    return projection


def repair_projections() -> None:
    _, _, state_path, deliveries_path = _paths()
    lock_path = ROOT / LOCK_NAME
    descriptor = _open_lock(lock_path)
    with os.fdopen(descriptor, "r+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            # Read while holding the projection lock.  A writer that commits
            # concurrently therefore cannot be followed by an older snapshot
            # replacing the newer compatibility files.
            snapshot = read()
            _write_projection(state_path, json.dumps({key: snapshot[key] for key in ("uidValidity", "nextUID", "messages")}, sort_keys=True, ensure_ascii=False), "mailbox")
            lines = "".join(json.dumps({"message": item["message"]}, ensure_ascii=False, sort_keys=True) + "\n" for item in snapshot["deliveries"])
            _write_projection(deliveries_path, lines, "deliveries")
            _write_projection(ROOT / CONTROL_NAME, json.dumps(_control_projection(snapshot), sort_keys=True), "control")
            observations_path = ROOT / OBSERVATIONS_NAME
            observation_lines = "".join(json.dumps({key: item[key] for key in ("kind", "protocol", "phase", "occurrence", "detail_digest")}, sort_keys=True) + "\n" for item in snapshot["observations"])
            _write_projection(observations_path, observation_lines, "observations")
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def record_delivery(
    message: bytes | str,
    *,
    tls_active: bool = False,
    authenticated: bool = False,
    envelope_sender: str = "",
    envelope_recipients: list[str] | tuple[str, ...] = (),
) -> bool:
    if not isinstance(tls_active, bool) or not isinstance(authenticated, bool):
        raise ValueError("delivery security fields must be booleans")
    if not isinstance(envelope_sender, str) or any(ch in envelope_sender for ch in "\r\n"):
        raise ValueError("delivery envelope sender is invalid")
    recipients = list(envelope_recipients)
    if any(not isinstance(item, str) or not item or any(ch in item for ch in "\r\n") for item in recipients):
        raise ValueError("delivery envelope recipients are invalid")
    source = canonical_source(message)
    raw = (message.encode("utf-8") if isinstance(message, str) else bytes(message)).decode("utf-8", "strict")
    digest = canonical_digest(source)
    parsed_message_id = message_id(source)
    _run_transaction(
        lambda connection, _state: connection.execute(
            "INSERT INTO deliveries(message_digest,message,created_at,tls_active,authenticated,envelope_sender,envelope_recipients,canonical_digest,message_id) VALUES(?,?,?,?,?,?,?,?,?)",
            (digest, raw, time.time(), int(tls_active), int(authenticated), envelope_sender, json.dumps(recipients, separators=(",", ":")), digest, parsed_message_id),
        ),
        replace_state=False,
    )
    return True


def arm_fault(name: str, occurrence: int, result_class: str) -> None:
    _enum(name, FAULTS, "fault name")
    _occurrence(occurrence)
    _enum(result_class, RESULT_CLASSES, "fault result class")
    allowed_results = TYPED_FAULT_RESULTS.get(name)
    if allowed_results is not None and result_class not in allowed_results:
        raise ValueError("typed protocol fault result class is outside its fixed allowlist")
    _run_transaction(lambda connection, _state: connection.execute("INSERT OR REPLACE INTO faults(name,occurrence,result_class,consumed,seen) VALUES(?,?,?,0,0)", (name, occurrence, result_class)), replace_state=False)


def consume_fault(name: str, occurrence: int) -> str | None:
    _enum(name, FAULTS, "fault name")
    _occurrence(occurrence)
    def mutate(connection: sqlite3.Connection, _state: dict) -> str | None:
        row = connection.execute("SELECT result_class,consumed FROM faults WHERE name=? AND occurrence=?", (name, occurrence)).fetchone()
        result = None
        if row is not None and not row["consumed"]:
            connection.execute("UPDATE faults SET consumed=1 WHERE name=? AND occurrence=?", (name, occurrence))
            connection.execute("INSERT INTO observations(kind,protocol,phase,occurrence,detail_digest) VALUES('fault-fired',?,?,?,?)", (name, "", occurrence, hashlib.sha256(row["result_class"].encode()).hexdigest()))
            result = row["result_class"]
        return result
    return _run_transaction(mutate, replace_state=False)  # type: ignore[return-value]


def claim_fault(name: str) -> str | None:
    """Atomically claim the configured occurrence of a one-shot fault."""
    _enum(name, FAULTS, "fault name")
    def mutate(connection: sqlite3.Connection, _state: dict) -> str | None:
        row = connection.execute("SELECT occurrence,result_class,consumed,seen FROM faults WHERE name=?", (name,)).fetchone()
        if row is None:
            return None
        seen = int(row["seen"]) + 1
        if seen != int(row["occurrence"]) or row["consumed"]:
            connection.execute("UPDATE faults SET seen=? WHERE name=?", (seen, name))
            return None
        connection.execute("UPDATE faults SET seen=?,consumed=1 WHERE name=?", (seen, name))
        digest = hashlib.sha256(str(row["result_class"]).encode()).hexdigest()
        connection.execute("INSERT INTO observations(kind,protocol,phase,occurrence,detail_digest) VALUES('fault-fired',?,?,?,?)", (name, "", seen, digest))
        return str(row["result_class"])
    return _run_transaction(mutate, replace_state=False)  # type: ignore[return-value]


def trigger_fault(name: str) -> str | None:
    """Advance a named fault occurrence and atomically consume its one shot."""
    _enum(name, FAULTS, "fault name")
    def mutate(connection: sqlite3.Connection, _state: dict) -> str | None:
        row = connection.execute("SELECT occurrence,result_class,consumed,seen FROM faults WHERE name=?", (name,)).fetchone()
        result = None
        if row is not None:
            seen = int(row["seen"]) + 1
            if seen != int(row["occurrence"]) or row["consumed"]:
                connection.execute("UPDATE faults SET seen=? WHERE name=?", (seen, name))
            else:
                connection.execute("UPDATE faults SET seen=?,consumed=1 WHERE name=?", (seen, name))
                digest = hashlib.sha256(str(row["result_class"]).encode()).hexdigest()
                connection.execute("INSERT INTO observations(kind,protocol,phase,occurrence,detail_digest) VALUES('fault-fired',?,?,?,?)", (name, "", seen, digest))
                result = str(row["result_class"])
        return result
    return _run_transaction(mutate, replace_state=False)  # type: ignore[return-value]


def configure_phase(protocol: str, phase: str, occurrence: int, action: str, delay_ms: int = 0) -> None:
    _enum(protocol, PROTOCOLS, "phase protocol")
    _enum(phase, PHASES, "phase name")
    _occurrence(occurrence)
    _enum(action, ACTIONS, "phase action")
    if not 0 <= delay_ms <= 30000:
        raise ValueError("phase delay must be between 0 and 30000 milliseconds")
    # A pause barrier deliberately holds the runtime transaction lock, while
    # this controller write remains available to publish resume/disconnect.
    _run_transaction(lambda connection, _state: connection.execute("INSERT OR REPLACE INTO phases(protocol,phase,occurrence,action,delay_ms) VALUES(?,?,?,?,?)", (protocol, phase, occurrence, action, delay_ms)), replace_state=False, lock=False)


def set_phase_action(protocol: str, phase: str, occurrence: int, action: str, delay_ms: int = 0) -> None:
    configure_phase(protocol, phase, occurrence, action, delay_ms)


def phase(protocol: str, phase_name: str) -> int:
    """Record a phase barrier and honor its typed pause/resume/disconnect action."""
    _enum(protocol, PROTOCOLS, "phase protocol")
    _enum(phase_name, PHASES, "phase name")
    # Acquire the runtime lock before publishing phase-reached. A competing
    # real protocol process therefore cannot slip through the observation
    # commit before a configured pause owns the transaction boundary.
    deadline = time.monotonic() + 30
    barrier = _open_lock(ROOT / TRANSACTION_LOCK_NAME)
    fcntl.flock(barrier, fcntl.LOCK_EX)
    try:
        def mutate(connection: sqlite3.Connection, _state: dict) -> tuple[int, str, int]:
            row = connection.execute("SELECT count FROM phase_counters WHERE protocol=? AND phase=?", (protocol, phase_name)).fetchone()
            actual = int(row["count"]) + 1 if row else 1
            connection.execute("INSERT INTO phase_counters(protocol,phase,count) VALUES(?,?,?) ON CONFLICT(protocol,phase) DO UPDATE SET count=excluded.count", (protocol, phase_name, actual))
            configured = connection.execute("SELECT action,delay_ms FROM phases WHERE protocol=? AND phase=? AND occurrence=?", (protocol, phase_name, actual)).fetchone()
            action = configured["action"] if configured else "continue"
            delay_ms = int(configured["delay_ms"]) if configured else 0
            digest = hashlib.sha256(f"{protocol}:{phase_name}:{actual}".encode()).hexdigest()
            connection.execute("INSERT INTO observations(kind,protocol,phase,occurrence,detail_digest) VALUES('phase-reached',?,?,?,?)", (protocol, phase_name, actual, digest))
            return actual, action, delay_ms
        actual, action, delay_ms = _run_transaction(mutate, replace_state=False, lock=False)  # type: ignore[misc]
        if action == "disconnect":
            raise ConnectionError(f"acceptance phase disconnected: {protocol}/{phase_name}/{actual}")
        if action == "delay":
            time.sleep(delay_ms / 1000)
            return actual
        if action != "pause":
            return actual
        while time.monotonic() < deadline:
            current = read()
            selected = next((item for item in current["phases"] if item["protocol"] == protocol and item["phase"] == phase_name and item["occurrence"] == actual), None)
            action = selected["action"] if selected else "continue"
            if action == "resume" or action == "continue":
                return actual
            if action == "disconnect":
                raise ConnectionError(f"acceptance phase disconnected: {protocol}/{phase_name}/{actual}")
            time.sleep(0.05)
        raise TimeoutError(f"acceptance phase pause timed out: {protocol}/{phase_name}/{actual}")
    finally:
        fcntl.flock(barrier, fcntl.LOCK_UN)
        os.close(barrier)


def observe_phase(protocol: str, phase: str, occurrence: int) -> None:
    record_observation("phase-reached", protocol, phase, occurrence, f"{protocol}:{phase}:{occurrence}")


def record_observation(kind: str, protocol: str, phase: str, occurrence: int, detail: str) -> None:
    _enum(kind, OBSERVATION_KINDS, "observation kind")
    if kind == "fault-fired" and phase == "":
        _enum(protocol, FAULTS, "fault observation name")
    elif kind == "fault-fired":
        _enum(protocol, PROTOCOLS, "fault observation protocol")
        _enum(phase, PHASES, "fault observation phase")
    else:
        _enum(protocol, PROTOCOLS, "observation protocol")
        _enum(phase, PHASES, "observation phase")
    _occurrence(occurrence)
    def mutate(connection: sqlite3.Connection, _state: dict) -> None:
        digest = hashlib.sha256(detail.encode("utf-8")).hexdigest()
        connection.execute("INSERT INTO observations(kind,protocol,phase,occurrence,detail_digest) VALUES(?,?,?,?,?)", (kind, protocol, phase, occurrence, digest))
    _run_transaction(mutate, replace_state=False)


def wait_for_phase(protocol: str, phase_name: str, occurrence: int, timeout_ms: int = 30000) -> dict:
    _enum(protocol, PROTOCOLS, "phase protocol")
    _enum(phase_name, PHASES, "phase name")
    _occurrence(occurrence)
    if not 0 <= timeout_ms <= 30000:
        raise ValueError("phase timeout must be between 0 and 30000 milliseconds")
    deadline = time.monotonic() + timeout_ms / 1000
    while time.monotonic() <= deadline:
        snapshot = read()
        for observation in snapshot["observations"]:
            if observation["kind"] == "phase-reached" and observation["protocol"] == protocol and observation["phase"] == phase_name and observation["occurrence"] == occurrence:
                return {"kind": observation["kind"], "protocol": protocol, "phase": phase_name, "occurrence": occurrence, "detail_digest": observation["detail_digest"]}
        time.sleep(0.05)
    raise TimeoutError("phase-reached observation was not observed before timeout")


def wait_for_phase_release(protocol: str, phase_name: str, occurrence: int, timeout_ms: int = 30000) -> dict:
    """Wait until a phase was reached and its transaction barrier unwound.

    A mutation phase can deliberately hold ``mail-state-transaction.lock``
    while the provider command is deciding whether to continue.  Observing
    the phase alone is not sufficient for a restart: the node could start
    while the fixture still owns that lock and resume the old command's
    write.  Require both the privacy-safe phase observation and a successful
    non-blocking lock claim before reporting the barrier released.
    """
    _enum(protocol, PROTOCOLS, "phase protocol")
    _enum(phase_name, PHASES, "phase name")
    _occurrence(occurrence)
    if not 0 <= timeout_ms <= 30000:
        raise ValueError("phase timeout must be between 0 and 30000 milliseconds")
    deadline = time.monotonic() + timeout_ms / 1000
    lock_path = ROOT / TRANSACTION_LOCK_NAME
    while time.monotonic() <= deadline:
        snapshot = read()
        observed = any(
            observation["kind"] == "phase-reached"
            and observation["protocol"] == protocol
            and observation["phase"] == phase_name
            and observation["occurrence"] == occurrence
            for observation in snapshot["observations"]
        )
        if observed:
            barrier = _open_lock(lock_path)
            try:
                try:
                    fcntl.flock(barrier, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    fcntl.flock(barrier, fcntl.LOCK_UN)
                    return {"operation": "wait-phase-release", "protocol": protocol, "phase": phase_name, "occurrence": occurrence}
            finally:
                os.close(barrier)
        time.sleep(0.05)
    raise TimeoutError("phase barrier was not released before timeout")


POSTCONDITION_FIELDS = {
    "checkpoint", "draft_count", "delivery_count", "sent_count", "envelope_sender", "envelope_recipients",
    "message_id", "canonical_digest", "bcc_header_absent", "correlated",
}
POSTCONDITION_CHECKPOINTS = ("draft-created", "draft-updated", "draft-deleted", "send-delivery")


def _postcondition_value(expected: dict, key: str, kind: type) -> object:
    value = expected.get(key)
    if type(value) is not kind:
        raise ValueError(f"postcondition {key} has an invalid type")
    return value


def assert_postcondition(expected: dict) -> dict:
    """Assert one closed, privacy-safe projection of the SQLite authority."""
    if not isinstance(expected, dict) or set(expected) - POSTCONDITION_FIELDS:
        raise ValueError("postcondition contains an unknown field")
    required = {"checkpoint", "draft_count", "delivery_count", "sent_count", "envelope_sender", "envelope_recipients", "message_id", "canonical_digest", "bcc_header_absent"}
    if set(expected) != required and set(expected) != required | {"correlated"}:
        raise ValueError("postcondition has an incomplete field set")
    checkpoint = _postcondition_value(expected, "checkpoint", str)
    if checkpoint not in POSTCONDITION_CHECKPOINTS:
        raise ValueError("postcondition checkpoint is outside the fixed allowlist")
    draft_count = _postcondition_value(expected, "draft_count", int)
    delivery_count = _postcondition_value(expected, "delivery_count", int)
    sent_count = _postcondition_value(expected, "sent_count", int)
    sender = _postcondition_value(expected, "envelope_sender", str)
    recipients = _postcondition_value(expected, "envelope_recipients", list)
    expected_id = _postcondition_value(expected, "message_id", str)
    expected_digest = _postcondition_value(expected, "canonical_digest", str)
    bcc_absent = _postcondition_value(expected, "bcc_header_absent", bool)
    if not 0 <= draft_count <= 1000 or not 0 <= delivery_count <= 1000 or not 0 <= sent_count <= 1000:
        raise ValueError("postcondition count is outside the fixed bound")
    if checkpoint == "send-delivery" and (not sender or any(not isinstance(item, str) or not item for item in [sender, *recipients])):
        raise ValueError("postcondition address is invalid")
    if any(any(ch in item for ch in "\r\n") for item in [sender, *recipients]):
        raise ValueError("postcondition address is invalid")
    if not re.fullmatch(r"<[^<>\s]+>", expected_id) or not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
        raise ValueError("postcondition identity or digest is invalid")
    snapshot = read()
    if checkpoint == "send-delivery" and len(snapshot["deliveries"]) != delivery_count:
        raise PostconditionMismatch("delivery-count")
    deliveries = [item for item in snapshot["deliveries"] if item["canonical_digest"] == expected_digest and item["message_id"] == expected_id]
    if checkpoint == "send-delivery" and len(deliveries) != delivery_count:
        raise PostconditionMismatch("delivery-identity")
    same_id_drafts = []
    for item in snapshot["messages"]:
        labels = {str(label).casefold() for label in item.get("labels", [])}
        if not labels.intersection({"draft", "drafts"}):
            continue
        try:
            item_id = message_id(item.get("raw", ""))
            if item_id == expected_id:
                same_id_drafts.append((item, canonical_digest(item.get("raw", ""))))
        except (UnicodeDecodeError, ValueError):
            continue
    if checkpoint in ("draft-created", "draft-updated"):
        # Create/update postconditions identify exactly one draft by both
        # immutable identity fields. Any stale same-ID row makes the result
        # ambiguous and must fail closed, even when a current row is present.
        drafts = [item for item, digest in same_id_drafts if digest == expected_digest]
        if len(same_id_drafts) != 1 or len(drafts) != 1:
            drafts = []
    else:
        # Delete remains deliberately stricter: any same-ID draft is evidence
        # that deletion did not fully remove the target.
        drafts = [item for item, _ in same_id_drafts]
    sent = []
    for item in snapshot["messages"]:
        labels = {str(label).casefold() for label in item.get("labels", [])}
        if "sent" not in labels:
            continue
        try:
            if canonical_digest(item.get("raw", "")) == expected_digest and message_id(item.get("raw", "")) == expected_id:
                sent.append(item)
        except (UnicodeDecodeError, ValueError):
            continue
    actual_bcc_absent = all(
        not re.search(rb"(?im)^bcc\s*:", canonical_source(item["message"]).split(b"\r\n\r\n", 1)[0])
        for item in deliveries
    )
    secure_delivery = len(deliveries) == 1 and deliveries[0]["tls_active"] and deliveries[0]["authenticated"]
    if checkpoint == "send-delivery" and not secure_delivery:
        raise PostconditionMismatch("delivery-security")
    actual = {
        "checkpoint": checkpoint,
        "draft_count": len(drafts),
        "delivery_count": len(deliveries),
        "sent_count": len(sent),
        "envelope_sender": deliveries[0]["envelope_sender"] if deliveries else "",
        "envelope_recipients": deliveries[0]["envelope_recipients"] if deliveries else [],
        "message_id": expected_id,
        "canonical_digest": expected_digest,
        "bcc_header_absent": actual_bcc_absent,
        "correlated": secure_delivery and len(sent) == 1 and actual_bcc_absent,
    }
    if actual["draft_count"] != draft_count:
        raise PostconditionMismatch("draft-state")
    if actual["delivery_count"] != delivery_count:
        raise PostconditionMismatch("delivery-identity")
    if actual["sent_count"] != sent_count:
        raise PostconditionMismatch("sent-state")
    if actual["envelope_sender"] != sender or actual["envelope_recipients"] != recipients:
        raise PostconditionMismatch("envelope")
    if actual["bcc_header_absent"] != bcc_absent:
        raise PostconditionMismatch("content-security")
    if "correlated" in expected and actual["correlated"] != expected["correlated"]:
        raise PostconditionMismatch("correlation")
    return {
        "checkpoint": checkpoint,
        "draft_count": actual["draft_count"],
        "delivery_count": actual["delivery_count"],
        "sent_count": actual["sent_count"],
        "envelope_sender_digest": hashlib.sha256(sender.encode()).hexdigest() if sender else "0" * 64,
        "envelope_recipient_digest": hashlib.sha256("\n".join(recipients).encode()).hexdigest() if recipients else "0" * 64,
        "message_id_digest": hashlib.sha256(expected_id.encode()).hexdigest(),
        "canonical_digest": expected_digest,
        "bcc_header_absent": actual["bcc_header_absent"],
        "correlated": actual["correlated"],
    }


def mode_paths() -> list[Path]:
    db, lock, state, deliveries = _paths()
    return [db, Path(str(db) + "-wal"), Path(str(db) + "-shm"), lock, ROOT / TRANSACTION_LOCK_NAME, state, deliveries, ROOT / CONTROL_NAME, ROOT / OBSERVATIONS_NAME]
