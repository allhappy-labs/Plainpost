"""Closed, private local fixture admission for named verification profiles.

Hashes bind admitted inputs; they do not authenticate a producer. These checks
coordinate cooperating local runners, not hostile same-UID path replacement.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat

SLOTS = {
    "recoveryPreparation": ("service", "PLAINPOST_RECOVERY_PREPARATION_FIXTURE"),
    "streamDiagnostics": ("service", "PLAINPOST_SYNC_NODE_STREAM_DIAGNOSTIC_LOG"),
    "browserSmoke": ("integration", "PLAINPOST_BROWSER_SMOKE_ROOT"),
}
MARKER = ".plainpost-fixture-use"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def closed(value, keys):
    require(type(value) is dict and set(value) == set(keys), "invalid fixture object fields")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate fixture JSON key")
        result[key] = value
    return result


def canonical(path):
    path = Path(path)
    require(path.is_absolute() and str(path) == str(path.resolve()), "fixture path must be absolute and canonical")
    for component in (path, *path.parents):
        require(not component.is_symlink(), "fixture symlink forbidden")
    return path


def identity(path, directory=False):
    value = path.lstat()
    require(value.st_uid == os.getuid(), "fixture must be owned by current user")
    require(stat.S_ISDIR(value.st_mode) if directory else stat.S_ISREG(value.st_mode), "invalid fixture file type")
    require(stat.S_IMODE(value.st_mode) == (0o700 if directory else 0o600), "fixture permissions must be private")
    if not directory:
        require(value.st_nlink == 1, "fixture hardlink forbidden")
    return {"device": value.st_dev, "inode": value.st_ino, "uid": value.st_uid, "mode": stat.S_IMODE(value.st_mode)}


def read_private(path, limit):
    path = canonical(path)
    before = identity(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        opened = os.fstat(fd)
        require((opened.st_dev, opened.st_ino) == (before["device"], before["inode"]), "fixture changed while opening")
        require(0 < opened.st_size <= limit, "fixture size out of bounds")
        with os.fdopen(fd, "rb", closefd=False) as file:
            data = file.read(limit + 1)
        require(0 < len(data) <= limit and len(data) == opened.st_size, "fixture changed while reading")
        require(identity(path) == before, "fixture changed while reading")
        return data, before
    finally:
        os.close(fd)


def json_private(path):
    data, file_identity = read_private(path, 65536)
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError):
        raise ValueError("invalid fixture JSON") from None
    return value, {"identity": file_identity, "sha256": hashlib.sha256(data).hexdigest()}


def leaf(value):
    require(type(value) is str and value not in ("", ".", "..", MARKER)
            and not any(c in value for c in "/\\") and all(ord(c) >= 32 and ord(c) != 127 for c in value),
            "fixture slot must use one relative leaf name")
    return value


def inspect(descriptor, profile, *, fresh=True):
    descriptor = canonical(descriptor)
    document, descriptor_identity = json_private(descriptor)
    closed(document, ("version", "profile", "root", "fixtures"))
    require(type(document["version"]) is int and document["version"] == 1, "unsupported fixture version")
    require(profile in ("service", "integration") and document["profile"] == profile, "fixture profile mismatch")
    require(type(document["root"]) is str, "invalid fixture root")
    root = canonical(document["root"])
    require(root not in (Path("/"), Path.home().resolve(), Path(__file__).resolve().parents[2]), "unsafe fixture root")
    root_identity = identity(root, directory=True)
    require(descriptor.parent == root, "descriptor must be inside fixture root")
    fixtures = document["fixtures"]
    require(type(fixtures) is dict and bool(fixtures) and set(fixtures) <= set(SLOTS), "unsupported fixture slots")
    mapping, slots, used = {}, {}, {descriptor.name, MARKER}
    for slot, value in fixtures.items():
        require(SLOTS[slot][0] == profile, "fixture slot not supported by profile")
        fields = {"recoveryPreparation": ("file", "sha256"), "streamDiagnostics": ("output",), "browserSmoke": ("coordinationRoot",)}[slot]
        closed(value, fields)
        name = leaf(value[fields[0]])
        require(name not in used, "fixture paths must be distinct")
        used.add(name)
        path = root / name
        canonical(path)
        detail = {"key": SLOTS[slot][1], "path": str(path)}
        if slot == "recoveryPreparation":
            require(type(value["sha256"]) is str and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]), "invalid fixture hash")
            data, file_identity = read_private(path, 16 * 1024 * 1024)
            digest = hashlib.sha256(data).hexdigest()
            require(digest == value["sha256"], "fixture input hash mismatch")
            detail.update(identity=file_identity, sha256=digest, bytes=len(data))
        elif slot == "streamDiagnostics":
            if fresh:
                require(not os.path.lexists(path), "diagnostic output must be fresh")
        else:
            detail["identity"] = identity(path, directory=True)
            if fresh:
                require(not any(path.iterdir()), "browser coordination root must initially be empty")
        mapping[SLOTS[slot][1]] = str(path)
        slots[slot] = detail
    admission = {"version": 1, "profile": profile, "descriptor": str(descriptor),
                 "descriptor_input": descriptor_identity, "root": str(root), "root_identity": root_identity, "slots": slots}
    return admission, mapping


def admit(descriptor, profile, record):
    admission, _ = inspect(descriptor, profile)
    fd = os.open(record, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump(admission, file, indent=2)
        file.write("\n")
    return admission


class Execution:
    def __init__(self, descriptor, record):
        self.descriptor = Path(descriptor)
        self.admission, self.record_identity = json_private(record)
        self.record = Path(record)
        require(type(self.admission) is dict and self.admission.get("profile") in ("service", "integration"), "invalid fixture admission")
        self.marker_identity = None
        self.output_identity = None
        self.environment = None

    def check(self, fresh):
        admission, environment = inspect(self.descriptor, self.admission["profile"], fresh=fresh)
        require(admission == self.admission, "fixture differs from admitted input")
        record, record_identity = json_private(self.record)
        require(record == self.admission and record_identity == self.record_identity, "fixture admission record changed")
        return environment

    def start(self):
        self.environment = self.check(fresh=True)
        self.marker = Path(self.admission["root"]) / MARKER
        fd = os.open(self.marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            self.marker_identity = identity(self.marker)
        finally:
            os.close(fd)
        try:
            self.check(fresh=True)
            slot = self.admission["slots"].get("streamDiagnostics")
            if slot:
                path = Path(slot["path"])
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                try:
                    self.output_identity = identity(path)
                finally:
                    os.close(fd)
            return self.environment
        except BaseException:
            self.release()
            raise

    def release(self):
        if self.marker_identity is not None:
            require(identity(self.marker) == self.marker_identity, "fixture ownership marker changed; retained")
            self.marker.unlink()
            self.marker_identity = None

    def finish(self):
        try:
            self.check(fresh=False)
            if self.output_identity is not None:
                path = Path(self.admission["slots"]["streamDiagnostics"]["path"])
                require(identity(path) == self.output_identity, "diagnostic output identity changed")
        finally:
            self.release()
