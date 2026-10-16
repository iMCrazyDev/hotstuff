// Command teebench measures the cost of TEE-related operations from inside the
// runtime it is started in: natively, under Gramine (gramine-direct or
// gramine-sgx) or under EGo. It complements the SGX SDK microbenchmark
// (tee/sgx-microbench), which measures raw ECALL/OCALL and DCAP costs in C:
// teebench measures what a Go replica actually pays inside each runtime.
//
// Every operation is timed over a number of samples; fast operations are timed
// in batches and reported per operation. Results, including the raw samples,
// are written as JSON for tee/scripts/analyze_tee.py.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"runtime"
	"slices"
	"strings"
	"time"
)

// op is a single benchmarked operation.
type op struct {
	name string
	desc string
	// batch is the number of operations timed together per sample.
	batch int
	// samples overrides the default number of samples (for slow operations).
	samples int
	// setup prepares the operation and returns the function to time and a cleanup function.
	setup func() (run func() error, cleanup func(), err error)
}

type stats struct {
	N     int     `json:"n"`
	Mean  float64 `json:"mean"`
	Stdev float64 `json:"stdev"`
	Min   float64 `json:"min"`
	P50   float64 `json:"p50"`
	P90   float64 `json:"p90"`
	P95   float64 `json:"p95"`
	P99   float64 `json:"p99"`
	Max   float64 `json:"max"`
}

type result struct {
	Name    string    `json:"name"`
	Desc    string    `json:"desc"`
	Batch   int       `json:"batch"`
	Unit    string    `json:"unit"`
	Stats   *stats    `json:"stats,omitempty"`
	Samples []float64 `json:"samples,omitempty"`
	Error   string    `json:"error,omitempty"`
}

type report struct {
	Runtime     string `json:"runtime"`
	Attestation string `json:"attestation"`
	GoVersion   string `json:"go_version"`
	GOMAXPROCS  int    `json:"gomaxprocs"`
	NumCPU      int    `json:"num_cpu"`
	// ClockResolutionNS is the smallest observed step of time.Now; EGo's
	// in-enclave clock, for example, only advances once per millisecond.
	ClockResolutionNS int64     `json:"clock_resolution_ns"`
	Start             time.Time `json:"start"`
	Results           []result  `json:"results"`
}

func main() {
	var (
		runtimeName  = flag.String("runtime", "native", "label of the runtime this benchmark runs in")
		out          = flag.String("out", "-", "output JSON file (- for stdout)")
		samples      = flag.Int("samples", 10000, "samples per fast operation")
		slowSamples  = flag.Int("slow-samples", 300, "samples per slow operation (quotes)")
		warmup       = flag.Int("warmup", 200, "untimed warm-up samples per operation")
		only         = flag.String("ops", "", "comma-separated operations to run (default: all)")
		quoteOut     = flag.String("quote-out", "", "write one attestation quote to this file (for tee/sgx-microbench verify)")
		noRawSamples = flag.Bool("no-raw", false, "omit raw samples from the output")
		coarseN      = flag.Int("coarse-samples", 300, "samples per operation when the clock is coarse (batches are enlarged instead)")
	)
	flag.Parse()

	ops := append(baseOps(), attestOps(*quoteOut)...)
	if *only != "" {
		want := strings.Split(*only, ",")
		ops = slices.DeleteFunc(ops, func(o op) bool { return !slices.Contains(want, o.name) })
	}

	res := clockResolution()
	coarse := res > 10*time.Microsecond
	if coarse {
		fmt.Fprintf(os.Stderr, "coarse clock (%s per step): batching each sample over >= %s\n", res, coarseSampleTicks*res)
	}
	rep := report{
		ClockResolutionNS: res.Nanoseconds(),
		Runtime:           *runtimeName,
		Attestation:       attestationType(),
		GoVersion:         runtime.Version(),
		GOMAXPROCS:        runtime.GOMAXPROCS(0),
		NumCPU:            runtime.NumCPU(),
		Start:             time.Now(),
	}
	for _, o := range ops {
		n := *samples
		if o.samples > 0 {
			n = min(o.samples, *slowSamples)
		}
		minSample := time.Duration(0)
		if coarse {
			n, minSample = min(n, *coarseN), coarseSampleTicks*res
		}
		res := measure(o, n, *warmup, minSample)
		if res.Error != "" {
			fmt.Fprintf(os.Stderr, "%-24s error: %s\n", o.name, res.Error)
		} else {
			fmt.Fprintf(os.Stderr, "%-24s p50 %10.3f us  p99 %10.3f us  (n=%d, batch=%d)\n",
				o.name, res.Stats.P50/1e3, res.Stats.P99/1e3, res.Stats.N, res.Batch)
		}
		if *noRawSamples {
			res.Samples = nil
		}
		rep.Results = append(rep.Results, res)
	}

	b, err := json.MarshalIndent(rep, "", "  ")
	if err != nil {
		fatal(err)
	}
	if *out == "-" {
		_, err = os.Stdout.Write(append(b, '\n'))
	} else {
		err = os.WriteFile(*out, b, 0o644)
	}
	if err != nil {
		fatal(err)
	}
}

