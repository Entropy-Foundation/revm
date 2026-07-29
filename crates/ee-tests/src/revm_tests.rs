//! Integration tests for the `revm` crate.

use crate::TestdataConfig;
use revm::{
    bytecode::opcode,
    context::{ContextTr, TxEnv},
    context_interface::{
        cfg::ExecutionMode,
        transaction::{Authorization, RecoveredAuthority, RecoveredAuthorization, TransactionType},
    },
    database::{BenchmarkDB, BENCH_CALLER, BENCH_TARGET},
    primitives::{address, b256, hardfork::SpecId, Bytes, TxKind, KECCAK_EMPTY, U256},
    state::{AccountStatus, Bytecode},
    Context, ExecuteEvm, MainBuilder, MainContext,
};
use std::path::PathBuf;

// Re-export the constant for testdata directory path
const TESTS_TESTDATA: &str = "tests/revm_testdata";

fn revm_testdata_config() -> TestdataConfig {
    TestdataConfig {
        testdata_dir: PathBuf::from(TESTS_TESTDATA),
    }
}

fn compare_or_save_revm_testdata<T>(filename: &str, output: &T)
where
    T: serde::Serialize + for<'a> serde::Deserialize<'a> + PartialEq + std::fmt::Debug,
{
    crate::compare_or_save_testdata_with_config(filename, output, revm_testdata_config());
}

const SELFDESTRUCT_BYTECODE: &[u8] = &[
    opcode::PUSH2,
    0xFF,
    0xFF,
    opcode::SELFDESTRUCT,
    opcode::STOP,
];

#[test]
fn test_selfdestruct_multi_tx() {
    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::BERLIN)
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new_legacy(
            SELFDESTRUCT_BYTECODE.into(),
        )))
        .build_mainnet();

    // trigger selfdestruct
    let result1 = evm
        .transact_one(TxEnv::builder_for_bench().build_fill())
        .unwrap();

    let destroyed_acc = evm.ctx.journal_mut().state.get_mut(&BENCH_TARGET).unwrap();

    // balance got transferred to 0x0000..00FFFF
    assert_eq!(destroyed_acc.info.balance, U256::ZERO);
    assert_eq!(destroyed_acc.info.nonce, 1);
    assert_eq!(
        destroyed_acc.info.code_hash,
        b256!("0x9125466aa9ef15459d85e7318f6d3bdc5f6978c0565bee37a8e768d7c202a67a")
    );

    // call on destroyed account. This accounts gets loaded and should contain empty code_hash afterwards.
    let result2 = evm
        .transact_one(TxEnv::builder_for_bench().nonce(1).build_fill())
        .unwrap();

    let destroyed_acc = evm.ctx.journal_mut().state.get_mut(&BENCH_TARGET).unwrap();

    assert_eq!(destroyed_acc.info.code_hash, KECCAK_EMPTY);
    assert_eq!(destroyed_acc.info.nonce, 0);
    assert_eq!(destroyed_acc.info.code, Some(Bytecode::default()));

    let output = evm.finalize();

    compare_or_save_revm_testdata(
        "test_selfdestruct_multi_tx.json",
        &(result1, result2, output),
    );
}

const STOP_BYTECODE: &[u8] = &[opcode::STOP];

/// Regression test for a bug where a later `ExecutionMode::ReadOnly` transaction's
/// `discard_tx()` could erase the `Touched` status a prior, already-committed transaction had
/// set on the same account (e.g. the caller of an automation-task predicate check that runs
/// after the same account's own ordinary transaction earlier in the block). Because
/// `Touched` is a sticky, block-scoped flag consumed by state-diff builders (e.g.
/// `CacheState::apply_account_state`) to decide whether an account appears in the persisted
/// output at all, incorrectly clearing it silently drops the prior transaction's committed
/// nonce/balance change from the output.
#[test]
fn test_read_only_discard_does_not_revert_prior_committed_tx() {
    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::CANCUN)
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new_legacy(
            STOP_BYTECODE.into(),
        )))
        .build_mainnet();

    // T1: an ordinary user transaction from BENCH_CALLER. Bumps its nonce, deducts gas from its
    // balance, and commits normally.
    let result1 = evm
        .transact_one(TxEnv::builder_for_bench().build_fill())
        .unwrap();
    assert!(result1.is_success());

    let caller_after_t1 = evm
        .ctx
        .journal_mut()
        .state
        .get(&BENCH_CALLER)
        .unwrap()
        .clone();
    assert!(caller_after_t1.is_touched());
    assert_eq!(caller_after_t1.info.nonce, 1);

    // T2: same caller, executed in ReadOnly mode (as an automation-task predicate check would
    // be). ReadOnly mode does not charge gas or bump the nonce, and this call performs no state
    // mutations, so it succeeds and its journal is discarded rather than erroring.
    evm.ctx
        .modify_cfg(|cfg| cfg.execution_mode = ExecutionMode::ReadOnly);
    let result2 = evm
        .transact_one(TxEnv::builder_for_bench().nonce(1).build_fill())
        .unwrap();
    assert!(result2.is_success());

    let caller_after_t2 = evm.ctx.journal_mut().state.get(&BENCH_CALLER).unwrap();

    // T2 must have been fully discarded: nonce/balance stay exactly as T1 committed them.
    assert_eq!(caller_after_t2.info.nonce, caller_after_t1.info.nonce);
    assert_eq!(caller_after_t2.info.balance, caller_after_t1.info.balance);

    // The critical assertion: T1's committed touch must survive T2's ReadOnly discard.
    assert!(
        caller_after_t2.is_touched(),
        "T1's committed AccountTouched status for the caller must survive a later ReadOnly \
         transaction's discard_tx(); otherwise state-diff builders skip the account entirely \
         and T1's committed nonce/balance change is lost"
    );

    // The account must still show up (with T1's values) once the batch is finalized.
    let output = evm.finalize();
    let caller_output = output.get(&BENCH_CALLER).unwrap();
    assert!(caller_output.is_touched());
    assert_eq!(caller_output.info.nonce, 1);
}

