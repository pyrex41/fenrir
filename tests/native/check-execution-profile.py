"""Exercise profile admission and diagnostics through the public CLI."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main(cli):
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)

        def run(*arguments, status=0):
            proc = subprocess.run([cli, *arguments], cwd=work, capture_output=True, text=True, timeout=60)
            if proc.returncode != status:
                raise ValueError((arguments, proc.returncode, proc.stdout, proc.stderr))
            return proc

        profile = json.loads(run("profile").stdout)
        assert profile == json.loads((root / "spec/native/standalone-v1.json").read_bytes())
        assert profile["id"] == "fenrir-native-standalone/1"
        assert set(profile["targets"]) == {"macos-arm64", "solo5-arm64-spt"}
        assert profile["limits"]["max_inline_captures"] == 7

        # Keep seven outer bindings reachable from the lambda; the eighth
        # variant adds one use, without changing any type or effect.
        source = """(define compute {I64 --> I64}
  x -> (let a (+ x 1) b (+ x 2) c (+ x 3) d (+ x 4)
            e (+ x 5) f (+ x 6) g (+ x 7) h (+ x 8)
            sum (lambda (n : I64) (+ n (+ (+ a b) (+ (+ c d) (+ (+ e f) g)))))
            (sum x)))
"""
        (work / "main.fen").write_text('(library "captures.fen")\n(define main {I64 --> I64} x -> (compute x))\n')
        (work / "captures.fen").write_text(source)
        # A locally handled durable operation and an unused remote declaration
        # once accepted by standalone builds remain admissible.
        (work / "local-store.fen").write_text("""(effect Store durable (put I64 --> I64))
(define main {I64 --> I64} x -> (handle Store ((put n) -> (+ n 1)) (perform Store put x)))
""")
        (work / "unused-remote.fen").write_text("""(remote-effect Meter (read-only total Unit --> I64))
(define main {I64 --> I64} n -> n)
""")
        (work / "managed-signature.fen").write_text("""(define ignore {Bytes --> I64} data -> 1)
(define main {I64 --> I64} n -> n)
""")
        assert "outcome: Ok 28" in run("model", "--profile", profile["id"], "main.fen").stdout
        bad_profile = run("model", "--profile", "unknown/1", "main.fen", status=2)
        assert "unknown execution profile" in bad_profile.stderr
        (work / "task.fen").write_text("(define main {I64 --> I64} x -> (do yield (+ x 1)))\n")
        for schedule in ([], ["fifo"]):
            assert "outcome: Ok 1" in run("model", "--profile", profile["id"], "task.fen", *schedule).stdout
        # These 639 scalar expressions have logarithmic live depth. A managed
        # frame that reserves one slot per AST node rejects this valid program.
        terms = ["1"] * 320
        while len(terms) > 1:
            terms = [f"(+ {a} {b})" for a, b in zip(terms[::2], terms[1::2])] + (terms[-1:] if len(terms) % 2 else [])
        (work / "wide.fen").write_text(f'(define main {{I64 --> I64}} x -> (do (emit "start" x) {terms[0]}))\n')
        for target in profile["targets"]:
            assert run("run", "--target", target, "wide.fen", "0").stdout.splitlines() == ['emit "start": 0', "320"]
            for name in ("main.fen", "local-store.fen", "unused-remote.fen", "managed-signature.fen"):
                run("check", "--target", target, name)

        (work / "captures.fen").write_text(source.replace("(+ (+ e f) g)", "(+ (+ e f) (+ g h))"))
        rejected_model = run("model", "--profile", profile["id"], "main.fen", status=1)
        assert "Closure captures 8 bindings" in rejected_model.stderr
        examples = root / "examples"
        cases = [
            ("main.fen", "captures.fen", "Closure captures 8 bindings"),
            (examples / "service/accepted-job.fen", "accepted-job.fen", "host/service/check-supervised-recovery.sh"),
            (examples / "remote/ledger-caller.fen", "ledger-caller.fen", "supervisor/run.sh"),
            (examples / "remote/ledger-peer.fen", "ledger-peer.fen", "supervisor/run.sh"),
        ]
        image = work / "image"
        image.write_bytes(b"previous image")
        for path, site, diagnostic in cases:
            run("check", path)
            for target in profile["targets"]:
                checked = run("check", "--target", target, path, status=1)
                built = run("build", "--target", target, path, "-o", image, status=1)
                assert built.stderr == checked.stderr, (built.stderr, checked.stderr)
                assert re.search(re.escape(site) + r":[1-9]\d*:[1-9]\d*: ", checked.stderr), checked.stderr
                assert profile["id"] in checked.stderr and diagnostic in checked.stderr
                assert len(checked.stderr.splitlines()) == 1 and image.read_bytes() == b"previous image"
    print("standalone profile, adapter diagnostics and capture boundaries passed on both targets")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
