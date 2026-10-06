package main

import (
	"encoding/json"
	"testing"
)

func launchFixture(t *testing.T, command []string, change func(map[string]any)) dockerInfo {
	t.Helper()
	b, e := json.Marshal(policyFixture())
	if e != nil {
		t.Fatal(e)
	}
	var d map[string]any
	if e = json.Unmarshal(b, &d); e != nil {
		t.Fatal(e)
	}
	config := d["Config"].(map[string]any)
	config["Cmd"] = command
	config["Entrypoint"] = []string{}
	d["Path"] = command[0]
	d["Args"] = command[1:]
	if change != nil {
		change(d)
	}
	b, e = json.Marshal([]any{d})
	if e != nil {
		t.Fatal(e)
	}
	info, e := decodeDockerInspect(b)
	if e != nil {
		t.Fatal(e)
	}
	return info
}

func TestContainerLaunchContradictions(t *testing.T) {
	for _, command := range [][]string{{"sh", "-c", "fixed compilation script"}, {"/opt/fenrir/solo5-spt-control", "--mem=16", "--fenrir-control-stdin", "/guest/guest.spt", "--solo5:quiet", "normal"}} {
		changes := map[string]func(map[string]any){
			"cmd":          func(d map[string]any) { d["Config"].(map[string]any)["Cmd"] = []string{"wrong"} },
			"missing cmd":  func(d map[string]any) { delete(d["Config"].(map[string]any), "Cmd") },
			"entrypoint":   func(d map[string]any) { d["Config"].(map[string]any)["Entrypoint"] = []string{"wrapper"} },
			"path":         func(d map[string]any) { d["Path"] = "wrong" },
			"missing path": func(d map[string]any) { delete(d, "Path") },
			"args":         func(d map[string]any) { d["Args"] = []string{"wrong"} },
			"missing args": func(d map[string]any) { delete(d, "Args") },
		}
		for name, change := range changes {
			t.Run(command[0]+"/"+name, func(t *testing.T) {
				if e := checkPolicy(launchFixture(t, command, change), []mount{}, false, false, command); e == nil {
					t.Fatal("contradictory launch metadata admitted")
				}
			})
		}
		if e := checkPolicy(launchFixture(t, command, nil), []mount{}, false, false, command); e != nil {
			t.Fatal(e)
		}
	}
}
