"""Authenticated, persistent IMAP/SMTP peer for the local Client API gate.

This is an acceptance-only provider peer. It owns the mailbox state on the
mounted temporary filesystem and exposes protocol effects to the production
Node provider runtime; it does not emit API/session evidence or accept state
from a caller.
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import json
import os
import quopri
import ssl
import sys
import re
from urllib.parse import unquote_to_bytes
from pathlib import Path

try:
    from . import plainpost_acceptance_mail_state as authority
except ImportError:  # direct execution from the fixture image
    import plainpost_acceptance_mail_state as authority


ROOT = Path(os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_ROOT", "/var/lib/plainpost"))
STATE = ROOT / "mailbox.json"
DELIVERIES = ROOT / "smtp-deliveries.jsonl"
USER = "acceptance@example.test"
PASSWORD = "acceptance-password"
SMTP_TLS_MODES = frozenset({"normal", "wrong-host", "untrusted-cert", "legacy-tls", "auth-before-starttls"})
IMAP_TLS_MODES = frozenset({"normal", "wrong-host", "untrusted-cert", "legacy-tls"})
_SMTP_TLS_CONTEXT: ssl.SSLContext | None = None
_IMAP_TLS_OBSERVATION_TASKS: dict[int, asyncio.Task[None]] = {}
_IMAP_TLS_OBSERVATION_LOCK: asyncio.Lock | None = None
_IMAP_TLS_OBSERVATION_LOCK_LOOP: asyncio.AbstractEventLoop | None = None


def _record_imap_tls_handshake(_ssl_object: ssl.SSLObject, _server_name: str | None, _context: ssl.SSLContext) -> None:
    """Queue a privacy-safe ClientHello checkpoint without blocking SNI."""
    loop = asyncio.get_running_loop()
    task = loop.create_task(_record_imap_tls_handshake_after_acceptance())
    key = id(_ssl_object)
    _IMAP_TLS_OBSERVATION_TASKS[key] = task

    def consume_failed_observation(completed: asyncio.Task[None]) -> None:
        # Failed handshakes have no accepted protocol handler to await this
        # task.  Retrieve the exception so asyncio does not emit an
        # unbounded "Task exception was never retrieved" warning; accepted
        # sessions still await the same task and surface its failure.
        try:
            completed.exception()
        except asyncio.CancelledError:
            pass

    task.add_done_callback(consume_failed_observation)

    def discard_expired() -> None:
        if _IMAP_TLS_OBSERVATION_TASKS.get(key) is task:
            _IMAP_TLS_OBSERVATION_TASKS.pop(key, None)

    loop.call_later(30, discard_expired)


async def _record_imap_tls_handshake_after_acceptance() -> None:
    """Persist the accepted TLS checkpoint without blocking the event loop."""
    global _IMAP_TLS_OBSERVATION_LOCK, _IMAP_TLS_OBSERVATION_LOCK_LOOP
    loop = asyncio.get_running_loop()
    if _IMAP_TLS_OBSERVATION_LOCK_LOOP is not loop:
        _IMAP_TLS_OBSERVATION_LOCK = asyncio.Lock()
        _IMAP_TLS_OBSERVATION_LOCK_LOOP = loop
    assert _IMAP_TLS_OBSERVATION_LOCK is not None
    async with _IMAP_TLS_OBSERVATION_LOCK:
        await asyncio.to_thread(
            authority.record_observation,
            "test-observation",
            "imap",
            "tls-handshake",
            1,
            "imap tls handshake",
        )


def smtp_tls_mode() -> str:
    """Return the closed startup mode selected for the SMTP fixture."""
    mode = os.environ.get("PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE", "normal")
    if mode not in SMTP_TLS_MODES:
        raise ValueError("unsupported acceptance SMTP TLS mode")
    return mode


def _configure_legacy_tls_ciphers(context: ssl.SSLContext) -> None:
    """Allow the fixture's TLS 1.1 endpoint on OpenSSL and LibreSSL."""
    try:
        context.set_ciphers("DEFAULT:@SECLEVEL=0")
    except ssl.SSLError:
        if "LibreSSL" not in ssl.OPENSSL_VERSION:
            raise
        # LibreSSL does not understand OpenSSL's security-level suffix. Its
        # DEFAULT policy still exposes the TLS 1.1 suites needed by this
        # fixture; the explicit TLS version bounds remain below.
        context.set_ciphers("DEFAULT")


def smtp_tls_context() -> ssl.SSLContext:
    """Build the server context for the selected acceptance-only TLS mode."""
    mode = smtp_tls_mode()
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    certificate_variable = "PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT"
    key_variable = "PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY"
    if mode == "wrong-host":
        certificate_variable = "PLAINPOST_ACCEPTANCE_SMTP_WRONG_HOST_TLS_CERT"
        key_variable = "PLAINPOST_ACCEPTANCE_SMTP_WRONG_HOST_TLS_KEY"
    elif mode == "untrusted-cert":
        certificate_variable = "PLAINPOST_ACCEPTANCE_SMTP_UNTRUSTED_TLS_CERT"
        key_variable = "PLAINPOST_ACCEPTANCE_SMTP_UNTRUSTED_TLS_KEY"
    context.load_cert_chain(os.environ[certificate_variable], os.environ[key_variable])
    if mode == "legacy-tls":
        # This fixture-only endpoint deliberately cannot negotiate the
        # production provider's TLS 1.2 minimum. OpenSSL 3 otherwise disables
        # all TLS 1.1 cipher suites before version negotiation can be tested.
        _configure_legacy_tls_ciphers(context)
        context.minimum_version = ssl.TLSVersion.TLSv1_1
        context.maximum_version = ssl.TLSVersion.TLSv1_1
    else:
        context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context


