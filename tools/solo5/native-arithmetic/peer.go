package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// A peer supplies transport faults, never semantic samples. The independent
// arithmetic candidate and Shen evaluation are not linked into this build.
func peerCLI(args []string) error {
	f := flag.NewFlagSet("peer", flag.ContinueOnError)
	root := f.String("root", ".", "repository root")
	artifact := f.String("artifact", "", "validated artifact for transport identities")
	input := f.String("input", "", "validated input for transport identities")
	dependency := f.String("transport-build", "", "immutable tender dependency")
	output := f.String("output-dir", "", "fresh peer evidence directory")
	kind := f.String("kind", "", "malformed, nonyield, eof-hello, eof-prefix, crash, cancel-hello or cancel-fragment (transport only)")
	faults := map[string]string{"malformed": "0", "nonyield": "1", "eof-hello": "2", "eof-prefix": "3", "crash": "4", "cancel-hello": "1", "cancel-fragment": "5"}
	if e := f.Parse(args); e != nil {
		return e
	}
	if f.NArg() != 0 || *artifact == "" || *input == "" || *dependency == "" || *output == "" || faults[*kind] == "" {
		return fmt.Errorf("PeerFlags")
	}
	for _, p := range []*string{root, artifact, input, dependency, output} {
		a, e := filepath.Abs(*p)
		if e != nil {
			return e
		}
		*p = a
	}
	r, e := filepath.EvalSymlinks(*root)
	if e != nil {
		return e
	}
	*root = r
	dep, e := admitDependency(*root, *dependency)
	if e != nil {
		return e
	}
	var raw any
	if e = loadJSON(*artifact, &raw); e != nil {
		return e
	}
	if e = loadJSON(*input, &raw); e != nil {
		return e
	}
	out, e := synchronous(*root, []string{"node", filepath.Join(*root, "tools/solo5/native-arithmetic/admit.mjs"), *artifact, *input}, 30*time.Second)
	if e != nil {
		return fmt.Errorf("PeerDataAdmission: %w", e)
	}
	admitted, e := decodeNativeAdmission([]byte(out.Stdout))
	if e != nil {
		return e
	}
	data := admitted.Data
	if e = freshDirectory(*root, *output); e != nil {
		return e
	}
	hello, e := canonical(common(data, "normal", "Hello", 0, 0))
	if e != nil {
		return e
	}
	init, e := canonical(common(data, "normal", "Init", 0, 0))
	if e != nil {
		return e
	}
	header := "#define PEER_HELLO " + strconv.Quote(string(hello)) + "\n#define PEER_INIT " + strconv.Quote(string(init)) + "\n"
	headerPath := filepath.Join(*output, "peer-data.h")
	if e = os.WriteFile(headerPath, []byte(header), 0644); e != nil {
		return e
	}
	sources := []string{filepath.Join(*root, "backends/solo5/native-arithmetic/test-peers/hostile.c"), filepath.Join(*root, "backends/solo5/protocol.h"), filepath.Join(*root, "backends/solo5/protocol.c"), headerPath, *dependency, *artifact, *input}
	host, e := hostSources(*root)
	if e != nil {
		return e
	}
	sources = append(sources, host...)
	for _, p := range []string{"tools/solo5/native-arithmetic/admit.mjs", "tools/solo5/native-arithmetic/lower.mjs", "tools/tc0/artifact.mjs", "tools/tc0/canonical.mjs"} {
		sources = append(sources, filepath.Join(*root, p))
	}
	before, e := sourceHashes(*root, sources)
	if e != nil {
		return e
	}
	mounts := []mount{{sources[0], "/inputs/hostile.c"}, {sources[1], "/inputs/protocol.h"}, {sources[2], "/inputs/protocol.c"}, {headerPath, "/inputs/peer-data.h"}}
	fault := faults[*kind]
	command := `set -eu
cd /work
export TMPDIR=/work PATH=/opt/solo5-install/bin:$PATH
for source in hostile protocol; do
 aarch64-solo5-none-static-cc -std=c99 -Wall -Wextra -Werror -DPEER_KIND=` + fault + ` -I/inputs -c /inputs/$source.c -o $source.o
done
printf '{"type":"solo5.manifest","version":1,"devices":[]}\n' > manifest.json
solo5-elftool gen-manifest manifest.json manifest.c
aarch64-solo5-none-static-cc -c manifest.c -o manifest.o
aarch64-solo5-none-static-ld -z solo5-abi=spt manifest.o hostile.o protocol.o -o guest.spt
printf 'FG_BINARY_BEGIN\n'; base64 guest.spt; printf 'FG_BINARY_END\n'
`
	logs := []commandResult{}
	binaries := [][]byte{}
	for i := 0; i < 2; i++ {
		log, e := isolatedBuild(*root, dep.Image, mounts, command, *output)
		logs = append(logs, log)
		if e != nil {
			_ = writeJSONFresh(filepath.Join(*output, "build-diagnostics.json"), logs)
			return fmt.Errorf("PeerCompile: %w", e)
		}
		const prefix = "FG_BINARY_BEGIN\n"
		const suffix = "FG_BINARY_END\n"
		if !strings.HasPrefix(log.Stdout, prefix) || !strings.HasSuffix(log.Stdout, suffix) {
			return fmt.Errorf("PeerTransferFraming")
		}
		body := strings.TrimSuffix(strings.TrimPrefix(log.Stdout, prefix), suffix)
		b, e := base64.StdEncoding.Strict().DecodeString(strings.ReplaceAll(body, "\n", ""))
		if e != nil || len(b) == 0 {
			return fmt.Errorf("PeerTransferEncoding")
		}
		binaries = append(binaries, b)
	}
	if e = writeJSONFresh(filepath.Join(*output, "build-diagnostics.json"), logs); e != nil {
		return e
	}
	if !bytes.Equal(binaries[0], binaries[1]) {
		return fmt.Errorf("PeerTwoBuildsDiffer")
	}
	if e = verifyHashes(*root, before); e != nil {
		return e
	}
	if _, e = admitDependency(*root, *dependency); e != nil {
		return e
	}
	binary := filepath.Join(*output, "guest.spt")
	if e = os.WriteFile(binary, binaries[0], 0644); e != nil {
		return e
	}
	// Shorter declared fault watchdog. Empty model means NO semantic samples;
	// these peers never emit a Terminal and cannot obtain Admitted conformance.
	parent, cancel := context.WithCancel(context.Background())
	defer cancel()
	cancelMS := 0
	if strings.HasPrefix(*kind, "cancel-") {
		cancelMS = 1500
		joined := make(chan struct{})
		timer := time.AfterFunc(time.Duration(cancelMS)*time.Millisecond, func() { cancel(); close(joined) })
		defer func() {
			if !timer.Stop() {
				<-joined
			}
		}()
	}
	result, e := runSessionContext(parent, *root, buildReport{Image: dep.Image}, data, referenceResult{}, binary, "normal", 2*time.Second, nil)
	if e != nil {
		return e
	}
	if e = verifyHashes(*root, before); e != nil {
		return e
	}
	if _, e = admitDependency(*root, *dependency); e != nil {
		return e
	}
	bundle := map[string]any{"schema": "fenrir.solo5.transport-peer-development/1", "role": "transport-peer-not-language-candidate", "qualification": "UNKNOWN", "kind": *kind, "watchdog_ms": 2000, "parent_cancel_ms": cancelMS, "two_builds_equal": true, "guest_sha256": hashBytes(binaries[0]), "sources": before, "image": dep.Image, "tender_sha256": dep.Tender, "result": result}
	if e = writeJSONFresh(filepath.Join(*output, "peer.json"), bundle); e != nil {
		return e
	}
	if result.Cleanup != "confirmed" || result.Conformance != "Unknown" {
		return fmt.Errorf("PeerExpectedUnknownConformanceAndCleanup")
	}
	if *kind == "malformed" && (len(result.Trace) != 1 || len(result.Choices) != 1 || result.Execution != "StoppedAtDivergence" || result.FirstError["kind"] != "MalformedHeader") {
		return fmt.Errorf("PeerMalformedExpectation")
	}
	if *kind == "nonyield" && (len(result.Trace) != 0 || len(result.Choices) != 0 || result.Execution != "HarnessTimeout") {
		return fmt.Errorf("PeerWatchdogExpectation")
	}
	if (*kind == "eof-hello" || *kind == "eof-prefix") && (result.Execution != "HarnessError" || result.Exit != "0" || result.FirstError != nil) {
		return fmt.Errorf("PeerIncompleteEOFExpectation")
	}
	if *kind == "eof-hello" && (len(result.Trace) != 0 || len(result.Choices) != 0) {
		return fmt.Errorf("PeerEOFHelloPrefix")
	}
	if *kind == "eof-prefix" && (len(result.Trace) != 1 || len(result.Choices) != 1) {
		return fmt.Errorf("PeerEOFValidPrefix")
	}
	if *kind == "crash" && (result.Execution != "CandidateCrash" || len(result.Trace) != 1 || len(result.Choices) != 1) {
		return fmt.Errorf("PeerCrashExpectation")
	}
	if strings.HasPrefix(*kind, "cancel-") && result.Execution != "HarnessCanceled" {
		return fmt.Errorf("PeerCancellationExpectation")
	}
	if *kind == "cancel-hello" && (len(result.Trace) != 0 || len(result.Choices) != 0) {
		return fmt.Errorf("PeerCancelHelloPrefix")
	}
	if *kind == "cancel-fragment" && (len(result.Trace) != 1 || len(result.Choices) != 1) {
		return fmt.Errorf("PeerCancelFragmentPrefix")
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"role": "transport-peer-not-language-candidate", "qualification": "UNKNOWN", "execution": result.Execution, "conformance": result.Conformance, "first_error": result.FirstError, "cleanup": result.Cleanup, "report": filepath.Join(*output, "peer.json")})
}
