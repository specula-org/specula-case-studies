//! Trace-generation scenarios for the TLA+ regalloc / liveness spec.
//!
//! Each `#[test]` drives the **real** compiler pipeline (allocate_registers +
//! calculate_stack_space_common) on a hand-constructed `IrFunction` and writes
//! one NDJSON trace to the directory named by the `TLA_TRACE_DIR` environment
//! variable. The bundled `run.sh` sets this variable so the traces land under
//! `.specula-output/traces/`.
//!
//! Design points:
//! 1. Each scenario owns its own trace file, keyed by scenario name. The
//!    emission module uses thread-local writers, so parallel `cargo test` is
//!    safe.
//! 2. Every scenario also emits a `config` line as the first JSON line.
//!    Phase 3 can extract this block into the TLC CONSTANTS configuration.
//! 3. Where possible, scenarios use distinct bug surfaces (F1 asm-no-operand
//!    drop, F3 dataflow cap, ordinary straight-line, multi-block dataflow).

#![cfg(test)]

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::common::types::IrType;
use crate::ir::reexports::{
    BasicBlock, BlockId, CallInfo, Instruction, IrBinOp, IrConst, IrFunction, Operand, Terminator,
    Value,
};

use super::regalloc::{PhysReg, RegAllocConfig};
use super::tla_trace;

// ── Helpers ──────────────────────────────────────────────────────────────────

fn trace_path(name: &str) -> PathBuf {
    let dir = std::env::var("TLA_TRACE_DIR").unwrap_or_else(|_| {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.push("target");
        p.push("tla_traces");
        p.to_string_lossy().into_owned()
    });
    let mut p = PathBuf::from(dir);
    std::fs::create_dir_all(&p).expect("create trace dir");
    p.push(format!("{}.ndjson", name));
    p
}

/// Callee-saved register pool used by Phase 1 and Phase 3 (x86-64 IDs).
fn callee_saved() -> Vec<PhysReg> {
    vec![PhysReg(1), PhysReg(2), PhysReg(3), PhysReg(4), PhysReg(5)]
}

/// Caller-saved register pool used by Phase 2 (x86-64 IDs).
fn caller_saved() -> Vec<PhysReg> {
    vec![
        PhysReg(10), PhysReg(11), PhysReg(12),
        PhysReg(13), PhysReg(14), PhysReg(15),
    ]
}

/// Simplified x86-style slot assignment closure.
fn x86_assign_slot() -> impl Fn(i64, i64, i64) -> (i64, i64) {
    |space, alloc_size, align| {
        let effective_align = if align > 0 { align.max(8) } else { 8 };
        let alloc = (alloc_size + 7) & !7;
        let new_space = ((space + alloc + effective_align - 1) / effective_align) * effective_align;
        (-new_space, new_space)
    }
}

/// Drive allocate_registers + calculate_stack_space_common end-to-end for one
/// scenario. Caller must have already called `tla_trace::open` / emitted the
/// config line.
fn drive_pipeline(func: &IrFunction) {
    let config = RegAllocConfig {
        available_regs: callee_saved(),
        caller_saved_regs: caller_saved(),
        allow_inline_asm_regalloc: false,
    };
    let alloc_result = super::regalloc::allocate_registers(func, &config);
    let reg_assigned = alloc_result.assignments.clone();
    let cached_liveness = alloc_result.liveness;

    let mut state = super::state::CodegenState::new();
    let _ = super::stack_layout::calculate_stack_space_common(
        &mut state,
        func,
        0,
        x86_assign_slot(),
        &reg_assigned,
        &callee_saved(),
        cached_liveness,
        false,
    );
}

