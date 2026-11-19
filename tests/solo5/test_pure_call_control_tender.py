"""Small real-spt wire checks, independent of the Shen comparison harness.

Run on Linux with Node 22 and FENRIR_SOLO5 set to a built pinned Solo5.
The v2 fixture exercises the C backend directly, not frontend admission.
"""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ARTIFACT = "a" * 64
SCHEMA = "tc1-durable-demo/1"
V2 = "fenrir.solo5.pure-call-control/2"

V2_DATA = r"""
static const int children[]={1};
static const struct pc_node nodes[]={
    {.tag=PC_PERFORM,.id=4,.integer=1,.text="Store",.text2="put",
     .child_count=1,.children=children,.type="T2IY"},
    {.tag=PC_VAR,.id=3,.binding=1}
};
static const char *const fields[]={"I"};
static const struct pc_constructor constructors[]={{"Key",1,fields}};
static const struct pc_datatype datatypes[]={{"Key",1,constructors}};
static const struct pc_function functions[]={{1,0}};
static const struct pc_program pc_programs[]={
    {nodes,2,functions,1,0,PC_INPUT_VALUE,0,"[\"data\",\"Key\",\"Key\",[\"int\",\"7\"]]","D0;",datatypes,1}
};
static const unsigned pc_program_count=1;
"""


def encode(direction, kind, seq, payload):
    text = json.dumps(payload, separators=(",", ":")).encode("ascii")
    return f"FGC1 {direction}{kind} {seq:08} {len(text):08}\n".encode() + text + b"\n"


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("FENRIR_SOLO5"),
                     "requires native Linux and FENRIR_SOLO5")
