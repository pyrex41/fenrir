package main

import (
	"fmt"
	"reflect"
	"strconv"
)

const nativeBuildSchema = "fenrir.solo5.native-arithmetic-build/2"

// Unchanged compilation recipe; receipt binding does not alter the candidate,
// compiler flags, tender, manifest or isolation policy.
func nativeCompileScript(fuel int) string {
	return `set -eu
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
}

func validateBuildCompileCommand(r buildReport) error {
	fuel, e := parseBuildFuel(r.Fuel)
	if e != nil {
		return e
	}
	if !reflect.DeepEqual(r.CompileCommand, []string{"sh", "-c", nativeCompileScript(fuel)}) {
		return fmt.Errorf("BuildCompileCommand")
	}
	return nil
}
