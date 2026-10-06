package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	if e := runCLI(os.Args[1:]); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
func runCLI(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("expected build subcommand")
	}
	switch args[0] {
	case "campaign":
		return campaignCLI(args[1:])
	case "campaign-inspect":
		return campaignInspectCLI(args[1:])
	case "peer":
		return peerCLI(args[1:])
	case "session":
		return sessionCLI(args[1:])
	case "replay":
		return replayCLI(args[1:])
	case "build":
		f := flag.NewFlagSet("build", flag.ContinueOnError)
		root := f.String("root", ".", "repository root")
		data := f.String("data", "", "validated data header")
		dest := f.String("output-dir", "", "fresh build/solo5 directory")
		dep := f.String("transport-build", "", "retained tender build report")
		fuel := f.Int("fuel", 200, "bounded transition fuel")
		if e := f.Parse(args[1:]); e != nil {
			return e
		}
		if f.NArg() != 0 || *data == "" || *dest == "" || *dep == "" {
			return fmt.Errorf("required build flags missing or extra arguments")
		}
		r, e := filepath.Abs(*root)
		if e != nil {
			return e
		}
		r, e = filepath.EvalSymlinks(r)
		if e != nil {
			return e
		}
		d, e := filepath.Abs(*data)
		if e != nil {
			return e
		}
		o, e := filepath.Abs(*dest)
		if e != nil {
			return e
		}
		p, e := filepath.Abs(*dep)
		if e != nil {
			return e
		}
		report, e := compileGuest(r, d, o, p, *fuel)
		if e != nil {
			return e
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"qualification": "UNKNOWN", "two_builds_equal": report.Equal, "cleanup": report.Cleanup, "report": filepath.Join(o, "build.json")})
	default:
		return fmt.Errorf("unsupported subcommand %q", args[0])
	}
}