/// Emit a configuration JSON line at the top of the trace. The body is passed
/// as a ready-formatted JSON object; this function simply wraps it in the
/// outer envelope used by Trace.tla.
fn emit_scenario_config(
    name: &str,
    vals: &[u32],
    points: &[u32],
    blocks: &[u32],
    func_end: u32,
    block_of_point: &BTreeMap<u32, u32>,
    block_succs: &BTreeMap<u32, Vec<u32>>,
    true_def: &BTreeMap<u32, u32>,
    true_uses: &BTreeMap<u32, Vec<u32>>,
    call_points: &[u32],
    asm_points: &[u32],
    asm_has_operands: &BTreeMap<u32, bool>,
    asm_clobbers: &BTreeMap<u32, Vec<u8>>,
    returns_twice_points: &[u32],
    is_recognized_returns_twice: &BTreeMap<u32, bool>,
    slots: &[u32],
    priority: &BTreeMap<u32, u32>,
) {
    let cs = callee_saved();
    let cr = caller_saved();
    let cs_ids: Vec<u8> = cs.iter().map(|r| r.0).collect();
    let cr_ids: Vec<u8> = cr.iter().map(|r| r.0).collect();
    let cfg = tla_trace::FunctionConfig {
        name,
        vals,
        points,
        blocks,
        func_end,
        max_iters: 50,
        block_of_point,
        block_succs,
        true_def,
        true_uses,
        call_points,
        asm_points,
        asm_has_operands,
        asm_clobbers,
        returns_twice_points,
        is_recognized_returns_twice,
        callee_saved_regs: &cs_ids,
        caller_saved_regs: &cr_ids,
        slots,
        priority,
    };
    tla_trace::emit_config(&cfg);
}

fn call_info(dest: Option<Value>, args: Vec<Operand>, arg_types: Vec<IrType>, ret: IrType) -> CallInfo {
    let n = args.len();
    CallInfo {
        dest,
        args,
        arg_types,
        return_type: ret,
        is_variadic: false,
        num_fixed_args: n,
        struct_arg_sizes: vec![None; n],
        struct_arg_aligns: vec![None; n],
        struct_arg_classes: (0..n).map(|_| Vec::new()).collect(),
        struct_arg_riscv_float_classes: vec![None; n],
        is_sret: false,
        is_fastcall: false,
        ret_eightbyte_classes: Vec::new(),
    }
}

// ── Scenario 1: straight-line, no calls ──────────────────────────────────────
//
// Single block, two binops, one return. Exercises:
// - AssignProgramPoints (no call_points, no asm_points)
// - DataflowIterStep — converges in 1-2 iterations
// - ExtendIntervalsFromLiveness, BuildIntervals
// - Phase1 empty, Phase2 allocates %0 and %1 to caller-saved
// - Phase3 empty, PackSlots empty
#[test]
fn scenario_straight_line_sum() {
    let mut func = IrFunction::new("straight_line_sum".into(), IrType::I32, vec![], false);
    func.blocks.push(BasicBlock {
        label: BlockId(0),
        instructions: vec![
            Instruction::BinOp {
                dest: Value(1), op: IrBinOp::Add,
                lhs: Operand::Const(IrConst::I32(10)),
                rhs: Operand::Const(IrConst::I32(20)),
                ty: IrType::I32,
            },
            Instruction::BinOp {
                dest: Value(2), op: IrBinOp::Add,
                lhs: Operand::Value(Value(1)),
                rhs: Operand::Const(IrConst::I32(30)),
                ty: IrType::I32,
            },
        ],
        terminator: Terminator::Return(Some(Operand::Value(Value(2)))),
        source_spans: Vec::new(),
    });
    func.next_value_id = 3;

    let path = trace_path("straight_line_sum");
    tla_trace::open(path.to_str().unwrap());
    tla_trace::begin_function("straight_line_sum");

    let vals = [1u32, 2];
    let points = [0u32, 1, 2];
    let blocks = [0u32];
    let func_end = 3;
    let block_of_point: BTreeMap<u32, u32> =
        [(0, 0), (1, 0), (2, 0)].iter().cloned().collect();
    let block_succs: BTreeMap<u32, Vec<u32>> = [(0, vec![])].iter().cloned().collect();
    let true_def: BTreeMap<u32, u32> = [(1, 0), (2, 1)].iter().cloned().collect();
    let true_uses: BTreeMap<u32, Vec<u32>> = [(1, vec![1]), (2, vec![2])].iter().cloned().collect();
    let empty_asm_bool: BTreeMap<u32, bool> = BTreeMap::new();
    let empty_asm_clb: BTreeMap<u32, Vec<u8>> = BTreeMap::new();
    let empty_irt: BTreeMap<u32, bool> = BTreeMap::new();
    let priority: BTreeMap<u32, u32> = [(1, 1), (2, 1)].iter().cloned().collect();

    emit_scenario_config(
        "straight_line_sum",
        &vals, &points, &blocks, func_end,
        &block_of_point, &block_succs, &true_def, &true_uses,
        &[], &[], &empty_asm_bool, &empty_asm_clb,
        &[], &empty_irt,
        &[100, 104], &priority,
    );

    drive_pipeline(&func);
    tla_trace::close();
}

