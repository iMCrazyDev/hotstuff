package config

config: {
    replicaHosts: ["localhost"]
    clientHosts:  ["localhost"]
    replicas:     16
    clients:      4
    consensus:    "fasthotstuff"
    crypto:       "ecdsa"
    leaderRotation: "round-robin"
    communication:  "clique"
    byzantineStrategy: {fork: [1, 4, 7, 10, 13]}
}
