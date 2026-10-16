package orchestration

import (
	"bytes"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/relab/hotstuff/internal/protostream"
)

// LocalProcConfig configures worker processes started on the local machine.
// Each process is an ordinary hotstuff worker, but it may be started through a
// wrapper command such as a TEE runtime (e.g. "gramine-sgx hotstuff" or
// "ego run hotstuff-ego"), so that every replica runs in its own enclave.
//
// The controller talks to these workers over a loopback TCP connection that
// each worker opens to the controller, not over stdin/stdout: TEE runtimes
// print to stdout, and Gramine forwards the application's stderr to the host's
// stdout as well. The workers' stdout and stderr are copied to the
// controller's stderr, prefixed with the worker name.
type LocalProcConfig struct {
	DeployConfig
	// Names lists the worker names; one process is started per name.
	Names []string
	// Command is the command prefix used to start a worker.
	// The "worker" subcommand and its flags are appended to it.
	Command []string
	// Dir is the working directory of the worker processes.
	Dir string
	// Env holds extra KEY=VALUE environment variables for the worker processes.
	Env []string
	// DataDir is the directory where workers write their measurements.
	// The path must be valid both inside and outside the TEE (e.g. a passthrough mount).
	// If empty, workers do not write measurements.
	DataDir string
	// StartTimeout bounds the time for all workers to start and connect,
	// which includes creating their enclaves. Defaults to 10 minutes.
	StartTimeout time.Duration
}

// LocalProcs is a set of running local worker processes.
type LocalProcs struct {
	procs  map[string]*localProc
	exited chan string
}

type localProc struct {
	cmd      *exec.Cmd
	conn     net.Conn
	dataFile string
	done     chan struct{}
	waitErr  error
}

// StartLocalProcs starts one worker process per name in cfg.Names and waits
// until every worker has connected back to the controller.
func StartLocalProcs(cfg LocalProcConfig) (lp *LocalProcs, err error) {
	if len(cfg.Command) == 0 {
		return nil, errors.New("no worker command given")
	}
	if cfg.StartTimeout == 0 {
		cfg.StartTimeout = 10 * time.Minute
	}
	if cfg.DataDir != "" {
		if err := os.MkdirAll(cfg.DataDir, 0o755); err != nil {
			return nil, fmt.Errorf("failed to create worker data directory: %w", err)
		}
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("failed to listen for workers: %w", err)
	}
	defer ln.Close()

	tag := rand.Text()[:8]
	lp = &LocalProcs{
		procs:  make(map[string]*localProc, len(cfg.Names)),
		exited: make(chan string, len(cfg.Names)),
	}
	defer func() {
		if err != nil {
			_ = lp.Close(time.Second)
		}
	}()
	for _, name := range cfg.Names {
		p := &localProc{done: make(chan struct{})}
		if cfg.DataDir != "" {
			p.dataFile = filepath.Join(cfg.DataDir, tag+"-"+name+".json")
		}
		args := append(append([]string{}, cfg.Command[1:]...), cfg.workerArgs(ln.Addr().String(), name, p.dataFile)...)
		p.cmd = exec.Command(cfg.Command[0], args...)
		p.cmd.Dir = cfg.Dir
		p.cmd.Env = append(os.Environ(), cfg.Env...)
		p.cmd.Stdout = newPrefixWriter(os.Stderr, "["+name+"] ")
		p.cmd.Stderr = newPrefixWriter(os.Stderr, "["+name+"] ")
		if err = p.cmd.Start(); err != nil {
			return nil, fmt.Errorf("failed to start worker %s: %w", name, err)
		}
		go func() {
			p.waitErr = p.cmd.Wait()
			close(p.done)
			lp.exited <- name
		}()
		lp.procs[name] = p
	}
	return lp, lp.accept(ln, cfg.StartTimeout)
}

// workerArgs returns the subcommand and flags passed to a local worker process.
func (cfg LocalProcConfig) workerArgs(controllerAddr, name, dataFile string) []string {
	args := []string{"worker", "--connect", controllerAddr, "--name", name}
	if dataFile != "" {
		args = append(args, "--data-path", dataFile)
	}
	if cfg.MeasurementInterval > 0 {
		args = append(args, "--measurement-interval", cfg.MeasurementInterval.String())
	}
	if len(cfg.Metrics) > 0 {
		args = append(args, "--metrics", strings.Join(cfg.Metrics, ","))
	}
	if cfg.LogLevel != "" {
		args = append(args, "--log-level", cfg.LogLevel)
	}
	return args
}