/// Regression test for the flip side of the above fix: an account whose *only* interaction in
/// a block is itself a discarded transaction (e.g. a `ReadOnly` predicate check on an account
/// that has not otherwise appeared in this block) must end up untouched, not spuriously touched.
#[test]
fn test_read_only_discard_of_first_touch_is_fully_undone() {
    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| {
            cfg.spec = SpecId::CANCUN;
            cfg.execution_mode = ExecutionMode::ReadOnly;
        })
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new_legacy(
            STOP_BYTECODE.into(),
        )))
        .build_mainnet();

    // BENCH_CALLER has never been touched before; this ReadOnly transaction is its first-ever
    // interaction this block, and it performs no mutations, so it is discarded.
    let result = evm
        .transact_one(TxEnv::builder_for_bench().build_fill())
        .unwrap();
    assert!(result.is_success());

    let caller_after = evm.ctx.journal_mut().state.get(&BENCH_CALLER).unwrap();
    assert!(
        !caller_after.is_touched(),
        "an account whose only interaction in the block was a discarded ReadOnly transaction \
         must end up untouched, not leak a spurious touch into the state diff"
    );
}

/// Regression test: `apply_eip7702_auth_list` mutates the authority account's
/// `info.code`/`info.code_hash`/`info.nonce` directly. In `ExecutionMode::ReadOnly`
/// (e.g. an automation-task predicate check), these mutations must be fully
/// journaled so that:
///   1. `has_state_mutations()` detects the attempt (rather than silently missing
///      it, since it only inspects journal entries), causing `transact_one` to
///      return an error instead of succeeding.
///   2. `discard_tx()` fully reverts the authority's code/nonce/touch, so nothing
///      leaks into subsequent transactions sharing this journal.
#[test]
fn test_read_only_eip7702_auth_list_is_fully_discarded() {
    let authority = address!("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    let delegate_to = address!("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| {
            cfg.spec = SpecId::PRAGUE;
            cfg.execution_mode = ExecutionMode::ReadOnly;
        })
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new_legacy(
            STOP_BYTECODE.into(),
        )))
        .build_mainnet();

    let auth = RecoveredAuthorization::new_unchecked(
        Authorization {
            // Zero chain_id is always accepted, regardless of the context's actual chain id.
            chain_id: U256::ZERO,
            address: delegate_to,
            nonce: 0,
        },
        RecoveredAuthority::Valid(authority),
    );

    let tx = TxEnv::builder_for_bench()
        .tx_type(Some(TransactionType::Eip7702 as u8))
        .authorization_list_recovered(vec![auth])
        .build_fill();

    // Applying the authorization list mutates the authority's code/nonce - this
    // must be detected as a ReadOnly state-mutation attempt, not allowed to
    // silently succeed.
    let err = evm.transact_one(tx).unwrap_err();
    assert!(
        err.to_string().contains("attempted state mutation"),
        "expected a ReadOnly state-mutation error, got: {err}"
    );

    // And the authority account must show no trace of the attempted delegation:
    // discard_tx() must have fully reverted the code/nonce/touch mutations that
    // apply_eip7702_auth_list made before last_frame_result detected them.
    if let Some(authority_after) = evm.ctx.journal_mut().state.get(&authority) {
        assert_eq!(authority_after.info.nonce, 0, "nonce bump must be reverted");
        assert_eq!(
            authority_after.info.code_hash, KECCAK_EMPTY,
            "code delegation must be reverted"
        );
        assert!(
            !authority_after.is_touched(),
            "the authority's touch must not leak from a discarded ReadOnly transaction"
        );
    }
}

