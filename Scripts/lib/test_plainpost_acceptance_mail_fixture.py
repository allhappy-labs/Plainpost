import asyncio
import fcntl
import json
import multiprocessing
import os
import ssl
import sqlite3
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock
from pathlib import Path
from tempfile import TemporaryDirectory


def _cold_wal_connection_worker(root, barrier, transition_log, error_log):
    from Scripts.lib import plainpost_acceptance_mail_state as state

    state.configure_root(root)
    original_enable_wal = state._enable_wal

    def tracked_enable_wal(*args, **kwargs):
        with open(transition_log, "a", encoding="ascii") as stream:
            stream.write("transition\n")
        return original_enable_wal(*args, **kwargs)

    state._enable_wal = tracked_enable_wal
    try:
        barrier.wait(timeout=10)
        connection = state._connect()
        connection.close()
    except BaseException as error:
        with open(error_log, "a", encoding="ascii") as stream:
            stream.write(type(error).__name__ + "\n")
        raise


def _hot_wal_connection_worker(root, result_log):
    from Scripts.lib import plainpost_acceptance_mail_state as state

    state.configure_root(root)
    try:
        connection = state._connect()
        connection.close()
    except BaseException as error:
        Path(result_log).write_text(type(error).__name__, encoding="ascii")
        raise
    Path(result_log).write_text("passed", encoding="ascii")

from Scripts.lib import plainpost_acceptance_mail_fixture as fixture
from Scripts.lib import plainpost_acceptance_mail_state as mail_state
from Scripts.lib import plainpost_acceptance_mail_docker_wire_probe as docker_probe
from Scripts.lib.plainpost_acceptance_mail_fixture import (
    authenticated,
    bodystructure_for,
    fetch_body_payload,
    _imap_attachment_path,
    message_sections,
    multipart_part_body,
    move_message,
    parse_imap_arguments,
    parse_append_request,
    search_message_uids,
    smtp_authenticated,
)


