"""Verify the idiomatic Bandit deployment's endpoint and keep-alive behavior."""
from concurrent.futures import ThreadPoolExecutor
from http.client import HTTPConnection
from pathlib import Path
import socket
import subprocess

root = Path(__file__).resolve().parent


def check(port):
    conn = HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        for path, status, kind, body in [
                ("/", 200, "text/plain", b"fenrir\n"),
                ("/status", 200, "application/json", b'{"ok":true}\n'),
                ("/items/00012", 200, "text/plain", b"00012"),
                ("/items/1a", 404, "text/plain", b""),
                ("/status?q=1", 404, "text/plain", b"")]:
            conn.request("GET", path)
            reply = conn.getresponse()
            actual = (reply.status, reply.getheader("Content-Type"), reply.read())
            if actual != (status, kind, body):
                raise ValueError((path, actual))
        conn.request("GET", "/", headers={"Content-Length": "0"})
        result = conn.getresponse()
        assert (result.status, result.read()) == (400, b"")
    finally:
        conn.close()


if __name__ == "__main__":
    with subprocess.Popen([root / "run.sh", "0"], stderr=subprocess.PIPE, text=True) as process:
        try:
            host, port = process.stderr.readline().strip().split(":")
            with socket.create_connection((host, int(port)), timeout=5) as partial:
                partial.sendall(b"GET /st")
                with ThreadPoolExecutor(max_workers=12) as pool:
                    list(pool.map(check, [int(port)] * 24))
            digits = b"0123456789" * 600
            with socket.socket() as slow:
                slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                slow.settimeout(5)
                slow.connect((host, int(port)))
                conn = HTTPConnection(host, int(port), timeout=5)
                conn.sock = slow
                try:
                    conn.request("GET", "/items/" + digits.decode("ascii"))
                    if not slow.recv(1, socket.MSG_PEEK):
                        raise ValueError("Bandit closed the slow connection")
                    check(int(port))
                    reply = conn.getresponse()
                    if reply.status != 200 or reply.read() != digits:
                        raise ValueError("Bandit returned a different item to the slow reader")
                finally:
                    conn.close()
            print("Bandit passed concurrent endpoint and delayed-reader checks")
        finally:
            process.terminate()
            process.wait(timeout=10)