// ── Scenario 2: value live across a call ─────────────────────────────────────
//
// Exercises Phase 1 callee-saved allocation (value live across a call point).
#[test]
fn scenario_value_across_call() {
    let mut func = IrFunction::new("value_across_call".into(), IrType::I32, vec![], false);
    func.blocks.push(BasicBlock {
        label: BlockId(0),
        instructions: vec![
            Instruction::BinOp {
                dest: Value(1), op: IrBinOp::Add,
                lhs: Operand::Const(IrConst::I32(7)),
                rhs: Operand::Const(IrConst::I32(13)),
                ty: IrType::I32,
            },
            Instruction::Call {
                func: "helper".to_string(),
                info: call_info(None, vec![], vec![], IrType::Void),
            },
            Instruction::BinOp {
                dest: Value(2), op: IrBinOp::Add,
                lhs: Operand::Value(Value(1)),
                rhs: Operand::Const(IrConst::I32(1)),
                ty: IrType::I32,
            },
        ],
        terminator: Terminator::Return(Some(Operand::Value(Value(2)))),
        source_spans: Vec::new(),
    });
    func.next_value_id = 3;

    let path = trace_path("value_across_call");
    tla_trace::open(path.to_str().unwrap());
    tla_trace::begin_function("value_across_call");

    // Points: 0 = BinOp(%1), 1 = Call, 2 = BinOp(%2), block_end = 3
    let vals = [1u32, 2];
    let points = [0u32, 1, 2];
    let blocks = [0u32];
    let func_end = 3;
    let block_of_point: BTreeMap<u32, u32> =
        [(0, 0), (1, 0), (2, 0)].iter().cloned().collect();
    let block_succs: BTreeMap<u32, Vec<u32>> = [(0, vec![])].iter().cloned().collect();
    let true_def: BTreeMap<u32, u32> = [(1, 0), (2, 2)].iter().cloned().collect();
    let true_uses: BTreeMap<u32, Vec<u32>> = [(1, vec![2]), (2, vec![2])].iter().cloned().collect();
    let empty_asm_bool: BTreeMap<u32, bool> = BTreeMap::new();
    let empty_asm_clb: BTreeMap<u32, Vec<u8>> = BTreeMap::new();
    let empty_irt: BTreeMap<u32, bool> = BTreeMap::new();
    let priority: BTreeMap<u32, u32> = [(1, 2), (2, 1)].iter().cloned().collect();

    emit_scenario_config(
        "value_across_call",
        &vals, &points, &blocks, func_end,
        &block_of_point, &block_succs, &true_def, &true_uses,
        &[1],            // CallPoints — one real call at point 1
        &[],
        &empty_asm_bool, &empty_asm_clb,
        &[], &empty_irt,
        &[100, 104], &priority,
    );

    drive_pipeline(&func);
    tla_trace::close();
}

