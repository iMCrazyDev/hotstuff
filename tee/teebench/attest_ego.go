//go:build ego

package main

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"os"

	"github.com/edgelesssys/ego/attestation"
	"github.com/edgelesssys/ego/enclave"
)

func attestationType() string {
	if os.Getenv("OE_SIMULATION") == "1" {
		return "ego-simulation"
	}
	return "ego-dcap"
}

func attestOps(quoteOut string) []op {
	ops := []op{
		{
			name: "report",
			desc: "SGX report (EREPORT) targeted at the enclave itself, via EGo/Open Enclave",
			setup: func() (func() error, func(), error) {
				self, err := enclave.GetLocalReport(nil, nil)
				if err != nil {
					return nil, nil, err
				}
				userData := make([]byte, 64)
				return func() error {
					_, _ = rand.Read(userData)
					_, err := enclave.GetLocalReport(userData, self)
					return err
				}, func() {}, nil
			},
		},
		{
			name: "report_verify",
			desc: "local report verification (EGETKEY + CMAC) inside the enclave, via EGo/Open Enclave",
			setup: func() (func() error, func(), error) {
				self, err := enclave.GetLocalReport(nil, nil)
				if err != nil {
					return nil, nil, err
				}
				report, err := enclave.GetLocalReport(make([]byte, 64), self)
				if err != nil {
					return nil, nil, err
				}
				return func() error {
					_, err := enclave.VerifyLocalReport(report)
					return err
				}, func() {}, nil
			},
		},
	}
	if attestationType() != "ego-dcap" {
		return ops
	}
	return append(ops,
		op{
			name:    "quote",
			desc:    "DCAP quote generation (report + in-process Quoting Enclave), via EGo/Open Enclave",
			samples: 300,
			setup: func() (func() error, func(), error) {
				userData := make([]byte, 64)
				written := quoteOut == ""
				return func() error {
					_, _ = rand.Read(userData)
					report, err := enclave.GetRemoteReport(userData)
					if err != nil {
						return err
					}
					if !written {
						written = true
						quote, err := rawQuote(report)
						if err != nil {
							return err
						}
						return os.WriteFile(quoteOut, quote, 0o644)
					}
					return nil
				}, func() {}, nil
			},
		},
		op{
			name:    "quote_verify",
			desc:    "DCAP quote verification inside the enclave (collateral via QPL), via EGo/Open Enclave",
			samples: 300,
			setup: func() (func() error, func(), error) {
				report, err := enclave.GetRemoteReport(make([]byte, 64))
				if err != nil {
					return nil, nil, err
				}
				return func() error {
					// ErrTCBLevelInvalid: the quote verified, but the platform's TCB is not
					// up to date (on cloud SGX typically CONFIG_AND_SW_HARDENING_NEEDED).
					_, err := enclave.VerifyRemoteReport(report)
					if errors.Is(err, attestation.ErrTCBLevelInvalid) {
						return nil
					}
					return err
				}, func() {}, nil
			},
		},
	)
}

// rawQuote strips the Open Enclave report header (version, type, size) and
// returns the SGX quote it wraps.
func rawQuote(report []byte) ([]byte, error) {
	const headerSize = 16
	if len(report) < headerSize {
		return nil, errors.New("report too short")
	}
	size := binary.LittleEndian.Uint64(report[8:16])
	if uint64(len(report)-headerSize) < size {
		return nil, errors.New("truncated report")
	}
	return report[headerSize : headerSize+size], nil
}
