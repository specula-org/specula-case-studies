//go:build specula
// +build specula

package raft

import pb "go.etcd.io/etcd/raft/raftpb"

// The hook is installed only by the tagged harness. Its observations never
// participate in a Raft decision. All calls are serialized by the caller.
var speculaHook func(string, *raft, pb.Message, interface{})

type speculaLoopState struct {
	HS        pb.HardState
	SS        *SoftState
	Lead      uint64
	Proposals bool
}

func speculaObserve(kind string, r *raft, m pb.Message, data interface{}) {
	if speculaHook != nil {
		speculaHook(kind, r, m, data)
	}
}

func speculaNodeLoop(r *raft, hs pb.HardState, ss *SoftState, lead uint64, proposals bool) {
	speculaObserve("node-loop", r, pb.Message{}, speculaLoopState{hs, ss, lead, proposals})
}
