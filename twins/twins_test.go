package twins_test

import (
	"testing"
	"time"

	"github.com/relab/hotstuff/core"
	"github.com/relab/hotstuff/core/logging"
	"github.com/relab/hotstuff/protocol/rules"
	"github.com/relab/hotstuff/twins"
)

func TestTwins(t *testing.T) {
	const (
		numNodes = 4
		numTwins = 1
	)

	g := twins.NewGenerator(logging.New(""), twins.Settings{
		NumNodes:   numNodes,
		NumTwins:   numTwins,
		Partitions: 2,
		Views:      8,
	})
	seed := time.Now().Unix()
	g.Shuffle(seed)

	scenarioCount := 10
	totalCommits := 0

	for range scenarioCount {
		s, err := g.NextScenario()
		if err != nil {
			break
		}
		result, err := twins.ExecuteScenario(s, numNodes, numTwins, 100, rules.NameChainedHotStuff)
		if err != nil {
			t.Fatal(err)
		}
		t.Log(result.Safe, result.Commits)
		t.Log(s)
		if !result.Safe {
			t.Logf("Scenario not safe: %v", s)
			continue
		}
		if result.Commits > 0 {
			totalCommits += result.Commits
		}
	}

	t.Logf("Average %.1f commits per scenario.", float64(totalCommits)/float64(scenarioCount))
}

// TestTwinsOFT runs the twins safety test for the OFT protocol.
// OFT uses a omission-fault-tolerant model: N=3 (=2f+1, f=1), QuorumSize=2.
// No twins (numTwins=0) — partitions simulate crash faults.
func TestTwinsOFT(t *testing.T) {
	const (
		numNodes = 3
		numTwins = 0
	)

	g := twins.NewGenerator(logging.New(""), twins.Settings{
		NumNodes:   numNodes,
		NumTwins:   numTwins,
		Partitions: 2,
		Views:      8,
	})
	seed := time.Now().Unix()
	g.Shuffle(seed)

	scenarioCount := 10
	totalCommits := 0

	for range scenarioCount {
		s, err := g.NextScenario()
		if err != nil {
			break
		}
		result, err := twins.ExecuteScenario(s, numNodes, numTwins, 100, rules.NameOFT, core.WithOFT())
		if err != nil {
			t.Fatal(err)
		}
		t.Log(result.Safe, result.Commits)
		t.Log(s)
		if !result.Safe {
			t.Logf("Scenario not safe: %v", s)
			continue
		}
		if result.Commits > 0 {
			totalCommits += result.Commits
		}
	}

	t.Logf("Average %.1f commits per scenario.", float64(totalCommits)/float64(scenarioCount))
}
