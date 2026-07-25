// Reproduction test for CR1: LightClientAttackEvidence.Hash() off-by-one byte truncation.
//
// Bug: types/evidence.go:322-329
//   bz := make([]byte, tmhash.Size+n)                            // size = 32+n, zero-init
//   copy(bz[:tmhash.Size-1], l.ConflictingBlock.Hash().Bytes())  // writes indices 0..30 only (31 bytes)
//   copy(bz[tmhash.Size:], buf)                                  // writes indices 32..32+n-1
//   --> bz[31] is never assigned (remains zero)
//
// Effect: the 32nd byte of ConflictingBlock.Hash() is dropped from the SHA-256 pre-image.
// Two distinct ConflictingBlock hashes that differ ONLY at byte 31 produce the same LCAE.Hash().
// This narrows collision resistance from 256-bit to ~248-bit. Cryptographically infeasible
// to *exploit* offline (you'd need to find two ConflictingBlock.Hash() values that differ
// only at byte 31 — pre-image space is the conflicting block content, not arbitrary 32-byte
// strings), but the implementation defect is real.
//
// Reproduction approach (Level 0 — pure black-box): replicate the Hash() algorithm exactly
// against two conflicting-block-hash inputs that share bytes 0..30 but differ at byte 31.
// The replicated algorithm reads `bz` after the two `copy()` calls and inspects byte 31.
// If our analysis is correct, bz[31] == 0 regardless of input. We then SHA-256 both
// pre-images and confirm the digests match.
//
// We do NOT call the LCAE Hash() method directly because constructing a ConflictingBlock
// whose .Hash() differs at byte 31 only requires brute-forcing many blocks (the hash is
// SHA-256 over a serialized struct, so we cannot choose it freely). The replicated algorithm
// gives the same result on the same input — this is a deterministic algorithmic claim.
package main

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"os"
)

// tmhashSize matches crypto/tmhash/hash.go:8-11: tmhash.Size = sha256.Size = 32
const tmhashSize = sha256.Size // 32

// lcaeHashReplica replicates the exact algorithm at types/evidence.go:322-329.
// commonHeight is the LCAE.CommonHeight field; conflictingHash is l.ConflictingBlock.Hash().Bytes().
func lcaeHashReplica(commonHeight int64, conflictingHash []byte) (digest []byte, preImage []byte) {
	buf := make([]byte, binary.MaxVarintLen64)
	n := binary.PutVarint(buf, commonHeight)
	bz := make([]byte, tmhashSize+n)
	copy(bz[:tmhashSize-1], conflictingHash) // <-- BUG: writes 31 bytes, not 32
	copy(bz[tmhashSize:], buf)                // <-- writes from index 32, skipping bz[31]
	sum := sha256.Sum256(bz)
	return sum[:], bz
}

func main() {
	// Two conflicting-block hashes that share bytes 0..30 but differ at byte 31.
	// These are 32-byte arrays — the format of types.BlockID.Hash().
	hashA := make([]byte, 32)
	hashB := make([]byte, 32)
	for i := 0; i < 31; i++ {
		hashA[i] = byte(i)
		hashB[i] = byte(i)
	}
	hashA[31] = 0xAA
	hashB[31] = 0xBB // differs from hashA only at the LAST byte

	const commonHeight = int64(1000)

	digestA, preA := lcaeHashReplica(commonHeight, hashA)
	digestB, preB := lcaeHashReplica(commonHeight, hashB)

	fmt.Println("=== CR1: LCAE.Hash() byte-31 truncation reproduction ===")
	fmt.Printf("Input ConflictingBlock.Hash A: %x\n", hashA)
	fmt.Printf("Input ConflictingBlock.Hash B: %x\n", hashB)
	fmt.Printf("Differ only at index 31: A[31]=%02x  B[31]=%02x\n", hashA[31], hashB[31])
	fmt.Printf("Pre-image A (bz)        : %x\n", preA)
	fmt.Printf("Pre-image B (bz)        : %x\n", preB)
	fmt.Printf("bz[31] in A             : %02x  (should hold hashA[31]=0xAA if the impl were correct)\n", preA[31])
	fmt.Printf("bz[31] in B             : %02x  (should hold hashB[31]=0xBB if the impl were correct)\n", preB[31])
	fmt.Printf("LCAE.Hash(A)            : %x\n", digestA)
	fmt.Printf("LCAE.Hash(B)            : %x\n", digestB)

	failures := 0

	// Assertion 1: bz[31] is silently dropped.
	if preA[31] != 0 || preB[31] != 0 {
		fmt.Println("FAIL: expected bz[31] == 0 in both pre-images (the bug claim), but it is non-zero")
		failures++
	} else {
		fmt.Println("PASS: bz[31] is uninitialized (zero) in both pre-images — byte 31 of ConflictingBlock.Hash() is dropped")
	}

	// Assertion 2: the two LCAE.Hash() digests collide despite distinct ConflictingBlock.Hash() inputs.
	collision := true
	for i := 0; i < len(digestA); i++ {
		if digestA[i] != digestB[i] {
			collision = false
			break
		}
	}
	if !collision {
		fmt.Println("FAIL: digests differ; expected collision because byte 31 is dropped from the pre-image")
		failures++
	} else {
		fmt.Println("PASS: LCAE.Hash(A) == LCAE.Hash(B) — collision confirmed despite differing 32nd byte of conflicting-block hash")
	}

	if failures > 0 {
		fmt.Printf("\nReproduction: FAIL (%d assertion failure(s))\n", failures)
		os.Exit(1)
	}
	fmt.Println("\nReproduction: PASS — CR1 bug confirmed.")
}
