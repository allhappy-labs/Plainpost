#!/bin/sh
set -eu

acceptance_active_database_name() {
  reference=$1
  fallback=$2
  expected_root=${3:-}
  required=${4:-0}
  python3 - "$reference" "$fallback" "$expected_root" "$required" <<'PY'
import os
import stat
import sys

reference, fallback, expected_root, required = sys.argv[1:]
required = required == "required"
flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
try:
    if expected_root:
        if os.path.dirname(reference) != expected_root:
            raise OSError("reference root mismatch")
        root_fd = os.open(expected_root, os.O_RDONLY | os.O_DIRECTORY | flags, 0)
        try:
            fd = os.open(os.path.basename(reference), flags, dir_fd=root_fd)
        finally:
            os.close(root_fd)
    else:
        fd = os.open(reference, flags, 0)
except FileNotFoundError:
    if required:
        raise SystemExit(1)
    print(fallback)
    raise SystemExit(0)
except OSError:
    raise SystemExit(1)
try:
    metadata = os.fstat(fd)
    if stat.S_IFMT(metadata.st_mode) != stat.S_IFREG or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_uid != os.geteuid():
        raise SystemExit(1)
    raw = os.read(fd, 257)
    if len(raw) > 256:
        raise SystemExit(1)
    value = raw.decode("ascii")
finally:
    os.close(fd)
if value.count("\n") != 1 or not value.endswith("\n"):
    raise SystemExit(1)
value = value[:-1]
if value == "active":
    if required:
        raise SystemExit(1)
    print(fallback)
elif len(value) == 40 and value.startswith("restore_") and all(char in "0123456789abcdef" for char in value[8:]):
    print(value)
else:
    raise SystemExit(1)
PY
}
