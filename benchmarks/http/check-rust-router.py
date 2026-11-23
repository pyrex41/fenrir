"""Validate the socket service's Rust parser against the shared Fenrir corpus."""
from pathlib import Path
import runpy
import subprocess
import tempfile

here = Path(__file__).resolve().parent
cases = runpy.run_path(str(here / "check-router.py"))["corpus"]()
with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    (work / "reference.rs").write_bytes((here / "reference.rs").read_bytes())
    calls = []
    for index, (head, decision) in enumerate(cases):
        path = work / f"head-{index}"
        path.write_bytes(head)
        calls.append(f'println!("{{}}", decision(include_bytes!("{path.name}")));')
    source = r'''
#[allow(dead_code)]
mod service {
    include!("reference.rs");
    pub fn decision(head: &[u8]) -> String {
        let (status, _, body, close) = route(head);
        let route = match status {
            "400 Bad Request" => return "Bad".into(),
            "431 Request Header Fields Too Large" => return "Oversized".into(),
            "404 Not Found" => "Missing".into(),
            "200 OK" => match body {
                "fenrir\n" => "Home".into(),
                "{\"ok\":true}\n" => "Status".into(),
                id => format!("(Item {} {})", id.as_ptr() as usize - head.as_ptr() as usize, id.len()),
            },
            _ => panic!("unexpected status {status}"),
        };
        format!("(Serve {route} {close})")
    }
}
use service::decision;
fn main() {
''' + "\n".join(calls) + "\n}\n"
    (work / "check.rs").write_text(source)
    subprocess.run(["rustc", "--edition=2021", "-O", "-C", "overflow-checks=yes",
                    "check.rs", "-o", "check"], cwd=work, check=True)
    actual = subprocess.check_output([work / "check"], text=True).splitlines()
    expected = [decision for _, decision in cases]
    if actual != expected:
        raise ValueError(list(zip(expected, actual)))
print(f"Rust passed {len(cases)} shared HTTP parser cases")
