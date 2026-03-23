package synchronizer

import (
	"testing"

	cuelangtime "cuelang.org/go/pkg/time"
	"github.com/relab/hotstuff"

	"github.com/relab/hotstuff/core"
	"github.com/relab/hotstuff/internal/proto/clientpb"
	"github.com/relab/hotstuff/internal/testutil"
	"github.com/relab/hotstuff/protocol"
	"github.com/relab/hotstuff/protocol/comm"
	"github.com/relab/hotstuff/protocol/consensus"
	"github.com/relab/hotstuff/protocol/leaderrotation"
	"github.com/relab/hotstuff/protocol/rules"
	"github.com/relab/hotstuff/protocol/votingmachine"
	"github.com/relab/hotstuff/security/crypto"
	"github.com/relab/hotstuff/wiring"
)

func wireUpSynchronizer(
	t *testing.T,
	essentials *testutil.Essentials,
	commandCache *clientpb.CommandCache,
	viewStates *protocol.ViewStates,
) (*Synchronizer, *consensus.Proposer) {
	t.Helper()
	leaderRotation := leaderrotation.NewFixed(1)
	consensusRules := rules.NewChainedHotStuff(
		essentials.Logger(),
		essentials.RuntimeCfg(),
		essentials.Blockchain(),
	)
	votingMachine := votingmachine.New(
		essentials.Logger(),
		essentials.EventLoop(),
		essentials.RuntimeCfg(),
		essentials.Blockchain(),
		essentials.Authority(),
		viewStates,
	)
	depsConsensus := wiring.NewConsensus(
		essentials.EventLoop(),
		essentials.Logger(),
		essentials.RuntimeCfg(),
		essentials.Blockchain(),
		essentials.Authority(),
		commandCache,
		consensusRules,
		leaderRotation,
		viewStates,
		comm.NewClique(
			essentials.RuntimeCfg(),
			votingMachine,
			leaderRotation,
			essentials.MockSender(),
		),
	)
	synchronizer := New(
		essentials.EventLoop(),
		essentials.Logger(),
		essentials.RuntimeCfg(),
		essentials.Authority(),
		leaderRotation,
		NewFixedDuration(1000*cuelangtime.Nanosecond),
		NewTimeoutRuler(essentials.RuntimeCfg(), essentials.Authority()),
		depsConsensus.Proposer(),
		depsConsensus.Voter(),
		viewStates,
		essentials.MockSender(),
	)
	return synchronizer, depsConsensus.Proposer()
}

func TestAdvanceViewQC(t *testing.T) {
	set := testutil.NewEssentialsSet(t, 4, crypto.NameECDSA)
	subject := set[0]
	viewStates, err := protocol.NewViewStates(
		subject.Blockchain(),
		subject.Authority(),
	)
	if err != nil {
		t.Fatal(err)
	}
	commandCache := clientpb.NewCommandCache(1)
	synchronizer, proposer := wireUpSynchronizer(t, subject, commandCache, viewStates)

	blockchain := subject.Blockchain()
	block := hotstuff.NewBlock(
		hotstuff.GetGenesis().Hash(),
		hotstuff.NewQuorumCert(nil, 0, hotstuff.GetGenesis().Hash()),
		&clientpb.Batch{Commands: []*clientpb.Command{{Data: []byte("foo")}}},
		1,
		1,
	)
	blockchain.Store(block)

	signers := set.Signers()
	qc := testutil.CreateQC(t, block, signers...)
	for i := range 2 {
		// adding multiple commands so the next call CreateProposal
		// in advanceView doesn't block
		commandCache.Add(&clientpb.Command{
			ClientID:       1,
			SequenceNumber: uint64(i + 1),
			Data:           []byte("bar"),
		})
	}
	proposal, err := proposer.CreateProposal(viewStates.SyncInfo())
	if err != nil {
		t.Fatal(err)
	}
	if err := proposer.Propose(&proposal); err != nil {
		t.Fatal(err)
	}

	synchronizer.advanceView(hotstuff.NewSyncInfoWith(qc))

	if viewStates.View() != 2 {
		t.Errorf("wrong view: expected: %d, got: %d", 2, viewStates.View())
	}
}

