// Fixed-rate loopback benchmark. Requests retain their scheduled timestamps
// while a connection is busy, so queueing delay contributes to tail latency.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/bits"
	"net"
	"net/http"
	"os"
	"runtime"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type endpoint struct {
	path, body, kind string
	status           int
}

var cases = []endpoint{
	{"/", "fenrir\n", "text/plain", 200},
	{"/items/00012", "00012", "text/plain", 200},
	{"/status", "{\"ok\":true}\n", "application/json", 200},
	{"/missing", "", "text/plain", 404},
}

type sample struct {
	Second, Scheduled, Completed, Backlog int
	ObservedNs                            int64
	Errors                                int64
}

// Bucket zero contains zero ns. Bucket k contains [2^(k-1), 2^k) ns.
type phases struct {
	PreviousRequest [64]int
	Dispatch        [64]int
	Fetch           [64]int
}

type slowRequest struct {
	Index, Lane                                       int
	ElapsedNs, PreviousRequestNs, DispatchNs, FetchNs int64
}

type laneOrigin struct {
	RunFetchNs int64
	slowRequest
	Valid bool
}

type driverCPU struct {
	UserNs, SystemNs int64
}

func readDriverUsage() (driverCPU, int64) {
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		panic(err)
	}
	var peakBytes int64
	switch runtime.GOOS {
	case "darwin":
		peakBytes = usage.Maxrss
	case "linux":
		peakBytes = usage.Maxrss * 1024
	}
	return driverCPU{usage.Utime.Nano(), usage.Stime.Nano()}, peakBytes
}

type report struct {
	LastValidCompletionNs                                                 int64
	DriverPeakRSSBytes                                                    int64 `json:",omitempty"`
	DriverCPU                                                             driverCPU
	SlowestLaneOrigin                                                     *laneOrigin  `json:",omitempty"`
	SlowestValid                                                          *slowRequest `json:",omitempty"`
	Address                                                               string
	Rate, Seconds, Connections, Scheduled, Valid, Errors, Invalid, Missed int
	P50ns, P99ns, MaxNs, ElapsedNs                                        int64
	Timeline                                                              []sample
	ErrorKinds                                                            map[string]int
	ValidRequestPhases                                                    phases
}

func errorKind(err error) string {
	var netErr net.Error
	switch {
	case errors.As(err, &netErr) && netErr.Timeout():
		return "timeout"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "connection refused"
	case errors.Is(err, syscall.ECONNRESET):
		return "connection reset"
	case errors.Is(err, syscall.EPIPE):
		return "broken pipe"
	case errors.Is(err, io.EOF):
		return "EOF"
	case errors.Is(err, io.ErrUnexpectedEOF):
		return "unexpected EOF"
	default:
		return "other"
	}
}

func fetch(client *http.Client, base string, e endpoint) (valid bool, err error) {
	res, err := client.Get(base + e.path)
	if err != nil {
		return false, err
	}
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, 8193))
	if err != nil {
		return false, err
	}
	return res.StatusCode == e.status && res.Header.Get("Content-Type") == e.kind && string(body) == e.body, nil
}

