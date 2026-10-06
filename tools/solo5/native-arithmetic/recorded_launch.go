package main

import (
	"fmt"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
)

var recordedContainerName = regexp.MustCompile(`^fenrir-solo5-native-[a-f0-9]{16}$`)
var recordedOwner = regexp.MustCompile(`^org\.fenrir\.probe\.owner=[a-f0-9]{32}$`)
var recordedImage = regexp.MustCompile(`^sha256:[a-f0-9]{64}$`)

// Validate the retained actual Docker argv, not a normalized replacement.
// Empty expected identities permit shape-only tape checks; production replay
// separately supplies independently admitted image and guest launch identities.
func validateRecordedSessionLaunch(command []string, mode, image, binary string) error {
	bad := func() error { return fmt.Errorf("ReplayLaunchIdentity") }
	if mode != "normal" && mode != "mutant" {
		return bad()
	}
	// Extract only the three run-local/identity fields at fixed canonical positions;
	// full reconstruction below rejects omitted/reordered/extra policy switches.
	if len(command) != 29 || !recordedContainerName.MatchString(command[3]) || !recordedOwner.MatchString(command[5]) || !recordedImage.MatchString(command[22]) {
		return bad()
	}
	const prefix = "type=bind,src="
	const suffix = ",dst=/guest/guest.spt,readonly"
	spec := command[21]
	if !strings.HasPrefix(spec, prefix) || !strings.HasSuffix(spec, suffix) {
		return bad()
	}
	source := strings.TrimSuffix(strings.TrimPrefix(spec, prefix), suffix)
	if !filepath.IsAbs(source) || strings.Contains(source, ",") {
		return bad()
	}
	if image != "" && image != command[22] || binary != "" && binary != source {
		return bad()
	}
	owner := strings.TrimPrefix(command[5], "org.fenrir.probe.owner=")
	want := append(dockerArgs(command[3], owner, command[22], []mount{{source, "/guest/guest.spt"}}, false, true), "/opt/fenrir/solo5-spt-control", "--mem=16", "--fenrir-control-stdin", "/guest/guest.spt", "--solo5:quiet", mode)
	if !reflect.DeepEqual(command, want) {
		return bad()
	}
	return nil
}