// ── Scenario 3: two-block control flow (branch + join) ───────────────────────
//
// Exercises multi-block dataflow with a cond-branch and join. Values are
// defined in block 0 and used in blocks 0 and 1 — Phase 4 must extend
// intervals through live-in/live-out.
#[test]
fn scenario_two_block_branch() {
    let mut func = IrFunction::new("two_block_branch".into(), IrType::I32, vec![], false);
    // Block 0 — compute %1, cond-branch on %2.
    func.blocks.push(BasicBlock {
        label: BlockId(0),
        instructions: vec![
            Instruction::BinOp {
                dest: Value(1), op: IrBinOp::Add,
                lhs: Operand::Const(IrConst::I32(1)),
                rhs: Operand::Const(IrConst::I32(2)),
                ty: IrType::I32,
            },
            Instruction::BinOp {
                dest: Value(2), op: IrBinOp::Add,
                lhs: Operand::Value(Value(1)),
                rhs: Operand::Const(IrConst::I32(3)),
                ty: IrType::I32,
            },
        ],
        terminator: Terminator::CondBranch {
            cond: Operand::Value(Value(2)),
            true_label: BlockId(1),
            false_label: BlockId(2),
        },
        source_spans: Vec::new(),
    });
    // Block 1 — use %1, return.
    func.blocks.push(BasicBlock {
        label: BlockId(1),
        instructions: vec![
            Instruction::BinOp {
                dest: Value(3), op: IrBinOp::Add,
                lhs: Operand::Value(Value(1)),
                rhs: Operand::Const(IrConst::I32(10)),
                ty: IrType::I32,
            },
        ],
        terminator: Terminator::Return(Some(Operand::Value(Value(3)))),
        source_spans: Vec::new(),
    });
    // Block 2 — return %2 directly.
    func.blocks.push(BasicBlock {
        label: BlockId(2),
        instructions: vec![],
        terminator: Terminator::Return(Some(Operand::Value(Value(2)))),
        source_spans: Vec::new(),
    });
    func.next_value_id = 4;

    let path = trace_path("two_block_branch");
    tla_trace::open(path.to_str().unwrap());
    tla_trace::begin_function("two_block_branch");

    // Points: 0 = %1, 1 = %2, 2 = block 0 end, 3 = %3, 4 = block 1 end,
    //         5 = block 2 empty end.
    let vals = [1u32, 2, 3];
    let points = [0u32, 1, 2, 3, 4, 5];
    let blocks = [0u32, 1, 2];
    let func_end = 6;
    let block_of_point: BTreeMap<u32, u32> =
        [(0, 0), (1, 0), (2, 0), (3, 1), (4, 1), (5, 2)].iter().cloned().collect();
    let block_succs: BTreeMap<u32, Vec<u32>> =
        [(0, vec![1, 2]), (1, vec![]), (2, vec![])].iter().cloned().collect();
    let true_def: BTreeMap<u32, u32> = [(1, 0), (2, 1), (3, 3)].iter().cloned().collect();
    let true_uses: BTreeMap<u32, Vec<u32>> =
        [(1, vec![1, 3]), (2, vec![2, 5]), (3, vec![4])]
            .iter().cloned().collect();
    let empty_asm_bool: BTreeMap<u32, bool> = BTreeMap::new();
    let empty_asm_clb: BTreeMap<u32, Vec<u8>> = BTreeMap::new();
    let empty_irt: BTreeMap<u32, bool> = BTreeMap::new();
    let priority: BTreeMap<u32, u32> = [(1, 2), (2, 2), (3, 1)].iter().cloned().collect();

    emit_scenario_config(
        "two_block_branch",
        &vals, &points, &blocks, func_end,
        &block_of_point, &block_succs, &true_def, &true_uses,
        &[], &[], &empty_asm_bool, &empty_asm_clb,
        &[], &empty_irt,
        &[100, 104, 108], &priority,
    );

    drive_pipeline(&func);
    tla_trace::close();
}

