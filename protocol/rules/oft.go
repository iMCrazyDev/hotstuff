package rules

import (
	"github.com/relab/hotstuff"
	"github.com/relab/hotstuff/core"
	"github.com/relab/hotstuff/core/logging"
	"github.com/relab/hotstuff/internal/proto/clientpb"
	"github.com/relab/hotstuff/protocol/consensus"
	"github.com/relab/hotstuff/security/blockchain"
)

const NameOFT = "oft"

// OFT implements a Chained HotStuff-style OFT consensus protocol.
// It is a 1-chain protocol: a block is committed as soon as the next block
// carries a QC for it (i.e., b.parent == H(b₀) where b₀ is the QC-referenced block).
type OFT struct {
	logger     logging.Logger
	config     *core.RuntimeConfig
	blockchain *blockchain.Blockchain
}

// NewOFT returns a new instance of the OFT consensus ruleset.
func NewOFT(
	logger logging.Logger,
	config *core.RuntimeConfig,
	blockchain *blockchain.Blockchain,
) *OFT {
	return &OFT{
		logger:     logger,
		config:     config,
		blockchain: blockchain,
	}
}

func (o *OFT) qcRef(qc hotstuff.QuorumCert) (*hotstuff.Block, bool) {
	if (hotstuff.Hash{}) == qc.BlockHash() {
		return nil, false
	}
	return o.blockchain.Get(qc.BlockHash())
}

// CommitRule implements the OFT commit logic:
// when receiving block b with highQC, look up b₀ (the block certified by highQC).
// If b.parent == H(b₀), commit b₀.
func (o *OFT) CommitRule(block *hotstuff.Block) *hotstuff.Block {
	// b₀ is the block referenced by the QC in the current block
	b0, ok := o.qcRef(block.QuorumCert())
	if !ok {
		return nil
	}

	o.logger.Debug("CommitRule - PREPARE: ", b0)

	// OFT 1-chain rule: if this block directly extends b₀, commit b₀
	if block.Parent() == b0.Hash() {
		o.logger.Debug("CommitRule - DECIDE: ", b0)
		return b0
	}

	return nil
}

// VoteRule decides whether to vote for the proposal.
// Per the OFT spec, replicas vote for any valid proposal in the current view
// (view/leader checks are handled by the framework). The parent check is only
// used in CommitRule to decide whether to commit, not to gate voting.
// This ensures liveness: after view changes with gaps, replicas still vote.
func (o *OFT) VoteRule(_ hotstuff.View, proposal hotstuff.ProposeMsg) bool {
	block := proposal.Block
	_, ok := o.qcRef(block.QuorumCert())
	if !ok {
		o.logger.Debug("VoteRule: QC block not found")
		return false
	}
	return true
}

// ChainLength returns 1: OFT commits after a single QC.
func (o *OFT) ChainLength() int {
	return 1
}

// ProposeRule creates a new OFT proposal.
func (o *OFT) ProposeRule(view hotstuff.View, cert hotstuff.SyncInfo, cmd *clientpb.Batch) (proposal hotstuff.ProposeMsg, ok bool) {
	qc, ok := cert.QC()
	if !ok {
		return proposal, false
	}
	proposal = hotstuff.NewProposeMsg(o.config.ID(), view, qc, cmd)
	return proposal, true
}

var _ consensus.Ruleset = (*OFT)(nil)
