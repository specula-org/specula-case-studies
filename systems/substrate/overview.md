# Substrate

## Scope

Specula analyzed and tested Substrate's GRANDPA finality gadget, including voting rounds, GHOST target selection, authority-set changes, equivocation handling, and concurrent finalization and round transitions.

## Bugs

Specula found 1 previously known bug:

- **Fixed:** Completing one round could overwrite an existing vote record for the next round, allowing crash recovery to make an honest validator equivocate (PR #6823).