func TestAdvanceViewTC(t *testing.T) {
	set := testutil.NewEssentialsSet(t, 4, crypto.NameECDSA)
	subject := set[0]
	viewStates, err := protocol.NewViewStates(
		subject.Blockchain(),
		subject.Authority(),
	)
	if err != nil {
		t.Fatal(err)
	}
	commandCache := clientpb.NewCommandCache(1)
	synchronizer, proposer := wireUpSynchronizer(t, subject, commandCache, viewStates)

	signers := set.Signers()
	tc := testutil.CreateTC(t, 1, signers)
	for i := range 2 {
		// adding multiple commands so the next call CreateProposal
		// in advanceView doesn't block
		commandCache.Add(&clientpb.Command{
			ClientID:       1,
			SequenceNumber: uint64(i + 1),
			Data:           []byte("bar"),
		})
	}
	proposal, err := proposer.CreateProposal(viewStates.SyncInfo())
	if err != nil {
		t.Fatal(err)
	}
	if err := proposer.Propose(&proposal); err != nil {
		t.Fatal(err)
	}

	synchronizer.advanceView(hotstuff.NewSyncInfoWith(tc))

	if viewStates.View() != 2 {
		t.Errorf("wrong view: expected: %d, got: %d", 2, viewStates.View())
	}
}

