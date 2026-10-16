//go:build !linux

package main

import "syscall"

// teebench targets Linux; these stand-ins only let it build and run elsewhere for testing.
const (
	sysGetppid    = syscall.SYS_GETPPID
	sysSchedYield = syscall.SYS_GETPID
)