class PureCallControlTender(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        tmp = tempfile.TemporaryDirectory(prefix="fenrir-spt-")
        cls.addClassCleanup(tmp.cleanup)
        cls.dir = Path(tmp.name)
        build = """
import {buildControlGuest, controlHeader, controlToolchain} from './tools/solo5/control-pure-call-build.mjs';
import {lowerBatch} from './tools/solo5/pure-call/lower.mjs';
import {cases} from './fixtures/tc0/pure-call-hand-cases.mjs';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
const [dir,artifact,schema]=process.argv.slice(1),tools=controlToolchain();
const program=cases[0].program, v1=lowerBatch([{program,input:['int','0']}]);
const a=buildControlGuest(tools,v1.header,controlHeader(v1,[{artifact:program}]),join(dir,'v1'));
const v2=batch=>'#define PC_BATCH_SHA256 "'+batch+'"\\n'+readFileSync(join(dir,'fixture.h'),'utf8');
const ids=controlHeader({artifact_sha256:[artifact]},[{artifact:{schema_version:schema}}]);
const batch='b'.repeat(64);
const b=buildControlGuest(tools,v2(batch),ids,join(dir,'v2'),{durable:true});
const other=buildControlGuest(tools,v2('c'.repeat(64)),ids,join(dir,'other'),{durable:true});
console.log(JSON.stringify({tender:tools.tender,a,b,other,batch,v1:{hash:v1.artifact_sha256[0],schema:program.schema_version}}));
"""
        (cls.dir / "fixture.h").write_text(V2_DATA)
        cls.images = json.loads(subprocess.check_output(
            ["node", "--input-type=module", "-e", build, str(cls.dir), ARTIFACT, SCHEMA],
            cwd=ROOT, timeout=120))

    def boot(self, image):
        console = tempfile.TemporaryFile()
        self.addCleanup(console.close)
        p = subprocess.Popen([self.images["tender"], "--mem=32", "--net:ctlin=@0",
                              "--net:ctlout=@2", self.images[image]], stdin=subprocess.PIPE,
                             stdout=console, stderr=subprocess.PIPE)
        self.addCleanup(p.__exit__, None, None, None)
        self.addCleanup(lambda: p.kill() if p.poll() is None else None)
        return p

    def read(self, p, kind, seq):
        self.assertTrue(select.select([p.stderr], [], [], 5)[0], "no guest frame")
        header = p.stderr.readline()
        prefix = f"FGC1 G{kind} {seq:08} ".encode()
        self.assertTrue(header.startswith(prefix), header)
        n = int(header[len(prefix):])
        raw = p.stderr.read(n + 1)
        payload = json.loads(raw)
        self.assertEqual(header + raw, encode("G", kind, seq, payload))
        return payload

    def send(self, p, kind, seq, payload):
        p.stdin.write(encode("H", kind, seq, payload))
        p.stdin.flush()

    def init(self, p, *, batch, artifact=ARTIFACT, schema=SCHEMA, protocol=V2):
        self.send(p, "I", 1, dict(artifact_sha256=artifact, batch_sha256=batch, fuel="200",
                                 kind="Init", mode="normal", program="0", protocol=protocol,
                                 schema=schema))

    def done(self, p, status):
        self.assertEqual(p.wait(timeout=5), status)
        self.assertEqual(p.stderr.read(), b"")

    def test_v1_run_and_v2_reply_rejected(self):
        p = self.boot("a")
        h = self.read(p, "H", 0)
        self.assertEqual(h["protocol"], V2[:-1] + "1")
        v1 = self.images["v1"]
        self.init(p, batch=h["batch_sha256"], artifact=v1["hash"], schema=v1["schema"],
                  protocol=h["protocol"])
        self.read(p, "Y", 1)
        for seq in range(2, 202):
            self.send(p, "R", seq, dict(kind="Run", steps="64"))
            steps = self.read(p, "S", seq)
            self.assertTrue(steps["steps"])
            if steps["execution"] == "Completed":
                break
            self.assertEqual(steps["execution"], "Running")
        else:
            self.fail("v1 program did not complete within fuel")
        self.send(p, "A", seq + 1, dict(kind="Reply", request="0", value=["unit"]))
        self.assertEqual(self.read(p, "E", seq + 1)["code"], "UnknownType")
        self.done(p, 3)

    def waiting(self):
        p = self.boot("b")
        h = self.read(p, "H", 0)
        self.assertEqual(h["protocol"], V2)
        self.init(p, batch=h["batch_sha256"])
        ready = self.read(p, "Y", 1)
        self.send(p, "R", 2, dict(kind="Run", steps="64"))
        wait = self.read(p, "S", 2)
        self.assertEqual(wait["execution"], "HostWait")
        self.assertEqual(wait["steps"][-1]["events"], [{
            "kind": "HostRequest", "task": "0", "node": "4", "seq": "0",
            "effect": "Store", "operation": "put", "value": ["data", "Key", "Key", ["int", "7"]],
        }])
        return p, [h, ready, wait]

    def test_v2_typed_reply_resumes_and_cold_replays(self):
        traces = []
        for _ in range(2):
            p, trace = self.waiting()
            answer = ["tuple", ["int", "-9223372036854775808"], ["bytes", "0abc"]]
            self.send(p, "A", 3, dict(kind="Reply", request="0", value=answer))
            reply = self.read(p, "S", 3)
            self.assertEqual(int(reply["epoch"]), int(trace[-1]["epoch"]) + 1)
            self.assertEqual(len(reply["steps"]), 1)
            self.assertEqual(reply["steps"][0]["events"], [{
                "kind": "HostReply", "task": "0", "node": "4", "seq": "0", "value": answer,
            }])
            self.send(p, "R", 4, dict(kind="Run", steps="64"))
            final = self.read(p, "S", 4)
            self.assertEqual(final["execution"], "Completed")
            self.assertEqual(final["steps"][-1]["events"][0]["outcome"], ["Ok", answer])
            self.send(p, "X", 5, dict(kind="Terminate"))
            traces.append(trace + [reply, final, self.read(p, "B", 5)])
            self.done(p, 0)
        self.assertEqual(*traces)

    def test_v2_refuses_wrong_batch_and_other_guest(self):
        for image, named_batch in [("b", "d" * 64), ("other", self.images["batch"])]:
            with self.subTest(image=image):
                p = self.boot(image)
                self.assertNotEqual(self.read(p, "H", 0)["batch_sha256"], named_batch)
                self.init(p, batch=named_batch)
                self.assertEqual(self.read(p, "E", 1)["code"], "Identity")
                self.done(p, 3)

    def test_v2_refuses_bad_reply_without_a_step(self):
        for request, value in [
            ("1", ["tuple", ["int", "1"], ["bytes", "00"]]),
            ("0", ["int", "1"]),
            ("0", ["tuple", ["int", "9223372036854775808"], ["bytes", "00"]]),
            ("0", ["tuple", ["int", "-0"], ["bytes", "00"]]),
            ("0", ["tuple", ["int", "1"], ["bytes", "AB"]]),
        ]:
            with self.subTest(request=request, value=value):
                p, _ = self.waiting()
                self.send(p, "A", 3, dict(kind="Reply", request=request, value=value))
                self.assertEqual(self.read(p, "E", 3)["code"], "BadReply")
                self.done(p, 3)


if __name__ == "__main__":
    unittest.main()