// ── Scenario 4: empty inline-asm barrier (F1 surface) ────────────────────────
//
// Uses an inline asm with empty inputs/outputs and a caller-saved clobber
// ("r11" → PhysReg(10)). The implementation filters this point out of
// `call_points` (liveness.rs:316-322), so the trace's `recordedCallPoints`
// will NOT list the asm point. The scenario's config declares the *ground-
// truth* clobber so Phase 3's `CallerSavedDeadAcrossAsmClobber` invariant
// can fire.
#[test]
fn scenario_asm_no_operands_f1() {
    let mut func = IrFunction::new("asm_no_operands_f1".into(), IrType::I32, vec![], false);
    func.blocks.push(BasicBlock {
        label: BlockId(0),
        instructions: vec![
            Instruction::BinOp {
                dest: Value(1), op: IrBinOp::Add,
                lhs: Operand::Const(IrConst::I32(100)),
                rhs: Operand::Const(IrConst::I32(200)),
                ty: IrType::I32,
            },
            // Empty inline asm barrier ("clobbers r11 but reports no operands")
            // — this is the F1 surface. The liveness pass drops it from
            // recordedCallPoints because outputs.is_empty() && inputs.is_empty().
            Instruction::InlineAsm {
                template: "".to_string(),
                outputs: vec![],
                inputs: vec![],
                clobbers: vec!["r11".to_string(), "memory".to_string()],
                operand_types: vec![],
                goto_labels: vec![],
                input_symbols: vec![],
                seg_overrides: vec![],
            },
            Instruction::BinOp {
                dest: Value(2), op: IrBinOp::Add,
                lhs: Operand::Value(Value(1)),
                rhs: Operand::Const(IrConst::I32(1)),
                ty: IrType::I32,
            },
        ],
        terminator: Terminator::Return(Some(Operand::Value(Value(2)))),
        source_spans: Vec::new(),
    });
    func.next_value_id = 3;

    let path = trace_path("asm_no_operands_f1");
    tla_trace::open(path.to_str().unwrap());
    tla_trace::begin_function("asm_no_operands_f1");

    let vals = [1u32, 2];
    let points = [0u32, 1, 2];
    let blocks = [0u32];
    let func_end = 3;
    let block_of_point: BTreeMap<u32, u32> =
        [(0, 0), (1, 0), (2, 0)].iter().cloned().collect();
    let block_succs: BTreeMap<u32, Vec<u32>> = [(0, vec![])].iter().cloned().collect();
    let true_def: BTreeMap<u32, u32> = [(1, 0), (2, 2)].iter().cloned().collect();
    // %1 is used at point 2 (in the BinOp) — it's live across the asm at 1.
    let true_uses: BTreeMap<u32, Vec<u32>> = [(1, vec![2]), (2, vec![2])].iter().cloned().collect();
    let asm_points = [1u32];
    let asm_has_operands: BTreeMap<u32, bool> = [(1u32, false)].iter().cloned().collect();
    // Ground-truth clobber set includes r11 (caller-saved, id 10).
    let asm_clobbers: BTreeMap<u32, Vec<u8>> = [(1u32, vec![10u8])].iter().cloned().collect();
    let empty_irt: BTreeMap<u32, bool> = BTreeMap::new();
    let priority: BTreeMap<u32, u32> = [(1, 2), (2, 1)].iter().cloned().collect();

    emit_scenario_config(
        "asm_no_operands_f1",
        &vals, &points, &blocks, func_end,
        &block_of_point, &block_succs, &true_def, &true_uses,
        &[],              // CallPoints — ground truth: no *real* calls
        &asm_points,
        &asm_has_operands, &asm_clobbers,
        &[], &empty_irt,
        &[100, 104], &priority,
    );

    drive_pipeline(&func);
    tla_trace::close();
}

