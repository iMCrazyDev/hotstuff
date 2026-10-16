package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/relab/hotstuff/internal/tree"
	"github.com/spf13/viper"
)

func NewViper() (*ExperimentConfig, error) {
	output := viper.GetString("output")
	if output != "" {
		var err error
		output, err = filepath.Abs(output)
		if err != nil {
			return nil, fmt.Errorf("failed to get absolute path: %v", err)
		}
		if err = os.MkdirAll(output, 0o755); err != nil {
			return nil, fmt.Errorf("failed to create output directory: %v", err)
		}
	}

	intTreePos := viper.GetIntSlice("tree-pos")
	treePos := make([]uint32, len(intTreePos))
	for i, pos := range intTreePos {
		treePos[i] = uint32(pos)
	}

	cfg := &ExperimentConfig{
		Duration:            viper.GetDuration("duration"),
		Replicas:            viper.GetInt("replicas"),
		Clients:             viper.GetInt("clients"),
		ReplicaHosts:        viper.GetStringSlice("replica-hosts"),
		ClientHosts:         viper.GetStringSlice("client-hosts"),
		BranchFactor:        viper.GetUint32("bf"),
		TreeDelta:           viper.GetDuration("tree-delta"),
		RandomTree:          viper.GetBool("random-tree"),
		Output:              output,
		TreePositions:       treePos,
		Worker:              viper.GetBool("worker"),
		Exe:                 viper.GetString("exe"),
		SSHConfig:           viper.GetString("ssh-config"),
		LogLevel:            viper.GetString("log-level"),
		CPUProfile:          viper.GetBool("cpu-profile"),
		MemProfile:          viper.GetBool("mem-profile"),
		Trace:               viper.GetBool("trace"),
		FgProfProfile:       viper.GetBool("fgprof-profile"),
		Metrics:             viper.GetStringSlice("metrics"),
		MeasurementInterval: viper.GetDuration("measurement-interval"),
		BatchSize:           viper.GetUint32("batch-size"),
		Consensus:           viper.GetString("consensus"),
		Crypto:              viper.GetString("crypto"),
		LeaderRotation:      viper.GetString("leader-rotation"),
		Communication:       viper.GetString("communication"),
		ConnectTimeout:      viper.GetDuration("connect-timeout"),
		TimeoutMultiplier:   viper.GetFloat64("timeout-multiplier"),
		ViewTimeout:         viper.GetDuration("view-timeout"),
		DurationSamples:     viper.GetUint32("duration-samples"),
		MaxTimeout:          viper.GetDuration("max-timeout"),
		FixedTimeout:        viper.GetDuration("fixed-timeout"),
		SharedSeed:          viper.GetInt64("shared-seed"),
		PayloadSize:         viper.GetUint32("payload-size"),
		MaxConcurrent:       viper.GetUint32("max-concurrent"),
		RateLimit:           viper.GetFloat64("rate-limit"),
		RateStep:            viper.GetFloat64("rate-step"),
		RateStepInterval:    viper.GetDuration("rate-step-interval"),
		ClientTimeout:       viper.GetDuration("client-timeout"),
		UseAggQC:            viper.GetBool("agg-qc"),
		UseTLS:              true,
		ReplicaProcs:        viper.GetInt("replica-procs"),
		WorkerCmd:           strings.Fields(viper.GetString("worker-cmd")),
		WorkerDir:           viper.GetString("worker-dir"),
		WorkerEnv:           viper.GetStringSlice("worker-env"),
		ProcDataDir:         viper.GetString("proc-data-dir"),
		WorkerStartTimeout:  viper.GetDuration("worker-start-timeout"),
	}

	if len(cfg.ReplicaHosts) == 0 {
		cfg.ReplicaHosts = []string{"localhost"}
	}
	if len(cfg.ClientHosts) == 0 {
		cfg.ClientHosts = []string{"localhost"}
	}
	if cfg.ReplicaProcs > 0 {
		if len(viper.GetStringSlice("replica-hosts")) > 0 {
			return nil, fmt.Errorf("--replica-procs cannot be combined with --replica-hosts")
		}
		if len(cfg.ClientHosts) != 1 || cfg.ClientHosts[0] != "localhost" {
			return nil, fmt.Errorf("--replica-procs requires clients to run on localhost")
		}
		if cfg.ReplicaProcs > cfg.Replicas {
			return nil, fmt.Errorf("--replica-procs (%d) exceeds --replicas (%d)", cfg.ReplicaProcs, cfg.Replicas)
		}
		cfg.ReplicaHosts = ProcHostNames(cfg.ReplicaProcs)
		if cfg.ProcDataDir == "" {
			cfg.ProcDataDir = cfg.Output
		}
	}
	if len(cfg.TreePositions) == 0 {
		cfg.TreePositions = tree.DefaultTreePosUint32(cfg.Replicas)
	}
	return cfg, nil
}
