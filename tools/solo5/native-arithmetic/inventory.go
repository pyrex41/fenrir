package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
)

// Dependency source identities are fixed by the control-build implementation,
// never selected by an incoming receipt.
func requiredDependencyFiles(root string) []string {
	files := []string{}
	for _, p := range []string{
		"tools/solo5/build-control-stdin.py", "tools/solo5/baseline.py", "tools/solo5/transport-feasibility.py",
		"backends/solo5/overlays/control-stdin/overlay.py", "build/vendor/solo5/tenders/spt/spt_core.c",
		"backends/solo5/Dockerfile",
	} {
		files = append(files, filepath.Join(root, p))
	}
	return files
}

func verifyDependencyInventory(root string, supplied map[string]string) error {
	required, e := sourceHashes(root, requiredDependencyFiles(root))
	if e != nil {
		return e
	}
	if !reflect.DeepEqual(required, supplied) {
		return fmt.Errorf("DependencyRequiredSourceSetOrIdentity")
	}
	return nil
}

// This list is derived from the adapter implementation, not the source keys
// supplied by a retained session. New captures explicitly bind dependency data
// and candidate sources as well as executable/model authority.
func requiredSessionFiles(root, build, artifact, input, shen string) ([]string, error) {
	var report buildReport
	if e := loadJSON(build, &report); e != nil {
		return nil, e
	}
	if e := verifyBuildSources(root, report); e != nil {
		return nil, e
	}
	host, e := hostSources(root)
	if e != nil {
		return nil, e
	}
	files := append(host, build, artifact, input, shen, filepath.Join(filepath.Dir(filepath.Dir(shen)), "lib/shen-scheme/shen.boot"), filepath.Join(filepath.Dir(build), "guest.spt"))
	for _, p := range []string{
		"tools/solo5/native-arithmetic/admit.mjs", "tools/solo5/native-arithmetic/lower.mjs",
		"tools/tc0/artifact.mjs", "tools/tc0/canonical.mjs",
		"models/tc0/arithmetic.shen", "models/tc0/expression-machine.shen",
		"backends/solo5/native-arithmetic/machine.h", "backends/solo5/native-arithmetic/machine.c",
		"backends/solo5/native-arithmetic/format.h", "backends/solo5/native-arithmetic/format.c",
		"backends/solo5/native-arithmetic/guest.c", "backends/solo5/protocol.h", "backends/solo5/protocol.c",
		report.DataPath, report.DependencyPath,
	} {
		files = append(files, filepath.Join(root, p))
	}
	files = append(files, requiredDependencyFiles(root)...)
	node, e := exec.LookPath("node")
	if e != nil {
		return nil, e
	}
	self, e := os.Executable()
	if e != nil {
		return nil, e
	}
	return append(files, node, self), nil
}

func verifyReplayInventory(required, supplied map[string]string) error {
	if !reflect.DeepEqual(required, supplied) {
		return fmt.Errorf("ReplayRequiredSourceSetOrIdentity")
	}
	return nil
}