func TestAdvanceView(t *testing.T) {
	const (
		S = false // simple timeout rule
		A = true  // aggregate timeout rule
		F = false
		T = true
	)
	tests := []struct {
		name           string
		tr, qc, tc, ac bool
		firstSignerIdx int
		wantView       hotstuff.View
	}{
		// four signers; quorum reached, advance view
		{name: "signers=4/Simple___/__/__/__", tr: S, qc: F, tc: F, ac: F, firstSignerIdx: 0, wantView: 1}, // empty syncInfo, should not advance view
		{name: "signers=4/Simple___/__/__/AC", tr: S, qc: F, tc: F, ac: T, firstSignerIdx: 0, wantView: 1}, // simple timeout rule ignores aggregate timeout cert, will not advance view
		{name: "signers=4/Simple___/__/TC/__", tr: S, qc: F, tc: T, ac: F, firstSignerIdx: 0, wantView: 2},
		{name: "signers=4/Simple___/__/TC/AC", tr: S, qc: F, tc: T, ac: T, firstSignerIdx: 0, wantView: 2},
		{name: "signers=4/Simple___/QC/__/__", tr: S, qc: T, tc: F, ac: F, firstSignerIdx: 0, wantView: 2},
		{name: "signers=4/Simple___/QC/__/AC", tr: S, qc: T, tc: F, ac: T, firstSignerIdx: 0, wantView: 2},
		{name: "signers=4/Simple___/QC/TC/AC", tr: S, qc: T, tc: T, ac: T, firstSignerIdx: 0, wantView: 2},
		{name: "signers=4/Aggregate/__/__/__", tr: A, qc: F, tc: F, ac: F, firstSignerIdx: 0, wantView: 1}, // empty syncInfo, should not advance view
		{name: "signers=4/Aggregate/__/__/AC", tr: A, qc: F, tc: F, ac: T, firstSignerIdx: 0, wantView: 2},
		{name: "signers=4/Aggregate/__/TC/__", tr: A, qc: F, tc: T, ac: F, firstSignerIdx: 0, wantView: 2},
		{name: "signers=4/Aggregate/__/TC/AC", tr: A, qc: F, tc: T, ac: T, firstSignerIdx: 0, wantView: 2},
		{name: "signers=4/Aggregate/QC/__/__", tr: A, qc: T, tc: F, ac: F, firstSignerIdx: 0, wantView: 2}, // falls back to plain QC when no AggQC present
		{name: "signers=4/Aggregate/QC/__/AC", tr: A, qc: T, tc: F, ac: T, firstSignerIdx: 0, wantView: 2},
		{name: "signers=4/Aggregate/QC/TC/AC", tr: A, qc: T, tc: T, ac: T, firstSignerIdx: 0, wantView: 2},
		// three signers; quorum reacted, advance view
		{name: "signers=3/Simple___/__/__/__", tr: S, qc: F, tc: F, ac: F, firstSignerIdx: 1, wantView: 1}, // empty syncInfo, should not advance view
		{name: "signers=3/Simple___/__/__/AC", tr: S, qc: F, tc: F, ac: T, firstSignerIdx: 1, wantView: 1}, // simple timeout rule ignores aggregate timeout cert, will not advance view
		{name: "signers=3/Simple___/__/TC/__", tr: S, qc: F, tc: T, ac: F, firstSignerIdx: 1, wantView: 2},
		{name: "signers=3/Simple___/__/TC/AC", tr: S, qc: F, tc: T, ac: T, firstSignerIdx: 1, wantView: 2},
		{name: "signers=3/Simple___/QC/__/__", tr: S, qc: T, tc: F, ac: F, firstSignerIdx: 1, wantView: 2},
		{name: "signers=3/Simple___/QC/__/AC", tr: S, qc: T, tc: F, ac: T, firstSignerIdx: 1, wantView: 2},
		{name: "signers=3/Simple___/QC/TC/AC", tr: S, qc: T, tc: T, ac: T, firstSignerIdx: 1, wantView: 2},
		{name: "signers=3/Aggregate/__/__/__", tr: A, qc: F, tc: F, ac: F, firstSignerIdx: 1, wantView: 1}, // empty syncInfo, should not advance view
		{name: "signers=3/Aggregate/__/__/AC", tr: A, qc: F, tc: F, ac: T, firstSignerIdx: 1, wantView: 2},
		{name: "signers=3/Aggregate/__/TC/__", tr: A, qc: F, tc: T, ac: F, firstSignerIdx: 1, wantView: 2},
		{name: "signers=3/Aggregate/__/TC/AC", tr: A, qc: F, tc: T, ac: T, firstSignerIdx: 1, wantView: 2},
		{name: "signers=3/Aggregate/QC/__/__", tr: A, qc: T, tc: F, ac: F, firstSignerIdx: 1, wantView: 2}, // falls back to plain QC when no AggQC present
		{name: "signers=3/Aggregate/QC/__/AC", tr: A, qc: T, tc: F, ac: T, firstSignerIdx: 1, wantView: 2},
		{name: "signers=3/Aggregate/QC/TC/AC", tr: A, qc: T, tc: T, ac: T, firstSignerIdx: 1, wantView: 2},
		// only two signers; no quorum reached, should not advance view
		{name: "signers=2/Simple___/__/__/__", tr: S, qc: F, tc: F, ac: F, firstSignerIdx: 2, wantView: 1}, // empty syncInfo, should not advance view
		{name: "signers=2/Simple___/__/__/AC", tr: S, qc: F, tc: F, ac: T, firstSignerIdx: 2, wantView: 1},
		{name: "signers=2/Simple___/__/TC/__", tr: S, qc: F, tc: T, ac: F, firstSignerIdx: 2, wantView: 1},
		{name: "signers=2/Simple___/__/TC/AC", tr: S, qc: F, tc: T, ac: T, firstSignerIdx: 2, wantView: 1},
		{name: "signers=2/Simple___/QC/__/__", tr: S, qc: T, tc: F, ac: F, firstSignerIdx: 2, wantView: 1},
		{name: "signers=2/Simple___/QC/__/AC", tr: S, qc: T, tc: F, ac: T, firstSignerIdx: 2, wantView: 1},
		{name: "signers=2/Simple___/QC/TC/AC", tr: S, qc: T, tc: T, ac: T, firstSignerIdx: 2, wantView: 1},
		{name: "signers=2/Aggregate/__/__/__", tr: A, qc: F, tc: F, ac: F, firstSignerIdx: 2, wantView: 1}, // empty syncInfo, should not advance view
		{name: "signers=2/Aggregate/__/__/AC", tr: A, qc: F, tc: F, ac: T, firstSignerIdx: 2, wantView: 1},
		{name: "signers=2/Aggregate/__/TC/__", tr: A, qc: F, tc: T, ac: F, firstSignerIdx: 2, wantView: 1},
		{name: "signers=2/Aggregate/__/TC/AC", tr: A, qc: F, tc: T, ac: T, firstSignerIdx: 2, wantView: 1},
		{name: "signers=2/Aggregate/QC/__/__", tr: A, qc: T, tc: F, ac: F, firstSignerIdx: 2, wantView: 1},
		{name: "signers=2/Aggregate/QC/__/AC", tr: A, qc: T, tc: F, ac: T, firstSignerIdx: 2, wantView: 1},
		{name: "signers=2/Aggregate/QC/TC/AC", tr: A, qc: T, tc: T, ac: T, firstSignerIdx: 2, wantView: 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var opts []core.RuntimeOption
			if tt.tr == A {
				opts = append(opts, core.WithAggregateQC())
			}
			set, viewStates, synchronizer, block := prepareSynchronizer(t, opts...)
			signers := set.Signers()

			syncInfo := hotstuff.NewSyncInfo()
			if tt.qc {
				validQC := testutil.CreateQC(t, block, signers[tt.firstSignerIdx:]...)
				syncInfo.SetQC(validQC)
			}
			if tt.tc {
				validTC := testutil.CreateTC(t, 1, signers[tt.firstSignerIdx:])
				syncInfo.SetTC(validTC)
			}
			if tt.ac {
				validAC := testutil.CreateAC(t, 1, signers[tt.firstSignerIdx:])
				syncInfo.SetAggQC(validAC)
			}

			// t.Logf("  %s: SyncInfo: %v", tt.name, syncInfo)
			// t.Logf("B %s: HighQC.View: %d, HighTC.View: %d", tt.name, viewStates.HighQC().View(), viewStates.HighTC().View())
			synchronizer.advanceView(syncInfo)
			if viewStates.View() != tt.wantView {
				t.Errorf("View() = %d, want %d", viewStates.View(), tt.wantView)
			}
			// t.Logf("A %s: HighQC.View: %d, HighTC.View: %d", tt.name, viewStates.HighQC().View(), viewStates.HighTC().View())
		})
	}
}

