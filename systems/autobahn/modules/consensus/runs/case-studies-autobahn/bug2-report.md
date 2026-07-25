# Potential Issue: View Change May Select Wrong Winning Proposal

## Summary

We noticed that in `TC::get_winning_proposals()`, the variable `winning_view` appears to be assigned `timeout.view` (the view the validator timed out from) instead of `*other_view` (the actual view of the highest QC). If our reading is correct, this could cause the function to select a proposal backed by a lower-view QC over one backed by a higher-view QC in certain orderings.

## Observation

In `primary/src/messages.rs`, lines 1436–1499, the function `get_winning_proposals()` iterates over timeout messages to find the proposal associated with the highest QC view. The comparison uses `other_view` (the QC's view from the Confirm message), but the assignment stores `timeout.view`:

```rust
// messages.rs:1443-1457
for timeout in &self.timeouts {
    match &timeout.high_qc {
        Some(qc) => {
            match qc {
                ConsensusMessage::Confirm {
                    slot: _, view: other_view, qc: _, proposals,
                } => {
                    if other_view > &winning_view {
                        winning_view = timeout.view;      // seems like this should be *other_view?
                        winning_proposals = proposals.clone();
                    }
                }
                // ...
            }
        }
        // ...
    }
}
```

These two values have different meanings:
- `other_view`: the view in which a PrepareQC was formed — this reflects the actual QC evidence
- `timeout.view`: the view the validator was in when it timed out — this can be higher than `other_view`

By storing `timeout.view` into `winning_view`, subsequent comparisons may use an inflated value that does not correspond to QC evidence.

## Possible Triggering Scenario

Consider 2 timeouts carrying different high QCs:

| Timeout | timeout.view (timed out from) | high_qc view (QC evidence) | Proposals |
|---------|------------------------------|---------------------------|-----------|
| timeout_A | 7 | 2 | v2 |
| timeout_B | 5 | 3 | v1 |

The expected behavior would be for v1 to win, since its QC view (3) is higher than v2's QC view (2).

However, if timeout_A is processed first:

1. Process timeout_A: `other_view=2 > winning_view=0` → true
   - `winning_view` is set to `timeout.view = 7` (rather than 2)
   - `winning_proposals = v2`
2. Process timeout_B: `other_view=3 > winning_view=7` → false (3 < 7)
   - v1 is skipped despite having the higher QC view

The result would be v2 being selected (QC view 2) instead of v1 (QC view 3).

## Reproduction Test

We wrote a unit test that constructs this scenario:

1. Create two proposal sets v1 and v2
2. Create two Confirm messages: one at view=3 (carrying v1) and one at view=2 (carrying v2)
3. Create timeout_A (view=7, high_qc at view=2) and timeout_B (view=5, high_qc at view=3)
4. Build a TC with timeout_A first, then timeout_B
5. Call `get_winning_proposals()` — it returns v2 instead of v1

```
$ cargo test -p primary test_da5 -- --nocapture

running 1 test
DA-5 CONFIRMED: get_winning_proposals selected proposals from QC view 2
              instead of QC view 3, because winning_view was inflated to timeout.view=7
test messages::messages_tests::test_da5_viewchange_wrong_winning_view ... ok
```