// accept waits until every worker has connected and identified itself.
func (lp *LocalProcs) accept(ln net.Listener, timeout time.Duration) error {
	type hello struct {
		name string
		conn net.Conn
		err  error
	}
	hellos := make(chan hello, len(lp.procs))
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return // listener closed
			}
			go func() {
				name, err := readName(conn)
				select {
				case hellos <- hello{name, conn, err}:
				case <-stop:
					_ = conn.Close()
				}
			}()
		}
	}()

	deadline := time.After(timeout)
	for pending := len(lp.procs); pending > 0; {
		select {
		case h := <-hellos:
			p, ok := lp.procs[h.name]
			if h.err != nil || !ok || p.conn != nil {
				_ = h.conn.Close()
				continue
			}
			p.conn = h.conn
			pending--
		case name := <-lp.exited:
			return fmt.Errorf("worker %s exited during start-up: %v", name, lp.procs[name].waitErr)
		case <-deadline:
			return fmt.Errorf("workers did not connect within %s", timeout)
		}
	}
	return nil
}

// readName reads the worker name, sent as the first line on the connection.
// It reads byte by byte so as not to consume any of the protocol that follows.
func readName(conn net.Conn) (string, error) {
	if err := conn.SetReadDeadline(time.Now().Add(30 * time.Second)); err != nil {
		return "", err
	}
	defer func() { _ = conn.SetReadDeadline(time.Time{}) }()
	var name []byte
	b := make([]byte, 1)
	for len(name) < 256 {
		if _, err := io.ReadFull(conn, b); err != nil {
			return "", err
		}
		if b[0] == '\n' {
			return string(name), nil
		}
		name = append(name, b[0])
	}
	return "", errors.New("worker name too long")
}

// Workers returns a controller-side proxy for each worker process.
func (lp *LocalProcs) Workers() map[string]RemoteWorker {
	workers := make(map[string]RemoteWorker, len(lp.procs))
	for name, p := range lp.procs {
		workers[name] = NewRemoteWorker(protostream.NewWriter(p.conn), protostream.NewReader(p.conn))
	}
	return workers
}

// Close closes the connections to the workers and waits for them to exit.
// Workers that have not exited within the timeout are killed.
func (lp *LocalProcs) Close(timeout time.Duration) (err error) {
	for _, p := range lp.procs {
		if p.conn != nil {
			_ = p.conn.Close()
		}
	}
	deadline := time.After(timeout)
	for name, p := range lp.procs {
		select {
		case <-p.done:
		case <-deadline:
			_ = p.cmd.Process.Kill()
			<-p.done
			err = errors.Join(err, fmt.Errorf("worker %s killed after %s", name, timeout))
			continue
		}
		if p.waitErr != nil {
			err = errors.Join(err, fmt.Errorf("worker %s: %w", name, p.waitErr))
		}
	}
	return err
}

// CollectData moves each worker's measurements to dest/<name>/measurements.json,
// matching the layout used by FetchData for remote workers.
func (lp *LocalProcs) CollectData(dest string) (err error) {
	for name, p := range lp.procs {
		if p.dataFile == "" || dest == "" {
			continue
		}
		dir := filepath.Join(dest, name)
		if mkErr := os.MkdirAll(dir, 0o755); mkErr != nil {
			err = errors.Join(err, mkErr)
			continue
		}
		err = errors.Join(err, moveFile(p.dataFile, filepath.Join(dir, "measurements.json")))
	}
	return err
}

// moveFile renames src to dst, falling back to copy+remove across file systems.
func moveFile(src, dst string) error {
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := os.WriteFile(dst, b, 0o644); err != nil {
		return err
	}
	return os.Remove(src)
}

// prefixWriter prefixes every line written to w; it is used to tell apart the
// output streams of the worker processes.
type prefixWriter struct {
	mu     *sync.Mutex
	w      io.Writer
	prefix []byte
	buf    []byte
}

var stderrMu sync.Mutex

func newPrefixWriter(w io.Writer, prefix string) *prefixWriter {
	return &prefixWriter{mu: &stderrMu, w: w, prefix: []byte(prefix)}
}

func (pw *prefixWriter) Write(p []byte) (int, error) {
	pw.buf = append(pw.buf, p...)
	for {
		i := bytes.IndexByte(pw.buf, '\n')
		if i < 0 {
			break
		}
		pw.mu.Lock()
		_, err := pw.w.Write(append(append([]byte{}, pw.prefix...), pw.buf[:i+1]...))
		pw.mu.Unlock()
		if err != nil {
			return len(p), err
		}
		pw.buf = pw.buf[i+1:]
	}
	return len(p), nil
}
