package main

import "syscall"

const (
	sysGetppid    = syscall.SYS_GETPPID
	sysSchedYield = syscall.SYS_SCHED_YIELD
)
