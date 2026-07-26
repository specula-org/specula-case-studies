# Substrate

## Scope

Specula analyzed and tested Substrate's GRANDPA finality gadget, including voting rounds, GHOST target selection, authority-set changes, equivocation handling, and concurrent finalization and round transitions.

## Bugs

The bug tracker records 1 known bug examined by Specula:

- Completing one round could overwrite an existing vote record for the next round, allowing crash recovery to make an honest validator equivocate; PR #6823 fixed the overwrite.