// ── Scenario 5: f32 multi-block values force Tier-2 slot packing ─────────────
//
// f32 values are non-GPR and therefore never register-assigned. Several f32
// values defined in block 0 and used in block 1 flow into Tier-2 packing,
// producing `AssignSlot` events. Exercises the slot-reuse path in
// slot_assignment.rs:752-760 (F4 bug surface).
#[test]
fn scenario_slot_packing_floats() {
    let mut func = IrFunction::new("slot_packing_floats".into(), IrType::F32, vec![], false);
    func.blocks.push(BasicBlock {
        label: BlockId(0),
        instructions: vec![
            Instruction::BinOp {
                dest: Value(1), op: IrBinOp::Add,
                lhs: Operand::Const(IrConst::F32(1.0)),
                rhs: Operand::Const(IrConst::F32(2.0)),
                ty: IrType::F32,
            },
            Instruction::BinOp {
                dest: Value(2), op: IrBinOp::Add,
                lhs: Operand::Const(IrConst::F32(3.0)),
                rhs: Operand::Const(IrConst::F32(4.0)),
                ty: IrType::F32,
            },
            Instruction::BinOp {
                dest: Value(3), op: IrBinOp::Add,
                lhs: Operand::Const(IrConst::F32(5.0)),
                rhs: Operand::Const(IrConst::F32(6.0)),
                ty: IrType::F32,
            },
            Instruction::BinOp {
                dest: Value(4), op: IrBinOp::Add,
                lhs: Operand::Const(IrConst::F32(7.0)),
                rhs: Operand::Const(IrConst::F32(8.0)),
                ty: IrType::F32,
            },
        ],
        terminator: Terminator::Branch(BlockId(1)),
        source_spans: Vec::new(),
    });
    func.blocks.push(BasicBlock {
        label: BlockId(1),
        instructions: vec![
            Instruction::BinOp {
                dest: Value(5), op: IrBinOp::Add,
                lhs: Operand::Value(Value(1)),
                rhs: Operand::Value(Value(2)),
                ty: IrType::F32,
            },
            Instruction::BinOp {
                dest: Value(6), op: IrBinOp::Add,
                lhs: Operand::Value(Value(3)),
                rhs: Operand::Value(Value(4)),
                ty: IrType::F32,
            },
            Instruction::BinOp {
                dest: Value(7), op: IrBinOp::Add,
                lhs: Operand::Value(Value(5)),
                rhs: Operand::Value(Value(6)),
                ty: IrType::F32,
            },
        ],
        terminator: Terminator::Return(Some(Operand::Value(Value(7)))),
        source_spans: Vec::new(),
    });
    func.next_value_id = 8;

    let path = trace_path("slot_packing_floats");
    tla_trace::open(path.to_str().unwrap());
    tla_trace::begin_function("slot_packing_floats");

    let vals = [1u32, 2, 3, 4, 5, 6, 7];
    let points = [0u32, 1, 2, 3, 4, 5, 6, 7, 8];
    let blocks = [0u32, 1];
    let func_end = 9;
    let block_of_point: BTreeMap<u32, u32> =
        [(0, 0), (1, 0), (2, 0), (3, 0), (4, 0),
         (5, 1), (6, 1), (7, 1), (8, 1)].iter().cloned().collect();
    let block_succs: BTreeMap<u32, Vec<u32>> =
        [(0, vec![1]), (1, vec![])].iter().cloned().collect();
    let true_def: BTreeMap<u32, u32> =
        [(1, 0), (2, 1), (3, 2), (4, 3), (5, 5), (6, 6), (7, 7)]
            .iter().cloned().collect();
    let true_uses: BTreeMap<u32, Vec<u32>> =
        [(1, vec![5]), (2, vec![5]), (3, vec![6]), (4, vec![6]),
         (5, vec![7]), (6, vec![7]), (7, vec![8])]
            .iter().cloned().collect();
    let empty_asm_bool: BTreeMap<u32, bool> = BTreeMap::new();
    let empty_asm_clb: BTreeMap<u32, Vec<u8>> = BTreeMap::new();
    let empty_irt: BTreeMap<u32, bool> = BTreeMap::new();
    let priority: BTreeMap<u32, u32> =
        [(1, 1), (2, 1), (3, 1), (4, 1), (5, 1), (6, 1), (7, 1)]
            .iter().cloned().collect();

    emit_scenario_config(
        "slot_packing_floats",
        &vals, &points, &blocks, func_end,
        &block_of_point, &block_succs, &true_def, &true_uses,
        &[], &[], &empty_asm_bool, &empty_asm_clb,
        &[], &empty_irt,
        &[100, 104, 108, 112, 116, 120, 124], &priority,
    );

    drive_pipeline(&func);
    tla_trace::close();
}

