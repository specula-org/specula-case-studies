# rippled

## Scope

Specula analyzed and tested rippled's XRP Ledger consensus and validation paths, including proposal and validation handling, consensus-round transitions, quorum-based ledger acceptance, validator-list and UNL transitions, overlap changes, and equivocation scenarios.

## Bugs

Specula found 1 new bug:

- Locally timed activation of future validator-list generations can give identically configured honest nodes low-overlap UNLs and allow them to accept conflicting ledgers at the same sequence.
