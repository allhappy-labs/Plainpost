#!/bin/sh
set -eu

# Classify only private, mode-0600 fixture logs. The caller must never expose
# the source log: this function returns one fixed vocabulary item only.
acceptance_fixture_crash_category() {
  acceptance_fixture_crash_log=$1
  acceptance_fixture_crash_mode=$(stat -f '%Lp' "$acceptance_fixture_crash_log" 2>/dev/null || stat -c '%a' "$acceptance_fixture_crash_log" 2>/dev/null || printf 'unknown')
  [ "$acceptance_fixture_crash_mode" = 600 ] || {
    printf 'unknown\n'
    return 0
  }

  if grep -Eiq '(sqlite|database).*(busy|locked)|(busy|locked).*(sqlite|database)' "$acceptance_fixture_crash_log"; then
    printf 'sqlite-busy-locked\n'
  elif grep -Eiq '(sqlite|database).*(schema|no such table|malformed)|(schema|malformed).*(sqlite|database)|no such table|sqlite_schema' "$acceptance_fixture_crash_log"; then
    printf 'sqlite-schema\n'
  elif grep -Eiq '(^|[^[:alnum:]_])sqlite3\.OperationalError:' "$acceptance_fixture_crash_log"; then
    printf 'sqlite-operational\n'
  elif grep -Eiq 'address already in use|cannot assign requested address|(^|[^[:alpha:]])bind([^[:alpha:]]|$)' "$acceptance_fixture_crash_log"; then
    printf 'bind-address\n'
  elif grep -Eiq 'terminated by signal|(^|[^[:alpha:]])killed([^[:alpha:]]|$)|signal [0-9]+' "$acceptance_fixture_crash_log"; then
    printf 'signal\n'
  elif grep -Eiq '(^|[^[:alnum:]_])RuntimeError:' "$acceptance_fixture_crash_log"; then
    printf 'python-runtime-error\n'
  elif grep -Eiq '(^|[^[:alnum:]_])ValueError:' "$acceptance_fixture_crash_log"; then
    printf 'python-value-error\n'
  elif grep -Eiq '(^|[^[:alnum:]_])(FileNotFoundError|PermissionError|IsADirectoryError|NotADirectoryError|OSError):' "$acceptance_fixture_crash_log"; then
    printf 'python-os-error\n'
  elif grep -Eiq '(^|[^[:alnum:]_])ssl\.SSLError:|(^|[^[:alnum:]_])SSLError:' "$acceptance_fixture_crash_log"; then
    printf 'python-ssl-error\n'
  elif grep -Eiq 'traceback \(most recent call last\)|^[[:alnum:]_.]+(Error|Exception):' "$acceptance_fixture_crash_log"; then
    printf 'python-exception\n'
  else
    printf 'unknown\n'
  fi
}

# Return one fixed SQLite failure subcategory. The private source log is never
# emitted; callers receive only this closed vocabulary item.
acceptance_fixture_sqlite_subcategory() {
  acceptance_fixture_sqlite_log=$1
  acceptance_fixture_sqlite_mode=$(stat -f '%Lp' "$acceptance_fixture_sqlite_log" 2>/dev/null || stat -c '%a' "$acceptance_fixture_sqlite_log" 2>/dev/null || printf 'unknown')
  [ "$acceptance_fixture_sqlite_mode" = 600 ] || { printf 'none\n'; return 0; }
  grep -Eiq 'sqlite3\.(OperationalError|DatabaseError)|sqlite|database' "$acceptance_fixture_sqlite_log" || { printf 'none\n'; return 0; }
  if grep -Eiq 'database[^[:alpha:]]*(is )?locked|sqlite[^[:alpha:]]*locked|locked[^[:alpha:]]*(database|sqlite|table|schema)' "$acceptance_fixture_sqlite_log"; then
    printf 'locked\n'
  elif grep -Eiq 'unable to open database|cannot open database|unable to open' "$acceptance_fixture_sqlite_log"; then
    printf 'open\n'
  elif grep -Eiq 'disk[[:space:]]+I/O|disk[[:space:]]+io|I/O error' "$acceptance_fixture_sqlite_log"; then
    printf 'disk-io\n'
  elif grep -Eiq 'database disk image is malformed|malformed database|corrupt' "$acceptance_fixture_sqlite_log"; then
    printf 'corrupt\n'
  elif grep -Eiq 'readonly database|read-only database' "$acceptance_fixture_sqlite_log"; then
    printf 'readonly\n'
  elif grep -Eiq 'no such table|no such column|schema' "$acceptance_fixture_sqlite_log"; then
    printf 'schema\n'
  elif grep -Eiq 'sqlite3\.(OperationalError|DatabaseError|IntegrityError|ProgrammingError):' "$acceptance_fixture_sqlite_log"; then
    printf 'other\n'
  else
    printf 'none\n'
  fi
}

# Return one fixed operation/seam inferred from traceback source labels.
acceptance_fixture_sqlite_operation() {
  acceptance_fixture_sqlite_log=$1
  acceptance_fixture_sqlite_mode=$(stat -f '%Lp' "$acceptance_fixture_sqlite_log" 2>/dev/null || stat -c '%a' "$acceptance_fixture_sqlite_log" 2>/dev/null || printf 'unknown')
  [ "$acceptance_fixture_sqlite_mode" = 600 ] || { printf 'none\n'; return 0; }
  grep -Eiq 'sqlite3\.(OperationalError|DatabaseError|IntegrityError|ProgrammingError)|sqlite|database' "$acceptance_fixture_sqlite_log" || { printf 'none\n'; return 0; }
  if grep -Eiq 'PRAGMA journal_mode|_enable_wal' "$acceptance_fixture_sqlite_log"; then
    printf 'wal-open\n'
  elif grep -Eiq 'BEGIN IMMEDIATE|_run_transaction' "$acceptance_fixture_sqlite_log"; then
    printf 'transaction\n'
  elif grep -Eiq 'ALTER TABLE|schema migration' "$acceptance_fixture_sqlite_log"; then
    printf 'schema-migration\n'
  elif grep -Eiq 'CREATE TABLE|executescript' "$acceptance_fixture_sqlite_log"; then
    printf 'schema-create\n'
  elif grep -Eiq 'repair_projections|projection' "$acceptance_fixture_sqlite_log"; then
    printf 'projection-repair\n'
  elif grep -Eiq 'SELECT|_snapshot|read' "$acceptance_fixture_sqlite_log"; then
    printf 'read\n'
  else
    printf 'other\n'
  fi
}