class MailDeliveryPostconditionTests(unittest.TestCase):
    def test_control_projection_includes_allowlisted_idle_lease_counters(self):
        projected = mail_state._control_projection({
            "faults": [],
            "phases": [],
            "phase_counters": [],
            "imap_idle_active_count": 3,
            "imap_idle_active_inbox_count": 1,
            "unprojected_private_value": "must-not-escape",
        })
        self.assertEqual(projected, {
            "faults": [],
            "phases": [],
            "phase_counters": [],
            "imap_idle_active_count": 3,
            "imap_idle_active_inbox_count": 1,
        })

    @staticmethod
    def _postcondition(checkpoint, digest, *, draft_count, delivery_count=0, sent_count=0, message_id_value="<draft@example.test>", bcc_header_absent=True):
        return {
            "checkpoint": checkpoint,
            "draft_count": draft_count,
            "delivery_count": delivery_count,
            "sent_count": sent_count,
            "envelope_sender": "sender@example.test" if checkpoint == "send-delivery" else "",
            "envelope_recipients": ["recipient@example.test"] if checkpoint == "send-delivery" else [],
            "message_id": message_id_value,
            "canonical_digest": digest,
            "bcc_header_absent": bcc_header_absent,
        }

    def test_canonical_source_normalizes_line_endings_and_terminal_crlf(self):
        self.assertEqual(
            mail_state.canonical_source(b"Subject: x\n\nbody"),
            b"Subject: x\r\n\r\nbody\r\n",
        )
        self.assertEqual(
            mail_state.canonical_source(b"Subject: x\rbody\r\n\n"),
            b"Subject: x\r\nbody\r\n\r\n",
        )

    def test_delivery_record_keeps_authenticated_envelope_digest_and_message_id(self):
        with TemporaryDirectory() as directory:
            mail_state.configure_root(Path(directory))
            mail_state.record_delivery(
                b"Message-ID: <postcondition@example.test>\n\nbody",
                tls_active=True,
                authenticated=True,
                envelope_sender="sender@example.test",
                envelope_recipients=["recipient@example.test", "blind@example.test"],
            )
            delivery = mail_state.read()["deliveries"][0]
            self.assertTrue(delivery["tls_active"])
            self.assertTrue(delivery["authenticated"])
            self.assertEqual(delivery["envelope_sender"], "sender@example.test")
            self.assertEqual(delivery["envelope_recipients"], ["recipient@example.test", "blind@example.test"])
            self.assertEqual(delivery["message_id"], "<postcondition@example.test>")
            self.assertEqual(delivery["canonical_digest"], mail_state.canonical_digest(b"Message-ID: <postcondition@example.test>\n\nbody"))

    def test_legacy_delivery_projection_import_uses_canonical_digest(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            raw = "Message-ID: <legacy-json@example.test>\r\n\r\nbody"
            (root / mail_state.DELIVERIES_NAME).write_text(
                json.dumps({"message": raw.replace("\r\n", "\n")}) + "\n",
                encoding="utf-8",
            )
            delivery = mail_state.read()["deliveries"][0]
            self.assertEqual(delivery["canonical_digest"], mail_state.canonical_digest(raw))

    def test_typed_postcondition_rejects_unknown_and_raw_fields(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            with self.assertRaises(ValueError):
                mail_state.assert_postcondition({"unknown": True})
            with self.assertRaises(ValueError):
                mail_state.assert_postcondition({"message": "raw body"})
            raw = b"Message-ID: <postcondition@example.test>\n\nbody"
            mail_state.record_delivery(raw, tls_active=True, authenticated=True, envelope_sender="sender@example.test", envelope_recipients=["recipient@example.test", "blind@example.test"])
            result = mail_state.assert_postcondition({
                "checkpoint": "send-delivery", "draft_count": 0, "delivery_count": 1,
                "sent_count": 0, "envelope_sender": "sender@example.test",
                "envelope_recipients": ["recipient@example.test", "blind@example.test"],
                "message_id": "<postcondition@example.test>",
                "canonical_digest": mail_state.canonical_digest(raw),
                "bcc_header_absent": True,
            })
            self.assertNotIn("envelope_sender", result)
            self.assertNotIn("message_id", result)
            self.assertTrue(all(len(value) == 64 for key, value in result.items() if key.endswith("digest")))

    def test_send_postcondition_rejects_matching_unauthenticated_delivery(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            raw = b"Message-ID: <send-security@example.test>\n\nbody"
            mail_state.record_delivery(
                raw,
                tls_active=False,
                authenticated=False,
                envelope_sender="sender@example.test",
                envelope_recipients=["recipient@example.test"],
            )
            expected = self._postcondition(
                "send-delivery",
                mail_state.canonical_digest(raw),
                draft_count=0,
                delivery_count=1,
                sent_count=0,
                message_id_value="<send-security@example.test>",
            )
            with self.assertRaises(ValueError):
                mail_state.assert_postcondition(expected)

    def test_send_postcondition_mismatch_reports_fixed_sent_state_category(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            raw = b"Message-ID: <send-category@example.test>\n\nbody"
            mail_state.record_delivery(
                raw,
                tls_active=True,
                authenticated=True,
                envelope_sender="sender@example.test",
                envelope_recipients=["recipient@example.test"],
            )
            expected = self._postcondition(
                "send-delivery",
                mail_state.canonical_digest(raw),
                draft_count=0,
                delivery_count=1,
                sent_count=1,
                message_id_value="<send-category@example.test>",
            )
            with self.assertRaisesRegex(ValueError, r"^mail postcondition mismatch: sent-state$"):
                mail_state.assert_postcondition(expected)

    def test_control_reports_postcondition_category_without_authoritative_values(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            raw = b"Message-ID: <control-category@example.test>\n\nbody"
            mail_state.record_delivery(
                raw,
                tls_active=True,
                authenticated=True,
                envelope_sender="sender@example.test",
                envelope_recipients=["recipient@example.test"],
            )
            expectation = root / "mail-postcondition.expectation"
            expectation.write_text(json.dumps(self._postcondition(
                "send-delivery",
                mail_state.canonical_digest(raw),
                draft_count=0,
                delivery_count=1,
                sent_count=1,
                message_id_value="<control-category@example.test>",
            )), encoding="utf-8")
            expectation.chmod(0o600)
            completed = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("plainpost_acceptance_mail_control.py")),
                 "--root", str(root), "postcondition", "--expectation-file", str(expectation)],
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(completed.stdout, "postcondition-category=sent-state\n")
            self.assertNotIn("control-category@example.test", completed.stdout + completed.stderr)

    def test_send_postcondition_rejects_multiple_matching_deliveries(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            raw = b"Message-ID: <send-duplicate@example.test>\n\nbody"
            for _ in range(2):
                mail_state.record_delivery(
                    raw,
                    tls_active=True,
                    authenticated=True,
                    envelope_sender="sender@example.test",
                    envelope_recipients=["recipient@example.test"],
                )
            expected = self._postcondition(
                "send-delivery",
                mail_state.canonical_digest(raw),
                draft_count=0,
                delivery_count=2,
                sent_count=0,
                message_id_value="<send-duplicate@example.test>",
            )
            with self.assertRaises(ValueError):
                mail_state.assert_postcondition(expected)

    def test_send_postcondition_rejects_matching_delivery_with_differently_rendered_delivery(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            raw = b"Message-ID: <send-total@example.test>\n\nbody"
            different = b"Message-ID: <send-total@example.test>\n\nrendered differently"
            for payload in (raw, different):
                mail_state.record_delivery(
                    payload,
                    tls_active=True,
                    authenticated=True,
                    envelope_sender="sender@example.test",
                    envelope_recipients=["recipient@example.test"],
                )
            expected = self._postcondition(
                "send-delivery",
                mail_state.canonical_digest(raw),
                draft_count=0,
                delivery_count=1,
                sent_count=0,
                message_id_value="<send-total@example.test>",
            )
            with self.assertRaises(ValueError):
                mail_state.assert_postcondition(expected)

    def test_draft_create_counts_stale_same_message_id_versions(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            stale = "Message-ID: <draft@example.test>\n\nold"
            current = "Message-ID: <draft@example.test>\n\nnew"
            mail_state.transaction(lambda state: state["messages"].extend([
                {"uid": 1, "flags": [], "labels": ["Drafts"], "raw": stale},
                {"uid": 2, "flags": [], "labels": ["Drafts"], "raw": current},
            ]))
            expected = self._postcondition("draft-created", mail_state.canonical_digest(current), draft_count=1)
            with self.assertRaises(ValueError):
                mail_state.assert_postcondition(expected)

    def test_draft_update_counts_stale_same_message_id_versions(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            stale = "Message-ID: <draft@example.test>\n\nold"
            current = "Message-ID: <draft@example.test>\n\nnew"
            mail_state.transaction(lambda state: state["messages"].extend([
                {"uid": 1, "flags": [], "labels": ["Drafts"], "raw": stale},
                {"uid": 2, "flags": [], "labels": ["Drafts"], "raw": current},
            ]))
            expected = self._postcondition("draft-updated", mail_state.canonical_digest(current), draft_count=1)
            with self.assertRaises(ValueError):
                mail_state.assert_postcondition(expected)

    def test_draft_create_rejects_stale_only_same_message_id(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            stale = "Message-ID: <draft@example.test>\n\nold"
            mail_state.transaction(lambda state: state["messages"].append(
                {"uid": 1, "flags": [], "labels": ["Drafts"], "raw": stale}
            ))
            expected = self._postcondition("draft-created", mail_state.canonical_digest("Message-ID: <draft@example.test>\n\nnew"), draft_count=1)
            with self.assertRaises(ValueError):
                mail_state.assert_postcondition(expected)

    def test_draft_update_rejects_stale_only_same_message_id(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            stale = "Message-ID: <draft@example.test>\n\nold"
            mail_state.transaction(lambda state: state["messages"].append(
                {"uid": 1, "flags": [], "labels": ["Drafts"], "raw": stale}
            ))
            expected = self._postcondition("draft-updated", mail_state.canonical_digest("Message-ID: <draft@example.test>\n\nnew"), draft_count=1)
            with self.assertRaises(ValueError):
                mail_state.assert_postcondition(expected)

    def test_draft_create_accepts_exactly_one_current_version(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            current = "Message-ID: <draft@example.test>\n\nnew"
            mail_state.transaction(lambda state: state["messages"].append(
                {"uid": 1, "flags": [], "labels": ["Drafts"], "raw": current}
            ))
            expected = self._postcondition("draft-created", mail_state.canonical_digest(current), draft_count=1)
            self.assertEqual(mail_state.assert_postcondition(expected)["draft_count"], 1)

    def test_draft_update_accepts_exactly_one_current_version(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            current = "Message-ID: <draft@example.test>\n\nnew"
            mail_state.transaction(lambda state: state["messages"].append(
                {"uid": 1, "flags": [], "labels": ["Drafts"], "raw": current}
            ))
            expected = self._postcondition("draft-updated", mail_state.canonical_digest(current), draft_count=1)
            self.assertEqual(mail_state.assert_postcondition(expected)["draft_count"], 1)

    def test_draft_delete_rejects_stale_same_message_id_version(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            stale = "Message-ID: <draft@example.test>\n\nold"
            deleted = "Message-ID: <draft@example.test>\n\ndeleted"
            mail_state.transaction(lambda state: state["messages"].append(
                {"uid": 1, "flags": [], "labels": ["Drafts"], "raw": stale}
            ))
            expected = self._postcondition("draft-deleted", mail_state.canonical_digest(deleted), draft_count=0)
            with self.assertRaises(ValueError):
                mail_state.assert_postcondition(expected)

    def test_bcc_text_in_body_does_not_fail_header_absence_postcondition(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            raw = b"Message-ID: <body-bcc@example.test>\n\nBcc: body-is-not-a-header"
            mail_state.record_delivery(
                raw,
                tls_active=True,
                authenticated=True,
                envelope_sender="sender@example.test",
                envelope_recipients=["recipient@example.test"],
            )
            expected = self._postcondition(
                "send-delivery",
                mail_state.canonical_digest(raw),
                draft_count=0,
                delivery_count=1,
                message_id_value="<body-bcc@example.test>",
            )
            result = mail_state.assert_postcondition(expected)
            self.assertTrue(result["bcc_header_absent"])


class IMAPAuthenticationTests(unittest.TestCase):
    def test_imap_tls_context_keeps_pre_auth_sni_observation_callback(self):
        context = mock.Mock()
        with mock.patch.object(fixture.ssl, "create_default_context", return_value=context), mock.patch.dict(
            os.environ,
            {
                "PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT": "unused-cert",
                "PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY": "unused-key",
            },
            clear=False,
        ):
            fixture.imap_tls_context()
        context.set_servername_callback.assert_called_once_with(fixture._record_imap_tls_handshake)

    def test_imap_tls_observation_offloads_concurrent_accepted_sessions(self):
        async def exercise():
            lock = threading.Lock()
            active_count = 0
            maximum_active_count = 0
            completed_count = 0

            def slow_observation(*_args):
                nonlocal active_count, maximum_active_count, completed_count
                with lock:
                    active_count += 1
                    maximum_active_count = max(maximum_active_count, active_count)
                time.sleep(0.05)
                with lock:
                    active_count -= 1
                    completed_count += 1

            with mock.patch.object(fixture.authority, "record_observation", side_effect=slow_observation):
                fixture._IMAP_TLS_OBSERVATION_TASKS.clear()
                ssl_objects = [object() for _ in range(6)]
                scheduled_at = asyncio.get_running_loop().time()
                for ssl_object in ssl_objects:
                    fixture._record_imap_tls_handshake(ssl_object, None, mock.Mock())
                heartbeat = asyncio.create_task(asyncio.sleep(0.01))
                await asyncio.sleep(0)
                self.assertLess(asyncio.get_running_loop().time() - scheduled_at, 0.05)
                await heartbeat
                observations = list(fixture._IMAP_TLS_OBSERVATION_TASKS.values())
                await asyncio.wait_for(
                    asyncio.gather(*observations),
                    timeout=5,
                )
                fixture._IMAP_TLS_OBSERVATION_TASKS.clear()
            self.assertEqual(completed_count, 6)
            self.assertEqual(maximum_active_count, 1)

        asyncio.run(exercise())

    def test_imap_sni_observation_recovers_from_transient_authority_open(self):
        async def exercise():
            calls = 0

            def record_observation(*_args):
                nonlocal calls
                calls += 1
                attempts = 0

                def open_wal(_statement):
                    nonlocal attempts
                    attempts += 1
                    if attempts == 1:
                        raise sqlite3.OperationalError("unable to open database file")

                mail_state._enable_wal(open_wal, sleep=lambda _delay: None)

            with mock.patch.object(fixture.authority, "record_observation", side_effect=record_observation):
                fixture._IMAP_TLS_OBSERVATION_TASKS.clear()
                fixture._record_imap_tls_handshake(object(), None, mock.Mock())
                await asyncio.wait_for(
                    asyncio.gather(*fixture._IMAP_TLS_OBSERVATION_TASKS.values()),
                    timeout=2,
                )
                fixture._IMAP_TLS_OBSERVATION_TASKS.clear()
            self.assertEqual(calls, 1)

        asyncio.run(exercise())

    def test_imap_tls_observation_completes_before_accepted_session_greeting(self):
        async def exercise():
            events = []
            ssl_object = object()

            class Reader:
                async def readline(self):
                    return b""

            class Writer:
                def get_extra_info(self, name):
                    return ssl_object if name == "ssl_object" else None

                def write(self, value):
                    events.append(("write", value))

                async def drain(self):
                    pass

                def close(self):
                    pass

                async def wait_closed(self):
                    pass

            async def record():
                events.append(("observation", None))

            with mock.patch.object(fixture, "_record_imap_tls_handshake_after_acceptance", side_effect=record):
                fixture._IMAP_TLS_OBSERVATION_TASKS.clear()
                fixture._record_imap_tls_handshake(ssl_object, None, mock.Mock())
                await fixture.imap(Reader(), Writer())
                self.assertNotIn(id(ssl_object), fixture._IMAP_TLS_OBSERVATION_TASKS)
            self.assertEqual(events[0], ("observation", None))
            self.assertEqual(events[1], ("write", b"* OK Plainpost acceptance IMAP4rev1\r\n"))

        asyncio.run(exercise())

    def test_real_imap_tls_acceptance_drains_one_sni_observation(self):
        async def exercise():
            with TemporaryDirectory() as directory:
                root = Path(directory)
                certificate = root / "imap.crt"
                key = root / "imap.key"
                subprocess.run(
                    [
                        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(key), "-out", str(certificate), "-subj", "/CN=localhost", "-days", "1",
                        "-addext", "basicConstraints=critical,CA:TRUE",
                        "-addext", "keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment",
                        "-addext", "subjectAltName=DNS:localhost",
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                mailbox = root / "mailbox.json"
                mailbox.write_text(
                    json.dumps({"uidValidity": 1, "nextUID": 2, "messages": []}),
                    encoding="utf-8",
                )
                old_state = fixture.STATE
                old_certificate = os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT")
                old_key = os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY")
                fixture.STATE = mailbox
                os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT"] = str(certificate)
                os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY"] = str(key)
                fixture._IMAP_TLS_OBSERVATION_TASKS.clear()
                mail_state.configure_root(root)
                server = None
                writer = None
                try:
                    server = await asyncio.start_server(
                        fixture.imap,
                        "127.0.0.1",
                        0,
                        ssl=fixture.imap_tls_context(),
                    )
                    port = server.sockets[0].getsockname()[1]
                    client_context = ssl.create_default_context()
                    client_context.check_hostname = False
                    client_context.verify_mode = ssl.CERT_NONE
                    reader, writer = await asyncio.open_connection(
                        "127.0.0.1",
                        port,
                        ssl=client_context,
                        server_hostname="localhost",
                    )
                    self.assertEqual(
                        await asyncio.wait_for(reader.readline(), 2),
                        b"* OK Plainpost acceptance IMAP4rev1\r\n",
                    )
                    writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\n')
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"A OK LOGIN\r\n")
                    writer.write(b"B LOGOUT\r\n")
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"B OK LOGOUT\r\n")
                    writer.close()
                    await writer.wait_closed()
                    writer = None
                    observations = [
                        item for item in mail_state.read()["observations"]
                        if item["kind"] == "test-observation"
                        and item["protocol"] == "imap"
                        and item["phase"] == "tls-handshake"
                    ]
                    self.assertEqual(len(observations), 1)
                    self.assertEqual(fixture._IMAP_TLS_OBSERVATION_TASKS, {})
                finally:
                    if writer is not None:
                        writer.close()
                        await writer.wait_closed()
                    if server is not None:
                        server.close()
                        await server.wait_closed()
                    fixture._IMAP_TLS_OBSERVATION_TASKS.clear()
                    fixture.STATE = old_state
                    if old_certificate is None:
                        os.environ.pop("PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT", None)
                    else:
                        os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT"] = old_certificate
                    if old_key is None:
                        os.environ.pop("PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY", None)
                    else:
                        os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY"] = old_key

        asyncio.run(exercise())

    def test_imap_peer_reset_does_not_escape_handler(self):
        class ResetReader:
            async def readline(self) -> bytes:
                raise ConnectionResetError("probe disconnected")

        class RecordingWriter:
            def __init__(self) -> None:
                self.closed = False

            def get_extra_info(self, _: str):
                return None

            def write(self, _: bytes) -> None:
                pass

            async def drain(self) -> None:
                pass

            def close(self) -> None:
                self.closed = True

            async def wait_closed(self) -> None:
                pass

        async def exercise():
            writer = RecordingWriter()
            await fixture.imap(ResetReader(), writer)  # type: ignore[arg-type]
            self.assertTrue(writer.closed)

        asyncio.run(exercise())

    def test_typed_imap_faults_accept_phase_specific_disconnect_and_truncation(self):
        with TemporaryDirectory() as directory:
            mail_state.configure_root(Path(directory))
            for name in ("imap-catalog", "imap-header-fetch", "imap-body-fetch", "imap-attachment-fetch"):
                mail_state.arm_fault(name, 1, "disconnect")
            mail_state.arm_fault("imap-truncated-literal", 1, "truncated")
            self.assertEqual(
                [mail_state.trigger_fault(name) for name in ("imap-catalog", "imap-header-fetch", "imap-body-fetch", "imap-attachment-fetch", "imap-truncated-literal")],
                ["disconnect", "disconnect", "disconnect", "disconnect", "truncated"],
            )
            with self.assertRaises(ValueError):
                mail_state.arm_fault("imap-header-fetch", 1, "temporary")

    def test_imap_phase_barrier_pauses_until_resume(self):
        async def exercise():
            with TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "mailbox.json").write_text(json.dumps({"uidValidity": 1, "nextUID": 2, "messages": [{"uid": 1, "flags": [], "labels": ["INBOX"], "raw": "Subject: barrier\r\n\r\nbody\r\n"}]}), encoding="utf-8")
                old_state = fixture.STATE
                fixture.STATE = root / "mailbox.json"
                writer = None
                mail_state.configure_root(root)
                mail_state.configure_phase("imap", "header-fetch", 1, "pause")
                server = None
                try:
                    server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
                    port = server.sockets[0].getsockname()[1]
                    reader, writer = await asyncio.open_connection("127.0.0.1", port)
                    await reader.readline()
                    writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\n')
                    await writer.drain()
                    await reader.readline()
                    writer.write(b'B UID FETCH 1 (BODY.PEEK[HEADER])\r\n')
                    await writer.drain()
                    barrier_result = []
                    barrier_errors = []

                    def resume_when_reached():
                        try:
                            barrier_result.append(mail_state.wait_for_phase("imap", "header-fetch", 1, 2000))
                            mail_state.set_phase_action("imap", "header-fetch", 1, "resume")
                        except BaseException as error:
                            barrier_errors.append(error)
                            try:
                                mail_state.set_phase_action("imap", "header-fetch", 1, "resume")
                            except BaseException as resume_error:
                                barrier_errors.append(resume_error)

                    resumer = threading.Thread(target=resume_when_reached)
                    resumer.start()
                    response = await asyncio.wait_for(reader.readuntil(b"B OK UID FETCH\r\n"), timeout=2)
                    resumer.join(timeout=3)
                    self.assertEqual(barrier_errors, [])
                    self.assertEqual(len(barrier_result), 1)
                    self.assertIn(b"Subject: barrier", response)
                finally:
                    if writer is not None:
                        writer.close()
                        await writer.wait_closed()
                    if server is not None:
                        server.close()
                        await server.wait_closed()
                    try:
                        mail_state.set_phase_action("imap", "header-fetch", 1, "resume")
                    except (OSError, ValueError):
                        pass
                    fixture.STATE = old_state

        asyncio.run(exercise())

    def test_imap_idle_live_mode_reports_authoritative_exists_count(self):
        async def exercise():
            with TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "mailbox.json").write_text(json.dumps({"uidValidity": 1, "nextUID": 2, "messages": [{"uid": 1, "flags": [], "labels": ["INBOX"], "raw": "Subject: idle\r\n\r\nbody\r\n"}]}), encoding="utf-8")
                old_state = fixture.STATE
                fixture.STATE = root / "mailbox.json"
                old_environment = os.environ.copy()
                os.environ.update({"PLAINPOST_ACCEPTANCE_IMAP_IDLE": "1", "PLAINPOST_ACCEPTANCE_IMAP_WAIT_FOR_IDLE_CHANGE": "1"})
                mail_state.configure_root(root)
                mail_state.configure_phase("imap", "idle", 1, "continue")
                events = []
                original_read_state = fixture.read_state
                original_phase = mail_state.phase

                def observed_read_state():
                    events.append("read-state")
                    return original_read_state()

                def observed_phase(protocol, phase_name):
                    if protocol == "imap" and phase_name == "idle":
                        events.append("idle-phase")
                    return original_phase(protocol, phase_name)

                server = None
                writer = None
                try:
                    with mock.patch.object(fixture, "read_state", side_effect=observed_read_state), mock.patch.object(mail_state, "phase", side_effect=observed_phase):
                        server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
                        reader, writer = await asyncio.open_connection("127.0.0.1", server.sockets[0].getsockname()[1])
                        await reader.readline()
                        writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\nB IDLE\r\n')
                        await writer.drain()
                        self.assertEqual(await reader.readline(), b"A OK LOGIN\r\n")
                        self.assertEqual(await reader.readline(), b"+ idling\r\n")
                        self.assertEqual(mail_state.wait_for_phase("imap", "idle", 1, 2000)["occurrence"], 1)
                        self.assertLess(events.index("read-state"), events.index("idle-phase"))
                        self.assertEqual(mail_state.read().get("imap_idle_active_count"), 1)
                        self.assertEqual(mail_state.read().get("imap_idle_active_inbox_count"), 1)
                        control = json.loads((root / "mail-control.json").read_text(encoding="utf-8"))
                        self.assertEqual(control["imap_idle_active_count"], 1)
                        self.assertEqual(control["imap_idle_active_inbox_count"], 1)

                        def append_message():
                            def append(state):
                                state["nextUID"] += 1
                                state["messages"].append({"uid": 2, "flags": [], "labels": ["INBOX"], "raw": "Subject: transition\r\n\r\nbody\r\n"})
                            mail_state.transaction(append)

                        await asyncio.to_thread(append_message)
                        self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=2), b"* 2 EXISTS\r\n")
                        writer.write(b"DONE\r\n")
                        await writer.drain()
                        self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=2), b"B OK IDLE\r\n")
                        self.assertEqual(mail_state.read().get("imap_idle_active_count"), 0)
                        self.assertEqual(mail_state.read().get("imap_idle_active_inbox_count"), 0)
                        control = json.loads((root / "mail-control.json").read_text(encoding="utf-8"))
                        self.assertEqual(control["imap_idle_active_count"], 0)
                        self.assertEqual(control["imap_idle_active_inbox_count"], 0)
                finally:
                    if writer is not None:
                        writer.close()
                        await writer.wait_closed()
                    if server is not None:
                        server.close()
                        await server.wait_closed()
                    os.environ.clear()
                    os.environ.update(old_environment)
                    fixture.STATE = old_state

        asyncio.run(exercise())

    def test_imap_idle_target_releases_non_target_workers_before_inbox_lease(self):
        async def exercise():
            with TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "mailbox.json").write_text(json.dumps({
                    "uidValidity": 1,
                    "nextUID": 2,
                    "messages": [{"uid": 1, "flags": [], "labels": ["INBOX"], "raw": "Subject: target\r\n\r\nbody\r\n"}],
                }), encoding="utf-8")
                old_state = fixture.STATE
                old_environment = os.environ.copy()
                fixture.STATE = root / "mailbox.json"
                os.environ.update({
                    "PLAINPOST_ACCEPTANCE_IMAP_IDLE": "1",
                    "PLAINPOST_ACCEPTANCE_IMAP_WAIT_FOR_IDLE_CHANGE": "1",
                    "PLAINPOST_ACCEPTANCE_IMAP_IDLE_TARGET": "INBOX",
                })
                mail_state.configure_root(root)
                mail_state.initialize()
                server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
                port = server.sockets[0].getsockname()[1]
                writer = None
                inbox_idle_active = False

                def append_message():
                    def append(state):
                        state["nextUID"] += 1
                        state["messages"].append({"uid": 2, "flags": [], "labels": ["INBOX"], "raw": "Subject: transition\r\n\r\nbody\r\n"})
                    mail_state.transaction(append)

                try:
                    reader, writer = await asyncio.open_connection("127.0.0.1", port)
                    await asyncio.wait_for(reader.readline(), timeout=1)
                    writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\n')
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"A OK LOGIN\r\n")
                    writer.write(b'B SELECT "Sent"\r\n')
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"* 0 EXISTS\r\n")
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"* OK [UIDVALIDITY 1] SELECT\r\n")
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"B OK SELECT\r\n")
                    writer.write(b"C IDLE\r\n")
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"+ idling\r\n")
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"C OK IDLE\r\n")
                    control = json.loads((root / "mail-control.json").read_text(encoding="utf-8"))
                    self.assertEqual(control["imap_idle_active_count"], 0)
                    self.assertEqual(control["imap_idle_active_inbox_count"], 0)

                    writer.write(b"D NOOP\r\n")
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"D OK NOOP\r\n")
                    writer.write(b"E SELECT \"INBOX\"\r\n")
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"* 1 EXISTS\r\n")
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"* OK [UIDVALIDITY 1] SELECT\r\n")
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"E OK SELECT\r\n")
                    writer.write(b"F IDLE\r\n")
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"+ idling\r\n")
                    control = json.loads((root / "mail-control.json").read_text(encoding="utf-8"))
                    self.assertEqual(control["imap_idle_active_count"], 1)
                    self.assertEqual(control["imap_idle_active_inbox_count"], 1)
                    inbox_idle_active = True
                    idle_count = next((item["count"] for item in mail_state.read()["phase_counters"] if item["protocol"] == "imap" and item["phase"] == "idle"), 0)
                    self.assertEqual(idle_count, 1)

                    await asyncio.to_thread(append_message)
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"* 2 EXISTS\r\n")
                    writer.write(b"DONE\r\n")
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), timeout=1), b"F OK IDLE\r\n")
                    inbox_idle_active = False
                finally:
                    if inbox_idle_active and writer is not None:
                        try:
                            await asyncio.to_thread(append_message)
                            writer.write(b"DONE\r\n")
                            await writer.drain()
                            await asyncio.wait_for(reader.readline(), timeout=2)
                        except (ConnectionError, asyncio.TimeoutError, OSError):
                            pass
                    if writer is not None:
                        writer.close()
                        await writer.wait_closed()
                    server.close()
                    await server.wait_closed()
                    os.environ.clear()
                    os.environ.update(old_environment)
                    fixture.STATE = old_state

        asyncio.run(exercise())

    def test_imap_truncated_literal_is_one_shot_and_leaves_mailbox_projection_intact(self):
        async def exercise():
            with TemporaryDirectory() as directory:
                root = Path(directory)
                raw = "Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=x.bin\r\n\r\nbody\r\n--x--\r\n"
                payload = b"body"
                (root / "mailbox.json").write_text(json.dumps({"uidValidity": 1, "nextUID": 2, "messages": [{"uid": 1, "flags": [], "labels": ["INBOX"], "raw": raw}]}), encoding="utf-8")
                old_state = fixture.STATE
                fixture.STATE = root / "mailbox.json"
                mail_state.configure_root(root)
                mail_state.arm_fault("imap-truncated-literal", 1, "truncated")
                server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
                port = server.sockets[0].getsockname()[1]
                try:
                    reader, writer = await asyncio.open_connection("127.0.0.1", port)
                    await reader.readline()
                    writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\nB UID FETCH 1 (BODY.PEEK[1])\r\n')
                    await writer.drain()
                    await reader.readline()
                    await reader.readuntil(b"{")
                    size_line = await reader.readuntil(b"}\r\n")
                    advertised = int(size_line[:-3])
                    actual = await reader.read()
                    self.assertEqual(actual, payload)
                    self.assertGreater(advertised, len(actual))
                    state = mail_state.read()
                    self.assertEqual(state["messages"][0]["raw"], raw)
                    fault = next(item for item in state["faults"] if item["name"] == "imap-truncated-literal")
                    self.assertEqual((fault["seen"], fault["consumed"]), (1, 1))
                    writer.close()
                    await writer.wait_closed()
                finally:
                    server.close()
                    await server.wait_closed()
                    fixture.STATE = old_state

        asyncio.run(exercise())

    def test_imap_truncated_literal_frames_only_the_owned_occurrence(self):
        async def exercise():
            with TemporaryDirectory() as directory:
                root = Path(directory)
                raw = "Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=x.bin\r\n\r\nbody\r\n--x--\r\n"
                payload = b"body"
                (root / "mailbox.json").write_text(json.dumps({"uidValidity": 1, "nextUID": 2, "messages": [{"uid": 1, "flags": [], "labels": ["INBOX"], "raw": raw}]}), encoding="utf-8")
                old_state = fixture.STATE
                fixture.STATE = root / "mailbox.json"
                mail_state.configure_root(root)
                mail_state.arm_fault("imap-truncated-literal", 2, "truncated")
                server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
                port = server.sockets[0].getsockname()[1]

                async def fetch(*, read_body: bool) -> tuple[int, bytes, bool]:
                    reader, writer = await asyncio.open_connection("127.0.0.1", port)
                    try:
                        await reader.readline()
                        writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\nB UID FETCH 1 (BODY.PEEK[1])\r\n')
                        await writer.drain()
                        await reader.readline()
                        await reader.readuntil(b"{")
                        size_line = await reader.readuntil(b"}\r\n")
                        advertised = int(size_line[:-3])
                        if not read_body:
                            return advertised, b"", False
                        try:
                            actual = await asyncio.wait_for(reader.readexactly(advertised), timeout=1)
                            await asyncio.wait_for(reader.readuntil(b"A OK UID FETCH\r\n"), timeout=1)
                            complete = True
                        except (asyncio.IncompleteReadError, asyncio.TimeoutError) as error:
                            actual = error.partial if isinstance(error, asyncio.IncompleteReadError) else b""
                            complete = False
                        return advertised, actual, complete
                    finally:
                        writer.close()
                        await writer.wait_closed()

                try:
                    first = await fetch(read_body=False)
                    second = await fetch(read_body=True)
                    self.assertEqual(first[0], len(payload))
                    self.assertEqual(second, (len(payload) + 1, payload, False))
                    fault = next(item for item in mail_state.read()["faults"] if item["name"] == "imap-truncated-literal")
                    self.assertEqual((fault["seen"], fault["consumed"]), (2, 1))
                finally:
                    server.close()
                    await server.wait_closed()
                    fixture.STATE = old_state

        asyncio.run(exercise())

    def test_imap_truncated_literal_fault_is_claimed_only_for_attachment_fetch(self):
        async def exercise():
            class RecordingWriter:
                def __init__(self) -> None:
                    self.closed = False

                def write(self, value: bytes) -> None:
                    pass

                async def drain(self) -> None:
                    pass

                def close(self) -> None:
                    self.closed = True

                async def wait_closed(self) -> None:
                    pass

            claims = []
            with mock.patch.object(fixture.authority, "claim_fault", side_effect=lambda name: claims.append(name) or "truncated"), \
                 mock.patch.object(fixture.authority, "phase"), \
                 mock.patch.object(fixture.authority, "trigger_fault", return_value=None):
                await fixture.write_literal_fetch(RecordingWriter(), "A", 1, "HEADER", b"header", "header-fetch", "imap-header-fetch")
                self.assertEqual(claims, [])
                await fixture.write_literal_fetch(RecordingWriter(), "B", 1, "2", b"attachment", "attachment-fetch", "imap-attachment-fetch")
                self.assertEqual(claims, ["imap-truncated-literal"])

        asyncio.run(exercise())

    def test_imap_authentication_rejection_and_each_fetch_loss_are_wire_observable(self):
        async def exercise():
            raw = (
                'Content-Type: multipart/mixed; boundary="faults"\r\n\r\n'
                '--faults\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nbody\r\n'
                '--faults\r\nContent-Type: application/octet-stream; name="x.bin"\r\n'
                'Content-Disposition: attachment; filename="x.bin"\r\n\r\nbytes\r\n'
                '--faults--\r\n'
            )
            cases = (
                ("imap-catalog", 'B LIST "" "*"\r\n', None),
                ("imap-header-fetch", "B UID FETCH 1 (BODY.PEEK[HEADER])\r\n", None),
                ("imap-body-fetch", "B UID FETCH 1 (BODY.PEEK[1])\r\n", None),
                ("imap-attachment-fetch", "B UID FETCH 1 (BODY.PEEK[2])\r\n", None),
            )
            for fault_name, command, _ in cases:
                with self.subTest(fault=fault_name), TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / "mailbox.json").write_text(json.dumps({"uidValidity": 1, "nextUID": 2, "messages": [{"uid": 1, "flags": [], "labels": ["INBOX"], "raw": raw}]}), encoding="utf-8")
                    old_state = fixture.STATE
                    fixture.STATE = root / "mailbox.json"
                    mail_state.configure_root(root)
                    mail_state.arm_fault(fault_name, 1, "disconnect")
                    server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
                    port = server.sockets[0].getsockname()[1]
                    try:
                        reader, writer = await asyncio.open_connection("127.0.0.1", port)
                        await reader.readline()
                        writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\n')
                        await writer.drain()
                        self.assertTrue((await reader.readline()).startswith(b"A OK"))
                        writer.write(command.encode())
                        await writer.drain()
                        if fault_name != "imap-catalog":
                            self.assertIn(b"{", await reader.readuntil(b"\r\n"))
                        self.assertEqual(await reader.read(), b"")
                        state = mail_state.read()
                        self.assertEqual(state["messages"][0]["raw"], raw)
                        fault = next(item for item in state["faults"] if item["name"] == fault_name)
                        self.assertEqual((fault["seen"], fault["consumed"]), (1, 1))
                    finally:
                        writer.close()
                        await writer.wait_closed()
                        server.close()
                        await server.wait_closed()
                        fixture.STATE = old_state

            with TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "mailbox.json").write_text(json.dumps({"uidValidity": 1, "nextUID": 2, "messages": [{"uid": 1, "flags": [], "labels": ["INBOX"], "raw": raw}]}), encoding="utf-8")
                old_state = fixture.STATE
                fixture.STATE = root / "mailbox.json"
                mail_state.configure_root(root)
                server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
                port = server.sockets[0].getsockname()[1]
                try:
                    reader, writer = await asyncio.open_connection("127.0.0.1", port)
                    await reader.readline()
                    writer.write(b'A LOGIN "acceptance@example.test" "wrong-password"\r\n')
                    await writer.drain()
                    self.assertEqual(await reader.readline(), b"A NO AUTHENTICATIONFAILED\r\n")
                    writer.close()
                    await writer.wait_closed()
                finally:
                    server.close()
                    await server.wait_closed()
                    fixture.STATE = old_state

            with TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "mailbox.json").write_text(json.dumps({"uidValidity": 1, "nextUID": 2, "messages": [{"uid": 1, "flags": [], "labels": ["INBOX"], "raw": raw}]}), encoding="utf-8")
                old_state = fixture.STATE
                fixture.STATE = root / "mailbox.json"
                mail_state.configure_root(root)
                mail_state.arm_fault("imap-authentication", 1, "rejected")
                server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
                port = server.sockets[0].getsockname()[1]
                try:
                    for expected in (b"A NO AUTHENTICATIONFAILED\r\n", b"A OK LOGIN\r\n"):
                        reader, writer = await asyncio.open_connection("127.0.0.1", port)
                        await reader.readline()
                        writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\n')
                        await writer.drain()
                        self.assertEqual(await reader.readline(), expected)
                        writer.close()
                        await writer.wait_closed()
                    fault = next(item for item in mail_state.read()["faults"] if item["name"] == "imap-authentication")
                    self.assertEqual((fault["seen"], fault["consumed"]), (2, 1))
                finally:
                    server.close()
                    await server.wait_closed()
                    fixture.STATE = old_state

        asyncio.run(exercise())

    def test_imap_consumed_disconnect_reconnects_with_exact_response(self):
        async def exercise():
            raw = (
                'Content-Type: multipart/mixed; boundary="faults"\r\n\r\n'
                '--faults\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nbody\r\n'
                '--faults\r\nContent-Type: application/octet-stream; name="x.bin"\r\n'
                'Content-Disposition: attachment; filename="x.bin"\r\n\r\nbytes\r\n'
                '--faults--\r\n'
            )
            cases = (
                (
                    "imap-catalog",
                    b'B LIST "" "*"\r\n',
                    b'* LIST (\\Inbox) "/" "INBOX"\r\n'
                    b'* LIST (\\Sent) "/" "Sent"\r\n'
                    b'* LIST (\\Drafts) "/" "Drafts"\r\n'
                    b'* LIST (\\Trash) "/" "Trash"\r\n'
                    b'* LIST (\\Archive) "/" "Archive"\r\n'
                    b'* LIST (\\All) "/" "All"\r\n'
                    b'B OK LIST\r\n',
                ),
                (
                    "imap-header-fetch",
                    b"B UID FETCH 1 (BODY.PEEK[HEADER])\r\n",
                    b'* 1 FETCH (BODY[HEADER] {52}\r\n'
                    b'Content-Type: multipart/mixed; boundary="faults"\r\n\r\n'
                    b')\r\nB OK UID FETCH\r\n',
                ),
                (
                    "imap-body-fetch",
                    b"B UID FETCH 1 (BODY.PEEK[1])\r\n",
                    b'* 1 FETCH (BODY[1] {4}\r\nbody)\r\nB OK UID FETCH\r\n',
                ),
            )
            for fault_name, command, expected in cases:
                with self.subTest(fault=fault_name), TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / "mailbox.json").write_text(json.dumps({"uidValidity": 1, "nextUID": 2, "messages": [{"uid": 1, "flags": [], "labels": ["INBOX"], "raw": raw}]}), encoding="utf-8")
                    old_state = fixture.STATE
                    fixture.STATE = root / "mailbox.json"
                    mail_state.configure_root(root)
                    mail_state.arm_fault(fault_name, 1, "disconnect")
                    server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
                    port = server.sockets[0].getsockname()[1]
                    writer = None
                    recovered_writer = None
                    try:
                        reader, writer = await asyncio.open_connection("127.0.0.1", port)
                        await reader.readline()
                        writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\n')
                        await writer.drain()
                        self.assertEqual(await reader.readline(), b"A OK LOGIN\r\n")
                        writer.write(command)
                        await writer.drain()
                        if fault_name != "imap-catalog":
                            self.assertEqual((await reader.readline()).split(b"{")[0], b"* 1 FETCH (BODY[HEADER] " if fault_name == "imap-header-fetch" else b"* 1 FETCH (BODY[1] ")
                        self.assertEqual(await reader.read(), b"")
                        writer.close()
                        await writer.wait_closed()
                        writer = None

                        recovered_reader, recovered_writer = await asyncio.open_connection("127.0.0.1", port)
                        await recovered_reader.readline()
                        recovered_writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\n')
                        await recovered_writer.drain()
                        self.assertEqual(await recovered_reader.readline(), b"A OK LOGIN\r\n")
                        recovered_writer.write(command)
                        await recovered_writer.drain()
                        self.assertEqual(await asyncio.wait_for(recovered_reader.readuntil(b"B OK " + (b"LIST\r\n" if fault_name == "imap-catalog" else b"UID FETCH\r\n")), timeout=2), expected)
                        state = mail_state.read()
                        self.assertEqual(state["messages"], [{"uid": 1, "flags": [], "labels": ["INBOX"], "raw": raw}])
                        fault = next(item for item in state["faults"] if item["name"] == fault_name)
                        self.assertEqual((fault["seen"], fault["consumed"]), (2, 1))
                    finally:
                        if writer is not None:
                            writer.close()
                            await writer.wait_closed()
                        if recovered_writer is not None:
                            recovered_writer.close()
                            await recovered_writer.wait_closed()
                        server.close()
                        await server.wait_closed()
                        fixture.STATE = old_state

        asyncio.run(exercise())

    def test_imap_uid_expunge_wire_response_removes_exact_uid(self):
        async def exercise():
            with TemporaryDirectory() as directory:
                root = Path(directory)
                messages = [
                    {"uid": 1, "flags": [], "labels": ["INBOX"], "raw": "Message-ID: <one@example.test>\r\nSubject: one\r\n\r\none\r\n"},
                    {"uid": 4, "flags": [], "labels": ["INBOX"], "raw": "Message-ID: <four@example.test>\r\nSubject: four\r\n\r\nfour\r\n"},
                    {"uid": 9, "flags": [], "labels": ["INBOX"], "raw": "Message-ID: <nine@example.test>\r\nSubject: nine\r\n\r\nnine\r\n"},
                ]
                (root / "mailbox.json").write_text(json.dumps({"uidValidity": 11, "nextUID": 10, "messages": messages}), encoding="utf-8")
                old_state = fixture.STATE
                fixture.STATE = root / "mailbox.json"
                old_environment = os.environ.copy()
                os.environ["PLAINPOST_ACCEPTANCE_IMAP_UIDEXPUNGE"] = "1"
                mail_state.configure_root(root)
                server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
                writer = None
                try:
                    reader, writer = await asyncio.open_connection("127.0.0.1", server.sockets[0].getsockname()[1])
                    await reader.readline()
                    writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\n')
                    writer.write(b'B UID EXPUNGE 4\r\n')
                    await writer.drain()
                    self.assertEqual(await reader.readline(), b"A OK LOGIN\r\n")
                    self.assertEqual(await reader.readline(), b"B OK UID EXPUNGE\r\n")
                    self.assertEqual(mail_state.read()["messages"], [messages[0], messages[2]])
                finally:
                    if writer is not None:
                        writer.close()
                        await writer.wait_closed()
                    server.close()
                    await server.wait_closed()
                    os.environ.clear()
                    os.environ.update(old_environment)
                    fixture.STATE = old_state

        asyncio.run(exercise())

    def test_imap_literal_delay_is_bounded_and_phase_observed(self):
        with TemporaryDirectory() as directory:
            mail_state.configure_root(Path(directory))
            mail_state.configure_phase("imap", "header-fetch", 1, "delay", 25)
            started = time.monotonic()
            self.assertEqual(mail_state.phase("imap", "header-fetch"), 1)
            self.assertGreaterEqual(time.monotonic() - started, 0.02)
            self.assertLess(time.monotonic() - started, 0.5)

    def test_imap_attachment_classifier_matches_production_inline_and_rfc2231_rules(self):
        cases = (
            ('Content-Disposition: inline; filename="inline.bin"\r\n', True),
            ('Content-ID: <logo@example.test>\r\n', True),
            ('Content-Type: application/octet-stream; name*=utf-8\'\'r%C3%A9sum%C3%A9.bin\r\n', True),
            ('Content-Disposition: inline; filename*=utf-8\'\'inline.bin\r\n', True),
            ('Content-Type: message/rfc822\r\n', True),
            ('Content-Type: text/plain; charset=utf-8\r\n', False),
        )
        for leaf_headers, expected in cases:
            with self.subTest(headers=leaf_headers):
                raw = "Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\n" + leaf_headers + "\r\nbody\r\n--x--\r\n"
                self.assertEqual(_imap_attachment_path(raw, "1"), expected)

    def test_authentication_accepts_quoted_wire_login_arguments(self):
        arguments = parse_imap_arguments('"acceptance@example.test" "acceptance-password"')
        self.assertEqual(arguments, ["acceptance@example.test", "acceptance-password"])
        self.assertTrue(authenticated(arguments))

    def test_authentication_rejects_wrong_credentials(self):
        self.assertFalse(authenticated(parse_imap_arguments('"acceptance@example.test" "wrong"')))

    def test_smtp_authentication_validates_plain_payload(self):
        import base64

        payload = base64.b64encode(b"\x00acceptance@example.test\x00acceptance-password").decode("ascii")
        self.assertTrue(smtp_authenticated(f"AUTH PLAIN {payload}"))
        wrong = base64.b64encode(b"\x00acceptance@example.test\x00wrong").decode("ascii")
        self.assertFalse(smtp_authenticated(f"AUTH PLAIN {wrong}"))

    def test_typed_smtp_faults_accept_only_bounded_result_classes(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            mail_state.arm_fault("smtp-recipient-550", 1, "rejected")
            self.assertEqual(mail_state.trigger_fault("smtp-recipient-550"), "rejected")
            with self.assertRaises(ValueError):
                mail_state.arm_fault("smtp-unlisted", 1, "rejected")
            with self.assertRaises(ValueError):
                mail_state.arm_fault("smtp-recipient-451", 1, "arbitrary")
            with self.assertRaises(ValueError):
                mail_state.arm_fault("smtp-after-354", 1, "temporary")
            for name in ("smtp-delivery", "imap-mutation", "provider-transition", "projection"):
                with self.assertRaises(ValueError):
                    mail_state.arm_fault(name, 1, "truncated")
            for result_class in ("truncated", "accepted", "rejected"):
                with self.assertRaises(ValueError):
                    mail_state.arm_fault("imap-sent-append", 1, result_class)

    def test_imap_fetch_metadata_and_lazy_body_share_message_bytes(self):
        raw = "Subject: Unicode é\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nBody é\r\n"
        headers, body = message_sections(raw)
        self.assertEqual(headers, "Subject: Unicode é\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n")
        self.assertEqual(body, "Body é\r\n")
        self.assertIn(f' {len(body.encode("utf-8"))} 1 NIL NIL NIL)', bodystructure_for(raw))

    def test_provider_transition_assigns_a_canonical_message_id(self):
        with TemporaryDirectory() as directory:
            previous_state = fixture.STATE
            fixture.STATE = Path(directory) / "mailbox.json"
            try:
                fixture.STATE.write_text('{"uidValidity": 1, "nextUID": 1, "messages": []}', encoding="utf-8")
                fixture.provider_transition()
                state = fixture.read_state()
            finally:
                fixture.STATE = previous_state
        self.assertIn("Message-ID: <provider-transition-1@example.test>", state["messages"][0]["raw"])
        self.assertIn("From: acceptance@example.test", state["messages"][0]["raw"])
        self.assertIn("To: recipient@example.test", state["messages"][0]["raw"])

    def test_append_request_requires_bounded_literal_and_preserves_destination(self):
        self.assertEqual(parse_append_request('"Drafts" (\\Draft) {42}'), ("Drafts", 42))
        self.assertIsNone(parse_append_request('"Drafts" {not-a-size}'))

    def test_search_message_id_is_limited_to_selected_mailbox(self):
        state = {
            "messages": [
                {"uid": 1, "labels": ["INBOX"], "raw": "Message-ID: <one@example.test>\r\n\r\nbody"},
                {"uid": 2, "labels": ["Sent"], "raw": "Message-ID: <one@example.test>\r\n\r\nbody"},
            ]
        }
        self.assertEqual(search_message_uids(state, "Sent", 'HEADER Message-ID "<one@example.test>"'), [2])
        self.assertEqual(search_message_uids(state, "INBOX", "ALL"), [1])

    def test_move_removes_selected_mailbox_and_adds_destination(self):
        state = {
            "messages": [
                {"uid": 1, "labels": ["Archive"], "raw": "Subject: retained\r\n\r\nbody"},
            ]
        }

        self.assertTrue(move_message(state, "Archive", "Trash", 1))
        self.assertEqual(state["messages"][0]["labels"], ["Trash"])

    def test_multipart_bodystructure_and_part_fetch_preserve_encoded_attachment(self):
        raw = (
            'Content-Type: multipart/mixed; boundary="fixture-boundary"\r\n\r\n'
            '--fixture-boundary\r\n'
            'Content-Type: text/plain; charset=utf-8\r\n\r\n'
            'Body\r\n'
            '--fixture-boundary\r\n'
            'Content-Type: application/octet-stream; name="fixture.bin"\r\n'
            'Content-Transfer-Encoding: base64\r\n'
            'Content-Disposition: attachment; filename="fixture.bin"\r\n\r\n'
            'Rml4dHVyZQ==\r\n'
            '--fixture-boundary--\r\n'
        )

        structure = bodystructure_for(raw)
        self.assertIn('"APPLICATION" "OCTET-STREAM"', structure)
        self.assertEqual(multipart_part_body(raw, "2"), "Rml4dHVyZQ==")

    def test_full_body_fetch_preserves_multipart_container_for_sync_parser(self):
        raw = (
            'Content-Type: multipart/mixed; boundary="fixture-boundary"\r\n\r\n'
            '--fixture-boundary\r\n'
            'Content-Type: text/plain; charset=utf-8\r\n\r\n'
            'Body\r\n'
            '--fixture-boundary\r\n'
            'Content-Type: application/octet-stream; name="fixture.bin"\r\n'
            'Content-Transfer-Encoding: base64\r\n'
            'Content-Disposition: attachment; filename="fixture.bin"\r\n\r\n'
            'Rml4dHVyZQ==\r\n'
            '--fixture-boundary--\r\n'
        )

        self.assertEqual(fetch_body_payload(raw, ""), raw)

    def test_nested_multipart_bodystructure_exposes_display_leaves(self):
        raw = (
            'Message-ID: <acceptance-one@example.test>\r\n'
            'Subject: Plainpost acceptance é\r\n'
            'Content-Type: multipart/mixed; boundary="outer"\r\n\r\n'
            '--outer\r\n'
            'Content-Type: multipart/alternative; boundary="alternative"\r\n\r\n'
            '--alternative\r\n'
            'Content-Type: text/plain; charset=utf-8\r\n'
            'Content-Transfer-Encoding: 8bit\r\n\r\n'
            'Unicode acceptance é body\r\n'
            '--alternative\r\n'
            'Content-Type: text/html; charset=utf-8\r\n'
            'Content-Transfer-Encoding: 8bit\r\n\r\n'
            '<p>Unicode <strong>acceptance</strong> é body</p>\r\n'
            '--alternative--\r\n'
            '--outer\r\n'
            'Content-Type: application/octet-stream; name="fixture.bin"\r\n'
            'Content-Transfer-Encoding: base64\r\n'
            'Content-Disposition: attachment; filename="fixture.bin"\r\n\r\n'
            'Rml4dHVyZQ==\r\n'
            '--outer--\r\n'
        )

        structure = bodystructure_for(raw)
        self.assertEqual(
            structure,
            '((("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "8BIT" 26 1 NIL NIL NIL NIL) '
            '("TEXT" "HTML" ("CHARSET" "utf-8") NIL NIL "8BIT" 50 1 NIL NIL NIL NIL) '
            '"ALTERNATIVE" ("BOUNDARY" "alternative") NIL NIL) '
            '("APPLICATION" "OCTET-STREAM" ("NAME" "fixture.bin") NIL NIL "BASE64" 7 NIL '
            '("ATTACHMENT" ("FILENAME" "fixture.bin")) NIL NIL) '
            '"MIXED" ("BOUNDARY" "outer") NIL NIL)',
        )
        self.assertEqual(multipart_part_body(raw, "1.1"), "Unicode acceptance é body")
        self.assertEqual(multipart_part_body(raw, "1.2"), "<p>Unicode <strong>acceptance</strong> é body</p>")
        self.assertEqual(multipart_part_body(raw, "2"), "Rml4dHVyZQ==")

    def test_text_attachment_bodystructure_keeps_text_lines_and_md5_slot(self):
        raw = (
            'Content-Type: multipart/mixed; boundary="outer"\r\n\r\n'
            '--outer\r\n'
            'Content-Type: text/plain; charset=utf-8\r\n'
            'Content-Disposition: attachment; filename="notes.txt"\r\n\r\n'
            'Attached text\r\n'
            '--outer--\r\n'
        )

        self.assertEqual(
            bodystructure_for(raw),
            '(("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "8BIT" 13 1 NIL '
            '("ATTACHMENT" ("FILENAME" "notes.txt")) NIL NIL) '
            '"MIXED" ("BOUNDARY" "outer") NIL NIL)',
        )

    def test_concurrent_state_transactions_preserve_both_mailbox_changes(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            barrier = root / "barrier"
            script = (
                "import os,time; "
                "from plainpost_acceptance_mail_state import transaction; "
                "open(os.environ['BARRIER'],'a').close(); "
                "time.sleep(.15); "
                "transaction(lambda state: state.setdefault('markers', []).append(os.environ['MARKER']))"
            )
            processes = []
            for marker in ("imap", "provider"):
                environment = os.environ | {
                    "PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root),
                    "BARRIER": str(barrier),
                    "MARKER": marker,
                    "PYTHONPATH": str(Path(__file__).parent),
                }
                processes.append(subprocess.Popen(["python3", "-c", script], env=environment))
            for process in processes:
                self.assertEqual(process.wait(timeout=5), 0)
            mail_state.configure_root(root)
            state = mail_state.read()
            self.assertEqual(sorted(state["markers"]), ["imap", "provider"])

    def test_legacy_read_replace_characterization_loses_one_update(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "mailbox.json"
            initial = {"uidValidity": 1, "nextUID": 1, "messages": []}
            path.write_text(json.dumps(initial), encoding="utf-8")
            first = json.loads(path.read_text(encoding="utf-8"))
            second = json.loads(path.read_text(encoding="utf-8"))
            first["messages"].append({"uid": 1, "flags": [], "labels": ["INBOX"], "raw": "first"})
            second["messages"].append({"uid": 2, "flags": [], "labels": ["Sent"], "raw": "second"})
            path.write_text(json.dumps(first), encoding="utf-8")
            path.write_text(json.dumps(second), encoding="utf-8")
            self.assertEqual([message["raw"] for message in json.loads(path.read_text())["messages"]], ["second"])

    def test_armed_fault_occurrence_is_consumed_once_and_observed(self):
        with TemporaryDirectory() as directory:
            mail_state.configure_root(Path(directory))
            mail_state.arm_fault("smtp-delivery", 2, "temporary")
            self.assertIsNone(mail_state.consume_fault("smtp-delivery", 1))
            self.assertEqual(mail_state.consume_fault("smtp-delivery", 2), "temporary")
            self.assertIsNone(mail_state.consume_fault("smtp-delivery", 2))
            observations = mail_state.read()["observations"]
            self.assertEqual(len([item for item in observations if item["kind"] == "fault-fired"]), 1)

    def test_concurrent_duplicate_deliveries_are_retained(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            script = "import os; from plainpost_acceptance_mail_state import record_delivery; record_delivery(os.environ['MESSAGE'])"
            processes = []
            for message in ("Message-ID: <one@example.test>", "Message-ID: <one@example.test>", "Message-ID: <two@example.test>"):
                processes.append(subprocess.Popen(
                    ["python3", "-c", script],
                    env=os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root), "MESSAGE": message, "PYTHONPATH": str(Path(__file__).parent)},
                ))
            for process in processes:
                self.assertEqual(process.wait(timeout=5), 0)
            mail_state.configure_root(root)
            self.assertEqual(sorted(item["message"] for item in mail_state.read()["deliveries"]), [
                "Message-ID: <one@example.test>", "Message-ID: <one@example.test>", "Message-ID: <two@example.test>",
            ])

    def test_every_authoritative_write_repairs_its_projections(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            mail_state.arm_fault("smtp-delivery", 2, "temporary")
            control = json.loads((root / "mail-control.json").read_text(encoding="utf-8"))
            self.assertEqual(control["faults"][0]["seen"], 0)
            mail_state.trigger_fault("smtp-delivery")
            mail_state.trigger_fault("smtp-delivery")
            mail_state.arm_fault("imap-mutation", 1, "disconnect")
            self.assertEqual(mail_state.consume_fault("imap-mutation", 1), "disconnect")
            mail_state.configure_phase("smtp", "delivery", 2, "pause")
            control = json.loads((root / "mail-control.json").read_text(encoding="utf-8"))
            self.assertEqual(control["phases"][0]["action"], "pause")
            mail_state.record_observation("test-observation", "smtp", "delivery", 2, "secret=not-output")
            observations = [json.loads(line) for line in (root / "mail-observations.jsonl").read_text(encoding="utf-8").splitlines()]
            self.assertTrue(any(item["kind"] == "test-observation" for item in observations))
            self.assertTrue(all("secret=not-output" not in json.dumps(item) for item in observations))

    def test_lock_symlink_is_rejected_without_following_target(self):
        with TemporaryDirectory() as directory, TemporaryDirectory() as outside:
            root = Path(directory)
            target = Path(outside) / "outside-lock"
            target.write_text("untouched", encoding="utf-8")
            mail_state.configure_root(root)
            (root / "mail-state.lock").symlink_to(target)
            with self.assertRaises(OSError):
                mail_state.read()
            self.assertEqual(target.read_text(encoding="utf-8"), "untouched")

    def test_phase_counter_table_overrides_stale_metadata_and_survives_restart(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            mail_state.transaction(lambda state: state.update({"phase_counters": [{"protocol": "smtp", "phase": "delivery", "count": 99}]}))
            self.assertEqual(mail_state.phase("smtp", "delivery"), 1)
            snapshot = mail_state.read()
            self.assertEqual(snapshot["phase_counters"], [{"protocol": "smtp", "phase": "delivery", "count": 1}])
            mail_state.initialize()
            self.assertEqual(mail_state.read()["phase_counters"], [{"protocol": "smtp", "phase": "delivery", "count": 1}])

    def test_state_files_and_observations_are_private_and_projection_repairs(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            mail_state.transaction(lambda state: state.update({"markers": ["durable"]}))
            (root / "mailbox.json").write_text("stale", encoding="utf-8")
            mail_state.repair_projections()
            self.assertEqual(mail_state.read()["markers"], ["durable"])
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            for path in (root / "mail-state.sqlite3", root / "mailbox.json", root / "smtp-deliveries.jsonl", root / "mail-state.lock", root / "mail-state-transaction.lock", root / mail_state.WAL_LOCK_NAME, root / "mail-control.json", root / "mail-observations.jsonl"):
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            connection = mail_state._connect()
            try:
                for path in root.glob("mail-state.sqlite3-*"):
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            finally:
                connection.close()

    def test_wal_open_retries_transient_cross_process_errors_then_succeeds(self):
        attempts = []
        sleeps = []

        def execute(statement):
            attempts.append(statement)
            if len(attempts) < 3:
                raise sqlite3.OperationalError("unable to open database file")

        mail_state._enable_wal(execute, sleep=sleeps.append)
        self.assertEqual(attempts, ["PRAGMA journal_mode=WAL"] * 3)
        self.assertEqual(sleeps, [mail_state.WAL_OPEN_RETRY_DELAY_SECONDS] * 2)

    def test_existing_wal_connections_do_not_reenter_mode_transition(self):
        with TemporaryDirectory() as directory:
            mail_state.configure_root(Path(directory))
            mail_state.initialize(repair=False)
            with mock.patch.object(mail_state, "_enable_wal", side_effect=AssertionError("WAL transition repeated")):
                connection = mail_state._connect()
            connection.close()

    def test_cold_connections_serialize_the_single_wal_transition(self):
        with TemporaryDirectory() as directory:
            context = multiprocessing.get_context("fork")
            barrier = context.Barrier(2)
            transition_log = Path(directory) / "wal-transitions.log"
            error_log = Path(directory) / "wal-errors.log"
            processes = [
                context.Process(
                    target=_cold_wal_connection_worker,
                    args=(directory, barrier, str(transition_log), str(error_log)),
                )
                for _ in range(2)
            ]
            for process in processes:
                process.start()
            for process in processes:
                process.join(timeout=15)
            self.assertEqual([process.exitcode for process in processes], [0, 0])
            self.assertEqual(transition_log.read_text(encoding="ascii").splitlines(), ["transition"])
            self.assertFalse(error_log.exists())

    def test_established_wal_hot_connection_does_not_wait_for_transition_lock(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            mail_state.initialize(repair=False)
            lock_path = root / mail_state.WAL_LOCK_NAME
            lock_descriptor = os.open(lock_path, os.O_RDWR)
            try:
                fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
                result_log = root / "hot-result.log"
                process = multiprocessing.get_context("spawn").Process(
                    target=_hot_wal_connection_worker,
                    args=(directory, str(result_log)),
                )
                process.start()
                process.join(timeout=3)
                blocked = process.is_alive()
                if blocked:
                    process.terminate()
                    process.join(timeout=3)
            finally:
                fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
                os.close(lock_descriptor)
            self.assertFalse(blocked, "hot WAL connection waited for transition lock")
            self.assertEqual(process.exitcode, 0)
            self.assertEqual(result_log.read_text(encoding="ascii"), "passed")

    def test_established_wal_connection_never_executes_direct_wal_transition(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            mail_state.initialize(repair=False)
            statements = []
            original_connect = mail_state.sqlite3.connect

            def traced_connect(*args, **kwargs):
                connection = original_connect(*args, **kwargs)
                connection.set_trace_callback(statements.append)
                return connection

            with mock.patch.object(mail_state.sqlite3, "connect", side_effect=traced_connect):
                connection = mail_state._connect()
            connection.close()
            self.assertNotIn(
                "PRAGMA JOURNAL_MODE=WAL",
                [statement.strip().upper() for statement in statements],
            )

    def test_cold_connection_failure_releases_transition_lock(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            original_connect = mail_state.sqlite3.connect
            database = root / "mail-state.sqlite3"
            connection = original_connect(database, isolation_level=None)
            connection.execute("PRAGMA journal_mode=DELETE")
            connection.close()
            connect_calls = 0

            def fail_fresh_cold_open(*args, **kwargs):
                nonlocal connect_calls
                connect_calls += 1
                if connect_calls == 1:
                    return original_connect(*args, **kwargs)
                raise RuntimeError("fresh cold connection failed")

            with mock.patch.object(mail_state.sqlite3, "connect", side_effect=fail_fresh_cold_open):
                with self.assertRaisesRegex(RuntimeError, "fresh cold connection failed"):
                    mail_state._connect()
            self.assertEqual(connect_calls, 2)
            lock_descriptor = os.open(root / mail_state.WAL_LOCK_NAME, os.O_RDWR)
            try:
                fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
            finally:
                os.close(lock_descriptor)

    def test_connect_closes_connection_when_setup_fails_after_open(self):
        with TemporaryDirectory() as directory:
            mail_state.configure_root(Path(directory))
            mail_state.initialize(repair=False)
            original_connect = mail_state.sqlite3.connect
            closed = []

            class TrackingConnection(sqlite3.Connection):
                def close(self):
                    closed.append(True)
                    return super().close()
                def executescript(self, script):
                    raise RuntimeError("setup failed")

            def tracked_connect(*args, **kwargs):
                kwargs["factory"] = TrackingConnection
                return original_connect(*args, **kwargs)

            with mock.patch.object(mail_state.sqlite3, "connect", side_effect=tracked_connect):
                with self.assertRaisesRegex(RuntimeError, "setup failed"):
                    mail_state._connect()
            self.assertEqual(closed, [True])

    def test_wal_open_retries_persistent_transient_error_only_to_bound(self):
        attempts = []
        sleeps = []

        def execute(_statement):
            attempts.append(True)
            raise sqlite3.OperationalError("database is locked")

        with self.assertRaisesRegex(sqlite3.OperationalError, "database is locked"):
            mail_state._enable_wal(execute, sleep=sleeps.append)
        self.assertEqual(len(attempts), mail_state.WAL_OPEN_RETRY_ATTEMPTS)
        self.assertEqual(len(sleeps), mail_state.WAL_OPEN_RETRY_ATTEMPTS - 1)

    def test_wal_open_does_not_retry_unrelated_operational_errors(self):
        attempts = []
        sleeps = []

        def execute(_statement):
            attempts.append(True)
            raise sqlite3.OperationalError("disk I/O error")

        with self.assertRaisesRegex(sqlite3.OperationalError, "disk I/O error"):
            mail_state._enable_wal(execute, sleep=sleeps.append)
        self.assertEqual(len(attempts), 1)
        self.assertEqual(sleeps, [])

    def test_wal_open_does_not_retry_when_fixture_paths_are_invalid(self):
        attempts = []
        sleeps = []

        def execute(_statement):
            attempts.append(True)
            raise sqlite3.OperationalError("unable to open database file")

        with self.assertRaisesRegex(sqlite3.OperationalError, "unable to open database file"):
            mail_state._enable_wal(execute, sleep=sleeps.append, paths_valid=lambda: False)
        self.assertEqual(len(attempts), 1)
        self.assertEqual(sleeps, [])

    def test_every_declared_crash_boundary_preserves_authority_and_startup_repairs(self):
        script = "from plainpost_acceptance_mail_state import transaction; transaction(lambda state: (state.__setitem__('nextUID', 2), state['messages'].append({'uid': 1, 'flags': [], 'labels': ['INBOX'], 'raw': 'boundary'})))"
        for boundary in mail_state.FAILPOINTS:
            with self.subTest(boundary=boundary), TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "mailbox.json").write_text('{"uidValidity":1,"nextUID":1,"messages":[]}', encoding="utf-8")
                environment = os.environ | {
                    "PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root),
                    "PLAINPOST_ACCEPTANCE_MAIL_FAILPOINT": boundary,
                    "PYTHONPATH": str(Path(__file__).parent),
                }
                process = subprocess.Popen(["python3", "-c", script], env=environment)
                self.assertEqual(process.wait(timeout=5), 97)
                environment.pop("PLAINPOST_ACCEPTANCE_MAIL_FAILPOINT", None)
                mail_state.configure_root(root)
                before = mail_state.read()
                if boundary == "transaction-before-commit":
                    self.assertEqual(before["messages"], [])
                mail_state.initialize()
                after = mail_state.read()
                if boundary != "transaction-before-commit":
                    self.assertEqual(len(after["messages"]), 1)
                mailbox = json.loads((root / "mailbox.json").read_text(encoding="utf-8"))
                self.assertEqual(mailbox["messages"], after["messages"])
                deliveries = [json.loads(line) for line in (root / "smtp-deliveries.jsonl").read_text(encoding="utf-8").splitlines()]
                self.assertEqual(deliveries, [{"message": item["message"]} for item in after["deliveries"]])
                control = json.loads((root / "mail-control.json").read_text(encoding="utf-8"))
                self.assertEqual(control["faults"], after["faults"])
                self.assertEqual(control["phases"], after["phases"])
                self.assertEqual(control["phase_counters"], after["phase_counters"])
                observations = [json.loads(line) for line in (root / "mail-observations.jsonl").read_text(encoding="utf-8").splitlines()]
                self.assertEqual(observations, [{key: item[key] for key in ("kind", "protocol", "phase", "occurrence", "detail_digest")} for item in after["observations"]])

    def test_observation_detail_is_digest_only(self):
        with TemporaryDirectory() as directory:
            mail_state.configure_root(Path(directory))
            secret = "smtp-password=never-render-this"
            mail_state.record_observation("fault-fired", "smtp", "delivery", 2, secret)
            observation = mail_state.read()["observations"][-1]
            self.assertNotIn(secret, json.dumps(observation))
            self.assertRegex(observation["detail_digest"], r"^[0-9a-f]{64}$")

    def test_direct_control_writes_require_central_fixed_enums(self):
        with TemporaryDirectory() as directory:
            mail_state.configure_root(Path(directory))
            with self.assertRaises(ValueError):
                mail_state.arm_fault("account@example.test", 1, "temporary")
            with self.assertRaises(ValueError):
                mail_state.configure_phase("smtp", "delivery", 1, "credential-token")
            with self.assertRaises(ValueError):
                mail_state.record_observation("arbitrary", "smtp", "delivery", 1, "detail")
            with self.assertRaises(ValueError):
                mail_state.transaction(lambda current: current.update({"messages": [{"uid": 1, "flags": [], "labels": ["account@example.test"], "raw": "x"}]}))

    def test_occurrence_n_is_one_shot_through_typed_control_cli(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            environment = os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root), "PYTHONPATH": str(Path(__file__).parent)}
            control = str(Path(__file__).with_name("plainpost_acceptance_mail_control.py"))
            subprocess.run(["python3", control, "arm-fault", "smtp-delivery", "2", "temporary"], env=environment, check=True, stdout=subprocess.DEVNULL)
            script = "from plainpost_acceptance_mail_state import trigger_fault; print(trigger_fault('smtp-delivery') or 'none')"
            results = []
            for _ in range(4):
                results.append(subprocess.check_output(["python3", "-c", script], env=environment, text=True).strip())
            self.assertEqual(results.count("temporary"), 1)
            status = json.loads(subprocess.check_output(["python3", control, "status"], env=environment, text=True))
            self.assertEqual(status["faults"][0]["seen"], 4)
            self.assertEqual(status["observation_count"], 1)

    def test_second_transaction_reaches_callback_only_after_first_releases_lock(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            reached = root / "first-reached"
            script = (
                "import os,time; from plainpost_acceptance_mail_state import transaction; "
                "transaction(lambda state: (open(os.environ['REACHED'],'a').close(), time.sleep(.4), state.update({'first': True})))"
            )
            environment = os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root), "REACHED": str(reached), "PYTHONPATH": str(Path(__file__).parent)}
            first = subprocess.Popen(["python3", "-c", script], env=environment)
            while not reached.exists():
                time.sleep(.01)
            started = time.monotonic()
            second = subprocess.Popen(["python3", "-c", "from plainpost_acceptance_mail_state import transaction; transaction(lambda state: state.update({'second': True}))"], env=environment)
            self.assertEqual(first.wait(timeout=5), 0)
            self.assertEqual(second.wait(timeout=5), 0)
            self.assertGreater(time.monotonic() - started, .25)
            mail_state.configure_root(root)
            self.assertEqual(mail_state.read()["first"], True)
            self.assertEqual(mail_state.read()["second"], True)

    def test_obsolete_delivery_digest_unique_index_is_removed_but_other_indexes_survive(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            connection = mail_state._connect()
            try:
                connection.execute("CREATE UNIQUE INDEX delivery_digest_unique ON deliveries(message_digest)")
                connection.execute("CREATE UNIQUE INDEX delivery_created_unique ON deliveries(created_at)")
            finally:
                connection.close()
            mail_state.read()
            check = mail_state._connect()
            try:
                indexes = {row[1] for row in check.execute("PRAGMA index_list(deliveries)")}
            finally:
                check.close()
            self.assertNotIn("delivery_digest_unique", indexes)
            self.assertIn("delivery_created_unique", indexes)

    def test_legacy_delivery_upgrade_recomputes_canonical_digest_and_message_id(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            database = root / mail_state.DB_NAME
            raw = "Message-ID: <legacy@example.test>\n\nbody"
            connection = sqlite3.connect(database)
            try:
                connection.execute(
                    "CREATE TABLE deliveries (delivery_id INTEGER PRIMARY KEY AUTOINCREMENT, message_digest TEXT NOT NULL, message TEXT NOT NULL, created_at REAL NOT NULL)"
                )
                connection.execute("CREATE UNIQUE INDEX delivery_digest_unique ON deliveries(message_digest)")
                connection.execute(
                    "INSERT INTO deliveries(message_digest,message,created_at) VALUES(?,?,?)",
                    ("historical-raw-digest", raw, 1.0),
                )
                connection.commit()
            finally:
                connection.close()
            delivery = mail_state.read()["deliveries"][0]
            self.assertEqual(delivery["canonical_digest"], mail_state.canonical_digest(raw))
            self.assertEqual(delivery["message_id"], "<legacy@example.test>")

    def test_concurrent_initialize_migrates_schema_without_alter_race(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / mail_state.DB_NAME
            connection = sqlite3.connect(database)
            try:
                connection.executescript(
                    """
                    CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE messages (uid INTEGER PRIMARY KEY, flags TEXT NOT NULL, labels TEXT NOT NULL, raw TEXT NOT NULL);
                    CREATE TABLE deliveries (delivery_id INTEGER PRIMARY KEY AUTOINCREMENT, message_digest TEXT NOT NULL, message TEXT NOT NULL, created_at REAL NOT NULL);
                    CREATE TABLE faults (name TEXT PRIMARY KEY, occurrence INTEGER NOT NULL, result_class TEXT NOT NULL, consumed INTEGER NOT NULL DEFAULT 0);
                    CREATE TABLE phases (protocol TEXT NOT NULL, phase TEXT NOT NULL, occurrence INTEGER NOT NULL, action TEXT NOT NULL, PRIMARY KEY(protocol, phase, occurrence));
                    CREATE TABLE phase_counters (protocol TEXT NOT NULL, phase TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(protocol, phase));
                    CREATE TABLE observations (sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, protocol TEXT NOT NULL, phase TEXT NOT NULL, occurrence INTEGER NOT NULL, detail_digest TEXT NOT NULL);
                    """
                )
                connection.commit()
            finally:
                connection.close()
            go = root / "initialize.go"
            environment = os.environ | {
                "PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root),
                "PYTHONPATH": str(Path(__file__).parent),
                "PLAINPOST_ACCEPTANCE_MAIL_INITIALIZE_GO": str(go),
            }
            script = (
                "import os,time\n"
                "from pathlib import Path\n"
                "while not Path(os.environ['PLAINPOST_ACCEPTANCE_MAIL_INITIALIZE_GO']).exists(): time.sleep(.001)\n"
                "from plainpost_acceptance_mail_state import configure_root, initialize\n"
                "configure_root(Path(os.environ['PLAINPOST_ACCEPTANCE_MAIL_ROOT'])); initialize(repair=False)\n"
            )
            processes = [subprocess.Popen(["python3", "-c", script], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(12)]
            try:
                go.touch(mode=0o600)
                failures = []
                for process in processes:
                    stdout, stderr = process.communicate(timeout=10)
                    if process.returncode != 0:
                        failures.append((process.returncode, stdout, stderr))
                self.assertEqual(failures, [])
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill()
                        process.wait()

    def test_schema_alter_operations_are_inside_one_migration_transaction(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / mail_state.DB_NAME
            connection = sqlite3.connect(database)
            try:
                connection.executescript(
                    """
                    CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE messages (uid INTEGER PRIMARY KEY, flags TEXT NOT NULL, labels TEXT NOT NULL, raw TEXT NOT NULL);
                    CREATE TABLE deliveries (delivery_id INTEGER PRIMARY KEY AUTOINCREMENT, message_digest TEXT NOT NULL, message TEXT NOT NULL, created_at REAL NOT NULL);
                    CREATE TABLE faults (name TEXT PRIMARY KEY, occurrence INTEGER NOT NULL, result_class TEXT NOT NULL, consumed INTEGER NOT NULL DEFAULT 0);
                    CREATE TABLE phases (protocol TEXT NOT NULL, phase TEXT NOT NULL, occurrence INTEGER NOT NULL, action TEXT NOT NULL, PRIMARY KEY(protocol, phase, occurrence));
                    CREATE TABLE phase_counters (protocol TEXT NOT NULL, phase TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(protocol, phase));
                    CREATE TABLE observations (sequence INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, protocol TEXT NOT NULL, phase TEXT NOT NULL, occurrence INTEGER NOT NULL, detail_digest TEXT NOT NULL);
                    """
                )
                connection.commit()
            finally:
                connection.close()
            original_connect = sqlite3.connect
            outside_transaction = []

            class TracingConnection(sqlite3.Connection):
                def execute(self, sql, parameters=()):
                    if sql.lstrip().upper().startswith("ALTER TABLE") and not self.in_transaction:
                        outside_transaction.append(sql)
                    return super().execute(sql, parameters)

            def traced_connect(*arguments, **keywords):
                keywords["factory"] = TracingConnection
                return original_connect(*arguments, **keywords)

            with mock.patch.object(mail_state.sqlite3, "connect", traced_connect):
                mail_state.configure_root(root)
                mail_state.initialize(repair=False)
            self.assertEqual(outside_transaction, [])

    def test_status_is_privacy_safe_and_has_no_raw_authority_dump(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            sentinel = "sentinel-body-must-not-reach-status"
            mail_state.transaction(lambda state: state["messages"].append({"uid": 1, "flags": [], "labels": ["INBOX"], "raw": sentinel}))
            control = str(Path(__file__).with_name("plainpost_acceptance_mail_control.py"))
            environment = os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root)}
            status = subprocess.check_output(["python3", control, "status"], env=environment, text=True)
            self.assertNotIn(sentinel, status)
            self.assertIn("raw_digest", status)

    def test_append_matrix_message_control_is_typed_and_persistent(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            mail_state.initialize(repair=False)
            control = str(Path(__file__).with_name("plainpost_acceptance_mail_control.py"))
            output = subprocess.check_output(
                ["python3", control, "append-matrix-message"],
                env=os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root)},
                text=True,
            )
            self.assertEqual(json.loads(output)["operation"], "append-matrix-message")
            snapshot = mail_state.read()
            self.assertEqual(len(snapshot["messages"]), 1)
            self.assertEqual(snapshot["messages"][0]["labels"], ["INBOX"])
            self.assertEqual(snapshot["messages"][0]["uid"], 1)
            self.assertNotIn("IMAP matrix transition body", output)

    def test_status_does_not_emit_delivery_identity_or_envelope_values(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            message = b"Message-ID: <sentinel-message-id@example.test>\n\nbody"
            mail_state.record_delivery(
                message,
                tls_active=True,
                authenticated=True,
                envelope_sender="sentinel-sender@example.test",
                envelope_recipients=["sentinel-recipient@example.test"],
            )
            control = str(Path(__file__).with_name("plainpost_acceptance_mail_control.py"))
            status = subprocess.check_output(
                ["python3", control, "status"],
                env=os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root)},
                text=True,
            )
            self.assertNotIn("sentinel-message-id@example.test", status)
            self.assertNotIn("sentinel-sender@example.test", status)
            self.assertNotIn("sentinel-recipient@example.test", status)
            self.assertIn("message_id_digest", status)

    def test_status_does_not_emit_arbitrary_message_flags(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            connection = mail_state._connect()
            try:
                connection.execute("INSERT INTO messages(uid,flags,labels,raw) VALUES(1,?,?,?)", (json.dumps(["flag-secret@example.test"]), json.dumps(["INBOX"]), "safe"))
            finally:
                connection.close()
            control = str(Path(__file__).with_name("plainpost_acceptance_mail_control.py"))
            status = subprocess.check_output(["python3", control, "status"], env=os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root)}, text=True)
            self.assertNotIn("flag-secret@example.test", status)

    def test_transaction_lock_is_released_when_database_open_fails(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            original_connect = mail_state._connect
            mail_state._connect = lambda: (_ for _ in ()).throw(OSError("forced open failure"))
            try:
                with self.assertRaises(OSError):
                    mail_state._run_transaction(lambda _connection, _state: None)
            finally:
                mail_state._connect = original_connect
            environment = os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root), "PYTHONPATH": str(Path(__file__).parent)}
            process = subprocess.Popen(["python3", "-c", "from plainpost_acceptance_mail_state import transaction; transaction(lambda state: state.update({'after_failure': True}))"], env=environment)
            try:
                self.assertEqual(process.wait(timeout=2), 0)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                self.fail("transaction lock remained held after database open failure")

    def test_probe_stops_and_reaps_before_reading_timeout_output(self):
        class Process:
            returncode = None
            stdout = None
            terminated = False
            waited = False

            def poll(self):
                return self.returncode

            def terminate(self):
                self.terminated = True
                self.returncode = -15

            def wait(self, timeout=None):
                self.waited = True
                return self.returncode

            def communicate(self, timeout=None):
                self.assert_order()
                return ("captured", "")

            def assert_order(self):
                if not self.terminated or not self.waited:
                    raise AssertionError("output was read before process termination and reap")

        process = Process()
        self.assertEqual(docker_probe.stop_process(process), "captured")

    def test_phase_occurrence_two_is_reached_then_resumed_and_disconnects(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            environment = os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root), "PYTHONPATH": str(Path(__file__).parent)}
            control = str(Path(__file__).parent / "plainpost_acceptance_mail_control.py")
            subprocess.run(["python3", control, "phase", "smtp", "delivery", "2", "pause"], env=environment, check=True, stdout=subprocess.DEVNULL)
            script = "from plainpost_acceptance_mail_state import phase; phase('smtp','delivery'); phase('smtp','delivery')"
            process = subprocess.Popen(["python3", "-c", script], env=environment)
            reached = subprocess.run(["python3", control, "wait-phase", "smtp", "delivery", "2", "--timeout-ms", "5000"], env=environment, check=True, capture_output=True, text=True)
            self.assertIn('"occurrence":2', reached.stdout)
            control_state = json.loads(subprocess.check_output(["python3", control, "status"], env=environment, text=True))
            self.assertEqual(control_state["phase_counters"], [{"protocol": "smtp", "phase": "delivery", "count": 2}])
            observations = control_state["observations"]
            self.assertTrue(any(item["occurrence"] == 2 for item in observations))
            subprocess.run(["python3", control, "phase", "smtp", "delivery", "2", "resume"], env=environment, check=True, stdout=subprocess.DEVNULL)
            self.assertEqual(process.wait(timeout=5), 0)
            subprocess.run(["python3", control, "phase", "smtp", "delivery", "3", "disconnect"], env=environment, check=True, stdout=subprocess.DEVNULL)
            disconnect = subprocess.run(["python3", "-c", script + "; phase('smtp','delivery')"], env=environment)
            self.assertNotEqual(disconnect.returncode, 0)

    def test_disconnected_imap_mutation_releases_barrier_without_store_commit(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            mail_state.configure_phase("imap", "mutation", 1, "disconnect")
            environment = os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root), "PYTHONPATH": str(Path(__file__).parent)}
            script = (
                "from plainpost_acceptance_mail_state import phase, transaction; "
                "phase('imap', 'mutation'); "
                "transaction(lambda state: state.update({'store_continued': True}))"
            )
            process = subprocess.run(["python3", "-c", script], env=environment, capture_output=True, text=True, check=False)
            self.assertNotEqual(process.returncode, 0)
            self.assertNotIn("store_continued", mail_state.read())

            control = str(Path(__file__).with_name("plainpost_acceptance_mail_control.py"))
            released = subprocess.run(
                ["python3", control, "wait-phase-release", "imap", "mutation", "1", "--timeout-ms", "2000"],
                env=environment, capture_output=True, text=True, check=False,
            )
            self.assertEqual(released.returncode, 0, released.stderr)

    def test_wait_phase_release_waits_for_transaction_lock_to_unwind(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            mail_state.observe_phase("imap", "mutation", 1)
            descriptor = os.open(root / mail_state.TRANSACTION_LOCK_NAME, os.O_RDWR)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            result = []
            errors = []

            def wait_for_release():
                try:
                    result.append(mail_state.wait_for_phase_release("imap", "mutation", 1, 2000))
                except BaseException as error:
                    errors.append(error)

            waiter = threading.Thread(target=wait_for_release)
            waiter.start()
            time.sleep(0.1)
            self.assertEqual(result, [])
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
            waiter.join(timeout=2)
            self.assertEqual(errors, [])
            self.assertEqual(result, [{"operation": "wait-phase-release", "protocol": "imap", "phase": "mutation", "occurrence": 1}])


class ProtocolConcurrencyTests(unittest.IsolatedAsyncioTestCase):
    async def test_concurrent_truncated_literals_assign_framing_to_one_owner(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            raw = "Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=x.bin\r\n\r\nbody\r\n--x--\r\n"
            payload = b"body"
            (root / "mailbox.json").write_text(json.dumps({"uidValidity": 1, "nextUID": 2, "messages": [{"uid": 1, "flags": [], "labels": ["INBOX"], "raw": raw}]}), encoding="utf-8")
            old_state = fixture.STATE
            fixture.STATE = root / "mailbox.json"
            mail_state.configure_root(root)
            mail_state.arm_fault("imap-truncated-literal", 1, "truncated")
            server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]

            async def fetch() -> int:
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                try:
                    await reader.readline()
                    writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\nB UID FETCH 1 (BODY.PEEK[1])\r\n')
                    await writer.drain()
                    await reader.readline()
                    await reader.readuntil(b"{")
                    size_line = await reader.readuntil(b"}\r\n")
                    return int(size_line[:-3])
                finally:
                    writer.close()
                    await writer.wait_closed()

            try:
                results = await asyncio.gather(fetch(), fetch())
                self.assertEqual(sorted(results), [len(payload), len(payload) + 1])
                fault = next(item for item in mail_state.read()["faults"] if item["name"] == "imap-truncated-literal")
                self.assertEqual((fault["seen"], fault["consumed"]), (2, 1))
            finally:
                server.close()
                await server.wait_closed()
                fixture.STATE = old_state

    async def test_sent_append_fault_targets_sent_after_drafts_append(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mailbox = root / "mailbox.json"
            mailbox.write_text('{"uidValidity":1,"nextUID":1,"messages":[]}', encoding="utf-8")
            old_state = fixture.STATE
            fixture.STATE = mailbox
            mail_state.configure_root(root)
            mail_state.arm_fault("imap-sent-append", 1, "temporary")
            mail_state.configure_phase("imap", "sent-append", 1, "continue")
            server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]

            async def append(destination: str, message_id: str) -> bytes:
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                await reader.readline()
                writer.write(b'A LOGIN "acceptance@example.test" "acceptance-password"\r\n')
                await writer.drain(); await reader.readline()
                payload = f"Message-ID: <{message_id}>\r\n\r\nbody\r\n".encode()
                writer.write(f'B APPEND "{destination}" {{{len(payload)}}}\r\n'.encode())
                await writer.drain(); await reader.readline()
                writer.write(payload + b"\r\n"); await writer.drain()
                response = await reader.readline()
                writer.close(); await writer.wait_closed()
                return response

            try:
                drafts = await append("Drafts", "draft-before-sent")
                sent = await append("Sent", "sent-fault")
                state = mail_state.read()
                self.assertTrue(drafts.startswith(b"B OK"))
                self.assertTrue(sent.startswith(b"B NO TEMPORARY"))
                self.assertEqual(state["faults"][0]["seen"], 1)
                self.assertEqual(state["faults"][0]["consumed"], 1)
                self.assertEqual([message["labels"] for message in state["messages"]], [["Drafts"]])
                observations = state["observations"]
                sent_phase = next(index for index, item in enumerate(observations) if item["kind"] == "phase-reached" and item["protocol"] == "imap" and item["phase"] == "sent-append")
                fault = next(index for index, item in enumerate(observations) if item["kind"] == "fault-fired" and item["protocol"] == "imap-sent-append")
                self.assertLess(sent_phase, fault)
            finally:
                server.close(); await server.wait_closed(); fixture.STATE = old_state

    async def test_concurrent_provider_transition_and_imap_append_preserve_both(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "mailbox.json").write_text('{"uidValidity":1,"nextUID":1,"messages":[]}', encoding="utf-8")
            old_state = fixture.STATE
            fixture.STATE = root / "mailbox.json"
            server = await asyncio.start_server(fixture.imap, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]
            environment = os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root), "PYTHONPATH": str(Path(__file__).parent)}

            async def append() -> None:
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                await reader.readline()
                writer.write(b"A LOGIN \"acceptance@example.test\" \"acceptance-password\"\r\n"); await writer.drain(); await reader.readline()
                payload = b"Message-ID: <imap-concurrent@example.test>\r\n\r\nbody\r\n"
                writer.write(f"B APPEND \"INBOX\" {{{len(payload)}}}\r\n".encode()); await writer.drain(); await reader.readline()
                writer.write(payload + b"\r\n"); await writer.drain(); self.assertTrue((await reader.readline()).startswith(b"B OK"))
                writer.close(); await writer.wait_closed()

            async def transition() -> None:
                process = await asyncio.create_subprocess_exec("python3", str(Path(__file__).parent / "plainpost_acceptance_mail_fixture.py"), "transition", env=environment)
                self.assertEqual(await process.wait(), 0)

            try:
                await asyncio.gather(append(), transition())
                fixture.authority.configure_root(root)
                messages = fixture.authority.read()["messages"]
                self.assertEqual(len(messages), 2)
                self.assertEqual(sorted(message["uid"] for message in messages), [1, 2])
            finally:
                server.close(); await server.wait_closed(); fixture.STATE = old_state


class SMTPStartTLSTests(unittest.IsolatedAsyncioTestCase):
    class _ScriptedReader:
        def __init__(self, lines):
            self.lines = iter(lines)

        async def readline(self):
            return next(self.lines, b"")

    class _RecordingWriter:
        def __init__(self):
            self.writes = []
            self.closed = False

        def write(self, value):
            self.writes.append(value)

        async def drain(self):
            pass

        async def start_tls(self, _context, **_kwargs):
            pass

        def close(self):
            self.closed = True

        async def wait_closed(self):
            pass

    async def _run_scripted_smtp(self, root, fault=None, result_class="disconnect", body_lines=None):
        previous_deliveries = fixture.DELIVERIES
        fixture.DELIVERIES = root / "smtp-deliveries.jsonl"
        mail_state.configure_root(root)
        if fault:
            mail_state.arm_fault(fault, 1, result_class)
        import base64
        credentials = base64.b64encode(b"\x00acceptance@example.test\x00acceptance-password")
        lines = [
            b"EHLO local\r\n", b"STARTTLS\r\n", b"EHLO local\r\n",
            b"AUTH PLAIN " + credentials + b"\r\n",
            b"MAIL FROM:<sender@example.test>\r\n",
            b"RCPT TO:<recipient@example.test>\r\n", b"DATA\r\n",
            *(body_lines or [b"Message-ID: <typed@example.test>\r\n", b"\r\n", b"body\r\n", b".\r\n"]),
            b"QUIT\r\n",
        ]
        writer = self._RecordingWriter()
        try:
            context = mock.Mock()
            with mock.patch.dict(os.environ, {
                "PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT": "unused-cert",
                "PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY": "unused-key",
            }, clear=False), mock.patch.object(fixture.ssl, "create_default_context", return_value=context):
                await fixture.smtp(self._ScriptedReader(lines), writer)
            return writer, mail_state.read()
        finally:
            fixture.DELIVERIES = previous_deliveries

    async def test_typed_recipient_replies_are_definitive_and_do_not_accept_data(self):
        for fault, status, result_class in (("smtp-recipient-451", b"451 ", "temporary"), ("smtp-recipient-550", b"550 ", "rejected")):
            with self.subTest(fault=fault):
                with TemporaryDirectory() as directory:
                    writer, state = await self._run_scripted_smtp(Path(directory), fault=fault, result_class=result_class)
                    self.assertTrue(any(value.startswith(status) for value in writer.writes))
                    self.assertEqual(state["deliveries"], [])

    async def test_typed_data_disconnects_preserve_uncertainty_boundary(self):
        for fault in ("smtp-after-354", "smtp-mid-data"):
            with self.subTest(fault=fault):
                with TemporaryDirectory() as directory:
                    _, state = await self._run_scripted_smtp(Path(directory), fault=fault)
                    self.assertEqual(state["deliveries"], [])
        with TemporaryDirectory() as directory:
            _, state = await self._run_scripted_smtp(Path(directory), fault="smtp-final-reply")
            self.assertEqual(len(state["deliveries"]), 1)
            self.assertTrue(any(item["phase"] == "acceptance-before-append" for item in state["observations"]))

    async def test_smtp_authentication_command_is_observed_separately_from_tls_authentication(self):
        with TemporaryDirectory() as directory:
            _, state = await self._run_scripted_smtp(Path(directory))
            command = next((item for item in state["observations"] if item["phase"] == "authentication-command"), None)
            authentication = next((item for item in state["observations"] if item["phase"] == "authentication"), None)
            self.assertIsNotNone(command)
            self.assertIsNotNone(authentication)
            self.assertEqual(command["protocol"], "smtp")
            self.assertEqual(command["occurrence"], 1)
            self.assertLess(command["sequence"], authentication["sequence"])

    async def test_pre_tls_authentication_command_is_observed_and_rejected(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            previous_deliveries = fixture.DELIVERIES
            fixture.DELIVERIES = root / "smtp-deliveries.jsonl"
            try:
                mail_state.configure_root(root)
                writer = self._RecordingWriter()
                import base64
                credentials = base64.b64encode(b"\x00acceptance@example.test\x00acceptance-password")
                await fixture.smtp(self._ScriptedReader([b"EHLO local\r\n", b"AUTH PLAIN " + credentials + b"\r\n"]), writer)
                self.assertIn(b"530 5.7.0 Must issue STARTTLS first\r\n", writer.writes)
                observations = mail_state.read()["observations"]
                commands = [item for item in observations if item["phase"] == "authentication-command"]
                authentications = [item for item in observations if item["phase"] == "authentication"]
                self.assertEqual(len(commands), 1)
                self.assertEqual(authentications, [])
            finally:
                fixture.DELIVERIES = previous_deliveries

    async def test_unauthenticated_quit_does_not_consume_authenticated_quit_fault(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            previous_deliveries = fixture.DELIVERIES
            fixture.DELIVERIES = root / "smtp-deliveries.jsonl"
            try:
                mail_state.configure_root(root)
                mail_state.arm_fault("smtp-quit-loss", 1, "disconnect")
                writer = self._RecordingWriter()
                await fixture.smtp(self._ScriptedReader([b"QUIT\r\n"]), writer)
                state = mail_state.read()
                self.assertEqual(state["faults"][0]["seen"], 0)
                self.assertEqual(state["faults"][0]["consumed"], 0)
                self.assertFalse(any(item["phase"] == "quit" for item in state["observations"]))
                self.assertIn(b"221 2.0.0 bye\r\n", writer.writes)
            finally:
                fixture.DELIVERIES = previous_deliveries

        with TemporaryDirectory() as directory:
            _, state = await self._run_scripted_smtp(Path(directory), fault="smtp-quit-loss")
            self.assertEqual(state["faults"][0]["seen"], 1)
            self.assertEqual(state["faults"][0]["consumed"], 1)
            self.assertTrue(any(item["phase"] == "quit" for item in state["observations"]))

    async def test_smtp_process_restart_preserves_starttls_authentication_after_delivery(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            certificate = root / "mail.crt"
            key = root / "mail.key"
            ready = root / "smtp-ready"
            subprocess.run(
                [
                    "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(key), "-out", str(certificate), "-subj", "/CN=localhost", "-days", "1",
                    "-addext", "basicConstraints=critical,CA:TRUE",
                    "-addext", "keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment",
                    "-addext", "subjectAltName=DNS:localhost",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            environment = os.environ | {
                "PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root),
                "PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT": str(certificate),
                "PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY": str(key),
                "PLAINPOST_ACCEPTANCE_MAIL_READY_FILE": str(ready),
                "PYTHONPATH": str(Path(__file__).parent),
            }
            script = str(Path(__file__).parent / "plainpost_acceptance_mail_fixture.py")

            async def start() -> tuple[asyncio.subprocess.Process, int]:
                ready.unlink(missing_ok=True)
                process = await asyncio.create_subprocess_exec(
                    sys.executable, script, "smtp", "0", env=environment,
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                )
                for _ in range(250):
                    if ready.exists():
                        return process, int(ready.read_text(encoding="ascii"))
                    if process.returncode is not None:
                        self.fail("SMTP fixture exited before publishing readiness")
                    await asyncio.sleep(0.02)
                process.kill()
                await process.wait()
                self.fail("SMTP fixture did not publish readiness")

            async def stop(process: asyncio.subprocess.Process) -> None:
                if process.returncode is None:
                    process.terminate()
                await asyncio.wait_for(process.wait(), 5)

            async def probe(port: int, *, deliver: bool) -> None:
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                try:
                    self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"220 Plainpost acceptance SMTP\r\n")
                    writer.write(b"EHLO plainpost.restart\r\n")
                    await writer.drain()
                    await self._read_response(reader, 250)
                    writer.write(b"STARTTLS\r\n")
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"220 2.0.0 Ready to start TLS\r\n")
                    context = ssl.create_default_context(cafile=str(certificate))
                    context.check_hostname = False
                    writer = await self._upgrade_client_tls(reader, writer, context)
                    writer.write(b"EHLO plainpost.restart\r\n")
                    await writer.drain()
                    await self._read_response(reader, 250)
                    import base64
                    payload = base64.b64encode(b"\x00acceptance@example.test\x00acceptance-password")
                    writer.write(b"AUTH PLAIN " + payload + b"\r\n")
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"235 2.7.0 Authentication successful\r\n")
                    if deliver:
                        for command, response in (
                            (b"MAIL FROM:<sender@example.test>\r\n", b"250 2.1.0 OK\r\n"),
                            (b"RCPT TO:<recipient@example.test>\r\n", b"250 2.1.0 OK\r\n"),
                            (b"DATA\r\n", b"354 End data with <CRLF>.<CRLF>\r\n"),
                        ):
                            writer.write(command)
                            await writer.drain()
                            self.assertEqual(await asyncio.wait_for(reader.readline(), 2), response)
                        writer.write(b"Message-ID: <restart@example.test>\r\n\r\nrestart\r\n.\r\n")
                        await writer.drain()
                        self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"250 2.0.0 accepted\r\n")
                    writer.write(b"QUIT\r\n")
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"221 2.0.0 bye\r\n")
                finally:
                    writer.close()
                    await writer.wait_closed()

            first, first_port = await start()
            try:
                await probe(first_port, deliver=True)
            finally:
                await stop(first)
            second, second_port = await start()
            try:
                await probe(second_port, deliver=False)
            finally:
                await stop(second)
            mail_state.configure_root(root)
            self.assertEqual(len(mail_state.read()["deliveries"]), 1)

    def test_smtp_tls_mode_is_closed_and_defaults_to_normal(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(fixture.smtp_tls_mode(), "normal")
        for mode in ("normal", "wrong-host", "untrusted-cert", "legacy-tls", "auth-before-starttls"):
            with self.subTest(mode=mode), mock.patch.dict(
                os.environ,
                {"PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE": mode},
                clear=True,
            ):
                self.assertEqual(fixture.smtp_tls_mode(), mode)
        with mock.patch.dict(
            os.environ,
            {"PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE": "unbounded"},
            clear=True,
        ):
            with self.assertRaises(ValueError):
                fixture.smtp_tls_mode()

    def test_imap_tls_mode_is_closed_and_defaults_to_normal(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(fixture.imap_tls_mode(), "normal")
        for mode in ("normal", "wrong-host", "untrusted-cert", "legacy-tls"):
            with self.subTest(mode=mode), mock.patch.dict(
                os.environ,
                {"PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE": mode},
                clear=True,
            ):
                self.assertEqual(fixture.imap_tls_mode(), mode)
        with mock.patch.dict(
            os.environ,
            {"PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE": "unbounded"},
            clear=True,
        ):
            with self.assertRaises(ValueError):
                fixture.imap_tls_mode()

    def test_legacy_tls_contexts_fallback_for_libressl(self):
        contexts = (
            (fixture.smtp_tls_context, "PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE"),
            (fixture.imap_tls_context, "PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE"),
        )
        for builder, mode_variable in contexts:
            with self.subTest(builder=builder.__name__), mock.patch.dict(
                os.environ,
                {
                    mode_variable: "legacy-tls",
                    "PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT": "unused-cert",
                    "PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY": "unused-key",
                },
                clear=False,
            ):
                context = mock.Mock()
                cipher_specs = []

                def set_ciphers(spec):
                    cipher_specs.append(spec)
                    if spec == "DEFAULT:@SECLEVEL=0":
                        raise fixture.ssl.SSLError("No cipher can be selected.")

                context.set_ciphers.side_effect = set_ciphers
                with mock.patch.object(fixture.ssl, "create_default_context", return_value=context), mock.patch.object(
                    fixture.ssl, "OPENSSL_VERSION", "LibreSSL 2.8.3"
                ):
                    builder()
                self.assertEqual(cipher_specs, ["DEFAULT:@SECLEVEL=0", "DEFAULT"])
                self.assertEqual(context.minimum_version, fixture.ssl.TLSVersion.TLSv1_1)
                self.assertEqual(context.maximum_version, fixture.ssl.TLSVersion.TLSv1_1)

    def test_legacy_tls_contexts_lower_openssl_security_level(self):
        contexts = (
            (fixture.smtp_tls_context, "PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE"),
            (fixture.imap_tls_context, "PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE"),
        )
        for builder, mode_variable in contexts:
            with self.subTest(builder=builder.__name__), mock.patch.dict(
                os.environ,
                {
                    mode_variable: "legacy-tls",
                    "PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT": "unused-cert",
                    "PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY": "unused-key",
                },
                clear=False,
            ):
                context = mock.Mock()
                with mock.patch.object(fixture.ssl, "create_default_context", return_value=context), mock.patch.object(
                    fixture.ssl, "OPENSSL_VERSION", "OpenSSL 3.6.3"
                ):
                    builder()
                context.set_ciphers.assert_called_once_with("DEFAULT:@SECLEVEL=0")

    def test_compose_declares_smtp_tls_mode_and_same_ca_wrong_host_asset(self):
        repository = Path(__file__).parents[2]
        compose = (repository / "Deploy/acceptance/compose.private-transport.yaml").read_text(encoding="utf-8")
        harness = (repository / "Scripts/test-sync-node-private-transport.sh").read_text(encoding="utf-8")
        imap_service, smtp_and_after = compose.split("  smtp-fixture:\n", 1)
        smtp_service = smtp_and_after.split("\n  sync-node-acceptance-seed:\n", 1)[0]
        self.assertIn(
            "PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE: ${PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE:-normal}",
            smtp_service,
        )
        self.assertIn(
            "PLAINPOST_ACCEPTANCE_SMTP_WRONG_HOST_TLS_CERT: /run/wrong-host-tls/server.crt",
            smtp_service,
        )
        self.assertIn(
            "PLAINPOST_ACCEPTANCE_SMTP_WRONG_HOST_TLS_KEY: /run/wrong-host-tls/server.key",
            smtp_service,
        )
        self.assertIn(
            "PLAINPOST_ACCEPTANCE_SMTP_UNTRUSTED_TLS_CERT: /run/untrusted-tls/server.crt",
            smtp_service,
        )
        self.assertIn(
            "PLAINPOST_ACCEPTANCE_SMTP_UNTRUSTED_TLS_KEY: /run/untrusted-tls/server.key",
            smtp_service,
        )
        self.assertIn(
            "${PLAINPOST_PRIVATE_ROOT:?required}/mail-wrong-host-tls:/run/wrong-host-tls:ro",
            smtp_service,
        )
        self.assertIn(
            "${PLAINPOST_PRIVATE_ROOT:?required}/mail-untrusted-tls:/run/untrusted-tls:ro",
            smtp_service,
        )
        self.assertIn(
            "PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE: ${PLAINPOST_ACCEPTANCE_IMAP_TLS_MODE:-normal}",
            imap_service,
        )
        self.assertIn(
            "PLAINPOST_ACCEPTANCE_IMAP_WRONG_HOST_TLS_CERT: /run/wrong-host-tls/server.crt",
            imap_service,
        )
        self.assertIn(
            "PLAINPOST_ACCEPTANCE_IMAP_UNTRUSTED_TLS_CERT: /run/untrusted-tls/server.crt",
            imap_service,
        )
        self.assertIn("mail-wrong-host-tls", imap_service)
        self.assertIn("mail-untrusted-tls", imap_service)
        self.assertIn('"$temporary/mail-wrong-host-tls"', harness)
        self.assertIn(
            'make_certificate smtp-wrong-host wrong-host.example.test "$temporary/mail-wrong-host-tls"',
            harness,
        )
        self.assertIn(
            'openssl verify -CAfile "$temporary/ca.crt" "$temporary/mail-wrong-host-tls/server.crt"',
            harness,
        )
        self.assertIn('find "$temporary" -depth -delete', harness)

    async def test_smtp_tls_failure_modes_record_zero_authentication_and_normal_mode_recovers(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            mail_state.configure_root(root)
            certificate_authority = root / "ca.crt"
            certificate_authority_key = root / "ca.key"
            subprocess.run(
                [
                    "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(certificate_authority_key), "-out", str(certificate_authority),
                    "-subj", "/CN=Plainpost acceptance CA", "-days", "1",
                    "-addext", "basicConstraints=critical,CA:TRUE",
                    "-addext", "keyUsage=critical,keyCertSign,digitalSignature",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

            def make_leaf(name: str, hostname: str) -> tuple[Path, Path]:
                certificate = root / f"{name}.crt"
                key = root / f"{name}.key"
                request = root / f"{name}.csr"
                extensions = root / f"{name}.extensions"
                extensions.write_text(
                    f"subjectAltName=DNS:{hostname}\nextendedKeyUsage=serverAuth\n",
                    encoding="ascii",
                )
                subprocess.run(
                    [
                        "openssl", "req", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(key), "-out", str(request),
                        "-subj", f"/CN={hostname}",
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                subprocess.run(
                    [
                        "openssl", "x509", "-req", "-days", "1", "-in", str(request),
                        "-CA", str(certificate_authority), "-CAkey", str(certificate_authority_key),
                        "-CAcreateserial", "-extfile", str(extensions), "-out", str(certificate),
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                return certificate, key

            valid_certificate, valid_key = make_leaf("valid", "localhost")
            wrong_certificate, wrong_key = make_leaf("wrong-host", "wrong-host.example.test")
            untrusted_certificate = root / "untrusted.crt"
            untrusted_key = root / "untrusted.key"
            subprocess.run(
                [
                    "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(untrusted_key), "-out", str(untrusted_certificate),
                    "-subj", "/CN=smtp-fixture", "-days", "1",
                    "-addext", "subjectAltName=DNS:smtp-fixture",
                    "-addext", "extendedKeyUsage=serverAuth",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            untrusted_identity = subprocess.check_output(
                ["openssl", "x509", "-in", str(untrusted_certificate), "-noout", "-subject", "-ext", "subjectAltName"],
                text=True,
            )
            self.assertIn("CN=smtp-fixture", untrusted_identity)
            self.assertIn("DNS:smtp-fixture", untrusted_identity)
            ready = root / "smtp-ready"
            script = str(Path(__file__).parent / "plainpost_acceptance_mail_fixture.py")
            base_environment = os.environ | {
                "PLAINPOST_ACCEPTANCE_MAIL_ROOT": str(root),
                "PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT": str(valid_certificate),
                "PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY": str(valid_key),
                "PLAINPOST_ACCEPTANCE_SMTP_WRONG_HOST_TLS_CERT": str(wrong_certificate),
                "PLAINPOST_ACCEPTANCE_SMTP_WRONG_HOST_TLS_KEY": str(wrong_key),
                "PLAINPOST_ACCEPTANCE_SMTP_UNTRUSTED_TLS_CERT": str(untrusted_certificate),
                "PLAINPOST_ACCEPTANCE_SMTP_UNTRUSTED_TLS_KEY": str(untrusted_key),
                "PLAINPOST_ACCEPTANCE_MAIL_READY_FILE": str(ready),
                "PYTHONPATH": str(Path(__file__).parent),
            }

            async def start(mode: str) -> tuple[asyncio.subprocess.Process, int]:
                ready.unlink(missing_ok=True)
                process = await asyncio.create_subprocess_exec(
                    sys.executable,
                    script,
                    "smtp",
                    "0",
                    env=base_environment | {"PLAINPOST_ACCEPTANCE_SMTP_TLS_MODE": mode},
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                for _ in range(250):
                    if ready.exists():
                        return process, int(ready.read_text(encoding="ascii"))
                    if process.returncode is not None:
                        self.fail(f"SMTP fixture mode {mode} exited before readiness")
                    await asyncio.sleep(0.02)
                process.kill()
                await process.wait()
                self.fail(f"SMTP fixture mode {mode} did not publish readiness")

            async def stop(process: asyncio.subprocess.Process) -> None:
                if process.returncode is None:
                    process.terminate()
                await asyncio.wait_for(process.wait(), 5)

            async def starttls(port: int, context: ssl.SSLContext, server_hostname: str = "localhost") -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
                writer = None
                try:
                    reader, writer = await asyncio.open_connection("127.0.0.1", port)
                    self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"220 Plainpost acceptance SMTP\r\n")
                    writer.write(b"EHLO plainpost.tls-mode\r\n")
                    await writer.drain()
                    await self._read_response(reader, 250)
                    writer.write(b"STARTTLS\r\n")
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"220 2.0.0 Ready to start TLS\r\n")
                    writer = await self._upgrade_client_tls(reader, writer, context, server_hostname=server_hostname)
                    return reader, writer
                except BaseException:
                    if writer is not None:
                        writer.close()
                        try:
                            await writer.wait_closed()
                        except (ConnectionResetError, BrokenPipeError, ConnectionError, ssl.SSLError):
                            pass
                    raise

            for mode in ("wrong-host", "untrusted-cert", "legacy-tls", "auth-before-starttls"):
                with self.subTest(mode=mode):
                    process, port = await start(mode)
                    try:
                        context = ssl.create_default_context(cafile=str(certificate_authority))
                        context.minimum_version = ssl.TLSVersion.TLSv1_2
                        rejected = False
                        try:
                            _, writer = await starttls(port, context, server_hostname="smtp-fixture" if mode == "untrusted-cert" else "localhost")
                        except (ssl.SSLError, ConnectionError, TimeoutError, OSError, AssertionError):
                            rejected = True
                        else:
                            writer.close()
                            await writer.wait_closed()
                        self.assertTrue(rejected, f"production TLS floor unexpectedly accepted {mode}")
                    finally:
                        await stop(process)
                    mail_state.configure_root(root)
                    authentication_count = next((
                        item["count"] for item in mail_state.read()["phase_counters"]
                        if item["protocol"] == "smtp" and item["phase"] == "authentication"
                    ), 0)
                    self.assertEqual(authentication_count, 0)

            process, port = await start("normal")
            try:
                context = ssl.create_default_context(cafile=str(certificate_authority))
                reader, writer = await starttls(port, context)
                writer.write(b"EHLO plainpost.tls-mode\r\n")
                await writer.drain()
                await self._read_response(reader, 250)
                import base64

                payload = base64.b64encode(b"\x00acceptance@example.test\x00acceptance-password")
                writer.write(b"AUTH PLAIN " + payload + b"\r\n")
                await writer.drain()
                self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"235 2.7.0 Authentication successful\r\n")
                writer.write(b"QUIT\r\n")
                await writer.drain()
                self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"221 2.0.0 bye\r\n")
                writer.close()
                await writer.wait_closed()
            finally:
                await stop(process)
            authentication_count = next((
                item["count"] for item in mail_state.read()["phase_counters"]
                if item["protocol"] == "smtp" and item["phase"] == "authentication"
            ), 0)
            self.assertEqual(authentication_count, 1)

    async def test_smtp_requires_starttls_and_authentication_before_envelope_or_data(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            previous_deliveries = fixture.DELIVERIES
            fixture.DELIVERIES = root / "smtp-deliveries.jsonl"
            mail_state.configure_root(root)
            server = await asyncio.start_server(fixture.smtp, "127.0.0.1", 0)
            try:
                port = server.sockets[0].getsockname()[1]
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                await reader.readline()
                writer.write(b"EHLO local\r\n")
                await writer.drain()
                await self._read_response(reader, 250)
                import base64

                credentials = base64.b64encode(b"\x00acceptance@example.test\x00acceptance-password")
                writer.write(b"AUTH PLAIN " + credentials + b"\r\n")
                await writer.drain()
                self.assertEqual(await reader.readline(), b"530 5.7.0 Must issue STARTTLS first\r\n")
                for command in (b"MAIL FROM:<sender@example.test>\r\n", b"DATA\r\n"):
                    writer.write(command)
                    await writer.drain()
                    self.assertEqual(await reader.readline(), b"530 5.7.0 STARTTLS and authentication required\r\n")
                writer.close()
                await writer.wait_closed()
                self.assertEqual(mail_state.read()["deliveries"], [])
            finally:
                server.close()
                await server.wait_closed()
                fixture.DELIVERIES = previous_deliveries

    async def test_starttls_rebinds_existing_stream_and_delivers_authenticated_data(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            certificate = root / "mail.crt"
            key = root / "mail.key"
            deliveries = root / "deliveries.jsonl"
            subprocess.run(
                [
                    "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(key), "-out", str(certificate), "-subj", "/CN=localhost", "-days", "1",
                    "-addext", "basicConstraints=critical,CA:TRUE",
                    "-addext", "keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment",
                    "-addext", "subjectAltName=DNS:localhost",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            old_cert = os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT")
            old_key = os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY")
            old_deliveries = fixture.DELIVERIES
            os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT"] = str(certificate)
            os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY"] = str(key)
            fixture.DELIVERIES = deliveries
            mail_state.configure_root(root)
            server = await asyncio.start_server(fixture.smtp, "127.0.0.1", 0)
            try:
                port = server.sockets[0].getsockname()[1]
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"220 Plainpost acceptance SMTP\r\n")
                writer.write(b"EHLO plainpost.local\r\n")
                await writer.drain()
                await self._read_response(reader, 250)
                writer.write(b"STARTTLS\r\n")
                await writer.drain()
                self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"220 2.0.0 Ready to start TLS\r\n")

                context = ssl.create_default_context(cafile=str(certificate))
                context.check_hostname = False
                writer = await self._upgrade_client_tls(reader, writer, context)
                writer.write(b"EHLO plainpost.local\r\n")
                await writer.drain()
                await self._read_response(reader, 250)
                import base64

                payload = base64.b64encode(b"\x00acceptance@example.test\x00acceptance-password")
                writer.write(b"AUTH PLAIN " + payload + b"\r\n")
                await writer.drain()
                self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"235 2.7.0 Authentication successful\r\n")
                for command, response in (
                    (b"MAIL FROM:<sender@example.test>\r\n", b"250 2.1.0 OK\r\n"),
                    (b"RCPT TO:<recipient@example.test>\r\n", b"250 2.1.0 OK\r\n"),
                    (b"DATA\r\n", b"354 End data with <CRLF>.<CRLF>\r\n"),
                ):
                    writer.write(command)
                    await writer.drain()
                    self.assertEqual(await asyncio.wait_for(reader.readline(), 2), response)
                writer.write(b"Message-ID: <fixture@example.test>\r\n\r\nbody\r\n.\r\n")
                await writer.drain()
                self.assertEqual(await asyncio.wait_for(reader.readline(), 2), b"250 2.0.0 accepted\r\n")
                writer.close()
                await writer.wait_closed()
                records = mail_state.read()["deliveries"]
                self.assertEqual(len(records), 1)
                self.assertIn("Message-ID: <fixture@example.test>", records[0]["message"])
            finally:
                server.close()
                await server.wait_closed()
                fixture.DELIVERIES = old_deliveries
                if old_cert is None:
                    os.environ.pop("PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT", None)
                else:
                    os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT"] = old_cert
                if old_key is None:
                    os.environ.pop("PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY", None)
                else:
                    os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY"] = old_key

    async def _read_response(self, reader: asyncio.StreamReader, status: int) -> list[bytes]:
        lines = [await asyncio.wait_for(reader.readline(), 2)]
        self.assertTrue(lines[0].startswith(f"{status} ".encode()) or lines[0].startswith(f"{status}-".encode()), repr(lines[0]))
        while lines[-1].startswith(f"{status}-".encode()):
            lines.append(await asyncio.wait_for(reader.readline(), 2))
        self.assertTrue(lines[-1].startswith(f"{status} ".encode()))
        return lines

    async def _upgrade_client_tls(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        context: ssl.SSLContext,
        server_hostname: str = "localhost",
    ) -> asyncio.StreamWriter:
        start_tls = getattr(writer, "start_tls", None)
        if start_tls is not None:
            await asyncio.wait_for(start_tls(context, server_hostname=server_hostname, ssl_handshake_timeout=2), 2)
            return writer
        loop = asyncio.get_running_loop()
        transport = await asyncio.wait_for(
            loop.start_tls(writer.transport, writer._protocol, context, server_side=False, server_hostname=server_hostname),
            2,
        )
        return asyncio.StreamWriter(transport, writer._protocol, reader, loop)

    async def test_smtp_peer_reset_does_not_escape_handler(self):
        class ResetReader:
            async def readline(self) -> bytes:
                raise ConnectionResetError("probe disconnected")

        class RecordingWriter:
            def __init__(self) -> None:
                self.closed = False

            def write(self, _: bytes) -> None:
                pass

            async def drain(self) -> None:
                pass

            def close(self) -> None:
                self.closed = True

            async def wait_closed(self) -> None:
                pass

        writer = RecordingWriter()
        await fixture.smtp(ResetReader(), writer)  # type: ignore[arg-type]
        self.assertTrue(writer.closed)

    async def test_concurrent_identical_smtp_sessions_each_record_delivery(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            certificate = root / "mail.crt"
            key = root / "mail.key"
            subprocess.run(
                [
                    "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(key), "-out", str(certificate), "-subj", "/CN=localhost", "-days", "1",
                    "-addext", "basicConstraints=critical,CA:TRUE",
                    "-addext", "keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment",
                    "-addext", "subjectAltName=DNS:localhost",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            old_cert = os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT")
            old_key = os.environ.get("PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY")
            os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT"] = str(certificate)
            os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY"] = str(key)
            context = ssl.create_default_context(cafile=str(certificate))
            context.check_hostname = False
            previous_deliveries = fixture.DELIVERIES
            fixture.DELIVERIES = root / "smtp-deliveries.jsonl"
            mail_state.configure_root(root)
            mail_state.arm_fault("smtp-delivery", 2, "temporary")
            server = await asyncio.start_server(fixture.smtp, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]

            async def deliver() -> bytes:
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                await reader.readline()
                writer.write(b"EHLO local\r\n")
                await writer.drain()
                await self._read_response(reader, 250)
                writer.write(b"STARTTLS\r\n")
                await writer.drain()
                self.assertEqual(await reader.readline(), b"220 2.0.0 Ready to start TLS\r\n")
                writer = await self._upgrade_client_tls(reader, writer, context)
                writer.write(b"EHLO local\r\n")
                await writer.drain()
                await self._read_response(reader, 250)
                import base64
                credentials = base64.b64encode(b"\x00acceptance@example.test\x00acceptance-password")
                writer.write(b"AUTH PLAIN " + credentials + b"\r\n")
                await writer.drain(); self.assertTrue((await reader.readline()).startswith(b"235 "))
                for command in (b"MAIL FROM:<sender@example.test>\r\n", b"RCPT TO:<recipient@example.test>\r\n"):
                    writer.write(command); await writer.drain(); self.assertTrue((await reader.readline()).startswith(b"250 "))
                writer.write(b"DATA\r\n"); await writer.drain(); self.assertTrue((await reader.readline()).startswith(b"354 "))
                writer.write(b"Message-ID: <identical@example.test>\r\n\r\nbody\r\n.\r\n"); await writer.drain()
                response = await reader.readline()
                writer.close(); await writer.wait_closed()
                return response

            try:
                responses = await asyncio.gather(deliver(), deliver(), deliver())
                self.assertEqual(sum(response.startswith(b"451 ") for response in responses), 1)
                state = fixture.authority.read()
                self.assertEqual(len(state["deliveries"]), 2)
                self.assertEqual(state["faults"][0]["seen"], 3)
                self.assertEqual(len([item for item in state["observations"] if item["kind"] == "fault-fired"]), 1)
            finally:
                server.close(); await server.wait_closed(); fixture.DELIVERIES = previous_deliveries
                if old_cert is None:
                    os.environ.pop("PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT", None)
                else:
                    os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT"] = old_cert
                if old_key is None:
                    os.environ.pop("PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY", None)
                else:
                    os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_KEY"] = old_key


if __name__ == "__main__":
    unittest.main()