def imap_tls_mode() -> str:
    """Return the closed startup mode selected for the IMAP fixture."""
    mode = os.environ.get("PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE", "normal")
    if mode not in IMAP_TLS_MODES:
        raise ValueError("unsupported acceptance IMAP TLS mode")
    return mode


def imap_tls_context() -> ssl.SSLContext:
    """Build the server context for the selected acceptance-only TLS mode."""
    mode = imap_tls_mode()
    certificate_variable = "PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT"
    key_variable = "PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY"
    if mode == "wrong-host":
        certificate_variable = "PLAINPOST_ACCEPTANCE_IMAP_WRONG_HOST_TLS_CERT"
        key_variable = "PLAINPOST_ACCEPTANCE_IMAP_WRONG_HOST_TLS_KEY"
    elif mode == "untrusted-cert":
        certificate_variable = "PLAINPOST_ACCEPTANCE_IMAP_UNTRUSTED_TLS_CERT"
        key_variable = "PLAINPOST_ACCEPTANCE_IMAP_UNTRUSTED_TLS_KEY"
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain(os.environ[certificate_variable], os.environ[key_variable])
    if mode == "legacy-tls":
        _configure_legacy_tls_ciphers(context)
        context.minimum_version = ssl.TLSVersion.TLSv1_1
        context.maximum_version = ssl.TLSVersion.TLSv1_1
    else:
        context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_servername_callback(_record_imap_tls_handshake)
    return context


def imap_capabilities() -> bytes:
    capabilities = b"IMAP4rev1 UIDPLUS"
    if os.environ.get("PLAINPOST_ACCEPTANCE_IMAP_UIDEXPUNGE") == "1":
        capabilities += b" UIDEXPUNGE"
    else:
        capabilities += b" MOVE"
    if os.environ.get("PLAINPOST_ACCEPTANCE_IMAP_IDLE") == "1":
        capabilities += b" IDLE"
    return capabilities


def read_state() -> dict:
    authority.configure_root(STATE.parent)
    return authority.read()


def write_state(state: dict) -> None:
    authority.configure_root(STATE.parent)
    authority.replace(state)


def provider_transition() -> None:
    """Apply the deterministic provider-side transition used by the gate."""
    authority.configure_root(STATE.parent)
    attempted = os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_TRANSITION_ATTEMPT_FILE")
    if attempted:
        marker = Path(attempted)
        marker.write_text("attempted\n", encoding="ascii")
        os.chmod(marker, 0o600)
    authority.phase("provider", "transition")
    fault = authority.trigger_fault("provider-transition")
    if fault == "disconnect":
        raise ConnectionError("acceptance provider transition disconnected")
    if fault in {"temporary", "unavailable"}:
        raise RuntimeError(f"acceptance provider transition: {fault}")
    def mutate(state: dict) -> None:
        uid = int(state.get("nextUID", 1))
        state["nextUID"] = uid + 1
        state.setdefault("messages", []).append({
            "uid": uid,
            "flags": [],
            "labels": ["INBOX"],
            "raw": f"Message-ID: <provider-transition-{uid}@example.test>\r\nFrom: acceptance@example.test\r\nTo: recipient@example.test\r\nSubject: Provider transition é\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nProvider transition body\r\n",
        })
    authority.transaction(mutate)
    completed = os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_TRANSITION_COMPLETE_FILE")
    if completed:
        marker = Path(completed)
        marker.write_text("completed\n", encoding="ascii")
        os.chmod(marker, 0o600)


def parse_imap_arguments(argument: str) -> list[str]:
    """Parse the bounded atom/quoted-string arguments used by this fixture."""
    fields: list[str] = []
    index = 0
    while index < len(argument):
        while index < len(argument) and argument[index].isspace():
            index += 1
        if index == len(argument):
            break
        if argument[index] != '"':
            start = index
            while index < len(argument) and not argument[index].isspace():
                index += 1
            fields.append(argument[start:index])
            continue
        index += 1
        value: list[str] = []
        closed = False
        while index < len(argument):
            character = argument[index]
            index += 1
            if character == '"':
                closed = True
                break
            if character == "\\" and index < len(argument):
                character = argument[index]
                index += 1
            value.append(character)
        if not closed:
            return []
        fields.append("".join(value))
    return fields


def parse_append_request(argument: str) -> tuple[str, int] | None:
    """Return the destination and literal size from an APPEND argument."""
    marker = argument.rfind("{")
    if marker < 0 or not argument.endswith("}"):
        return None
    fields = parse_imap_arguments(argument[:marker].strip())
    if not fields:
        return None
    try:
        size = int(argument[marker + 1:-1])
    except ValueError:
        return None
    if size < 0:
        return None
    return fields[0], size


def selected_messages(state: dict, mailbox: str) -> list[dict]:
    wanted = mailbox.casefold()
    return [
        message for message in state.get("messages", [])
        if any(str(label).casefold() == wanted for label in message.get("labels", []))
    ]


def message_has_header(raw: str, name: str, value: str) -> bool:
    for line in raw.replace("\r\n", "\n").split("\n"):
        header, separator, candidate = line.partition(":")
        if separator and header.casefold() == name.casefold() and candidate.strip() == value:
            return True
    return False


def search_message_uids(state: dict, mailbox: str, argument: str) -> list[int]:
    """Implement the bounded SEARCH forms used by the production adapter."""
    fields = parse_imap_arguments(argument)
    messages = selected_messages(state, mailbox)
    if not fields or fields[0].upper() == "ALL":
        return [int(message["uid"]) for message in messages]
    if len(fields) == 3 and fields[0].upper() == "HEADER" and fields[1].upper() == "MESSAGE-ID":
        return [
            int(message["uid"])
            for message in messages
            if message_has_header(str(message.get("raw", "")), "Message-ID", fields[2])
        ]
    return []