// ── Scenario 6: simple loop (multi-iteration dataflow) ───────────────────────
//
// A back-edge forces dataflow to iterate more than once and produces a
// meaningful sequence of `DataflowIterStep` events.
#[test]
fn scenario_loop_fixpoint() {
    let mut func = IrFunction::new("loop_fixpoint".into(), IrType::I32, vec![], false);
    // Block 0 (entry): define %1, jmp to header.
    func.blocks.push(BasicBlock {
        label: BlockId(0),
        instructions: vec![
            Instruction::BinOp {
                dest: Value(1), op: IrBinOp::Add,
                lhs: Operand::Const(IrConst::I32(0)),
                rhs: Operand::Const(IrConst::I32(0)),
                ty: IrType::I32,
            },
        ],
        terminator: Terminator::Branch(BlockId(1)),
        source_spans: Vec::new(),
    });
    // Block 1 (header): cond-branch on %1 — exits or continues.
    func.blocks.push(BasicBlock {
        label: BlockId(1),
        instructions: vec![
            Instruction::BinOp {
                dest: Value(2), op: IrBinOp::Add,
                lhs: Operand::Value(Value(1)),
                rhs: Operand::Const(IrConst::I32(1)),
                ty: IrType::I32,
            },
        ],
        terminator: Terminator::CondBranch {
            cond: Operand::Value(Value(2)),
            true_label: BlockId(2),
            false_label: BlockId(3),
        },
        source_spans: Vec::new(),
    });
    // Block 2 (body): back-edge to header.
    func.blocks.push(BasicBlock {
        label: BlockId(2),
        instructions: vec![],
        terminator: Terminator::Branch(BlockId(1)),
        source_spans: Vec::new(),
    });
    // Block 3 (exit): return %2.
    func.blocks.push(BasicBlock {
        label: BlockId(3),
        instructions: vec![],
        terminator: Terminator::Return(Some(Operand::Value(Value(2)))),
        source_spans: Vec::new(),
    });
    func.next_value_id = 3;

    let path = trace_path("loop_fixpoint");
    tla_trace::open(path.to_str().unwrap());
    tla_trace::begin_function("loop_fixpoint");

    // Points layout: 0=%1 block 0 inst, 1=block0 end, 2=%2, 3=block1 end,
    // 4=block2 end, 5=block3 end.
    let vals = [1u32, 2];
    let points = [0u32, 1, 2, 3, 4, 5];
    let blocks = [0u32, 1, 2, 3];
    let func_end = 6;
    let block_of_point: BTreeMap<u32, u32> =
        [(0, 0), (1, 0), (2, 1), (3, 1), (4, 2), (5, 3)]
            .iter().cloned().collect();
    let block_succs: BTreeMap<u32, Vec<u32>> =
        [(0, vec![1]), (1, vec![2, 3]), (2, vec![1]), (3, vec![])]
            .iter().cloned().collect();
    let true_def: BTreeMap<u32, u32> = [(1, 0), (2, 2)].iter().cloned().collect();
    let true_uses: BTreeMap<u32, Vec<u32>> =
        [(1, vec![2]), (2, vec![3, 5])].iter().cloned().collect();
    let empty_asm_bool: BTreeMap<u32, bool> = BTreeMap::new();
    let empty_asm_clb: BTreeMap<u32, Vec<u8>> = BTreeMap::new();
    let empty_irt: BTreeMap<u32, bool> = BTreeMap::new();
    let priority: BTreeMap<u32, u32> = [(1, 1), (2, 2)].iter().cloned().collect();

    emit_scenario_config(
        "loop_fixpoint",
        &vals, &points, &blocks, func_end,
        &block_of_point, &block_succs, &true_def, &true_uses,
        &[], &[], &empty_asm_bool, &empty_asm_clb,
        &[], &empty_irt,
        &[100, 104], &priority,
    );

    drive_pipeline(&func);
    tla_trace::close();
}

