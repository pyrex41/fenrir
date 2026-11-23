"""Compare bounded services with protocol expectations over loopback TCP."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path
import socket
import subprocess
import sys


@contextmanager
def server(command, *, on_start=None, env=None):
    proc = subprocess.Popen(command, stderr=subprocess.PIPE, text=True, env=env)
    try:
        host, port = proc.stderr.readline().strip().split(":")
        if on_start is not None:
            on_start(proc.pid)
        yield host, int(port)
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def request(path, fields=b"Connection: close"):
    return b"GET " + path + b" HTTP/1.1\r\nHost:x\r\n" + fields + b"\r\n\r\n"


def response(status, body=b"", close=True, kind=b"text/plain"):
    return (b"HTTP/1.1 " + status + b"\r\nContent-Type: " + kind
            + b"\r\nContent-Length: " + str(len(body)).encode()
            + b"\r\nConnection: " + (b"close" if close else b"keep-alive") + b"\r\n\r\n" + body)


def verify(addr, parts, expected, allow_reset=False):
    with socket.create_connection(addr, timeout=5) as conn:
        for part in parts:
            conn.sendall(part)
        conn.shutdown(socket.SHUT_WR)
        actual = bytearray()
        while True:
            try:
                chunk = conn.recv(4096)
            except ConnectionResetError:
                if allow_reset:
                    break
                raise
            if not chunk:
                break
            actual.extend(chunk)
    if actual != expected:
        raise ValueError((actual[:256], expected[:256]))


def check_slow_reader(addr, independent_response):
    digits = b"0123456789" * 600
    line = request(b"/items/" + digits, b"X:y")
    final = request(b"/items/" + digits)
    keep = response(b"200 OK", digits, close=False)
    expected = keep * 31 + response(b"200 OK", digits)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as slow:
        slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        slow.settimeout(5)
        slow.connect(addr)
        with ThreadPoolExecutor(max_workers=1) as pool:
            sending = pool.submit(slow.sendall, line * 31 + final)
            # Once the first response is available, leave it unread while a
            # separate client completes. Then drain and check the whole stream.
            try:
                first_byte = slow.recv(1, socket.MSG_PEEK)
            except socket.timeout as exc:
                state = "still sending"
                if sending.done():
                    sending.result()
                    state = "sent"
                raise TimeoutError(
                    f"slow-reader preflight timed out before first response ({state} request batch)"
                ) from exc
            if not first_byte:
                raise ValueError("slow connection closed before the first response")
            verify(addr, [request(b"/status")], independent_response)
            actual = bytearray()
            while len(actual) <= len(expected):
                part = slow.recv(16384)
                if not part:
                    break
                actual.extend(part)
            sending.result(timeout=5)
    if actual != expected:
        raise ValueError("incorrect pipelined responses after the slow reader resumed")


def check(addr):
    ok = b"200 OK"
    status = response(ok, b'{"ok":true}\n', kind=b"application/json")
    check_slow_reader(addr, status)
    line = request(b"/items/00012")
    verify(addr, [line[:2], line[2:-3], line[-3:]], response(ok, b"00012"))
    verify(addr, [request(b"/", b"X:y") + request(b"/status")],
           response(ok, b"fenrir\n", close=False) + status)
    verify(addr, [request(b"/missing")], response(b"404 Not Found"))
    verify(addr, [request(b"/", b"Host:y")], response(b"400 Bad Request"))
    verify(addr, [b"x" * 8192], response(b"431 Request Header Fields Too Large"))
    sized = request(b"/", b"Connection: close\r\nX:")
    exact = sized[:-4] + b"a" * (8192 - len(sized)) + sized[-4:]
    verify(addr, [exact], response(ok, b"fenrir\n"))
    verify(addr, [exact[:-4] + b"a" + exact[-4:]], response(b"431 Request Header Fields Too Large"), allow_reset=True)
    verify(addr, [request(b"/", b"Content-Length: 0")], response(b"400 Bad Request"))
    verify(addr, [line[:-1]], b"")
    # An abandoned partial head must leave other connections usable.
    with socket.create_connection(addr, timeout=5) as stalled:
        stalled.sendall(b"GET /")
        with ThreadPoolExecutor(max_workers=12) as workers:
            futures = []
            for i in range(48):
                digits = b"0" * i + str(i).encode()
                # Vary the decision's body length as well as the body bytes;
                # a reply consumed by a different connection must be observable.
                parts = [request(b"/items/" + digits, b"X:y") + request(b"/status")]
                expected = response(ok, digits, close=False) + status
                futures.append(workers.submit(verify, addr, parts, expected))
            for task in futures:
                task.result()


if __name__ == "__main__":
    commands = [[sys.argv[1], "0"], [sys.argv[2], "127.0.0.1:0"]]
    for entry in sys.argv[3:]:
        if Path(entry).is_dir():
            commands.append([sys.executable, Path(__file__).with_name("run-spt.py"), entry, "0"])
        else:
            commands.append([entry, "0"])
    for command in commands:
        with server(command) as address:
            check(address)
        print(command[-2], "wire and concurrent client checks passed")
