//go:build !specula
// +build !specula

package raft

import pb "go.etcd.io/etcd/raft/raftpb"

func speculaObserve(string, *raft, pb.Message, interface{})         {}
func speculaNodeLoop(*raft, pb.HardState, *SoftState, uint64, bool) {}