/// Tests multiple transactions with contract creation.
/// Verifies that created contracts persist correctly across transactions
/// and that their state is properly maintained.
#[test]
fn test_multi_tx_create() {
    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| {
            cfg.spec = SpecId::BERLIN;
            cfg.disable_nonce_check = true;
        })
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new()))
        .build_mainnet();

    let result1 = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .kind(TxKind::Create)
                .data(deployment_contract(SELFDESTRUCT_BYTECODE))
                .build_fill(),
        )
        .unwrap();

    let created_address = result1.created_address().unwrap();

    let created_acc = evm
        .ctx
        .journal_mut()
        .state
        .get_mut(&created_address)
        .unwrap();

    assert_eq!(
        created_acc.status,
        AccountStatus::Created
            | AccountStatus::CreatedLocal
            | AccountStatus::Touched
            | AccountStatus::LoadedAsNotExisting
    );

    let result2 = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .nonce(1)
                .kind(TxKind::Call(created_address))
                .build_fill(),
        )
        .unwrap();

    let created_acc = evm
        .ctx
        .journal_mut()
        .state
        .get_mut(&created_address)
        .unwrap();

    // reset nonce to trigger create on same address.
    assert_eq!(
        created_acc.status,
        AccountStatus::Created
            | AccountStatus::SelfDestructed
            | AccountStatus::SelfDestructedLocal
            | AccountStatus::Touched
            | AccountStatus::LoadedAsNotExisting
    );

    // reset caller nonce
    evm.ctx
        .journal_mut()
        .state
        .get_mut(&BENCH_CALLER)
        .unwrap()
        .info
        .nonce = 0;

    // re create the contract.
    let result3 = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .nonce(0)
                .kind(TxKind::Create)
                .data(deployment_contract(SELFDESTRUCT_BYTECODE))
                .build_fill(),
        )
        .unwrap();

    let created_address_new = result3.created_address().unwrap();
    assert_eq!(created_address, created_address_new);

    let created_acc = evm
        .ctx
        .journal_mut()
        .state
        .get_mut(&created_address)
        .unwrap();

    // T3 recreated the contract at the same address without destroying it again,
    // so the stale `SelfDestructed` flag from T2's destruction must be cleared -
    // see the EIP-6780 recreate-after-selfdestruct fix.
    assert_eq!(
        created_acc.status,
        AccountStatus::Created
            | AccountStatus::CreatedLocal
            | AccountStatus::Touched
            | AccountStatus::LoadedAsNotExisting
    );
    let output = evm.finalize();

    compare_or_save_revm_testdata(
        "test_multi_tx_create.json",
        &(result1, result2, result3, output),
    );
}

/// Creates deployment bytecode for a contract.
/// Prepends the initialization code that will deploy the provided runtime bytecode.
fn deployment_contract(bytes: &[u8]) -> Bytes {
    assert!(bytes.len() < 256);
    let len = bytes.len();
    let ret = &[
        opcode::PUSH1,
        len as u8,
        opcode::PUSH1,
        12,
        opcode::PUSH1,
        0,
        // Copy code to memory.
        opcode::CODECOPY,
        opcode::PUSH1,
        len as u8,
        opcode::PUSH1,
        0,
        // Return copied code.
        opcode::RETURN,
    ];

    [ret, bytes].concat().into()
}

#[test]
fn test_frame_stack_index() {
    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::BERLIN)
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new_legacy(
            SELFDESTRUCT_BYTECODE.into(),
        )))
        .build_mainnet();

    // transfer to other account
    let result1 = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .to(address!("0xc000000000000000000000000000000000000000"))
                .build_fill(),
        )
        .unwrap();

    assert_eq!(evm.frame_stack.index(), None);
    compare_or_save_revm_testdata("test_frame_stack_index.json", &result1);
}

#[test]
#[cfg(feature = "optional_balance_check")]
fn test_disable_balance_check() {
    use revm::database::BENCH_CALLER_BALANCE;
    const RETURN_CALLER_BALANCE_BYTECODE: &[u8] = &[
        opcode::CALLER,
        opcode::BALANCE,
        opcode::PUSH1,
        0x00,
        opcode::MSTORE,
        opcode::PUSH1,
        0x20,
        opcode::PUSH1,
        0x00,
        opcode::RETURN,
    ];

    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.disable_balance_check = true)
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new_legacy(
            RETURN_CALLER_BALANCE_BYTECODE.into(),
        )))
        .build_mainnet();

    // Construct tx so that effective cost is more than caller balance.
    let gas_price = 1;
    let gas_limit = 100_000;
    // Make sure value doesn't consume all balance since we want to validate that all effective
    // cost is deducted.
    let tx_value = BENCH_CALLER_BALANCE - U256::from(1);

    let result = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .gas_price(gas_price)
                .gas_limit(gas_limit)
                .value(tx_value)
                .build_fill(),
        )
        .unwrap();

    assert!(result.is_success());

    let returned_balance = U256::from_be_slice(result.output().unwrap().as_ref());
    let expected_balance = U256::ZERO;
    assert_eq!(returned_balance, expected_balance);
}
