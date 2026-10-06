package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
)

const profile = "fenrir.solo5.native-arithmetic-demo/1"

type dependencyReport struct {
	Schema        string            `json:"schema"`
	Qualification string            `json:"qualification"`
	Cleanup       string            `json:"cleanup"`
	Equal         bool              `json:"two_tender_builds_equal"`
	Before        map[string]string `json:"sources_before"`
	After         map[string]string `json:"sources_after"`
	Image         string            `json:"overlay_image"`
	Stock         string            `json:"stock_image"`
	Tender        string            `json:"tender_sha256"`
	Solo5Commit   string            `json:"solo5_commit"`
	OverlayTag    string            `json:"overlay_tag_advisory"`
	PatchedSource string            `json:"patched_source_sha256"`
	Patch         string            `json:"patch_sha256"`
	Recipe        string            `json:"recipe_sha256"`
	Toolchain     string            `json:"toolchain_inventory"`
	Command       []string          `json:"command"`
	Scope         string            `json:"scope"`
	Limitations   []string          `json:"limitations"`
}
type buildReport struct {
	Schema         string            `json:"schema"`
	Qualification  string            `json:"qualification"`
	Profile        string            `json:"profile"`
	Cleanup        string            `json:"cleanup"`
	Image          string            `json:"image"`
	Dependency     string            `json:"transport_build_sha256"`
	DependencyPath string            `json:"transport_build_path"`
	DataPath       string            `json:"data_path"`
	Tender         string            `json:"tender_sha256"`
	Guest          string            `json:"guest_sha256"`
	Data           string            `json:"data_sha256"`
	Fuel           string            `json:"fuel"`
	Before         map[string]string `json:"sources_before"`
	After          map[string]string `json:"sources_after"`
	Equal          bool              `json:"two_builds_equal"`
	Command        []string          `json:"command"`
	Limitations    []string          `json:"limitations"`
}

