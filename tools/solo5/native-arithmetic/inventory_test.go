package main

import "testing"

func TestReplayRequiresIndependentInventory(t *testing.T) {
	required := map[string]string{"model": "m", "boot": "b", "node": "n", "host": "h", "dependency": "d", "guest": "g", "input": "i"}
	if e := verifyReplayInventory(required, required); e != nil {
		t.Fatal(e)
	}
	for key := range required {
		t.Run("omitted-"+key, func(t *testing.T) {
			supplied := map[string]string{}
			for k, v := range required {
				if k != key {
					supplied[k] = v
				}
			}
			if e := verifyReplayInventory(required, supplied); e == nil {
				t.Fatal("omitted required identity admitted")
			}
		})
	}
	for _, key := range []string{"node", "host", "guest", "input"} {
		t.Run("swapped-"+key, func(t *testing.T) {
			supplied := map[string]string{}
			for k, v := range required {
				supplied[k] = v
			}
			supplied[key] = "swapped"
			if e := verifyReplayInventory(required, supplied); e == nil {
				t.Fatal("swapped identity admitted")
			}
		})
	}
	extra := map[string]string{}
	for k, v := range required {
		extra[k] = v
	}
	extra["unrelated"] = "u"
	if e := verifyReplayInventory(required, extra); e == nil {
		t.Fatal("extra source admitted")
	}
}
