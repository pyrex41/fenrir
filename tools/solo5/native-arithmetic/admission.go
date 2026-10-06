package main

import (
	"fmt"
	"path/filepath"
	"reflect"
	"strconv"
)

func parseBuildFuel(raw string) (int, error) {
	fuel, e := strconv.Atoi(raw)
	if e != nil || fuel < 0 || fuel > 200 || strconv.Itoa(fuel) != raw {
		return 0, fmt.Errorf("BuildFuelBounds")
	}
	return fuel, nil
}

// Source maps must cover the entire current implementation, not merely the
// entries a retained report happens to supply. Added/removed Go files invalidate
// admission until a fresh build binds the new source set.
func verifyBuildSources(root string, r buildReport) error {
	if r.DataPath == "" || r.DependencyPath == "" || filepath.IsAbs(r.DataPath) || filepath.IsAbs(r.DependencyPath) {
		return fmt.Errorf("MissingBuildInputPaths")
	}
	paths, e := hostSources(root)
	if e != nil {
		return e
	}
	for _, p := range []string{"backends/solo5/native-arithmetic/machine.h", "backends/solo5/native-arithmetic/machine.c", "backends/solo5/native-arithmetic/format.h", "backends/solo5/native-arithmetic/format.c", "backends/solo5/native-arithmetic/guest.c", "backends/solo5/protocol.h", "backends/solo5/protocol.c", "tools/solo5/native-arithmetic/lower.mjs", "tools/solo5/native-arithmetic/admit.mjs", "tools/tc0/artifact.mjs", "tools/tc0/canonical.mjs", r.DataPath, r.DependencyPath} {
		paths = append(paths, filepath.Join(root, p))
	}
	current, e := sourceHashes(root, paths)
	if e != nil {
		return e
	}
	if !reflect.DeepEqual(current, r.Before) || !reflect.DeepEqual(current, r.After) {
		return fmt.Errorf("BuildSourceSetOrIdentityDrift")
	}
	if current[r.DataPath] != r.Data || current[r.DependencyPath] != r.Dependency {
		return fmt.Errorf("BuildInputIdentity")
	}
	return nil
}
