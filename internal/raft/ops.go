package raft

// This file is intentionally minimal.
// All Op types, OpType constants, and op data structs are defined in
// internal/store/ops.go to avoid import cycles (raft imports store, not vice versa).
//
// The raft package uses store.OpType, store.Op, store.OpResult, store.EnqueueOp, etc.
