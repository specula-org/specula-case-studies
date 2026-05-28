#!/usr/bin/env python3
"""Apply Specula trace instrumentation to the Babylon artifact source.

This script:
  1. Copies the tlatrace package into <artifact>/x/tlatrace.
  2. Inserts trace.Emit() calls at well-defined anchors in keeper files.

The script is idempotent: each insertion is guarded by a marker comment so a
second run does nothing.  Reverting is handled by `git -C artifact checkout
-- .` (see harness/clean.sh).
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]  # .specula-output/
HARNESS_DIR = REPO_ROOT / "harness"
ARTIFACT_ROOT = REPO_ROOT.parent / "artifact" / "babylon"
SRC_TLATRACE = HARNESS_DIR / "src" / "tlatrace"
SRC_SCENARIOS = HARNESS_DIR / "src" / "scenarios"

MARKER = "// SPECULA_TRACE"

TLATRACE_IMPORT = (
    'tlatrace "github.com/babylonlabs-io/babylon/v4/x/tlatrace"'
)


def copy_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src, dst)


def ensure_import(path: Path) -> None:
    """Add tlatrace import to a Go file if missing."""
    text = path.read_text()
    if "tlatrace " in text or '"github.com/babylonlabs-io/babylon/v4/x/tlatrace"' in text:
        return
    # Insert into the first import block. We look for ")" that closes import.
    lines = text.splitlines(keepends=True)
    in_import = False
    insert_at = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("import ("):
            in_import = True
            continue
        if in_import and stripped == ")":
            insert_at = i
            break
        if (
            not in_import
            and stripped.startswith("import ")
            and stripped != "import ("
        ):
            # single-line import - replace with block
            lines[i] = "import (\n\t" + stripped[len("import "):] + "\n\t" + TLATRACE_IMPORT + "\n)\n"
            path.write_text("".join(lines))
            return
    if insert_at is None:
        # No import block; create one after the package declaration.
        for i, line in enumerate(lines):
            if line.startswith("package "):
                lines.insert(
                    i + 1,
                    "\nimport (\n\t" + TLATRACE_IMPORT + "\n)\n",
                )
                path.write_text("".join(lines))
                return
        raise RuntimeError(f"could not find import insertion point in {path}")
    lines.insert(insert_at, "\t" + TLATRACE_IMPORT + "\n")
    path.write_text("".join(lines))


def insert_after(path: Path, anchor: str, payload: str, tag: str) -> bool:
    """Insert `payload` on the line after the first occurrence of `anchor`.

    Returns True if the insertion was performed.  If a previous insertion is
    detected (search for `tag`), the file is left unchanged.
    """
    text = path.read_text()
    if tag in text:
        return False
    if anchor not in text:
        raise RuntimeError(f"anchor not found in {path}: {anchor!r}")
    lines = text.splitlines(keepends=True)
    out = []
    inserted = False
    for line in lines:
        out.append(line)
        if not inserted and anchor in line:
            # Compute leading whitespace from the anchor line and apply it
            indent = line[: len(line) - len(line.lstrip())]
            for p in payload.splitlines():
                out.append(indent + p + "\n")
            inserted = True
    path.write_text("".join(out))
    return inserted


def patch_finality_msg_server() -> None:
    p = ARTIFACT_ROOT / "x" / "finality" / "keeper" / "msg_server.go"
    ensure_import(p)

    # AddFinalitySigCanonical (after IndexRefundableMsg at line 224).
    insert_after(
        p,
        "ms.IncentiveKeeper.IndexRefundableMsg(ctx, req)",
        (
            f"{MARKER} CANONICAL_BEGIN\n"
            "fp_canon, _ := ms.BTCStakingKeeper.GetFinalityProvider(ctx, fpPK.MustMarshal())\n"
            "var fpSlashedFlag, fpJailedFlag bool\n"
            "var highestVoted uint32\n"
            "if fp_canon != nil { fpSlashedFlag = fp_canon.IsSlashed(); fpJailedFlag = fp_canon.IsJailed(); highestVoted = fp_canon.HighestVotedHeight }\n"
            "tlatrace.Emit(tlatrace.Event{\n"
            "    Name:   \"AddFinalitySigCanonical\",\n"
            "    Module: \"finality\",\n"
            "    Fp:     tlatrace.Fp(req.FpBtcPk.MarshalHex()),\n"
            "    Msg: map[string]interface{}{\n"
            "        \"blockHeight\": req.BlockHeight,\n"
            "        \"appHash\":     tlatrace.Hash(fmt.Sprintf(\"%x\", indexedBlock.AppHash)),\n"
            "    },\n"
            "    State: map[string]interface{}{\n"
            "        \"sigStoreAt\":     tlatrace.Hash(fmt.Sprintf(\"%x\", indexedBlock.AppHash)),\n"
            "        \"fpSlashed\":      fpSlashedFlag,\n"
            "        \"fpJailed\":       fpJailedFlag,\n"
            "        \"fpHighestVoted\": highestVoted,\n"
            "        \"currentHeight\":  ctx.BlockHeight(),\n"
            "    },\n"
            "})\n"
            f"{MARKER} CANONICAL_END\n"
        ),
        tag=f"{MARKER} CANONICAL_BEGIN",
    )

    # AddFinalitySigFork (after SetEvidence at line 177).  Insert before the
    # `return &types.MsgAddFinalitySigResponse{}, nil` that follows.
    insert_after(
        p,
        "ms.SetEvidence(ctx, evidence)\n",
        (
            f"{MARKER} FORK_BEGIN\n"
            "fp_fork, _ := ms.BTCStakingKeeper.GetFinalityProvider(ctx, fpPK.MustMarshal())\n"
            "var fpForkSlashed bool\n"
            "if fp_fork != nil { fpForkSlashed = fp_fork.IsSlashed() }\n"
            "var canonHashTag string\n"
            "if _, gerr := ms.GetSig(ctx, req.BlockHeight, fpPK); gerr == nil { canonHashTag = tlatrace.Hash(fmt.Sprintf(\"%x\", indexedBlock.AppHash)) } else { canonHashTag = \"NilHash\" }\n"
            "tlatrace.Emit(tlatrace.Event{\n"
            "    Name:   \"AddFinalitySigFork\",\n"
            "    Module: \"finality\",\n"
            "    Fp:     tlatrace.Fp(req.FpBtcPk.MarshalHex()),\n"
            "    Msg: map[string]interface{}{\n"
            "        \"blockHeight\":      req.BlockHeight,\n"
            "        \"forkAppHash\":      tlatrace.Hash(fmt.Sprintf(\"%x\", req.BlockAppHash)),\n"
            "        \"canonicalAppHash\": tlatrace.Hash(fmt.Sprintf(\"%x\", indexedBlock.AppHash)),\n"
            "    },\n"
            "    State: map[string]interface{}{\n"
            "        \"sigStoreAt\":    canonHashTag,\n"
            "        \"fpSlashed\":     fpForkSlashed,\n"
            "        \"currentHeight\": ctx.BlockHeight(),\n"
            "    },\n"
            "})\n"
            f"{MARKER} FORK_END\n"
        ),
        tag=f"{MARKER} FORK_BEGIN",
    )

    # CommitPubRand: there are two SetPubRandCommit call sites (lines ~304,
    # ~317).  Insert after each.
    text = p.read_text()
    if f"{MARKER} COMMITPUBRAND_BEGIN" not in text:
        new_text_parts = []
        cursor = 0
        anchor = "if err := ms.SetPubRandCommit(ctx, req.FpBtcPk, prCommit); err != nil {"
        # Walk the whole-file twice; insert the trace block right before the
        # function returns success after the SetPubRandCommit block.
        # We rely on the "return &types.MsgCommitPubRandListResponse{}, nil"
        # being the *next* return after each SetPubRandCommit success.
        ret_anchor = "return &types.MsgCommitPubRandListResponse{}, nil"
        idx = 0
        while True:
            sp_idx = text.find(anchor, cursor)
            if sp_idx == -1:
                break
            ret_idx = text.find(ret_anchor, sp_idx)
            if ret_idx == -1:
                break
            # Find indent of the return line (use 1 tab as default).
            line_start = text.rfind("\n", 0, ret_idx) + 1
            indent = text[line_start:ret_idx]
            block = (
                f"{indent}{MARKER} COMMITPUBRAND_BEGIN\n"
                f"{indent}tlatrace.Emit(tlatrace.Event{{\n"
                f"{indent}    Name:   \"CommitPubRand\",\n"
                f"{indent}    Module: \"finality\",\n"
                f"{indent}    Fp:     tlatrace.Fp(req.FpBtcPk.MarshalHex()),\n"
                f"{indent}    Msg: map[string]interface{{}}{{\n"
                f"{indent}        \"startHeight\": req.StartHeight,\n"
                f"{indent}        \"numPubRand\":  req.NumPubRand,\n"
                f"{indent}    }},\n"
                f"{indent}    State: map[string]interface{{}}{{\n"
                f"{indent}        \"currentHeight\": ctx.BlockHeight(),\n"
                f"{indent}    }},\n"
                f"{indent}}})\n"
                f"{indent}{MARKER} COMMITPUBRAND_END\n"
            )
            new_text_parts.append(text[cursor:ret_idx])
            new_text_parts.append(block)
            cursor = ret_idx
            idx += 1
        new_text_parts.append(text[cursor:])
        p.write_text("".join(new_text_parts))

    # UnjailFp: insert before the final return in UnjailFinalityProvider.
    insert_after(
        p,
        'err = ms.BTCStakingKeeper.UnjailFinalityProvider(ctx, fpPk.MustMarshal())',
        (
            f"{MARKER} UNJAIL_BEGIN\n"
            "tlatrace.Emit(tlatrace.Event{\n"
            "    Name:   \"UnjailFp\",\n"
            "    Module: \"finality\",\n"
            "    Fp:     tlatrace.Fp(fpPk.MarshalHex()),\n"
            "    State: map[string]interface{}{\n"
            "        \"fpJailed\":      false,\n"
            "        \"currentHeight\": sdkCtx.BlockHeight(),\n"
            "    },\n"
            "})\n"
            f"{MARKER} UNJAIL_END\n"
        ),
        tag=f"{MARKER} UNJAIL_BEGIN",
    )


def patch_finality_liveness() -> None:
    p = ARTIFACT_ROOT / "x" / "finality" / "keeper" / "liveness.go"
    ensure_import(p)
    # HandleLivenessAtHeight: emit after the FinalityProviderSigningTracker.Set
    # call near the end of HandleFinalityProviderLiveness.
    insert_after(
        p,
        "return k.FinalityProviderSigningTracker.Set(ctx, fpPk.MustMarshal(), *signInfo)",
        "",  # we need to insert BEFORE the return, handled below
        tag="__never__",
    ) if False else None  # noop
    # The simplest reliable insertion: insert right before "if updated {" by
    # appending immediately after the jailing block.  We use a multi-anchor
    # approach: emit at end of function via the "// Set the updated signing
    # info" comment.
    insert_after(
        p,
        "// Set the updated signing info",
        (
            f"{MARKER} LIVENESS_BEGIN\n"
            "tlatrace.Emit(tlatrace.Event{\n"
            "    Name:   \"HandleLivenessAtHeight\",\n"
            "    Module: \"finality\",\n"
            "    Fp:     tlatrace.Fp(fpPk.MarshalHex()),\n"
            "    Msg: map[string]interface{}{\n"
            "        \"height\": height,\n"
            "        \"missed\": missed,\n"
            "    },\n"
            "    State: map[string]interface{}{\n"
            "        \"missedCounter\": signInfo.MissedBlocksCounter,\n"
            "        \"fpJailed\":      fp.IsJailed(),\n"
            "        \"currentHeight\": height,\n"
            "    },\n"
            "})\n"
            f"{MARKER} LIVENESS_END\n"
        ),
        tag=f"{MARKER} LIVENESS_BEGIN",
    )


def patch_finality_power_dist() -> None:
    p = ARTIFACT_ROOT / "x" / "finality" / "keeper" / "power_dist_change.go"
    ensure_import(p)
    # ActivateFp: after HandleActivatedFinalityProvider's tracker Set
    # (the "return k.FinalityProviderSigningTracker.Set" line).
    insert_after(
        p,
        "return k.FinalityProviderSigningTracker.Set(ctx, fpPk.MustMarshal(), signingInfo)",
        # We emit *before* the return: but Go won't allow inserting after the
        # return.  So we instead emit just before by using a different anchor.
        "",
        tag="__activate_via_returns__",
    ) if False else None

    text = p.read_text()
    if f"{MARKER} ACTIVATE_BEGIN" not in text:
        anchor = "return k.FinalityProviderSigningTracker.Set(ctx, fpPk.MustMarshal(), signingInfo)"
        if anchor in text:
            line_start = text.rfind("\n", 0, text.index(anchor)) + 1
            indent = text[line_start: text.index(anchor)]
            block = (
                f"{indent}{MARKER} ACTIVATE_BEGIN\n"
                f"{indent}tlatrace.Emit(tlatrace.Event{{\n"
                f"{indent}    Name:   \"ActivateFp\",\n"
                f"{indent}    Module: \"finality\",\n"
                f"{indent}    Fp:     tlatrace.Fp(fpPk.MarshalHex()),\n"
                f"{indent}    State: map[string]interface{{}}{{\n"
                f"{indent}        \"fpActive\":      true,\n"
                f"{indent}        \"startHeight\":   signingInfo.StartHeight,\n"
                f"{indent}        \"missedCounter\": signingInfo.MissedBlocksCounter,\n"
                f"{indent}    }},\n"
                f"{indent}}})\n"
                f"{indent}{MARKER} ACTIVATE_END\n"
            )
            new_text = text.replace(
                anchor, block + indent + anchor, 1
            )
            p.write_text(new_text)

    # DeactivateFp: in processInactiveFp.
    insert_after(
        p,
        'k.Logger(ctx).Info("a new finality provider becomes inactive", "pk", fp.BtcPk.MarshalHex())',
        (
            f"{MARKER} DEACTIVATE_BEGIN\n"
            "tlatrace.Emit(tlatrace.Event{\n"
            "    Name:   \"DeactivateFp\",\n"
            "    Module: \"finality\",\n"
            "    Fp:     tlatrace.Fp(fp.BtcPk.MarshalHex()),\n"
            "    State: map[string]interface{}{\n"
            "        \"fpActive\": false,\n"
            "    },\n"
            "})\n"
            f"{MARKER} DEACTIVATE_END\n"
        ),
        tag=f"{MARKER} DEACTIVATE_BEGIN",
    )

    # ProcessPowerDistAtHeight: emit one event per btcHeight inside the loop
    # after processEventsAtHeight returns.
    text = p.read_text()
    if f"{MARKER} PD_AT_HEIGHT_BEGIN" not in text:
        anchor = "k.processEventsAtHeight(sdkCtx, btcHeight, state)"
        if anchor in text:
            line_start = text.rfind("\n", 0, text.index(anchor)) + 1
            indent = text[line_start: text.index(anchor)]
            block = (
                f"\n{indent}{MARKER} PD_AT_HEIGHT_BEGIN\n"
                f"{indent}{{\n"
                f"{indent}\tslashed := []string{{}}\n"
                f"{indent}\tfor pk, st := range state.FPStatesByBtcPk {{\n"
                f"{indent}\t\tif st == ftypes.FinalityProviderState_SLASHED {{\n"
                f"{indent}\t\t\tslashed = append(slashed, tlatrace.Fp(pk))\n"
                f"{indent}\t\t}}\n"
                f"{indent}\t}}\n"
                f"{indent}\ttlatrace.Emit(tlatrace.Event{{\n"
                f"{indent}\t\tName:   \"ProcessPowerDistAtHeight\",\n"
                f"{indent}\t\tModule: \"finality\",\n"
                f"{indent}\t\tMsg: map[string]interface{{}}{{\n"
                f"{indent}\t\t\t\"btcHeight\": btcHeight,\n"
                f"{indent}\t\t}},\n"
                f"{indent}\t\tState: map[string]interface{{}}{{\n"
                f"{indent}\t\t\t\"pendingLen\":  0,\n"
                f"{indent}\t\t\t\"slashedFps\":  slashed,\n"
                f"{indent}\t\t}},\n"
                f"{indent}\t}})\n"
                f"{indent}}}\n"
                f"{indent}{MARKER} PD_AT_HEIGHT_END"
            )
            text = text.replace(anchor, anchor + block, 1)
            p.write_text(text)


def patch_btc_reorg() -> None:
    p = ARTIFACT_ROOT / "x" / "btcstaking" / "keeper" / "btc_reorg.go"
    ensure_import(p)
    # BtcReorgDeep: emit just before the panic site.
    insert_after(
        p,
        'if largestReorg.BlockDiff >= p.BtcConfirmationDepth {',
        (
            f"{MARKER} REORG_DEEP_BEGIN\n"
            "tlatrace.Emit(tlatrace.Event{\n"
            "    Name:   \"BtcReorgDeep\",\n"
            "    Module: \"btcstaking\",\n"
            "    Msg: map[string]interface{}{\n"
            "        \"depth\": largestReorg.BlockDiff,\n"
            "    },\n"
            "    State: map[string]interface{}{\n"
            "        \"chainHalted\": true,\n"
            "    },\n"
            "})\n"
            f"{MARKER} REORG_DEEP_END\n"
        ),
        tag=f"{MARKER} REORG_DEEP_BEGIN",
    )


def patch_btcstaking_msg_server() -> None:
    p = ARTIFACT_ROOT / "x" / "btcstaking" / "keeper" / "msg_server.go"
    ensure_import(p)
    # CreateBtcDelegation: after ms.Keeper.CreateBTCDelegation returns OK.
    insert_after(
        p,
        "if err := ms.Keeper.CreateBTCDelegation(ctx, parsedMsg); err != nil {",
        "",
        tag="__noop_unused__",
    ) if False else None
    text = p.read_text()
    if f"{MARKER} CREATE_BTCDEL_BEGIN" not in text:
        anchor = "return &types.MsgCreateBTCDelegationResponse{}, nil"
        if anchor in text:
            line_start = text.rfind("\n", 0, text.index(anchor)) + 1
            indent = text[line_start: text.index(anchor)]
            block = (
                f"{indent}{MARKER} CREATE_BTCDEL_BEGIN\n"
                f"{indent}{{\n"
                f"{indent}\tvar _fpid string\n"
                f"{indent}\tif parsedMsg.FinalityProviderKeys != nil && len(parsedMsg.FinalityProviderKeys.PublicKeys) > 0 {{\n"
                f"{indent}\t\t_fpid = tlatrace.Fp(fmt.Sprintf(\"%x\", parsedMsg.FinalityProviderKeys.PublicKeys[0].SerializeCompressed()))\n"
                f"{indent}\t}}\n"
                f"{indent}\ttlatrace.Emit(tlatrace.Event{{\n"
                f"{indent}\t\tName:   \"CreateBtcDelegation\",\n"
                f"{indent}\t\tModule: \"btcstaking\",\n"
                f"{indent}\t\tMsg: map[string]interface{{}}{{\n"
                f"{indent}\t\t\t\"stakingTxHash\": parsedMsg.StakingTx.Transaction.TxHash().String(),\n"
                f"{indent}\t\t\t\"fpBtcPk\":       _fpid,\n"
                f"{indent}\t\t\t\"totalSat\":      uint64(parsedMsg.StakingValue),\n"
                f"{indent}\t\t}},\n"
                f"{indent}\t\tState: map[string]interface{{}}{{\n"
                f"{indent}\t\t\t\"delStatus\": \"VERIFIED\",\n"
                f"{indent}\t\t}},\n"
                f"{indent}\t}})\n"
                f"{indent}}}\n"
                f"{indent}{MARKER} CREATE_BTCDEL_END\n"
            )
            new_text = text.replace(anchor, block + indent + anchor, 1)
            p.write_text(new_text)

    # ActivateBtcDelegation: after AddBTCDelegationInclusionProof success.
    text = p.read_text()
    if f"{MARKER} ACTIVATE_BTCDEL_BEGIN" not in text:
        anchor = "return &types.MsgAddBTCDelegationInclusionProofResponse{}, nil"
        if anchor in text:
            line_start = text.rfind("\n", 0, text.index(anchor)) + 1
            indent = text[line_start: text.index(anchor)]
            block = (
                f"{indent}{MARKER} ACTIVATE_BTCDEL_BEGIN\n"
                f"{indent}tlatrace.Emit(tlatrace.Event{{\n"
                f"{indent}    Name:   \"ActivateBtcDelegation\",\n"
                f"{indent}    Module: \"btcstaking\",\n"
                f"{indent}    Msg: map[string]interface{{}}{{\n"
                f"{indent}        \"stakingTxHash\": req.StakingTxHash,\n"
                f"{indent}    }},\n"
                f"{indent}    State: map[string]interface{{}}{{\n"
                f"{indent}        \"delStatus\": \"ACTIVE\",\n"
                f"{indent}    }},\n"
                f"{indent}}})\n"
                f"{indent}{MARKER} ACTIVATE_BTCDEL_END\n"
            )
            new_text = text.replace(anchor, block + indent + anchor, 1)
            p.write_text(new_text)

    # UnbondBtcDelegation_Intent: after BTCUndelegate sets status.
    text = p.read_text()
    if f"{MARKER} UNBOND_BTCDEL_BEGIN" not in text:
        anchor = "return &types.MsgBTCUndelegateResponse{}, nil"
        if anchor in text:
            line_start = text.rfind("\n", 0, text.index(anchor)) + 1
            indent = text[line_start: text.index(anchor)]
            block = (
                f"{indent}{MARKER} UNBOND_BTCDEL_BEGIN\n"
                f"{indent}tlatrace.Emit(tlatrace.Event{{\n"
                f"{indent}    Name:   \"UnbondBtcDelegation_Intent\",\n"
                f"{indent}    Module: \"btcstaking\",\n"
                f"{indent}    Msg: map[string]interface{{}}{{\n"
                f"{indent}        \"stakingTxHash\": req.StakingTxHash,\n"
                f"{indent}    }},\n"
                f"{indent}    State: map[string]interface{{}}{{\n"
                f"{indent}        \"delStatus\": \"UNBONDED\",\n"
                f"{indent}    }},\n"
                f"{indent}}})\n"
                f"{indent}{MARKER} UNBOND_BTCDEL_END\n"
            )
            new_text = text.replace(anchor, block + indent + anchor, 1)
            p.write_text(new_text)


def patch_btccheckpoint_keeper() -> None:
    p = ARTIFACT_ROOT / "x" / "btccheckpoint" / "keeper" / "keeper.go"
    ensure_import(p)
    # CheckCheckpointsLoop: emit once per call (use defer to fire at end).
    # We avoid k.btcLightClientKeeper.GetTipInfo here because the interface
    # does not expose it; the spec wrapper only requires lastFinalizedEpoch.
    insert_after(
        p,
        "func (k Keeper) checkCheckpoints(ctx context.Context) {",
        (
            f"{MARKER} CKPT_LOOP_BEGIN\n"
            "defer func() {\n"
            "    tlatrace.Emit(tlatrace.Event{\n"
            "        Name:   \"CheckCheckpointsLoop\",\n"
            "        Module: \"btccheckpoint\",\n"
            "        State: map[string]interface{}{\n"
            "            \"lastFinalizedEpoch\": k.getLastFinalizedEpochNumber(ctx),\n"
            "        },\n"
            "    })\n"
            "}()\n"
            f"{MARKER} CKPT_LOOP_END\n"
        ),
        tag=f"{MARKER} CKPT_LOOP_BEGIN",
    )


def patch_btccheckpoint_msg_server() -> None:
    p = ARTIFACT_ROOT / "x" / "btccheckpoint" / "keeper" / "msg_server.go"
    if not p.exists():
        return
    ensure_import(p)
    text = p.read_text()
    if f"{MARKER} SUBMIT_BTC_PROOF_BEGIN" not in text:
        anchor = "return &types.MsgInsertBTCSpvProofResponse{}, nil"
        if anchor in text:
            line_start = text.rfind("\n", 0, text.index(anchor)) + 1
            indent = text[line_start: text.index(anchor)]
            block = (
                f"{indent}{MARKER} SUBMIT_BTC_PROOF_BEGIN\n"
                f"{indent}tlatrace.Emit(tlatrace.Event{{\n"
                f"{indent}    Name:   \"SubmitBTCProof\",\n"
                f"{indent}    Module: \"btccheckpoint\",\n"
                f"{indent}    State: map[string]interface{{}}{{\n"
                f"{indent}        \"btcEpochStatus\":  \"SUBMITTED\",\n"
                f"{indent}        \"localCkptStatus\": \"SUBMITTED\",\n"
                f"{indent}    }},\n"
                f"{indent}}})\n"
                f"{indent}{MARKER} SUBMIT_BTC_PROOF_END\n"
            )
            text = text.replace(anchor, block + indent + anchor, 1)
            p.write_text(text)


def patch_indexed_blocks() -> None:
    p = ARTIFACT_ROOT / "x" / "finality" / "keeper" / "indexed_blocks.go"
    if not p.exists():
        return
    ensure_import(p)
    # AdvanceHeight: emit after SetBlock in IndexBlock.  IndexBlock is called
    # exactly once per Babylon block (in EndBlocker), and also from tests
    # before invoking a finality vote — both produce the spec event.
    insert_after(
        p,
        "types.RecordLastHeight(uint64(headerInfo.Height))",
        (
            f"{MARKER} ADVANCE_HEIGHT_BEGIN\n"
            "tlatrace.Emit(tlatrace.Event{\n"
            "    Name:   \"AdvanceHeight\",\n"
            "    Module: \"chain\",\n"
            "    Msg: map[string]interface{}{\n"
            "        \"appHash\": tlatrace.Hash(fmt.Sprintf(\"%x\", headerInfo.AppHash)),\n"
            "    },\n"
            "    State: map[string]interface{}{\n"
            "        \"currentHeight\": headerInfo.Height + 1,\n"
            "    },\n"
            "})\n"
            f"{MARKER} ADVANCE_HEIGHT_END\n"
        ),
        tag=f"{MARKER} ADVANCE_HEIGHT_BEGIN",
    )
    # Add fmt import if missing (used by our Sprintf).
    text = p.read_text()
    if '"fmt"' not in text:
        text = text.replace(
            'import (\n\t"context"\n',
            'import (\n\t"context"\n\t"fmt"\n',
            1,
        )
        p.write_text(text)


def patch_tallying() -> None:
    p = ARTIFACT_ROOT / "x" / "finality" / "keeper" / "tallying.go"
    if not p.exists():
        return
    ensure_import(p)
    insert_after(
        p,
        "block.Finalized = true",
        (
            f"{MARKER} TALLY_BEGIN\n"
            "tlatrace.Emit(tlatrace.Event{\n"
            "    Name:   \"TallyBlock\",\n"
            "    Module: \"finality\",\n"
            "    Msg: map[string]interface{}{\n"
            "        \"blockHeight\": block.Height,\n"
            "    },\n"
            "    State: map[string]interface{}{\n"
            "        \"finalized\": true,\n"
            "    },\n"
            "})\n"
            f"{MARKER} TALLY_END\n"
        ),
        tag=f"{MARKER} TALLY_BEGIN",
    )


def copy_packages() -> None:
    # Copy tlatrace package into artifact.
    dst = ARTIFACT_ROOT / "x" / "tlatrace"
    copy_tree(SRC_TLATRACE, dst)

    # Copy scenarios package into artifact (test files).
    scenarios_dst = ARTIFACT_ROOT / "x" / "tlatrace_scenarios"
    copy_tree(SRC_SCENARIOS, scenarios_dst)


def main() -> int:
    if not ARTIFACT_ROOT.exists():
        print(f"ERROR: artifact root not found: {ARTIFACT_ROOT}", file=sys.stderr)
        return 1
    copy_packages()
    patch_finality_msg_server()
    patch_finality_liveness()
    patch_finality_power_dist()
    patch_btc_reorg()
    patch_btcstaking_msg_server()
    patch_btccheckpoint_keeper()
    patch_btccheckpoint_msg_server()
    patch_indexed_blocks()
    patch_tallying()
    print("instrumentation applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
