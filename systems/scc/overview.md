# scc

## Scope

Specula analyzed and tested scc's concurrent HashMap, HashIndex, HashCache, and TreeIndex, including insert and remove and iteration interleavings, incremental resize and bucket migration, asynchronous reference lifetimes, locking, and epoch-based reclamation.

## Bugs

Specula found 1 previously known bug:

- **Fixed:** A historical resize path cleared an entry from the old bucket before publishing it in the new bucket, briefly making it invisible (commit `9573fa1`).
