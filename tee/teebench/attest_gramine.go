//go:build !ego

package main

import (
	"crypto/rand"
	"errors"
	"os"
	"strings"
)

// Gramine exposes SGX attestation through the /dev/attestation pseudo-filesystem.
// See https://gramine.readthedocs.io/en/stable/attestation.html.
const attDir = "/dev/attestation/"

func attestationType() string {
	b, err := os.ReadFile(attDir + "attestation_type")
	if err != nil {
		return "none"
	}
	return "gramine-" + strings.TrimSpace(string(b))
}

func attestOps(quoteOut string) []op {
	// Local reports need SGX but not a quoting setup; under gramine-direct
	// /dev/attestation is absent, so nothing is measured there.
	if _, err := os.Stat(attDir + "my_target_info"); err != nil {
		return nil
	}
	ops := []op{{
		name: "report",
		desc: "SGX report (EREPORT) targeted at the enclave itself, via /dev/attestation",
		setup: func() (func() error, func(), error) {
			targetInfo, err := os.ReadFile(attDir + "my_target_info")
			if err != nil {
				return nil, nil, err
			}
			userData := make([]byte, 64)
			return func() error {
				if err := os.WriteFile(attDir+"target_info", targetInfo, 0); err != nil {
					return err
				}
				_, _ = rand.Read(userData)
				if err := os.WriteFile(attDir+"user_report_data", userData, 0); err != nil {
					return err
				}
				report, err := os.ReadFile(attDir + "report")
				if err != nil {
					return err
				}
				if len(report) == 0 {
					return errors.New("empty report")
				}
				return nil
			}, func() {}, nil
		},
	}}
	if attestationType() != "gramine-dcap" {
		return ops
	}
	return append(ops, op{
		name:    "quote",
		desc:    "DCAP quote generation (report + Quoting Enclave via AESM), via /dev/attestation",
		samples: 300,
		setup: func() (func() error, func(), error) {
			userData := make([]byte, 64)
			written := quoteOut == ""
			return func() error {
				_, _ = rand.Read(userData)
				if err := os.WriteFile(attDir+"user_report_data", userData, 0); err != nil {
					return err
				}
				quote, err := os.ReadFile(attDir + "quote")
				if err != nil {
					return err
				}
				if !written {
					written = true
					return os.WriteFile(quoteOut, quote, 0o644)
				}
				return nil
			}, func() {}, nil
		},
	})
}
