package orchestration

import (
	"net"
	"testing"
)

func TestReadName(t *testing.T) {
	client, server := net.Pipe()
	defer server.Close()
	go func() {
		_, _ = client.Write([]byte("proc7\nPAYLOAD"))
		_ = client.Close()
	}()
	name, err := readName(server)
	if err != nil {
		t.Fatal(err)
	}
	if name != "proc7" {
		t.Fatalf("got name %q, want proc7", name)
	}
	// the bytes after the name must be left for the protocol
	rest := make([]byte, 7)
	if _, err := server.Read(rest); err != nil || string(rest) != "PAYLOAD" {
		t.Fatalf("got %q (%v), want PAYLOAD", rest, err)
	}
}