func hashBytes(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func digest(p string) (string, error) {
	// Nonblocking open lets us reject FIFOs without waiting for a writer.
	// Inspect the opened descriptor, not the path, before streaming bytes.
	f, e := os.OpenFile(p, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if e != nil {
		return "", e
	}
	defer f.Close()
	info, e := f.Stat()
	if e != nil {
		return "", e
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("DigestRegularFileRequired")
	}
	h := sha256.New()
	if _, e = io.Copy(h, f); e != nil {
		return "", e
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
func within(root, p string) bool {
	r, e := filepath.Rel(root, p)
	return e == nil && r != "." && r != ".." && !strings.HasPrefix(r, ".."+string(filepath.Separator)) && !filepath.IsAbs(r)
}
func sealedPath(root, p string) (string, error) {
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	a, e := filepath.Abs(p)
	if e != nil {
		return "", e
	}
	a, e = filepath.EvalSymlinks(a)
	if e != nil {
		return "", e
	}
	if !within(root, a) {
		return "", fmt.Errorf("PathOutsideRoot: %s", p)
	}
	return a, nil
}
func sourceHashes(root string, paths []string) (map[string]string, error) {
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, err
	}
	m := map[string]string{}
	for _, p := range paths {
		a, e := sealedPath(root, p)
		if e != nil {
			return nil, e
		}
		r, e := filepath.Rel(root, a)
		if e != nil {
			return nil, e
		}
		h, e := digest(a)
		if e != nil {
			return nil, e
		}
		m[r] = h
	}
	return m, nil
}
func verifyHashes(root string, m map[string]string) error {
	if len(m) == 0 {
		return fmt.Errorf("EmptySourceIdentity")
	}
	for p, h := range m {
		if filepath.IsAbs(p) {
			return fmt.Errorf("AbsoluteSourcePath")
		}
		a, e := sealedPath(root, filepath.Join(root, p))
		if e != nil {
			return e
		}
		actual, e := digest(a)
		if e != nil {
			return e
		}
		if actual != h {
			return fmt.Errorf("SourceDrift: %s", p)
		}
	}
	return nil
}
func admitDependency(root, path string) (dependencyReport, error) {
	var r dependencyReport
	if e := loadJSON(path, &r); e != nil {
		return r, e
	}
	if r.Schema != "fenrir.solo5.control-build/1" || r.Qualification != "UNKNOWN" || r.Cleanup != "confirmed" || !r.Equal || !reflect.DeepEqual(r.Before, r.After) {
		return r, fmt.Errorf("DependencyReceipt")
	}
	if e := verifyDependencyInventory(root, r.After); e != nil {
		return r, e
	}
	image, e := inspect(root, "image", "inspect", r.Image)
	if e != nil {
		return r, e
	}
	stock, e := inspect(root, "image", "inspect", r.Stock)
	if e != nil {
		return r, e
	}
	if image.ID != r.Image || stock.ID != r.Stock || len(image.RootFS.Layers) != len(stock.RootFS.Layers)+1 || !reflect.DeepEqual(image.RootFS.Layers[:len(stock.RootFS.Layers)], stock.RootFS.Layers) {
		return r, fmt.Errorf("ImageProvenance")
	}
	return r, nil
}
func freshDirectory(root, dest string) error {
	base, e := filepath.EvalSymlinks(filepath.Join(root, "build/solo5"))
	if e != nil {
		return e
	}
	parent, e := filepath.EvalSymlinks(filepath.Dir(dest))
	if e != nil {
		return e
	}
	if parent != base && !within(base, parent) {
		return fmt.Errorf("OutputOutsideBuild")
	}
	if _, e = os.Lstat(dest); !os.IsNotExist(e) {
		return fmt.Errorf("FreshOutputRequired")
	}
	return os.Mkdir(dest, 0755)
}
func writeJSONFresh(path string, v any) error {
	b, e := json.MarshalIndent(v, "", "  ")
	if e != nil {
		return e
	}
	f, e := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0644)
	if e != nil {
		return e
	}
	_, e = f.Write(append(b, '\n'))
	ce := f.Close()
	if e != nil {
		return e
	}
	return ce
}
func hostSources(root string) ([]string, error) {
	paths, e := filepath.Glob(filepath.Join(root, "tools/solo5/native-arithmetic/*.go"))
	if e != nil {
		return nil, e
	}
	return append(paths, filepath.Join(root, "tools/solo5/native-arithmetic/go.mod")), nil
}
func compileGuest(root, data, dest, dependency string, fuel int) (r buildReport, err error) {
	if fuel < 0 || fuel > 200 {
		return r, fmt.Errorf("FuelBounds")
	}
	dep, e := admitDependency(root, dependency)
	if e != nil {
		return r, e
	}
	data, e = sealedPath(filepath.Join(root, "build/solo5"), data)
	if e != nil {
		return r, e
	}
	info, e := os.Stat(data)
	if e != nil || info.Size() > 65536 {
		return r, fmt.Errorf("DataHeaderBounds")
	}
	files := []string{}
	for _, name := range []string{"machine.h", "machine.c", "format.h", "format.c", "guest.c"} {
		files = append(files, filepath.Join(root, "backends/solo5/native-arithmetic", name))
	}
	files = append(files, filepath.Join(root, "backends/solo5/protocol.h"), filepath.Join(root, "backends/solo5/protocol.c"))
	mounts := []mount{}
	for _, p := range files {
		mounts = append(mounts, mount{p, "/inputs/" + filepath.Base(p)})
	}
	mounts = append(mounts, mount{data, "/inputs/data.h"})
	host, e := hostSources(root)
	if e != nil {
		return r, e
	}
	files = append(files, host...)
	files = append(files, filepath.Join(root, "tools/solo5/native-arithmetic/lower.mjs"), data, dependency)
	for _, p := range []string{"tools/solo5/native-arithmetic/admit.mjs", "tools/tc0/artifact.mjs", "tools/tc0/canonical.mjs"} {
		files = append(files, filepath.Join(root, p))
	}
	before, e := sourceHashes(root, files)
	if e != nil {
		return r, e
	}
	if e = freshDirectory(root, dest); e != nil {
		return r, e
	}
	logs := []commandResult{}
	defer func() {
		if e := writeJSONFresh(filepath.Join(dest, "diagnostics.json"), logs); e != nil {
			err = e
		}
	}()
	command := `set -eu
cd /work
export TMPDIR=/work PATH=/opt/solo5-install/bin:$PATH
for source in guest machine format protocol; do
 aarch64-solo5-none-static-cc -std=c99 -Wall -Wextra -Werror -DNA_FUEL=` + strconv.Itoa(fuel) + ` -I/inputs -c /inputs/$source.c -o $source.o
done
printf '{"type":"solo5.manifest","version":1,"devices":[]}\n' > manifest.json
solo5-elftool gen-manifest manifest.json manifest.c
aarch64-solo5-none-static-cc -c manifest.c -o manifest.o
aarch64-solo5-none-static-ld -z solo5-abi=spt manifest.o guest.o machine.o format.o protocol.o -o guest.spt
printf 'FG_BINARY_BEGIN\n'; base64 guest.spt; printf 'FG_BINARY_END\n'
`
	binaries := [][]byte{}
	for i := 0; i < 2; i++ {
		out, e := isolatedBuild(root, dep.Image, mounts, command, dest)
		logs = append(logs, out)
		if e != nil {
			return r, fmt.Errorf("GuestCompile: %w: %s", e, out.Stderr)
		}
		const prefix = "FG_BINARY_BEGIN\n"
		const suffix = "FG_BINARY_END\n"
		if !strings.HasPrefix(out.Stdout, prefix) || !strings.HasSuffix(out.Stdout, suffix) {
			return r, fmt.Errorf("ArtifactTransferFraming")
		}
		body := strings.TrimSuffix(strings.TrimPrefix(out.Stdout, prefix), suffix)
		for _, c := range body {
			if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '+' || c == '/' || c == '=' || c == '\n') {
				return r, fmt.Errorf("ArtifactTransferEncoding")
			}
		}
		b, e := base64.StdEncoding.Strict().DecodeString(strings.ReplaceAll(body, "\n", ""))
		if e != nil || len(b) == 0 {
			return r, fmt.Errorf("ArtifactTransferEncoding")
		}
		binaries = append(binaries, b)
	}
	if !bytes.Equal(binaries[0], binaries[1]) {
		return r, fmt.Errorf("TwoBuildsDiffer")
	}
	if e = verifyHashes(root, before); e != nil {
		return r, e
	}
	if _, e = admitDependency(root, dependency); e != nil {
		return r, e
	}
	guest := filepath.Join(dest, "guest.spt")
	if e = os.WriteFile(guest, binaries[0], 0644); e != nil {
		return r, e
	}
	gh, e := digest(guest)
	if e != nil {
		return r, e
	}
	dh, e := digest(data)
	if e != nil {
		return r, e
	}
	deph, e := digest(dependency)
	if e != nil {
		return r, e
	}
	dataRel, e := filepath.Rel(root, data)
	if e != nil {
		return r, e
	}
	depRel, e := filepath.Rel(root, dependency)
	if e != nil {
		return r, e
	}
	r = buildReport{Schema: "fenrir.solo5.native-arithmetic-build/1", Qualification: "UNKNOWN", Profile: profile, Cleanup: "confirmed", Image: dep.Image, Dependency: deph, DependencyPath: depRel, DataPath: dataRel, Tender: dep.Tender, Guest: gh, Data: dh, Fuel: strconv.Itoa(fuel), Before: before, After: before, Equal: true, Command: os.Args, Limitations: []string{"Native startup/counters unmediated", "Not TC0/G4/G5 qualification"}}
	if e = writeJSONFresh(filepath.Join(dest, "build.json"), r); e != nil {
		return r, e
	}
	return r, nil
}
