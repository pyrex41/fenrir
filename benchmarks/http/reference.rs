// Compile with rustc --edition=2021 -O reference.rs -o http-reference
use std::io::{self, BufRead, BufReader, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

const LIMIT: usize = 8192;
const CONNECTIONS: usize = 64;
static ACTIVE: AtomicUsize = AtomicUsize::new(0);

fn serve(mut socket: TcpStream) -> io::Result<()> {
    let timeout = Some(Duration::from_secs(5));
    socket.set_read_timeout(timeout)?;
    socket.set_write_timeout(timeout)?;
    let mut reader = BufReader::new(socket.try_clone()?);
    let mut head = Vec::with_capacity(1024);
    let mut response = Vec::with_capacity(256);
    loop {
        head.clear();
        while head.len() < LIMIT && !head.ends_with(b"\r\n\r\n") {
            let available = reader.fill_buf()?;
            if available.is_empty() {
                return Ok(());
            }
            let mut consumed = 0;
            for &byte in available {
                head.push(byte);
                consumed += 1;
                if head.len() == LIMIT || head.ends_with(b"\r\n\r\n") {
                    break;
                }
            }
            reader.consume(consumed);
        }
        let (status, kind, body, close) = route(&head);
        let connection = if close { "close" } else { "keep-alive" };
        response.clear();
        write!(response, "HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: {connection}\r\n\r\n", body.len())?;
        if body.len() <= response.capacity() - response.len() {
            response.extend_from_slice(body.as_bytes());
            socket.write_all(&response)?;
        } else {
            socket.write_all(&response)?;
            socket.write_all(body.as_bytes())?;
        }
        if close {
            socket.shutdown(Shutdown::Write)?;
            return Ok(());
        }
    }
}

fn route(head: &[u8]) -> (&'static str, &'static str, &str, bool) {
    let bad = ("400 Bad Request", "text/plain", "", true);
    if head.len() > LIMIT || (head.len() == LIMIT && !head.ends_with(b"\r\n\r\n")) {
        return (
            "431 Request Header Fields Too Large",
            "text/plain",
            "",
            true,
        );
    }
    if !head.ends_with(b"\r\n\r\n") {
        return bad;
    }
    let Ok(text) = std::str::from_utf8(&head[..head.len() - 4]) else {
        return bad;
    };
    let mut lines = text.split("\r\n");
    let mut request = lines.next().unwrap_or_default().split(' ');
    let (Some("GET"), Some(path), Some("HTTP/1.1"), None) = (
        request.next(),
        request.next(),
        request.next(),
        request.next(),
    ) else {
        return bad;
    };
    if !path.starts_with('/') || !path.bytes().all(|b| b.is_ascii_graphic()) {
        return bad;
    }
    let mut close = false;
    let mut host = false;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            return bad;
        };
        if name.is_empty()
            || !name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
            || !value.bytes().all(|b| b == b'\t' || (32..127).contains(&b))
        {
            return bad;
        }
        let value = value.trim();
        if name.eq_ignore_ascii_case("host") {
            if host || value.is_empty() {
                return bad;
            }
            host = true;
        }
        if name.eq_ignore_ascii_case("transfer-encoding")
            || name.eq_ignore_ascii_case("content-length")
        {
            return bad;
        }
        if name.eq_ignore_ascii_case("connection") {
            close |= value
                .split(',')
                .any(|v| v.trim().eq_ignore_ascii_case("close"));
        }
    }
    if !host {
        return bad;
    }
    match path {
        "/" => ("200 OK", "text/plain", "fenrir\n", close),
        "/status" => ("200 OK", "application/json", "{\"ok\":true}\n", close),
        _ => match path.strip_prefix("/items/") {
            Some(id) if !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()) => {
                ("200 OK", "text/plain", id, close)
            }
            _ => ("404 Not Found", "text/plain", "", close),
        },
    }
}

fn main() -> io::Result<()> {
    let listener = TcpListener::bind(
        std::env::args()
            .nth(1)
            .unwrap_or_else(|| "127.0.0.1:8080".into()),
    )?;
    eprintln!("{}", listener.local_addr()?);
    for socket in listener.incoming() {
        let socket = socket?;
        if ACTIVE.fetch_add(1, Ordering::Relaxed) >= CONNECTIONS {
            ACTIVE.fetch_sub(1, Ordering::Relaxed);
            continue;
        }
        std::thread::spawn(move || {
            let _ = serve(socket);
            ACTIVE.fetch_sub(1, Ordering::Relaxed);
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn corpus() {
        for (path, status, body) in [
            ("/", "200 OK", "fenrir\n"),
            ("/status", "200 OK", "{\"ok\":true}\n"),
            ("/items/001", "200 OK", "001"),
            ("/items/", "404 Not Found", ""),
            ("/items/1x", "404 Not Found", ""),
        ] {
            let request = format!("GET {path} HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n");
            let (actual_status, _, actual_body, close) = route(request.as_bytes());
            assert_eq!((actual_status, actual_body, close), (status, body, true));
        }
        for headers in [
            "",
            "Bad\r\n",
            "Host: one\r\nHost: two\r\n",
            "Host: test\r\nTransfer-Encoding: chunked\r\n",
        ] {
            let request = format!("GET / HTTP/1.1\r\n{headers}\r\n");
            assert_eq!(route(request.as_bytes()).0, "400 Bad Request");
        }
        assert_eq!(
            route(&vec![b'A'; LIMIT]).0,
            "431 Request Header Fields Too Large"
        );
    }
}
