//! Trace scenarios for mem2reg validation.
//!
//! Each test builds an IrFunction matching one of the spec fixtures
//! (DefaultUseSites etc.) and runs `promote_allocas` + `eliminate_phis`
//! with trace emission enabled. The resulting NDJSON file is consumed
//! by Trace.tla.

#![cfg(test)]

use crate::common::types::AddressSpace;
use crate::ir::mem2reg::{promote_allocas, eliminate_phis};
use crate::ir::mem2reg::tla_trace;
use crate::ir::reexports::{
    BasicBlock, BlockId, Instruction, IrConst, IrFunction, IrModule, Operand,
    Terminator, Value,
};
use crate::common::types::IrType;

fn trace_path(name: &str) -> Option<String> {
    if let Ok(dir) = std::env::var("CCC_TRACE_DIR") {
        Some(format!("{}/{}.ndjson", dir, name))
    } else {
        None
    }
}

/// Build the diamond fixture matching `DefaultUseSites` from MC.tla:
///   block 0 (entry): alloca, STORE_PTR a1, CondBranch -> b1 / b2
///   block 1: STORE_PTR a1 -> Branch b3
///   block 2: STORE_PTR a1 -> Branch b3
///   block 3: LOAD a1 -> Return
fn build_diamond() -> IrModule {
    let mut func = IrFunction::new("diamond".to_string(), IrType::I32, vec![], false);

    // Block 0 (entry): alloca, store, cond branch
    func.blocks.push(BasicBlock {
        label: BlockId(0),
        instructions: vec![
            Instruction::Alloca {
                dest: Value(0),
                ty: IrType::I32,
                size: 4,
                align: 4,
                volatile: false,
            },
            Instruction::Store {
                val: Operand::Const(IrConst::I32(10)),
                ptr: Value(0),
                ty: IrType::I32,
                seg_override: AddressSpace::Default,
            },
        ],
        terminator: Terminator::CondBranch {
            cond: Operand::Const(IrConst::I32(1)),
            true_label: BlockId(1),
            false_label: BlockId(2),
        },
        source_spans: Vec::new(),
    });

    // Block 1: store, branch
    func.blocks.push(BasicBlock {
        label: BlockId(1),
        instructions: vec![Instruction::Store {
            val: Operand::Const(IrConst::I32(20)),
            ptr: Value(0),
            ty: IrType::I32,
            seg_override: AddressSpace::Default,
        }],
        terminator: Terminator::Branch(BlockId(3)),
        source_spans: Vec::new(),
    });

    // Block 2: store, branch
    func.blocks.push(BasicBlock {
        label: BlockId(2),
        instructions: vec![Instruction::Store {
            val: Operand::Const(IrConst::I32(30)),
            ptr: Value(0),
            ty: IrType::I32,
            seg_override: AddressSpace::Default,
        }],
        terminator: Terminator::Branch(BlockId(3)),
        source_spans: Vec::new(),
    });

    // Block 3: load, return
    func.blocks.push(BasicBlock {
        label: BlockId(3),
        instructions: vec![Instruction::Load {
            dest: Value(1),
            ptr: Value(0),
            ty: IrType::I32,
            seg_override: AddressSpace::Default,
        }],
        terminator: Terminator::Return(Some(Operand::Value(Value(1)))),
        source_spans: Vec::new(),
    });
    func.next_value_id = 2;

    let mut module = IrModule::new();
    module.functions.push(func);
    module
}

/// Run mem2reg + phi elim with tracing enabled to a per-scenario file.
fn run_traced<F: FnOnce() -> IrModule>(scenario_name: &str, build: F) {
    let path = match trace_path(scenario_name) {
        Some(p) => p,
        None => {
            // No trace directory configured — just run without tracing.
            let mut m = build();
            promote_allocas(&mut m);
            eliminate_phis(&mut m);
            return;
        }
    };

    tla_trace::init(&path);
    let mut module = build();
    promote_allocas(&mut module);
    eliminate_phis(&mut module);
    tla_trace::shutdown();
}

#[test]
fn trace_diamond() {
    run_traced("diamond", build_diamond);
}
