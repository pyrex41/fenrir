"""Record and replay bounded native CLI observations for a caller-selected image."""
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import shutil
import subprocess
import sys
import tempfile

LIMIT = 1024 * 1024
LEGACY = "fenrir-native-observations/1"
SCHEMA = "fenrir-native-observations/2"
SCHEDULE = "fenrir-native-schedule/1"
LAUNCH = Path(__file__).resolve().parent / "run-image.sh"


def limit_output():
    resource.setrlimit(resource.RLIMIT_FSIZE, (LIMIT, LIMIT))


def execution_environment(target, env):
    identity = dict(launcher_sha256=hashlib.sha256(LAUNCH.read_bytes()).hexdigest(),
                    system=platform.system(), machine=platform.machine(), release=platform.release())
    if target == "solo5-arm64-spt":
        if (identity["system"], identity["machine"]) == ("Linux", "aarch64"):
            prefix = env.get("FENRIR_SOLO5")
            tender = Path(prefix) / "bin/solo5-spt" if prefix else shutil.which("solo5-spt")
            if not tender:
                raise ValueError("Solo5 tender unavailable")
            identity["tender_sha256"] = hashlib.sha256(Path(tender).read_bytes()).hexdigest()
        else:
            tag = env.get("FENRIR_SOLO5_IMAGE") or "fenrir-track1-solo5:38e0c348be23-arm64"
            digest = subprocess.check_output(["docker", "image", "inspect", "--format", "{{.Id}}", tag],
                                             text=True, timeout=15).strip()
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
                raise ValueError("invalid Solo5 container identity")
            identity["solo5_container"] = env["FENRIR_SOLO5_IMAGE"] = digest
    return identity


def encode_choices(ids):
    if (not isinstance(ids, list) or not 1 <= len(ids) <= 240 or
            any(type(i) is not int or not 0 <= i < 2**64 for i in ids)):
        raise ValueError("expected 1..240 unsigned task IDs")
    encoded = ",".join(map(str, ids))
    if len(encoded) > 960:
        raise ValueError("schedule exceeds native CLI transport limit")
    return encoded


def observe(image, target, argument, expected_hash=None, schema=SCHEMA, expected_env=None, choices=None):
    if target not in ("macos-arm64", "solo5-arm64-spt"):
        raise ValueError("unknown target")
    if not isinstance(argument, str) or not re.fullmatch(r"-?[0-9]+", argument):
        raise ValueError("invalid I64 argument")
    negative = argument.startswith("-")
    magnitude = argument.lstrip("-").lstrip("0") or "0"
    limit = "9223372036854775808" if negative else "9223372036854775807"
    if len(magnitude) > 19 or (len(magnitude) == 19 and magnitude > limit):
        raise ValueError("I64 argument out of range")
    # Older receipts preserve the spelling of short decimal arguments.
    # Compact longer spellings before passing them to the bounded guest cmdline.
    if len(argument.lstrip("-")) > 19:
        argument = ("-" if negative and magnitude != "0" else "") + magnitude
    with tempfile.TemporaryDirectory() as work:
        snapshot = Path(work) / "image"
        shutil.copyfile(image, snapshot)
        snapshot.chmod(0o500)
        image_hash = hashlib.sha256(snapshot.read_bytes()).hexdigest()
        if expected_hash is not None and image_hash != expected_hash:
            raise ValueError("image identity mismatch")
        env = os.environ.copy()
        environment = {} if schema == LEGACY else {"execution": execution_environment(target, env)}
        if expected_env is not None and environment.get("execution") != expected_env:
            raise ValueError("execution environment mismatch")
        wire = argument
        if schema == SCHEDULE:
            wire += "@" + ("r" if choices is None else encode_choices(choices))
        with tempfile.TemporaryFile() as trace:
            run = subprocess.run(["sh", LAUNCH, target, work, wire],
                                 stdin=subprocess.DEVNULL, stdout=trace, stderr=subprocess.STDOUT,
                                 timeout=30, env=env, preexec_fn=limit_output)
            trace.seek(0)
            data = trace.read(LIMIT)
        if len(data) == LIMIT:
            raise ValueError("observation exceeds recording limit")
        if schema == SCHEDULE:
            pattern = rb"^fenrir schedule ([0-9]+(?:,[0-9]+)*)\n"
            rows = re.findall(pattern, data, re.M)
            if len(rows) != 1:
                raise ValueError("task image did not complete the requested schedule")
            selected = [int(i) for i in rows[0].split(b",")]
            encode_choices(selected)
            if choices is not None and selected != choices:
                raise ValueError("native dispatch sequence differs")
            environment["dispatches"] = selected
            data = re.sub(pattern, b"", data, flags=re.M)
        if run.returncode not in (0, 1):
            raise ValueError(f"native launcher exited {run.returncode}")
        wait = rb"task [0-9]+ (?:awaits task|joins scope|sends on channel|receives on channel) [0-9]+"
        if run.returncode == 1 and not (
                re.search(rb"^trap: (Overflow|DivZero|Bounds|HeapExhausted|ChildFailed|TaskLimit|InvalidDuration)$", data, re.M)
                or re.search(rb"^deadlock: " + wait + rb"(?:, " + wait + rb")*\n\Z", data, re.M)):
            raise ValueError("execution failed without a recognized native trap")
        return dict(**environment, schema=schema, target=target, input=argument, image_sha256=image_hash,
                    exit_status=run.returncode, observations=base64.b64encode(data).decode("ascii"))


def main(args):
    if (len(args) == 5 and args[0] == "record") or (len(args) in (5, 6) and args[0] == "record-schedule"):
        command, target, image, value, destination = args[:5]
        choices = None
        if len(args) == 6:
            with open(args[5], "rb") as stream:
                raw = stream.read(8193)
            if len(raw) > 8192:
                raise ValueError("schedule input exceeds size limit")
            choices = json.loads(raw)
            encode_choices(choices)
        receipt = observe(image, target, value, schema=SCHEDULE if command == "record-schedule" else SCHEMA,
                          choices=choices)
        path = Path(destination)
        with tempfile.TemporaryDirectory(dir=path.parent) as work:
            staging = Path(work) / "receipt"
            staging.write_text(json.dumps(receipt, indent=2) + "\n")
            os.link(staging, path)
        print("recorded", path)
    elif len(args) == 3 and args[0] == "replay":
        _, image, path = args
        with open(path, "rb") as f:
            raw = f.read(2 * LIMIT + 1)
        if len(raw) > 2 * LIMIT:
            raise ValueError("receipt exceeds size limit")
        receipt = json.loads(raw)
        if not isinstance(receipt, dict) or receipt.get("schema") not in (SCHEMA, LEGACY, SCHEDULE):
            raise ValueError("unsupported replay schema")
        if not isinstance(receipt.get("image_sha256"), str):
            raise ValueError("missing image identity")
        choices = receipt.get("dispatches")
        if receipt["schema"] == SCHEDULE:
            encode_choices(choices)
        current = observe(image, receipt["target"], receipt["input"], receipt["image_sha256"],
                          receipt["schema"], receipt.get("execution"), choices)
        if json.dumps(current, sort_keys=True) != json.dumps(receipt, sort_keys=True):
            raise ValueError("native observation or identity mismatch")
        print("exact native observations")
    else:
        raise ValueError("see fenrir --help for record, record-schedule and replay usage")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