// ── Scenario 7: Phase 3 spillover — too many non-call-spanning values ────────
//
// With 6 caller-saved registers, define 8 i32 values whose live ranges do NOT
// span any call. Phase 2 fills 6 of them; the remaining 2 spill over into
// Phase 3 (callee-saved spillover), producing `Phase3Allocate` events.
#[test]
fn scenario_phase3_spillover() {
    let mut func = IrFunction::new("phase3_spillover".into(), IrType::I32, vec![], false);
    let mut instructions = Vec::new();
    // Define 8 values in block 0 by chaining binops; each uses the previous
    // so they're all live simultaneously near the return.
    instructions.push(Instruction::BinOp {
        dest: Value(1), op: IrBinOp::Add,
        lhs: Operand::Const(IrConst::I32(1)),
        rhs: Operand::Const(IrConst::I32(2)),
        ty: IrType::I32,
    });
    for i in 2u32..=8 {
        instructions.push(Instruction::BinOp {
            dest: Value(i), op: IrBinOp::Add,
            lhs: Operand::Const(IrConst::I32(i as i32)),
            rhs: Operand::Const(IrConst::I32(i as i32 + 10)),
            ty: IrType::I32,
        });
    }
    // Final value — sum of all, keeps the previous 8 live.
    let mut acc = Value(9);
    instructions.push(Instruction::BinOp {
        dest: acc, op: IrBinOp::Add,
        lhs: Operand::Value(Value(1)),
        rhs: Operand::Value(Value(2)),
        ty: IrType::I32,
    });
    for i in 3u32..=8 {
        let dest = Value(acc.0 + 1);
        instructions.push(Instruction::BinOp {
            dest, op: IrBinOp::Add,
            lhs: Operand::Value(acc),
            rhs: Operand::Value(Value(i)),
            ty: IrType::I32,
        });
        acc = dest;
    }
    func.blocks.push(BasicBlock {
        label: BlockId(0),
        instructions,
        terminator: Terminator::Return(Some(Operand::Value(acc))),
        source_spans: Vec::new(),
    });
    func.next_value_id = acc.0 + 1;

    let path = trace_path("phase3_spillover");
    tla_trace::open(path.to_str().unwrap());
    tla_trace::begin_function("phase3_spillover");

    // Points 0..7 define %1..%8; 8..13 fold them together; 14 block end.
    let final_v = acc.0;
    let num_points = final_v as u32; // Last instruction's point is final_v - 1.
    let vals: Vec<u32> = (1..=final_v).collect();
    let points: Vec<u32> = (0..=num_points).collect();
    let blocks = [0u32];
    let func_end = num_points + 1;
    let block_of_point: BTreeMap<u32, u32> = points.iter().map(|&p| (p, 0u32)).collect();
    let block_succs: BTreeMap<u32, Vec<u32>> = [(0, vec![])].iter().cloned().collect();
    let mut true_def: BTreeMap<u32, u32> = BTreeMap::new();
    for v in 1..=8u32 { true_def.insert(v, v - 1); }
    for v in 9..=final_v { true_def.insert(v, v - 1); }
    let mut true_uses: BTreeMap<u32, Vec<u32>> = BTreeMap::new();
    for v in 1..=8u32 {
        // each initial value used by the corresponding fold.
        true_uses.insert(v, vec![8 + (v - 1).max(1)]);
    }
    for v in 10..final_v {
        true_uses.insert(v, vec![v]);
    }
    true_uses.insert(final_v, vec![final_v]);
    let empty_asm_bool: BTreeMap<u32, bool> = BTreeMap::new();
    let empty_asm_clb: BTreeMap<u32, Vec<u8>> = BTreeMap::new();
    let empty_irt: BTreeMap<u32, bool> = BTreeMap::new();
    let priority: BTreeMap<u32, u32> = vals.iter().map(|&v| (v, 1u32)).collect();
    let slots: Vec<u32> = (0..vals.len() as u32).map(|i| 100 + 4 * i).collect();

    emit_scenario_config(
        "phase3_spillover",
        &vals, &points, &blocks, func_end,
        &block_of_point, &block_succs, &true_def, &true_uses,
        &[], &[], &empty_asm_bool, &empty_asm_clb,
        &[], &empty_irt,
        &slots, &priority,
    );

    drive_pipeline(&func);
    tla_trace::close();
}
