# Persistent finding recheck — current source

## MC-1 — FIXED

`MC-1-control/main.go` creates and snapshots the public joint state
`{1,2,4} && {1,2,3}`, restarts nodes 1 and 4, and attempts an election with
only votes from the incoming half. The run in `MC-1-control/result.log` restores
progress `[1,2,3,4]` and leaves node 1 in `StateCandidate` because the outgoing
majority is absent. This directly closes the prior constructor/restart defect.

## CR-3 — REPRODUCED

`CR-3/main.go` uses the public asynchronous `Node` interface. The run in
`CR-3/result.log` commits the first membership entry at index 3, calls
`Advance` before applying it, and then commits the second membership entry at
index 4 before `ApplyConfChange` for index 3. The prior admission-boundary
finding remains present on this source revision.
