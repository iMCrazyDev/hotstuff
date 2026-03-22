package votingmachine_test

import (
	"context"
	"testing"
	"time"

	"github.com/relab/hotstuff"
	"github.com/relab/hotstuff/core"
	"github.com/relab/hotstuff/core/eventloop"
	"github.com/relab/hotstuff/internal/testutil"
	"github.com/relab/hotstuff/protocol"
	"github.com/relab/hotstuff/protocol/votingmachine"
	"github.com/relab/hotstuff/security/crypto"
)

func TestCollectVote(t *testing.T) {
	signers := testutil.NewEssentialsSet(t, 4, crypto.NameECDSA)
	leader := signers[0]
	viewStates, err := protocol.NewViewStates(
		leader.Blockchain(),
		leader.Authority(),
	)
	if err != nil {
		t.Fatal(err)
	}
	votingMachine := votingmachine.New(
		leader.Logger(),
		leader.EventLoop(),
		leader.RuntimeCfg(),
		leader.Blockchain(),
		leader.Authority(),
		viewStates,
	)

	newViewTriggered := false
	eventloop.Register(leader.EventLoop(), func(_ hotstuff.NewViewMsg) {
		newViewTriggered = true
	})

	block := testutil.CreateBlock(t, leader.Authority())
	leader.Blockchain().Store(block)

	for _, signer := range signers {
		pc := testutil.CreatePC(t, block, signer.Authority())
		vote := hotstuff.VoteMsg{
			ID:          signer.RuntimeCfg().ID(),
			PartialCert: pc,
		}
		votingMachine.CollectVote(vote)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	leader.EventLoop().Run(ctx)

	if !newViewTriggered {
		t.Fatal("expected advancing the view on quorum")
	}
}

// TestCollectVoteOFT verifies that in OFT mode:
//   - the voting machine triggers after f+1 votes (QuorumSize = (n+1)/2)
//   - the resulting QC has exactly 1 participant (the leader's own signature)
func TestCollectVoteOFT(t *testing.T) {
	// N=3, f=1, OFT QuorumSize=2. The leader needs only 2 votes.
	signers := testutil.NewEssentialsSet(t, 3, crypto.NameECDSA, core.WithOFT())
	leader := signers[0]
	viewStates, err := protocol.NewViewStates(
		leader.Blockchain(),
		leader.Authority(),
	)
	if err != nil {
		t.Fatal(err)
	}
	vm := votingmachine.New(
		leader.Logger(),
		leader.EventLoop(),
		leader.RuntimeCfg(),
		leader.Blockchain(),
		leader.Authority(),
		viewStates,
	)

	var receivedNewView *hotstuff.NewViewMsg
	eventloop.Register(leader.EventLoop(), func(msg hotstuff.NewViewMsg) {
		receivedNewView = &msg
	})

	block := testutil.CreateBlock(t, leader.Authority())
	leader.Blockchain().Store(block)

	// Send exactly QuorumSize=2 votes. The third replica is "crashed".
	quorum := leader.RuntimeCfg().QuorumSize() // should be 2
	for _, signer := range signers[:quorum] {
		pc := testutil.CreatePC(t, block, signer.Authority())
		vm.CollectVote(hotstuff.VoteMsg{
			ID:          signer.RuntimeCfg().ID(),
			PartialCert: pc,
		})
	}

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	leader.EventLoop().Run(ctx)

	if receivedNewView == nil {
		t.Fatal("expected NewViewMsg after OFT quorum of votes")
	}
	qc, ok := receivedNewView.SyncInfo.QC()
	if !ok {
		t.Fatal("expected QC in NewViewMsg SyncInfo")
	}
	// OFT QC must have exactly 1 participant (leader self-signs).
	participants := qc.Signature().Participants()
	if participants.Len() != 1 {
		t.Errorf("OFT QC participants = %d; want 1", participants.Len())
	}
	// The single participant must be the leader.
	var signerID hotstuff.ID
	participants.RangeWhile(func(id hotstuff.ID) bool { signerID = id; return false })
	if signerID != leader.RuntimeCfg().ID() {
		t.Errorf("OFT QC signer = %d; want leader %d", signerID, leader.RuntimeCfg().ID())
	}
}

func TestCollectVoteWithDuplicates(t *testing.T) {
	signers := testutil.NewEssentialsSet(t, 4, crypto.NameECDSA)
	leader := signers[0]
	viewStates, err := protocol.NewViewStates(
		leader.Blockchain(),
		leader.Authority(),
	)
	if err != nil {
		t.Fatal(err)
	}
	votingMachine := votingmachine.New(
		leader.Logger(),
		leader.EventLoop(),
		leader.RuntimeCfg(),
		leader.Blockchain(),
		leader.Authority(),
		viewStates,
	)

	newViewTriggered := false
	eventloop.Register(leader.EventLoop(), func(_ hotstuff.NewViewMsg) {
		newViewTriggered = true
	})

	block := testutil.CreateBlock(t, leader.Authority())
	leader.Blockchain().Store(block)

	// Send duplicate votes from the first signer
	// This will cause an error unless the duplicate is filtered
	firstSigner := signers[0]
	pc := testutil.CreatePC(t, block, firstSigner.Authority())
	vote := hotstuff.VoteMsg{
		ID:          firstSigner.RuntimeCfg().ID(),
		PartialCert: pc,
	}
	votingMachine.CollectVote(vote)

	// Collect votes from all signers
	for _, signer := range signers {
		pc := testutil.CreatePC(t, block, signer.Authority())
		vote := hotstuff.VoteMsg{
			ID:          signer.RuntimeCfg().ID(),
			PartialCert: pc,
		}
		votingMachine.CollectVote(vote)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	leader.EventLoop().Run(ctx)

	if !newViewTriggered {
		t.Fatal("expected advancing the view on quorum even with duplicate votes")
	}
}
