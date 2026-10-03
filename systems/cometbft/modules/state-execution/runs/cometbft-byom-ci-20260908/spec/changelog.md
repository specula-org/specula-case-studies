# Validation Changelog

## Round 1 - Trace Validation

- No fixes required: all six retained Category A traces fully matched `TraceSpec`, including `TraceMatched` and post-state validation (4-11 states generated per trace).

## Round 1 - Model Checking

- No fixes required: `MC.cfg` completed its full bounded BFS with 6,921 states generated, 5,126 distinct states, zero queued states, and diameter 33.

## Bug Hunting

- Scenario 1 parameter validation: complete BFS found no violation (224 generated / 183 distinct, diameter 18); the required 30-minute depth-50 simulation checked 4,381,164,075 states across 87,623,286 traces without a violation.
- Scenario 2 durable boundaries: complete BFS found no violation (2,277 generated / 1,719 distinct, diameter 27).
- Scenario 3 startup recovery: complete BFS found no violation (5,147 generated / 3,892 distinct, diameter 33).
- All seven supplied reachability configs produced their expected `NeverReached*` witness violations, confirming the targeted branches are non-vacuous.

## Result

Converged in 1 round. Bug hunting: no bugs found.