def authenticated(fields: list[str]) -> bool:
    return len(fields) == 2 and fields[0] == USER and fields[1] == PASSWORD


def smtp_authenticated(argument: str) -> bool:
    fields = argument.split()
    if len(fields) != 3 or fields[0].upper() != "AUTH" or fields[1].upper() != "PLAIN":
        return False
    try:
        decoded = base64.b64decode(fields[2], validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return False
    credentials = decoded.split("\x00")
    return len(credentials) == 3 and credentials[1] == USER and credentials[2] == PASSWORD


def message_for(state: dict, uid: int) -> dict | None:
    return next((message for message in state["messages"] if message["uid"] == uid), None)


def move_message(state: dict, source: str, destination: str, uid: int) -> bool:
    """Apply IMAP MOVE semantics to one message in the selected mailbox."""
    message = message_for(state, uid)
    if message is None:
        return False
    source_key = source.casefold()
    destination_key = destination.casefold()
    labels = [label for label in message.get("labels", []) if str(label).casefold() != source_key]
    if not any(str(label).casefold() == destination_key for label in labels):
        labels.append(destination)
    message["labels"] = labels
    return True


def message_sections(raw: str) -> tuple[str, str]:
    headers, separator, body = raw.partition("\r\n\r\n")
    if not separator:
        headers, separator, body = raw.partition("\n\n")
    if not separator:
        return raw, ""
    return headers + "\r\n\r\n", body


def _header_value(headers: str, name: str) -> str:
    wanted = name.casefold()
    for line in headers.replace("\r\n", "\n").split("\n"):
        key, separator, value = line.partition(":")
        if separator and key.casefold() == wanted:
            return value.strip()
    return ""


def _mime_parameters(value: str) -> list[tuple[str, str]]:
    """Parse the bounded semicolon parameters used by the acceptance MIME."""
    result: list[tuple[str, str]] = []
    for item in value.split(";"):
        key, separator, parameter = item.partition("=")
        if not separator or not key.strip():
            continue
        parameter = parameter.strip()
        if len(parameter) >= 2 and parameter[0] == '"' and parameter[-1] == '"':
            parameter = parameter[1:-1].replace('\\"', '"').replace('\\\\', '\\')
        result.append((key.strip().upper(), parameter))
    return result


def _bodystructure_parameters(value: str) -> str:
    parameters = _mime_parameters(value)
    if not parameters:
        return "NIL"
    encoded = []
    seen: set[str] = set()
    for key, parameter in parameters:
        normalized_key = key[:-1] if key.endswith("*") else key
        if normalized_key in seen:
            continue
        seen.add(normalized_key)
        encoded.append(f'"{normalized_key}" {_imap_quote(_mime_parameter(value, normalized_key) or parameter)}')
    return "(" + " ".join(encoded) + ")"


def _imap_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _mime_parameter(value: str, wanted: str) -> str:
    wanted = wanted.upper()
    for key, parameter in _mime_parameters(value):
        if key == wanted:
            return parameter
        if key == wanted + "*":
            charset, separator, encoded = parameter.partition("'")
            if separator:
                _, separator, encoded = encoded.partition("'")
            if separator:
                try:
                    return unquote_to_bytes(encoded).decode(charset or "utf-8")
                except (LookupError, UnicodeDecodeError):
                    return unquote_to_bytes(encoded).decode("utf-8", "replace")
            return parameter
    return ""


def _multipart_parts(raw: str) -> list[tuple[str, str]]:
    headers, body = message_sections(raw)
    content_type = _header_value(headers, "Content-Type")
    match = re.search(r"boundary=\"?([^\";]+)", content_type, flags=re.IGNORECASE)
    if not match:
        return []
    delimiter = "--" + match.group(1)
    parts: list[tuple[str, str]] = []
    for chunk in body.split(delimiter)[1:]:
        if chunk.startswith("--"):
            break
        chunk = chunk.lstrip("\r\n")
        part_headers, separator, part_body = chunk.partition("\r\n\r\n")
        if not separator:
            part_headers, separator, part_body = chunk.partition("\n\n")
        if separator:
            parts.append((part_headers, part_body.rstrip("\r\n")))
    return parts


def multipart_part_body(raw: str, path: str) -> str:
    """Return the encoded body for a bounded multipart leaf path."""
    if not path or any(not value.isdigit() or int(value) < 1 for value in path.split(".")):
        return ""
    current = raw
    values = path.split(".")
    for value in values:
        parts = _multipart_parts(current)
        index = int(value) - 1
        if index >= len(parts):
            return ""
        headers, body = parts[index]
        current = headers + "\r\n\r\n" + body
    return message_sections(current)[1].rstrip("\r\n")


def _bodystructure_part(headers: str, body: str) -> str:
    """Render one MIME entity using the IMAP BODYSTRUCTURE grammar."""
    content_type = _header_value(headers, "Content-Type") or "text/plain; charset=utf-8"
    media_type, _, parameters = content_type.partition(";")
    media = media_type.strip().split("/", 1)
    if len(media) != 2:
        media = ["text", "plain"]
    if media[0].casefold() == "multipart":
        children = _multipart_parts(headers + "\r\n\r\n" + body)
        if not children:
            return ""
        nested = [_bodystructure_part(child_headers, child_body) for child_headers, child_body in children]
        if any(not child for child in nested):
            return ""
        boundary_parameters = _bodystructure_parameters(parameters)
        return f'({" ".join(nested)} "{media[1].upper()}" {boundary_parameters} NIL NIL)'

    transfer = (_header_value(headers, "Content-Transfer-Encoding") or "8BIT").upper()
    if transfer == "BASE64":
        try:
            decoded_size = len(base64.b64decode(body, validate=True))
        except (ValueError, binascii.Error):
            # Keep malformed attachment metadata observable so the production
            # lazy FetchPart boundary, rather than BODYSTRUCTURE generation,
            # owns the protocol rejection.
            decoded_size = 0
    elif transfer == "QUOTED-PRINTABLE":
        decoded_size = len(quopri.decodestring(body.encode("utf-8")))
    else:
        decoded_size = len(body.encode("utf-8"))
    name = _mime_parameter(parameters, "name")
    part_parameters = _bodystructure_parameters(parameters)
    disposition = "NIL"
    disposition_header = _header_value(headers, "Content-Disposition")
    disposition_value = disposition_header.partition(";")[0].strip().upper()
    if disposition_value in {"ATTACHMENT", "INLINE"}:
        filename = _mime_parameter(disposition_header, "filename") or name
        disposition_parameters = "NIL" if not filename else f'("FILENAME" {_imap_quote(filename)})'
        disposition = f'("{disposition_value}" {disposition_parameters})'
    content_id = _header_value(headers, "Content-ID")
    content_id_value = "NIL" if not content_id else _imap_quote(content_id)
    if media[0].casefold() == "text":
        return f'("{media[0].upper()}" "{media[1].upper()}" {part_parameters} {content_id_value} NIL "{transfer}" {decoded_size} 1 NIL {disposition} NIL NIL)'
    return f'("{media[0].upper()}" "{media[1].upper()}" {part_parameters} {content_id_value} NIL "{transfer}" {decoded_size} NIL {disposition} NIL NIL)'


def fetch_body_payload(raw: str, path: str) -> str:
    """Return the exact payload for BODY.PEEK[<section>]."""
    if path == "":
        return raw
    if _multipart_parts(raw):
        return multipart_part_body(raw, path)
    return message_sections(raw)[1]


def bodystructure_for(raw: str) -> str:
    if _multipart_parts(raw):
        structure = _bodystructure_part(*message_sections(raw))
        if structure:
            return structure
    _, body = message_sections(raw)
    return f'("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "8BIT" {len(body.encode("utf-8"))} 1 NIL NIL NIL)'


def _imap_attachment_path(raw: str, path: str) -> bool:
    """Classify one bounded MIME leaf without decoding its transfer bytes."""
    if not path or not _multipart_parts(raw):
        return False
    current = raw
    for value in path.split("."):
        parts = _multipart_parts(current)
        index = int(value) - 1 if value.isdigit() else -1
        if index < 0 or index >= len(parts):
            return False
        headers, body = parts[index]
        current = headers + "\r\n\r\n" + body
    headers, _ = message_sections(current)
    disposition = _header_value(headers, "Content-Disposition").lower()
    content_type = _header_value(headers, "Content-Type").lower()
    media_type = content_type.partition(";")[0].strip()
    disposition_parameters = _mime_parameters(disposition.partition(";")[2])
    content_type_parameters = _mime_parameters(content_type.partition(";")[2])
    filename_present = any(key in {"FILENAME", "FILENAME*"} and value for key, value in disposition_parameters)
    name_present = any(key in {"NAME", "NAME*"} and value for key, value in content_type_parameters)
    content_id_present = bool(_header_value(headers, "Content-ID"))
    return disposition.startswith("attachment") or filename_present or name_present or content_id_present or media_type == "message/rfc822"


def _imap_fault(protocol_phase: str, fault_name: str) -> str | None:
    """Publish one typed IMAP phase, then consume its one-shot fault."""
    authority.phase("imap", protocol_phase)
    return authority.trigger_fault(fault_name)


async def write_literal_fetch(
    writer: asyncio.StreamWriter,
    tag: str,
    uid: int,
    path: str,
    payload: bytes,
    phase_name: str,
    fault_name: str,
) -> None:
    """Frame a literal, then barrier before its bytes become readable."""
    truncated_fault = authority.claim_fault("imap-truncated-literal") if fault_name == "imap-attachment-fetch" else None
    declared_size = len(payload) + 1 if truncated_fault == "truncated" else len(payload)
    writer.write(f"* {uid} FETCH (BODY[{path}] {{{declared_size}}}\r\n".encode("ascii"))
    await writer.drain()
    fault = _imap_fault(phase_name, fault_name)
    if fault == "disconnect":
        writer.close()
        await writer.wait_closed()
        return
    if truncated_fault == "truncated":
        writer.write(payload)
        await writer.drain()
        writer.close()
        await writer.wait_closed()
        return
    writer.write(payload)
    writer.write(f")\r\n{tag} OK UID FETCH\r\n".encode("ascii"))
    await writer.drain()


async def imap(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    """Serve one IMAP peer and tolerate disposable probe disconnects."""
    try:
        await _imap_session(reader, writer)
    except (ConnectionResetError, BrokenPipeError, ConnectionError, ssl.SSLError):
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionResetError, BrokenPipeError, ConnectionError, ssl.SSLError):
            pass


async def _imap_session(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    ssl_object = writer.get_extra_info("ssl_object")
    if ssl_object is not None:
        observation = _IMAP_TLS_OBSERVATION_TASKS.pop(id(ssl_object), None)
        if observation is None:
            await _record_imap_tls_handshake_after_acceptance()
        else:
            await observation
    writer.write(b"* OK Plainpost acceptance IMAP4rev1\r\n")
    await writer.drain()
    logged_in = False
    selected = "INBOX"
    while line := await reader.readline():
        fields = line.decode("utf-8", "replace").strip().split(" ", 2)
        if len(fields) < 2:
            continue
        tag, command = fields[0], fields[1].upper()
        argument = fields[2] if len(fields) == 3 else ""
        if command == "CAPABILITY":
            writer.write(b"* CAPABILITY " + imap_capabilities() + f"\r\n{tag} OK CAPABILITY\r\n".encode())
        elif command == "LOGIN":
            authority.configure_root(STATE.parent)
            authority.phase("imap", "authentication")
            auth_fault = authority.trigger_fault("imap-authentication")
            if auth_fault == "disconnect":
                writer.close()
                await writer.wait_closed()
                return
            logged_in = authenticated(parse_imap_arguments(argument)) and auth_fault != "rejected"
            writer.write(f"{tag} {'OK LOGIN' if logged_in else 'NO AUTHENTICATIONFAILED'}\r\n".encode())
        elif not logged_in:
            writer.write(f"{tag} NO AUTHENTICATIONREQUIRED\r\n".encode())
        elif command == "LIST":
            if _imap_fault("catalog", "imap-catalog") == "disconnect":
                writer.close()
                await writer.wait_closed()
                return
            writer.write(
                b'* LIST (\\Inbox) "/" "INBOX"\r\n'
                b'* LIST (\\Sent) "/" "Sent"\r\n'
                b'* LIST (\\Drafts) "/" "Drafts"\r\n'
                b'* LIST (\\Trash) "/" "Trash"\r\n'
                b'* LIST (\\Archive) "/" "Archive"\r\n'
                b'* LIST (\\All) "/" "All"\r\n'
                + f"{tag} OK LIST\r\n".encode()
            )
        elif command == "SELECT":
            selected = argument.strip('"') or "INBOX"
            state = read_state()
            writer.write(f"* {len(selected_messages(state, selected))} EXISTS\r\n* OK [UIDVALIDITY {state['uidValidity']}] SELECT\r\n{tag} OK SELECT\r\n".encode())
        elif command == "STATUS":
            status_fields = parse_imap_arguments(argument)
            mailbox = status_fields[0] if status_fields else selected
            state = read_state()
            writer.write(f'* STATUS "{mailbox}" (UIDNEXT {state["nextUID"]} MESSAGES {len(selected_messages(state, mailbox))})\r\n{tag} OK STATUS\r\n'.encode())
        elif command == "IDLE" and os.environ.get("PLAINPOST_ACCEPTANCE_IMAP_IDLE") == "1":
            authority.configure_root(STATE.parent)
            wait_for_change = os.environ.get("PLAINPOST_ACCEPTANCE_IMAP_WAIT_FOR_IDLE_CHANGE") == "1"
            idle_target = os.environ.get("PLAINPOST_ACCEPTANCE_IMAP_IDLE_TARGET", "").strip()
            if idle_target and idle_target.casefold() not in {mailbox.casefold() for mailbox in authority.MAILBOXES}:
                raise ValueError("IMAP IDLE target is outside the fixed mailbox allowlist")
            idle_target_non_target = bool(idle_target and selected.casefold() != idle_target.casefold())
            if idle_target_non_target:
                # The acceptance mid-page probe needs one deterministic active
                # INBOX lease. Non-target workers must complete their IDLE
                # round immediately so the owner reaches that target without
                # changing the normal six-mailbox scheduling behavior.
                wait_for_change = False
            tracks_inbox_lease = wait_for_change and selected.casefold() == "inbox"
            if wait_for_change:
                baseline = read_state()
                baseline_key = (baseline["uidValidity"], baseline["nextUID"], tuple(item["uid"] for item in baseline["messages"]))
                def mark_idle_active(state: dict) -> None:
                    state["imap_idle_active_count"] = int(state.get("imap_idle_active_count", 0)) + 1
                    if tracks_inbox_lease:
                        state["imap_idle_active_inbox_count"] = int(state.get("imap_idle_active_inbox_count", 0)) + 1

                authority.transaction(mark_idle_active)
            try:
                writer.write(b"+ idling\r\n")
                await writer.drain()
                if idle_target_non_target:
                    writer.write(f"{tag} OK IDLE\r\n".encode())
                    await writer.drain()
                    continue
                authority.phase("imap", "idle")
                if wait_for_change:
                    for _ in range(600):
                        current = read_state()
                        current_key = (current["uidValidity"], current["nextUID"], tuple(item["uid"] for item in current["messages"]))
                        if current_key != baseline_key:
                            break
                        await asyncio.sleep(0.05)
                    else:
                        writer.close()
                        await writer.wait_closed()
                        return
                exists_count = len(selected_messages(read_state(), selected))
                if not wait_for_change:
                    # Compatibility for the older provider probe, which only
                    # observes the unsolicited wakeup and supplies no mutation.
                    exists_count += 1
                writer.write(f"* {exists_count} EXISTS\r\n".encode())
                await writer.drain()
                await reader.readline()
                writer.write(f"{tag} OK IDLE\r\n".encode())
            finally:
                if wait_for_change:
                    def mark_idle_inactive(state: dict) -> None:
                        state["imap_idle_active_count"] = max(0, int(state.get("imap_idle_active_count", 0)) - 1)
                        if tracks_inbox_lease:
                            state["imap_idle_active_inbox_count"] = max(0, int(state.get("imap_idle_active_inbox_count", 0)) - 1)

                    authority.transaction(mark_idle_inactive)
        elif command == "UID" and argument:
            operation, _, rest = argument.partition(" ")
            operation = operation.upper()
            if operation == "SEARCH":
                state = read_state()
                uids = " ".join(str(uid) for uid in search_message_uids(state, selected, rest))
                writer.write(f"* SEARCH {uids}\r\n{tag} OK UID SEARCH\r\n".encode())
            elif operation == "FETCH":
                uid_text, _, items = rest.partition(" ")
                state = read_state()
                message = message_for(state, int(uid_text)) if uid_text.isdigit() else None
                if message:
                    raw = message["raw"]
                    upper_items = items.upper()
                    if "BODYSTRUCTURE" in upper_items:
                        structure = bodystructure_for(raw)
                        writer.write(f"* {message['uid']} FETCH (UID {message['uid']} FLAGS ({' '.join(message.get('flags', []))}) INTERNALDATE \"10-Aug-2026 12:34:56 +0000\" BODYSTRUCTURE {structure})\r\n{tag} OK UID FETCH\r\n".encode())
                    elif "BODY.PEEK[HEADER]" in upper_items:
                        headers, _ = message_sections(raw)
                        await write_literal_fetch(writer, tag, message["uid"], "HEADER", headers.encode("utf-8"), "header-fetch", "imap-header-fetch")
                        if writer.is_closing():
                            return
                    elif "BODY.PEEK[" in upper_items:
                        path = upper_items.split("BODY.PEEK[", 1)[1].split("]", 1)[0]
                        phase_name = "attachment-fetch" if _imap_attachment_path(raw, path) else "body-fetch"
                        fault_name = "imap-attachment-fetch" if phase_name == "attachment-fetch" else "imap-body-fetch"
                        body = fetch_body_payload(raw, path)
                        await write_literal_fetch(writer, tag, message["uid"], path, body.encode("utf-8"), phase_name, fault_name)
                        if writer.is_closing():
                            return
                    else:
                        writer.write(f"{tag} BAD unsupported FETCH\r\n".encode())
                else:
                    writer.write(f"{tag} NO missing message\r\n".encode())
            elif operation in {"COPY", "STORE", "MOVE", "EXPUNGE"}:
                authority.configure_root(STATE.parent)
                if os.environ.get("PLAINPOST_ACCEPTANCE_IMAP_MUTATION_PHASE") == "1":
                    authority.phase("imap", "mutation")
                uid_text, _, rest = rest.partition(" ")
                state = read_state()
                message = message_for(state, int(uid_text)) if uid_text.isdigit() else None
                if message and operation == "COPY":
                    destination = rest.strip().strip('"')
                    def copy(current: dict) -> None:
                        source = message_for(current, int(uid_text))
                        if source is None:
                            return
                        copied = dict(source)
                        copied["uid"] = int(current["nextUID"])
                        copied["labels"] = [destination]
                        current["nextUID"] = copied["uid"] + 1
                        current.setdefault("messages", []).append(copied)
                    authority.configure_root(STATE.parent)
                    authority.transaction(copy)
                elif operation == "EXPUNGE":
                    if message:
                        authority.configure_root(STATE.parent)
                        authority.transaction(lambda current: current.update(messages=[candidate for candidate in current.get("messages", []) if candidate.get("uid") != int(uid_text)]))
                elif message and operation == "STORE":
                    def store(current: dict) -> None:
                        target = message_for(current, int(uid_text))
                        if target is None:
                            return
                        if "+FLAGS" in rest.upper():
                            for flag in ("\\Seen", "\\Answered", "\\Flagged", "\\Draft", "\\Deleted"):
                                if flag in rest and flag not in target.setdefault("flags", []):
                                    target["flags"].append(flag)
                        elif "-FLAGS" in rest.upper():
                            target["flags"] = [flag for flag in target.get("flags", []) if flag not in rest]
                    authority.configure_root(STATE.parent)
                    authority.transaction(store)
                elif message and operation == "MOVE":
                    destination = rest.split()[-1].strip('"')
                    authority.configure_root(STATE.parent)
                    authority.transaction(lambda current: move_message(current, selected, destination, int(uid_text)))
                writer.write(f"{tag} OK UID {operation}\r\n".encode())
            else:
                writer.write(f"{tag} BAD unsupported UID operation\r\n".encode())
        elif command == "APPEND":
            request = parse_append_request(argument)
            if request is None:
                writer.write(f"{tag} BAD malformed APPEND literal\r\n".encode())
                await writer.drain()
                continue
            destination, size = request
            writer.write(b"+ Ready for literal\r\n")
            await writer.drain()
            try:
                payload = await reader.readexactly(size)
                terminator = await reader.readexactly(2)
            except asyncio.IncompleteReadError:
                writer.write(f"{tag} BAD incomplete APPEND literal\r\n".encode())
                await writer.drain()
                break
            if terminator != b"\r\n":
                writer.write(f"{tag} BAD malformed APPEND terminator\r\n".encode())
                await writer.drain()
                continue
            authority.configure_root(STATE.parent)
            if destination.casefold() == "sent":
                authority.phase("imap", "sent-append")
            authority.phase("imap", "append")
            fault_name = "imap-sent-append" if destination.casefold() == "sent" else "imap-mutation"
            fault = authority.trigger_fault(fault_name)
            if fault == "disconnect":
                raise ConnectionError("acceptance IMAP APPEND disconnected")
            if fault in {"temporary", "unavailable"}:
                writer.write(f"{tag} NO {fault.upper()} APPEND\r\n".encode())
                await writer.drain()
                continue
            assigned: list[int] = []
            def append(current: dict) -> None:
                uid = int(current["nextUID"])
                current["nextUID"] = uid + 1
                current["messages"].append({"uid": uid, "flags": [], "labels": [destination], "raw": payload.decode("utf-8", "replace")})
                assigned.append(uid)
            committed = authority.transaction(append)
            uid = assigned[0]
            writer.write(f"{tag} OK [APPENDUID {committed['uidValidity']} {uid}] APPEND\r\n".encode())
        elif command in {"NOOP", "CHECK", "CLOSE", "LOGOUT"}:
            writer.write(f"{tag} OK {command}\r\n".encode())
            if command == "LOGOUT":
                break
        else:
            writer.write(f"{tag} BAD unsupported command\r\n".encode())
        await writer.drain()
    writer.close()
    await writer.wait_closed()


async def smtp(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    """Serve one SMTP peer and tolerate disposable probe disconnects."""
    try:
        await _smtp_session(reader, writer)
    except (ConnectionResetError, BrokenPipeError, ConnectionError, ssl.SSLError):
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionResetError, BrokenPipeError, ConnectionError, ssl.SSLError):
            pass


async def _smtp_session(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    writer.write(b"220 Plainpost acceptance SMTP\r\n")
    await writer.drain()
    tls_active = False
    authenticated_smtp = False
    envelope_sender = ""
    envelope_recipients: list[str] = []
    data: list[bytes] = []
    while line := await reader.readline():
        text = line.decode("utf-8", "replace").rstrip("\r\n")
        upper = text.upper()
        if upper.startswith("EHLO") or upper.startswith("HELO"):
            if tls_active:
                writer.write(b"250-Plainpost\r\n250 AUTH PLAIN\r\n")
            elif smtp_tls_mode() == "auth-before-starttls":
                # Deliberately advertise credentials before TLS without
                # advertising STARTTLS. The production client must fail
                # closed without emitting an AUTH command.
                writer.write(b"250-Plainpost\r\n250 AUTH PLAIN\r\n")
            else:
                writer.write(b"250-Plainpost\r\n250-STARTTLS\r\n250 AUTH PLAIN\r\n")
        elif upper.startswith("AUTH PLAIN"):
            authority.configure_root(DELIVERIES.parent)
            authority.phase("smtp", "authentication-command")
            if not tls_active:
                authenticated_smtp = False
                writer.write(b"530 5.7.0 Must issue STARTTLS first\r\n")
            else:
                authority.configure_root(DELIVERIES.parent)
                authority.phase("smtp", "authentication")
                authenticated_smtp = smtp_authenticated(text)
                fault = authority.trigger_fault("smtp-authentication")
                if fault == "disconnect":
                    raise ConnectionError("acceptance SMTP authentication disconnected")
                if fault in {"rejected", "temporary", "unavailable"}:
                    authenticated_smtp = False
                writer.write(b"235 2.7.0 Authentication successful\r\n" if authenticated_smtp else b"535 5.7.8 Authentication failed\r\n")
        elif upper == "STARTTLS":
            if tls_active or authenticated_smtp:
                writer.write(b"503 5.5.1 Bad sequence of commands\r\n")
                await writer.drain()
                continue
            if smtp_tls_mode() == "auth-before-starttls":
                writer.write(b"502 5.5.1 STARTTLS unavailable\r\n")
                await writer.drain()
                continue
            writer.write(b"220 2.0.0 Ready to start TLS\r\n")
            await writer.drain()
            context = _SMTP_TLS_CONTEXT or smtp_tls_context()
            # Upgrade the existing StreamReaderProtocol in place. Creating a
            # second protocol leaves the handler reading from the old clear
            # text stream while the client speaks TLS, which manifests as a
            # reset during the first post-STARTTLS command. SMTP also requires
            # the client to issue EHLO again after the TLS handshake; there is
            # no server response between the handshake and that EHLO.
            writer = await upgrade_smtp_tls(reader, writer, context)
            tls_active = True
            authenticated_smtp = False
            envelope_sender = ""
            envelope_recipients = []
            data = []
        elif upper.startswith("MAIL FROM"):
            if not tls_active or not authenticated_smtp:
                writer.write(b"530 5.7.0 STARTTLS and authentication required\r\n")
            else:
                match = re.match(r"(?i)^MAIL FROM:\s*<([^<>\r\n]+)>", text)
                if match is None:
                    writer.write(b"501 5.1.7 Bad sender address syntax\r\n")
                else:
                    envelope_sender = match.group(1)
                    envelope_recipients = []
                    writer.write(b"250 2.1.0 OK\r\n")
        elif upper.startswith("RCPT TO"):
            if not tls_active or not authenticated_smtp:
                writer.write(b"530 5.7.0 STARTTLS and authentication required\r\n")
            elif not envelope_sender:
                writer.write(b"503 5.5.1 Need MAIL FROM first\r\n")
            else:
                match = re.match(r"(?i)^RCPT TO:\s*<([^<>\r\n]+)>", text)
                if match is None:
                    writer.write(b"501 5.1.3 Bad recipient address syntax\r\n")
                else:
                    authority.configure_root(DELIVERIES.parent)
                    authority.phase("smtp", "recipient")
                    recipient = match.group(1)
                    fault_451 = authority.trigger_fault("smtp-recipient-451")
                    fault_550 = authority.trigger_fault("smtp-recipient-550")
                    fault = fault_451 or fault_550
                    if fault == "disconnect":
                        raise ConnectionError("acceptance SMTP recipient disconnected")
                    if fault_451 is not None:
                        writer.write(b"451 4.3.0 Recipient temporarily rejected\r\n")
                    elif fault_550 is not None:
                        writer.write(b"550 5.1.1 Recipient rejected\r\n")
                    else:
                        envelope_recipients.append(recipient)
                        writer.write(b"250 2.1.0 OK\r\n")
        elif upper == "DATA":
            if not tls_active or not authenticated_smtp:
                writer.write(b"530 5.7.0 STARTTLS and authentication required\r\n")
            elif not envelope_sender or not envelope_recipients:
                writer.write(b"503 5.5.1 Need RCPT TO first\r\n")
            else:
                data = []
                authority.configure_root(DELIVERIES.parent)
                authority.phase("smtp", "before-data")
                writer.write(b"354 End data with <CRLF>.<CRLF>\r\n")
                await writer.drain()
                after_354 = authority.trigger_fault("smtp-after-354")
                if after_354 == "disconnect":
                    raise ConnectionError("acceptance SMTP disconnected after 354")
                while line := await reader.readline():
                    if line == b".\r\n" or line == b".\n":
                        authority.configure_root(DELIVERIES.parent)
                        authority.configure_delivery_path(DELIVERIES)
                        authority.phase("smtp", "delivery")
                        final_fault = authority.trigger_fault("smtp-final-reply")
                        legacy_fault = None if final_fault is not None else authority.trigger_fault("smtp-delivery")
                        fault = final_fault or legacy_fault
                        if final_fault == "disconnect":
                            authority.record_delivery(
                                b"".join(data), tls_active=tls_active,
                                authenticated=authenticated_smtp,
                                envelope_sender=envelope_sender,
                                envelope_recipients=envelope_recipients,
                            )
                            authority.phase("smtp", "acceptance-before-append")
                            raise ConnectionError("acceptance SMTP disconnected before final reply")
                        if fault in {"temporary", "unavailable"}:
                            writer.write(f"451 4.3.0 {fault}\r\n".encode())
                        elif fault == "rejected":
                            writer.write(b"550 5.7.0 Message rejected\r\n")
                        elif fault == "disconnect":
                            raise ConnectionError("acceptance SMTP delivery disconnected")
                        else:
                            authority.record_delivery(
                                b"".join(data), tls_active=tls_active,
                                authenticated=authenticated_smtp,
                                envelope_sender=envelope_sender,
                                envelope_recipients=envelope_recipients,
                            )
                            authority.phase("smtp", "acceptance-before-append")
                            writer.write(b"250 2.0.0 accepted\r\n")
                        envelope_sender = ""
                        envelope_recipients = []
                        data = []
                        break
                    if not data:
                        authority.configure_root(DELIVERIES.parent)
                        authority.phase("smtp", "data")
                        mid_data = authority.trigger_fault("smtp-mid-data")
                        if mid_data == "disconnect":
                            raise ConnectionError("acceptance SMTP disconnected during DATA")
                    # SMTP dot transparency removes exactly one leading dot;
                    # all source line endings remain byte-for-byte intact.
                    data.append(line[1:] if line.startswith(b"..") else line)
        elif upper == "QUIT":
            if tls_active and authenticated_smtp:
                authority.configure_root(DELIVERIES.parent)
                authority.phase("smtp", "quit")
                if authority.trigger_fault("smtp-quit-loss") == "disconnect":
                    raise ConnectionError("acceptance SMTP QUIT disconnected")
            writer.write(b"221 2.0.0 bye\r\n")
            await writer.drain()
            break
        else:
            writer.write(b"250 2.0.0 OK\r\n")
        await writer.drain()
    writer.close()
    await writer.wait_closed()


async def upgrade_smtp_tls(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    context: ssl.SSLContext,
) -> asyncio.StreamWriter:
    """Upgrade this SMTP stream without replacing its reader protocol."""
    start_tls = getattr(writer, "start_tls", None)
    if start_tls is not None:
        await start_tls(context, ssl_handshake_timeout=10)
        return writer

    # Python 3.9 lacks StreamWriter.start_tls. Keep the same reader and its
    # bound protocol when using the compatibility path for local fixture tests.
    loop = asyncio.get_running_loop()
    protocol = writer._protocol
    transport = await loop.start_tls(writer.transport, protocol, context, server_side=True, ssl_handshake_timeout=10)
    return asyncio.StreamWriter(transport, protocol, reader, loop)


async def main(kind: str, port: int) -> None:
    global _SMTP_TLS_CONTEXT
    authority.configure_root(ROOT)
    authority.initialize(repair=kind != "transition")
    if kind == "transition":
        provider_transition()
        return
    if kind == "imap":
        # A restarted fixture has no surviving IDLE sessions; clear leases
        # before advertising readiness so stale markers cannot wake a client.
        authority.transaction(lambda state: state.update({
            "imap_idle_active_count": 0,
            "imap_idle_active_inbox_count": 0,
        }))
    handler = imap if kind == "imap" else smtp
    kwargs = {}
    if kind == "imap":
        context = imap_tls_context()
        kwargs["ssl"] = context
    else:
        # Validate the closed mode and all required assets before publishing
        # readiness; every SMTP session reuses this immutable server context.
        _SMTP_TLS_CONTEXT = smtp_tls_context()
    server = await asyncio.start_server(handler, "0.0.0.0", port, **kwargs)
    ready_file = os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_READY_FILE")
    if ready_file:
        ready_path = Path(ready_file)
        temporary = ready_path.with_name(ready_path.name + ".tmp")
        temporary.write_text(str(server.sockets[0].getsockname()[1]), encoding="ascii")
        os.chmod(temporary, 0o600)
        os.replace(temporary, ready_path)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "transition":
        authority.configure_root(ROOT)
        authority.initialize(repair=False)
        provider_transition()
    else:
        asyncio.run(main(sys.argv[1], int(sys.argv[2])))
