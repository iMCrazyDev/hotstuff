package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"io"
	"net"
	"syscall"
	"time"
)

// baseOps returns the operations that are available in every runtime.
func baseOps() []op {
	return []op{
		{
			name:  "clock",
			desc:  "time.Now (vDSO clock_gettime; emulated by the LibOS inside an enclave)",
			batch: 1000,
			setup: func() (func() error, func(), error) {
				return func() error { _ = time.Now(); return nil }, func() {}, nil
			},
		},
		{
			name:  "syscall_getppid",
			desc:  "raw getppid syscall (Gramine: emulated inside the LibOS; EGo: forwarded to the host)",
			batch: 100,
			setup: func() (func() error, func(), error) {
				return func() error {
					syscall.RawSyscall(sysGetppid, 0, 0, 0)
					return nil
				}, func() {}, nil
			},
		},
		{
			name:  "syscall_sched_yield",
			desc:  "raw sched_yield syscall (Gramine: forwarded to the host; EGo: handled in the enclave)",
			batch: 100,
			setup: func() (func() error, func(), error) {
				return func() error {
					syscall.RawSyscall(sysSchedYield, 0, 0, 0)
					return nil
				}, func() {}, nil
			},
		},
		udpSendOp("udp_send_64B", 64),
		udpSendOp("udp_send_4KB", 4096),
		tcpRTTOp("tcp_rtt_64B", 64),
		tcpRTTOp("tcp_rtt_4KB", 4096),
		{
			name:  "sha256_1KB",
			desc:  "SHA-256 of 1 KiB (pure computation)",
			batch: 100,
			setup: func() (func() error, func(), error) {
				buf := make([]byte, 1024)
				return func() error { _ = sha256.Sum256(buf); return nil }, func() {}, nil
			},
		},
		{
			name: "ecdsa_p256_sign",
			desc: "ECDSA P-256 signature, as used by the replicas (pure computation)",
			setup: func() (func() error, func(), error) {
				key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
				if err != nil {
					return nil, nil, err
				}
				digest := sha256.Sum256([]byte("block"))
				return func() error {
					_, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
					return err
				}, func() {}, nil
			},
		},
		{
			name: "ecdsa_p256_verify",
			desc: "ECDSA P-256 verification, as used by the replicas (pure computation)",
			setup: func() (func() error, func(), error) {
				key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
				if err != nil {
					return nil, nil, err
				}
				digest := sha256.Sum256([]byte("block"))
				sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
				if err != nil {
					return nil, nil, err
				}
				return func() error {
					if !ecdsa.VerifyASN1(&key.PublicKey, digest[:], sig) {
						return errors.New("signature did not verify")
					}
					return nil
				}, func() {}, nil
			},
		},
	}
}

// udpSendOp sends datagrams of the given size to a loopback socket that is
// never read; each send is one host send syscall (one enclave exit) including
// the copy of the payload out of the enclave.
func udpSendOp(name string, size int) op {
	return op{
		name:  name,
		desc:  "one UDP send to loopback (one host syscall incl. payload copy)",
		batch: 100,
		setup: func() (func() error, func(), error) {
			sink, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
			if err != nil {
				return nil, nil, err
			}
			conn, err := net.DialUDP("udp", nil, sink.LocalAddr().(*net.UDPAddr))
			if err != nil {
				_ = sink.Close()
				return nil, nil, err
			}
			buf := make([]byte, size)
			return func() error {
					_, err := conn.Write(buf)
					return err
				}, func() {
					_ = conn.Close()
					_ = sink.Close()
				}, nil
		},
	}
}

// tcpRTTOp measures the round-trip time of a message of the given size over a
// loopback TCP connection to an echo server in the same process, i.e. the
// network path a replica message takes (send, netpoll wake-up, receive).
func tcpRTTOp(name string, size int) op {
	return op{
		name: name,
		desc: "loopback TCP echo round trip (2 sends, 2 receives, netpoll)",
		setup: func() (func() error, func(), error) {
			ln, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				return nil, nil, err
			}
			go func() {
				c, err := ln.Accept()
				if err != nil {
					return
				}
				// A plain read/write loop: io.Copy between two TCP connections
				// uses splice(2), which Gramine does not implement.
				buf := make([]byte, 64*1024)
				for {
					n, err := c.Read(buf)
					if err != nil {
						break
					}
					if _, err := c.Write(buf[:n]); err != nil {
						break
					}
				}
				_ = c.Close()
			}()
			conn, err := net.Dial("tcp", ln.Addr().String())
			if err != nil {
				_ = ln.Close()
				return nil, nil, err
			}
			_ = conn.(*net.TCPConn).SetNoDelay(true)
			out, in := make([]byte, size), make([]byte, size)
			return func() error {
					if _, err := conn.Write(out); err != nil {
						return err
					}
					_, err := io.ReadFull(conn, in)
					return err
				}, func() {
					_ = conn.Close()
					_ = ln.Close()
				}, nil
		},
	}
}
