# Specification Validation Changelog

## Round 1 - Trace Validation

## Round 1 - Model Checking

- [fix-inv] ImplicitDeadlockProperty: TLC's deadlock oracle rejected an intentionally quiescent, counter-exhausted state while `MCSpec` permits stuttering and the implementation requires a new external agent submission to progress. Classified as Case A and disabled the non-promised deadlock check for the `MC.cfg` safety/structural run.
- [fix-spec] ReceiveSubmission: Scenario 2 initially accumulated multiple zero-retry endpoint handlers before any called the no-suspension `Conductor.submit` coroutine, which the single API event loop prevents. Classified as Case B; subsequent receives now require every older received handler to have yielded through `RetrySubmission`, preserving genuine delayed-retry races.

## Round 2 - Trace Validation

## Round 2 - Model Checking

## Result

Converged in 2 rounds. Bug hunting: 4 bugs found.