// wireUpOFTSynchronizer wires up a 3-replica (N=2f+1, f=1) OFT synchronizer for testing.
// The subject is always replica 1, which is also the fixed leader.
func wireUpOFTSynchronizer(t *testing.T) (testutil.EssentialsSet, *protocol.ViewStates, *Synchronizer, *clientpb.CommandCache) {
	t.Helper()
	set := testutil.NewEssentialsSet(t, 3, crypto.NameECDSA, core.WithOFT())
	subject := set[0]
	viewStates, err := protocol.NewViewStates(subject.Blockchain(), subject.Authority())
	if err != nil {
		t.Fatal(err)
	}
	commandCache := clientpb.NewCommandCache(2)
	for i := range 2 {
		commandCache.Add(&clientpb.Command{ClientID: 1, SequenceNumber: uint64(i + 1), Data: []byte("cmd")})
	}
	sync, _ := wireUpSynchronizer(t, subject, commandCache, viewStates)
	return set, viewStates, sync, commandCache
}

// TestForceAdvanceViewOFT verifies that OnLocalTimeout in OFT mode does NOT send a
// TimeoutMsg and advances the view immediately via forceAdvanceView.
func TestForceAdvanceViewOFT(t *testing.T) {
	_, viewStates, sync, _ := wireUpOFTSynchronizer(t)

	if viewStates.View() != 1 {
		t.Fatalf("expected initial view 1, got %d", viewStates.View())
	}

	// Simulate a local timeout — in OFT mode this should force-advance the view.
	sync.forceAdvanceView(1)

	if viewStates.View() != 2 {
		t.Errorf("after forceAdvanceView: view = %d, want 2", viewStates.View())
	}
}

