package hotstuff

import "math"

// NumFaulty returns the maximum number of faulty replicas in a system with n replicas.
func NumFaulty(n int) int {
	return (n - 1) / 3
}

// QuorumSize returns the minimum number of replicas that must agree on a value for it to be considered a quorum.
func QuorumSize(n int) int {
	f := NumFaulty(n)
	return int(math.Ceil(float64(n+f+1) / 2.0))
}

// OFTNumFaulty returns the maximum number of crash-faulty replicas in an OFT system with n replicas.
// OFT uses a crash-fault-tolerant model where N = 2f+1.
func OFTNumFaulty(n int) int {
	return (n - 1) / 2
}

// OFTQuorumSize returns the quorum size for OFT: f+1 where N = 2f+1.
func OFTQuorumSize(n int) int {
	return OFTNumFaulty(n) + 1
}
