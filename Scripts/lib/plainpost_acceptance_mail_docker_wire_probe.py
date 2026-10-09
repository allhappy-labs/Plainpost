"""Drive the mounted acceptance SMTP fixture over real loopback sockets."""
from __future__ import annotations

import base64
import os
import socket
import ssl
import subprocess
import sys
import time
from pathlib import Path


def submit(port: int) -> int:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
        stream = connection.makefile("rwb")
        stream.readline()
        stream.write(b"EHLO docker-probe\r\n")
        stream.flush()
        while stream.readline().startswith(b"250-"):
            pass
        stream.write(b"STARTTLS\r\n")
        stream.flush()
        if not stream.readline().startswith(b"220 "):
            raise RuntimeError("acceptance SMTP fixture did not offer STARTTLS")
        stream.close()
        tls_context = ssl.create_default_context(cafile=os.environ["PLAINPOST_ACCEPTANCE_MAIL_TLS_CERT"])
        with tls_context.wrap_socket(connection, server_hostname="localhost") as tls_connection:
            stream = tls_connection.makefile("rwb")
            stream.write(b"EHLO docker-probe\r\n")
            stream.flush()
            while stream.readline().startswith(b"250-"):
                pass
            stream.write(b"AUTH PLAIN " + base64.b64encode(b"\x00acceptance@example.test\x00acceptance-password") + b"\r\n")
            stream.flush()
            stream.readline()
            stream.write(b"MAIL FROM:<sender@example.test>\r\n")
            stream.flush()
            stream.readline()
            stream.write(b"RCPT TO:<recipient@example.test>\r\n")
            stream.flush()
            stream.readline()
            stream.write(b"DATA\r\n")
            stream.flush()
            stream.readline()
            stream.write(b"Message-ID: <docker-probe@example.test>\r\n\r\ndocker probe\r\n.\r\n")
            stream.flush()
            response = stream.readline()
            stream.write(b"QUIT\r\n")
            stream.flush()
            stream.close()
            return int(response.split(maxsplit=1)[0])


def stop_process(process: subprocess.Popen[str]) -> str:
    """Terminate, reap, then collect bounded subprocess diagnostics."""
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=1)
    output, _ = process.communicate(timeout=1)
    return output or ""


def main() -> int:
    root = Path(os.environ["PLAINPOST_ACCEPTANCE_MAIL_ROOT"])
    ready = root / "docker-wire-ready"
    ready.unlink(missing_ok=True)
    fixture = Path(__file__).with_name("plainpost_acceptance_mail_fixture.py")
    environment = os.environ | {"PLAINPOST_ACCEPTANCE_MAIL_READY_FILE": str(ready)}
    process = subprocess.Popen([sys.executable, str(fixture), "smtp", "0"], env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not ready.exists():
            if process.poll() is not None:
                output = stop_process(process)
                raise RuntimeError(f"fixture exited before readiness ({process.returncode}): {output}")
            time.sleep(0.02)
        if not ready.exists():
            output = stop_process(process)
            raise TimeoutError(f"fixture did not publish readiness: {output}")
        port = int(ready.read_text(encoding="ascii"))
        responses = [submit(port) for _ in range(3)]
        if responses.count(250) != 2 or responses.count(451) != 1:
            raise AssertionError(f"unexpected SMTP response classes: {responses}")
        return 0
    finally:
        stop_process(process)
        ready.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