func main() {
	addr := flag.String("addr", "", "numeric loopback address:port")
	rate := flag.Int("rate", 1000, "scheduled requests per second")
	seconds := flag.Int("seconds", 10, "offered load duration")
	workers := flag.Int("connections", 16, "persistent connection lanes")
	flag.Parse()
	host, _, err := net.SplitHostPort(*addr)
	if err != nil || !net.ParseIP(host).IsLoopback() || *rate < 1 || *rate > 1000000 ||
		*seconds < 1 || *seconds > 3600 || *rate**seconds > 128_000_000 ||
		*workers < 1 || *workers > 64 {
		fmt.Fprintln(os.Stderr, "invalid loopback workload")
		os.Exit(2)
	}
	total := *rate * *seconds
	times := make([]int64, total)
	base := "http://" + *addr
	var ready, done sync.WaitGroup
	var completed, failed, invalid atomic.Int64
	var start time.Time
	begin := make(chan struct{})
	// Only one goroutine writes each map. Merge them after the workers exit.
	kinds := make([]map[string]int, *workers)
	timings := make([]phases, *workers)
	slowest := make([]slowRequest, *workers)
	lastValid := make([]time.Time, *workers)
	origins := make([]laneOrigin, *workers)
	ready.Add(*workers)
	done.Add(*workers)
	for lane := 0; lane < *workers; lane++ {
		go func(lane int) {
			defer done.Done()
			kinds[lane] = make(map[string]int)
			tr := &http.Transport{MaxConnsPerHost: 1, DisableCompression: true}
			defer tr.CloseIdleConnections()
			client := &http.Client{Transport: tr, Timeout: 5 * time.Second,
				CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
			if valid, err := fetch(client, base, cases[0]); err != nil || !valid {
				fmt.Fprintln(os.Stderr, "connection warmup failed", err)
				os.Exit(2)
			}
			ready.Done()
			<-begin
			var lastValidFinish time.Time
			var origin laneOrigin
			var runFetchNs int64
			available := start
			cutoff := start.Add(time.Duration(*seconds+5) * time.Second)
			for i := lane; i < total; i += *workers {
				due := start.Add(time.Duration(int64(i) * int64(time.Second) / int64(*rate)))
				time.Sleep(time.Until(due))
				issued := time.Now()
				if issued.After(cutoff) {
					break
				}
				valid, err := fetch(client, base, cases[i%len(cases)])
				finished := time.Now()
				elapsed := finished.Sub(due)
				if !available.After(due) {
					// Start of the uninterrupted run of overlapping lane requests.
					runFetchNs = 0
					origin = laneOrigin{slowRequest: slowRequest{i, lane, elapsed.Nanoseconds(), 0,
						issued.Sub(due).Nanoseconds(), finished.Sub(issued).Nanoseconds()}, Valid: valid && err == nil}
				}
				runFetchNs += finished.Sub(issued).Nanoseconds()
				if err != nil {
					failed.Add(1)
					kinds[lane][errorKind(err)]++
				} else if !valid {
					invalid.Add(1)
				} else {
					lastValidFinish = finished
					times[i] = elapsed.Nanoseconds()
					eligible := due
					if available.After(due) {
						eligible = available
					}
					if elapsed.Nanoseconds() > slowest[lane].ElapsedNs {
						origins[lane] = origin
						origins[lane].RunFetchNs = runFetchNs
						slowest[lane] = slowRequest{i, lane, elapsed.Nanoseconds(), eligible.Sub(due).Nanoseconds(),
							issued.Sub(eligible).Nanoseconds(), finished.Sub(issued).Nanoseconds()}
					}
					timings[lane].PreviousRequest[bits.Len64(uint64(eligible.Sub(due)))]++
					timings[lane].Dispatch[bits.Len64(uint64(issued.Sub(eligible)))]++
					timings[lane].Fetch[bits.Len64(uint64(finished.Sub(issued)))]++
				}
				available = finished
				completed.Add(1)
			}
			lastValid[lane] = lastValidFinish
		}(lane)
	}
	ready.Wait()
	initialCPU, _ := readDriverUsage()
	start = time.Now()
	close(begin)
	r := report{Address: *addr, Rate: *rate, Seconds: *seconds, Connections: *workers, Scheduled: total}
	for second := 1; second <= *seconds; second++ {
		time.Sleep(time.Until(start.Add(time.Duration(second) * time.Second)))
		count := int(completed.Load())
		observed := time.Since(start).Nanoseconds()
		scheduled := min(total, int(observed*int64(*rate)/int64(time.Second))+1)
		r.Timeline = append(r.Timeline, sample{second, scheduled, count, max(0, scheduled-count), observed, failed.Load()})
	}
	done.Wait()
	r.ElapsedNs = time.Since(start).Nanoseconds()
	finalCPU, peakBytes := readDriverUsage()
	r.DriverPeakRSSBytes = peakBytes
	r.DriverCPU = driverCPU{finalCPU.UserNs - initialCPU.UserNs, finalCPU.SystemNs - initialCPU.SystemNs}
	for lane := range slowest {
		if !lastValid[lane].IsZero() {
			r.LastValidCompletionNs = max(r.LastValidCompletionNs, lastValid[lane].Sub(start).Nanoseconds())
		}
		candidate := &slowest[lane]
		if candidate.ElapsedNs > 0 && (r.SlowestValid == nil || candidate.ElapsedNs > r.SlowestValid.ElapsedNs) {
			r.SlowestValid = candidate
			r.SlowestLaneOrigin = &origins[lane]
		}
	}
	for _, t := range timings {
		for i := range t.Fetch {
			r.ValidRequestPhases.PreviousRequest[i] += t.PreviousRequest[i]
			r.ValidRequestPhases.Dispatch[i] += t.Dispatch[i]
			r.ValidRequestPhases.Fetch[i] += t.Fetch[i]
		}
	}
	r.ErrorKinds = make(map[string]int)
	for _, counts := range kinds {
		for kind, count := range counts {
			r.ErrorKinds[kind] += count
		}
	}
	r.Errors, r.Invalid = int(failed.Load()), int(invalid.Load())
	r.Missed = total - int(completed.Load())
	validTimes := times[:0]
	for _, elapsed := range times {
		if elapsed > 0 {
			validTimes = append(validTimes, elapsed)
		}
	}
	r.Valid = len(validTimes)
	sort.Slice(validTimes, func(i, j int) bool { return validTimes[i] < validTimes[j] })
	if r.Valid > 0 {
		r.P50ns = validTimes[(r.Valid-1)/2]
		r.P99ns = validTimes[(99*r.Valid+99)/100-1]
		r.MaxNs = validTimes[r.Valid-1]
	}
	if err := json.NewEncoder(os.Stdout).Encode(r); err != nil {
		panic(err)
	}
	if r.Invalid+r.Errors+r.Missed > 0 {
		os.Exit(1)
	}
}