// coarseSampleTicks is the minimum length of one sample, in clock steps, when
// the clock is coarse: it bounds the quantization error of a sample to ~2%.
const coarseSampleTicks = 50

// clockResolution returns the smallest step of time.Now observed over a few steps.
func clockResolution() time.Duration {
	step := time.Duration(math.MaxInt64)
	deadline := time.Now().Add(500 * time.Millisecond)
	prev := time.Now()
	for steps := 0; steps < 20; {
		now := time.Now()
		if d := now.Sub(prev); d > 0 {
			step = min(step, d)
			prev = now
			steps++
		}
		if now.After(deadline) {
			break
		}
	}
	return step
}

// measure runs warm-up samples and then n timed samples of the operation.
// If minSample is set, the batch is doubled until one batch takes at least
// minSample, so that a coarse clock still yields accurate per-operation times.
func measure(o op, n, warmup int, minSample time.Duration) (res result) {
	res = result{Name: o.name, Desc: o.desc, Batch: max(o.batch, 1), Unit: "ns/op"}
	run, cleanup, err := o.setup()
	if err != nil {
		res.Error = err.Error()
		return res
	}
	defer cleanup()
	if minSample > 0 {
		// one untimed call first: first calls can be much slower (e.g. loading the
		// Quoting Enclave) and would stop the batch calibration below too early
		if err := run(); err != nil {
			res.Error = err.Error()
			return res
		}
	}
	for minSample > 0 {
		start := time.Now()
		for range res.Batch {
			if err := run(); err != nil {
				res.Error = err.Error()
				return res
			}
		}
		if time.Since(start) >= minSample || res.Batch >= 1<<24 {
			break
		}
		res.Batch *= 2
	}
	if minSample > 0 {
		warmup = min(warmup, 3)
	}
	warmup = min(warmup, n)
	samples := make([]float64, 0, n)
	for i := range warmup + n {
		start := time.Now()
		for range res.Batch {
			if err := run(); err != nil {
				res.Error = err.Error()
				return res
			}
		}
		elapsed := time.Since(start)
		if i >= warmup {
			samples = append(samples, float64(elapsed.Nanoseconds())/float64(res.Batch))
		}
	}
	res.Samples = samples
	res.Stats = summarize(samples)
	return res
}

func summarize(samples []float64) *stats {
	s := slices.Clone(samples)
	slices.Sort(s)
	var sum, sq float64
	for _, v := range s {
		sum += v
	}
	mean := sum / float64(len(s))
	for _, v := range s {
		sq += (v - mean) * (v - mean)
	}
	q := func(p float64) float64 {
		return s[min(len(s)-1, int(math.Ceil(p*float64(len(s))))-1)]
	}
	return &stats{
		N:     len(s),
		Mean:  mean,
		Stdev: math.Sqrt(sq / float64(max(len(s)-1, 1))),
		Min:   s[0],
		P50:   q(0.50),
		P90:   q(0.90),
		P95:   q(0.95),
		P99:   q(0.99),
		Max:   s[len(s)-1],
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "teebench:", err)
	os.Exit(1)
}