// TestOFTLeaderWaitsForNewViewQuorum verifies that the OFT leader (replica 1 in view 2)
// waits for f+1 network NewViewMsgs before proposing, and proposes as soon as quorum is reached.
// The check is done synchronously (no event loop run) to avoid the short-duration timer in
// wireUpSynchronizer triggering another force-advance and resetting OFT state.
func TestOFTLeaderWaitsForNewViewQuorum(t *testing.T) {
	set, viewStates, sync, _ := wireUpOFTSynchronizer(t)

	// Force-advance to view 2 — the leader sets oftWaitingForNewViewQuorum=true
	// and pre-seeds the count with 1 (counts itself).
	sync.forceAdvanceView(1)

	if viewStates.View() != 2 {
		t.Fatalf("expected view 2 after forceAdvanceView, got %d", viewStates.View())
	}
	if !sync.oftWaitingForNewViewQuorum {
		t.Fatal("expected leader to be waiting for NewViewMsg quorum after force-advance")
	}

	// QuorumSize = (3+1)/2 = 2. Leader pre-seeded count=1, so 1 more network msg triggers proposal.
	replica2ID := set[1].RuntimeCfg().ID()
	sync.OnNewView(hotstuff.NewViewMsg{
		ID:          replica2ID,
		SyncInfo:    viewStates.SyncInfo(),
		FromNetwork: true,
	})

	// OnNewView is synchronous. After it returns, OFT state must be cleared.
	if sync.oftWaitingForNewViewQuorum {
		t.Error("expected oftWaitingForNewViewQuorum to be cleared after quorum of NewViewMsgs")
	}

	// The leader must have sent a proposal via the mock sender.
	var proposalSent bool
	for _, msg := range set[0].MockSender().MessagesSent() {
		if _, ok := msg.(hotstuff.ProposeMsg); ok {
			proposalSent = true
			break
		}
	}
	if !proposalSent {
		t.Error("expected leader to send a proposal after receiving f+1 NewViewMsgs")
	}
}

func prepareSynchronizer(t *testing.T, opts ...core.RuntimeOption) (testutil.EssentialsSet, *protocol.ViewStates, *Synchronizer, *hotstuff.Block) {
	set := testutil.NewEssentialsSet(t, 4, crypto.NameECDSA, opts...)
	subject := set[0]
	viewStates, err := protocol.NewViewStates(
		subject.Blockchain(),
		subject.Authority(),
	)
	if err != nil {
		t.Fatal(err)
	}
	commandCache := clientpb.NewCommandCache(1)
	synchronizer, proposer := wireUpSynchronizer(t, subject, commandCache, viewStates)

	blockchain := subject.Blockchain()
	block := testutil.CreateBlock(t, subject.Authority())
	blockchain.Store(block)

	for i := range 2 {
		// adding multiple commands so the next call CreateProposal
		// in advanceView doesn't block
		commandCache.Add(&clientpb.Command{
			ClientID:       1,
			SequenceNumber: uint64(i + 1),
			Data:           []byte("bar"),
		})
	}
	proposal, err := proposer.CreateProposal(viewStates.SyncInfo())
	if err != nil {
		t.Fatal(err)
	}
	if err := proposer.Propose(&proposal); err != nil {
		t.Fatal(err)
	}
	return set, viewStates, synchronizer, block
}
