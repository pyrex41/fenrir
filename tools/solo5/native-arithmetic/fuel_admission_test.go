package main

import "testing"

func TestBuildFuelCanonicalBound(t *testing.T) {
	for _, raw := range []string{"", "04", "+4", "-0", " 4", "4 ", "-1", "201", "4.0", "1e2", "999999999999999999999999999"} {
		t.Run("reject-"+raw, func(t *testing.T) {
			if _, e := parseBuildFuel(raw); e == nil || e.Error() != "BuildFuelBounds" {
				t.Fatalf("unsafe build fuel %q admitted: %v", raw, e)
			}
		})
	}
	for raw, want := range map[string]int{"0": 0, "3": 3, "4": 4, "200": 200} {
		got, e := parseBuildFuel(raw)
		if e != nil || got != want {
			t.Fatalf("builder fuel %q rejected: %d %v", raw, got, e)
		}
	}
}
