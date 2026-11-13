//! Integration tests for the `revm` crate.

use revm::{
    bytecode::opcode,
    context::{CfgEnv, ContextTr, TxEnv},
    context_interface::{
        cfg::ExecutionMode,
        transaction::{Authorization, RecoveredAuthority, RecoveredAuthorization, TransactionType},
    },
    database::{BenchmarkDB, BENCH_CALLER, BENCH_TARGET},
    primitives::{address, b256, hardfork::SpecId, Bytes, TxKind, KECCAK_EMPTY, U256},
    state::{AccountStatus, Bytecode},
    Context, ExecuteCommitEvm, ExecuteEvm, MainBuilder, MainContext,
};

const SELFDESTRUCT_BYTECODE: &[u8] = &[
    opcode::PUSH2,
    0xFF,
    0xFF,
    opcode::SELFDESTRUCT,
    opcode::STOP,
];

#[test]
#[cfg(feature = "account-ext")]
fn extension_only_changes_are_persisted_and_reverted() {
    use revm::{
        database::{
            states::TransitionAccount, AccountStatus, BundleAccount, BundleState,
            OriginalValuesKnown,
        },
        state::{AccountExtension, AccountInfo},
    };

    let original = AccountInfo::from_balance(U256::from(1))
        .with_extension(AccountExtension::copy_from_slice(&[1; 32]));
    let present = original
        .clone()
        .with_extension(AccountExtension::copy_from_slice(&[2; 32]));
    let mut account = BundleAccount::new(
        Some(original.clone()),
        Some(original.clone()),
        Default::default(),
        AccountStatus::Loaded,
    );
    let revert = account
        .update_and_create_revert(TransitionAccount {
            info: Some(present.clone()),
            status: AccountStatus::Changed,
            previous_info: Some(original.clone()),
            previous_status: AccountStatus::Loaded,
            ..Default::default()
        })
        .expect("an extension-only change needs account revert data");
    assert!(account.is_info_changed());

    let mut bundle = BundleState::default();
    bundle.state.insert(BENCH_TARGET, account.clone());
    let changes = bundle.to_plain_state(OriginalValuesKnown::Yes);
    assert_eq!(changes.accounts.len(), 1);
    assert_eq!(
        changes.accounts[0].1.as_ref().unwrap().extension,
        present.extension
    );

    account.revert(revert);
    assert_eq!(account.info.as_ref().unwrap().extension, original.extension);
    assert!(!account.is_info_changed());
}

#[test]
fn test_selfdestruct_multi_tx() {
    let mut evm = Context::mainnet()
        .with_cfg(CfgEnv::new_with_spec(SpecId::BERLIN))
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

    crate::assert_sorted_json_snapshot!(&(result1, result2, output));
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

/// Regression test: `JournalEntry::CodeChange`'s revert previously always
/// reset the account to `code_hash = KECCAK_EMPTY, code = None` - correct
/// for CREATE (whose collision check requires the target to already be
/// empty), but wrong for EIP-7702: step 5 of the spec explicitly permits
/// re-delegating an authority that already holds a delegation, so the
/// "previous" code being reverted-to is not necessarily empty.
///
/// T1 (committed) delegates `authority` to X. T2 (`ReadOnly`) attempts to
/// re-delegate the *same* authority to Y, correctly errors as a state
/// mutation attempt, and gets discarded. T1's delegation to X must survive
/// - not be wiped to empty by T2's reverted `CodeChange` entry.
#[test]
fn test_read_only_eip7702_redelegate_restores_prior_delegation_on_discard() {
    let authority = address!("0xcccccccccccccccccccccccccccccccccccccccc");
    let delegate_to_x = address!("0xdddddddddddddddddddddddddddddddddddddddd");
    let delegate_to_y = address!("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");

    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::PRAGUE)
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new_legacy(
            STOP_BYTECODE.into(),
        )))
        .build_mainnet();

    // T1 (normal, committed): delegate `authority` to X.
    let auth1 = RecoveredAuthorization::new_unchecked(
        Authorization {
            chain_id: U256::ZERO,
            address: delegate_to_x,
            nonce: 0,
        },
        RecoveredAuthority::Valid(authority),
    );
    let tx1 = TxEnv::builder_for_bench()
        .tx_type(Some(TransactionType::Eip7702 as u8))
        .authorization_list_recovered(vec![auth1])
        .build_fill();

    let result1 = evm.transact_one(tx1).unwrap();
    assert!(result1.is_success());

    let authority_after_t1 = evm.ctx.journal_mut().state.get(&authority).unwrap().clone();
    assert_eq!(
        authority_after_t1.info.nonce, 1,
        "sanity: T1's delegation bumped the authority's nonce"
    );
    assert_ne!(
        authority_after_t1.info.code_hash, KECCAK_EMPTY,
        "sanity: T1's delegation to X must be committed before T2 runs"
    );

    // T2 (ReadOnly): attempt to re-delegate the SAME authority to Y.
    evm.ctx
        .modify_cfg(|cfg| cfg.execution_mode = ExecutionMode::ReadOnly);

    let auth2 = RecoveredAuthorization::new_unchecked(
        Authorization {
            chain_id: U256::ZERO,
            address: delegate_to_y,
            nonce: 1,
        },
        RecoveredAuthority::Valid(authority),
    );
    let tx2 = TxEnv::builder_for_bench()
        .nonce(1)
        .tx_type(Some(TransactionType::Eip7702 as u8))
        .authorization_list_recovered(vec![auth2])
        .build_fill();

    let err = evm.transact_one(tx2).unwrap_err();
    assert!(
        err.to_string().contains("attempted state mutation"),
        "expected a ReadOnly state-mutation error, got: {err}"
    );

    // T1's committed delegation to X must survive T2's discarded
    // re-delegation attempt - not be wiped to empty.
    let authority_after_t2 = evm.ctx.journal_mut().state.get(&authority).unwrap();
    assert_eq!(
        authority_after_t2.info.nonce, 1,
        "T2's nonce bump must be reverted, leaving T1's committed nonce"
    );
    assert_eq!(
        authority_after_t2.info.code_hash, authority_after_t1.info.code_hash,
        "T1's committed delegation to X must be restored, not wiped to empty"
    );
    assert_eq!(
        authority_after_t2.info.code, authority_after_t1.info.code,
        "T1's committed delegation bytecode must be restored"
    );
}

/// Tests multiple transactions with contract creation.
/// Verifies that created contracts persist correctly across transactions
/// and that their state is properly maintained.
#[test]
fn test_multi_tx_create() {
    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| {
            cfg.set_spec_and_mainnet_gas_params(SpecId::BERLIN);
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

    crate::assert_sorted_json_snapshot!(&(result1, result2, result3, output));
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
        .with_cfg(CfgEnv::new_with_spec(SpecId::BERLIN))
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
    crate::assert_sorted_json_snapshot!(&result1);
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

// ============================================================================
// EIP-7708: ETH transfers emit a log
// ============================================================================

use revm::primitives::eip7708::{BURN_LOG_TOPIC, ETH_TRANSFER_LOG_ADDRESS, ETH_TRANSFER_LOG_TOPIC};
use revm::primitives::B256;

/// Test EIP-7708 transfer log emission for transaction value transfer
#[test]
fn test_eip7708_transfer_log_tx_value() {
    let recipient = address!("0xc000000000000000000000000000000000000001");

    let mut evm = Context::mainnet()
        .with_cfg(CfgEnv::new_with_spec(SpecId::AMSTERDAM))
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new()))
        .build_mainnet();

    let tx_value = U256::from(1_000_000_000_000_000u128); // 0.001 ETH (within balance)

    // ETH transfer creating new account costs ~205k gas under EIP-2780
    // (TX_BASE_COST + COLD_ACCOUNT_ACCESS + TX_VALUE_COST
    //  + STATE_BYTES_PER_NEW_ACCOUNT × CPSB at top-level execution).
    let result = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .to(recipient)
                .value(tx_value)
                .gas_limit(300_000)
                .gas_price(0) // Zero gas price to avoid balance issues
                .build_fill(),
        )
        .unwrap();

    assert!(result.is_success());

    // Verify that a transfer log was emitted
    let logs = result.logs();
    assert_eq!(logs.len(), 1, "Expected 1 transfer log");

    let log = &logs[0];
    assert_eq!(log.address, ETH_TRANSFER_LOG_ADDRESS);
    assert_eq!(log.data.topics().len(), 3);
    assert_eq!(log.data.topics()[0], ETH_TRANSFER_LOG_TOPIC);
    assert_eq!(
        log.data.topics()[1],
        B256::left_padding_from(BENCH_CALLER.as_slice())
    );
    assert_eq!(
        log.data.topics()[2],
        B256::left_padding_from(recipient.as_slice())
    );
    assert_eq!(log.data.data.as_ref(), &tx_value.to_be_bytes::<32>());
}

/// Test that no transfer log is emitted for zero value transfer
#[test]
fn test_eip7708_no_log_for_zero_value() {
    let recipient = address!("0xc000000000000000000000000000000000000001");

    let mut evm = Context::mainnet()
        .with_cfg(CfgEnv::new_with_spec(SpecId::AMSTERDAM))
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new()))
        .build_mainnet();

    let result = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .to(recipient)
                .value(U256::ZERO)
                .gas_limit(100_000)
                .gas_price(0)
                .build_fill(),
        )
        .unwrap();

    assert!(result.is_success());

    // No logs should be emitted for zero value transfer
    let logs = result.logs();
    assert_eq!(logs.len(), 0, "Expected no logs for zero value transfer");
}

/// Test that no transfer log is emitted before AMSTERDAM
#[test]
fn test_eip7708_no_log_before_amsterdam() {
    let recipient = address!("0xc000000000000000000000000000000000000001");

    let mut evm = Context::mainnet()
        .with_cfg(CfgEnv::new_with_spec(SpecId::OSAKA)) // Before AMSTERDAM
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new()))
        .build_mainnet();

    let tx_value = U256::from(1_000_000_000_000_000u128); // 0.001 ETH (within balance)

    let result = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .to(recipient)
                .value(tx_value)
                .gas_limit(100_000)
                .gas_price(0)
                .build_fill(),
        )
        .unwrap();

    assert!(result.is_success());

    // No logs should be emitted before AMSTERDAM
    let logs = result.logs();
    assert_eq!(logs.len(), 0, "Expected no logs before AMSTERDAM");
}

/// Bytecode that selfdestructs to the caller (different address)
const SELFDESTRUCT_TO_CALLER_BYTECODE: &[u8] = &[
    opcode::CALLER, // Push caller address
    opcode::SELFDESTRUCT,
    opcode::STOP,
];

/// Test EIP-7708 transfer log emission for selfdestruct to different address
#[test]
fn test_eip7708_selfdestruct_to_different_address() {
    let mut evm = Context::mainnet()
        .with_cfg(CfgEnv::new_with_spec(SpecId::AMSTERDAM))
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new_legacy(
            SELFDESTRUCT_TO_CALLER_BYTECODE.into(),
        )))
        .build_mainnet();

    // Execute selfdestruct - the contract at BENCH_TARGET will selfdestruct to BENCH_CALLER
    // After Cancun (and Amsterdam), SELFDESTRUCT only destroys if created in same tx,
    // but it still transfers balance, so we should see a transfer log.
    let result = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .gas_limit(100_000)
                .gas_price(0)
                .build_fill(),
        )
        .unwrap();

    assert!(result.is_success());

    // There should be two logs:
    // 1. Transfer log for initial tx value transfer from BENCH_CALLER to BENCH_TARGET
    // 2. Transfer log for selfdestruct balance transfer from BENCH_TARGET to BENCH_CALLER
    let logs = result.logs();

    // Find the selfdestruct transfer log (from BENCH_TARGET to BENCH_CALLER)
    let selfdestruct_log = logs.iter().find(|log| {
        log.data.topics().len() == 3
            && log.data.topics()[0] == ETH_TRANSFER_LOG_TOPIC
            && log.data.topics()[1] == B256::left_padding_from(BENCH_TARGET.as_slice())
    });

    assert!(
        selfdestruct_log.is_some(),
        "Expected selfdestruct transfer log"
    );
    let log = selfdestruct_log.unwrap();
    assert_eq!(log.address, ETH_TRANSFER_LOG_ADDRESS);
    assert_eq!(
        log.data.topics()[2],
        B256::left_padding_from(BENCH_CALLER.as_slice())
    );
}

/// Init code that selfdestructs to itself during construction
/// This triggers the selfdestruct-to-self scenario where a newly created
/// contract (is_created_locally = true) selfdestructs to itself.
const SELFDESTRUCT_TO_SELF_INIT_CODE: &[u8] = &[
    opcode::ADDRESS, // Push contract's own address
    opcode::SELFDESTRUCT,
];

/// Test EIP-8246 selfdestruct-to-self balance preservation.
/// This test creates a contract with value that selfdestructs to itself during construction.
/// Before EIP-8246 this burned the balance and emitted a `Burn` log; with EIP-8246 the balance
/// is preserved and the account is kept with cleared code, storage and nonce.
#[test]
fn test_eip8246_selfdestruct_to_self_preserves_balance() {
    let mut evm = Context::mainnet()
        .with_cfg(CfgEnv::new_with_spec(SpecId::AMSTERDAM))
        .modify_block_chained(|block| block.gas_limit = 100_000_000)
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new()))
        .build_mainnet();

    let create_value = U256::from(1_000_000u128); // 1M wei

    // Create a contract with value that selfdestructs to itself during init
    let result = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .kind(TxKind::Create)
                .data(SELFDESTRUCT_TO_SELF_INIT_CODE.into())
                .value(create_value)
                .gas_limit(500_000)
                .gas_price(0)
                .build_fill(),
        )
        .unwrap();

    assert!(result.is_success(), "Transaction should succeed");

    // EIP-8246: self-destruct to self no longer burns the balance, so no `Burn` log is emitted.
    let logs = result.logs();
    let burn_log = logs
        .iter()
        .find(|log| log.data.topics().len() == 2 && log.data.topics()[0] == BURN_LOG_TOPIC);
    assert!(
        burn_log.is_none(),
        "Expected no burn log, got logs: {logs:?}"
    );

    // The created account keeps its balance, while its code, storage and nonce are cleared
    // and it is no longer marked self-destructed.
    let created_address = result.created_address().unwrap();
    let account = evm
        .ctx
        .journal_mut()
        .state
        .get(&created_address)
        .expect("self-destructed account should be preserved");
    assert_eq!(account.info.balance, create_value);
    assert_eq!(account.info.nonce, 0);
    assert_eq!(account.info.code_hash, KECCAK_EMPTY);
    assert!(!account.is_selfdestructed());
}

/// Bytecode that performs a CALL with value to a specific address
#[expect(clippy::vec_init_then_push)]
fn call_with_value_bytecode(target: [u8; 20], value: U256) -> Bytecode {
    // CALL(gas, addr, value, argsOffset, argsSize, retOffset, retSize)
    let mut bytecode = Vec::new();

    // Push return size (0)
    bytecode.push(opcode::PUSH1);
    bytecode.push(0);

    // Push return offset (0)
    bytecode.push(opcode::PUSH1);
    bytecode.push(0);

    // Push args size (0)
    bytecode.push(opcode::PUSH1);
    bytecode.push(0);

    // Push args offset (0)
    bytecode.push(opcode::PUSH1);
    bytecode.push(0);

    // Push value (32 bytes)
    let value_bytes = value.to_be_bytes::<32>();
    bytecode.push(opcode::PUSH32);
    bytecode.extend_from_slice(&value_bytes);

    // Push target address (20 bytes)
    bytecode.push(opcode::PUSH20);
    bytecode.extend_from_slice(&target);

    // Push gas (use all remaining gas)
    bytecode.push(opcode::GAS);

    // Execute CALL
    bytecode.push(opcode::CALL);

    // Clean up stack
    bytecode.push(opcode::POP);

    // Stop
    bytecode.push(opcode::STOP);

    Bytecode::new_legacy(bytecode.into())
}

/// Test EIP-7708 transfer log emission for CALL with value
#[test]
fn test_eip7708_call_with_value() {
    let call_target = address!("0xd000000000000000000000000000000000000001");
    let call_value = U256::from(1_000_000u128); // Small value (1M wei)

    let bytecode = call_with_value_bytecode(call_target.into_array(), call_value);

    let mut evm = Context::mainnet()
        .with_cfg(CfgEnv::new_with_spec(SpecId::AMSTERDAM))
        .modify_block_chained(|block| block.gas_limit = 100_000_000)
        .with_db(BenchmarkDB::new_bytecode(bytecode))
        .build_mainnet();

    let result = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .gas_limit(500_000)
                .gas_price(0)
                .build_fill(),
        )
        .unwrap();

    assert!(result.is_success(), "Transaction should succeed");

    // There should be transfer logs:
    // Transfer from BENCH_TARGET to call_target (CALL value transfer)
    let logs = result.logs();

    // Find the CALL transfer log (from BENCH_TARGET to call_target)
    let call_log = logs.iter().find(|log| {
        log.data.topics().len() == 3
            && log.data.topics()[0] == ETH_TRANSFER_LOG_TOPIC
            && log.data.topics()[1] == B256::left_padding_from(BENCH_TARGET.as_slice())
            && log.data.topics()[2] == B256::left_padding_from(call_target.as_slice())
    });

    assert!(
        call_log.is_some(),
        "Expected CALL transfer log, got logs: {:?}",
        logs
    );
    let log = call_log.unwrap();
    assert_eq!(log.address, ETH_TRANSFER_LOG_ADDRESS);
    assert_eq!(log.data.data.as_ref(), &call_value.to_be_bytes::<32>());
}

/// Bytecode that creates a contract with initial value
fn create_with_value_bytecode(init_code: &[u8], value: U256) -> Bytecode {
    // CREATE(value, offset, length)
    let mut bytecode = Vec::new();

    // First, store init_code in memory
    // PUSH init_code bytes
    for (i, byte) in init_code.iter().enumerate() {
        bytecode.push(opcode::PUSH1);
        bytecode.push(*byte);
        bytecode.push(opcode::PUSH1);
        bytecode.push(i as u8);
        bytecode.push(opcode::MSTORE8);
    }

    // Push length
    bytecode.push(opcode::PUSH1);
    bytecode.push(init_code.len() as u8);

    // Push offset (0)
    bytecode.push(opcode::PUSH1);
    bytecode.push(0);

    // Push value (32 bytes)
    let value_bytes = value.to_be_bytes::<32>();
    bytecode.push(opcode::PUSH32);
    bytecode.extend_from_slice(&value_bytes);

    // Execute CREATE
    bytecode.push(opcode::CREATE);

    // Clean up stack
    bytecode.push(opcode::POP);

    // Stop
    bytecode.push(opcode::STOP);

    Bytecode::new_legacy(bytecode.into())
}

/// Simple init code that just returns nothing (creates empty contract)
const SIMPLE_INIT_CODE: &[u8] = &[
    opcode::PUSH1,
    0, // length
    opcode::PUSH1,
    0, // offset
    opcode::RETURN,
];

/// Test EIP-7708 transfer log emission for CREATE with value
#[test]
fn test_eip7708_create_with_value() {
    let create_value = U256::from(1_000_000u128); // Small value (1M wei)

    let bytecode = create_with_value_bytecode(SIMPLE_INIT_CODE, create_value);

    let mut evm = Context::mainnet()
        .with_cfg(CfgEnv::new_with_spec(SpecId::AMSTERDAM))
        .modify_block_chained(|block| block.gas_limit = 100_000_000)
        .with_db(BenchmarkDB::new_bytecode(bytecode))
        .build_mainnet();

    let result = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .gas_limit(500_000)
                .gas_price(0)
                .build_fill(),
        )
        .unwrap();

    assert!(result.is_success(), "Transaction should succeed");

    // There should be transfer logs:
    // Transfer from BENCH_TARGET to created address (CREATE value transfer)
    let logs = result.logs();

    // Find the CREATE transfer log (from BENCH_TARGET to some address)
    let create_log = logs.iter().find(|log| {
        log.data.topics().len() == 3
            && log.data.topics()[0] == ETH_TRANSFER_LOG_TOPIC
            && log.data.topics()[1] == B256::left_padding_from(BENCH_TARGET.as_slice())
            && log.data.topics()[2] != B256::left_padding_from(BENCH_CALLER.as_slice())
    });

    assert!(
        create_log.is_some(),
        "Expected CREATE transfer log, got logs: {:?}",
        logs
    );
    let log = create_log.unwrap();
    assert_eq!(log.address, ETH_TRANSFER_LOG_ADDRESS);
    assert_eq!(log.data.data.as_ref(), &create_value.to_be_bytes::<32>());
}

/// Test that demonstrates using the full EVM API with a custom opcode.
///
/// Deploys a contract with a custom opcode (0x0C) that doubles the top stack value,
/// then calls the contract and verifies the result via SSTORE + state inspection.
#[test]
fn test_custom_opcode_transaction() {
    use revm::{
        context::Evm,
        database::InMemoryDB,
        handler::{instructions::EthInstructions, EthPrecompiles},
        interpreter::{interpreter::EthInterpreter, Instruction, InstructionContext},
        state::AccountInfo,
    };

    // Custom opcode 0x0C: pops top value, pushes it doubled.
    const DOUBLE: u8 = 0x0C;

    // Runtime bytecode:
    //   PUSH1 0x07      ; push value 7
    //   DOUBLE (0x0C)   ; custom opcode: doubles top -> 14
    //   PUSH0           ; storage slot 0
    //   SSTORE          ; store result at slot 0
    //   STOP
    let runtime_bytecode: Bytes = [
        opcode::PUSH1,
        0x07,
        DOUBLE,
        opcode::PUSH0,
        opcode::SSTORE,
        opcode::STOP,
    ]
    .into();

    let deploy_bytecode = deployment_contract(&runtime_bytecode);

    let caller = address!("0x1000000000000000000000000000000000000001");

    // Setup in-memory database with funded caller
    let mut db = InMemoryDB::default();
    db.insert_account_info(
        caller,
        AccountInfo {
            balance: U256::from(1_000_000_000_000_000_000u128),
            ..Default::default()
        },
    );

    // Build EVM with custom instruction set
    let ctx = Context::mainnet()
        .with_cfg(CfgEnv::new_with_spec(SpecId::CANCUN))
        .with_db(db);

    let mut instructions = EthInstructions::new_mainnet_with_spec(SpecId::CANCUN);
    instructions.insert_instruction(
        DOUBLE,
        Instruction::new(|ctx: InstructionContext<'_, _, EthInterpreter>| {
            revm::interpreter::popn_top!([], val, ctx.interpreter);
            *val = val.wrapping_mul(U256::from(2));
            Ok(())
        }),
        3, // static gas cost (same as ADD)
    );

    let mut evm = Evm::new(ctx, instructions, EthPrecompiles::new(SpecId::CANCUN));

    // Step 1: Deploy the contract (commit state so nonce and contract persist)
    let deploy_result = evm
        .transact_commit(
            TxEnv::builder()
                .caller(caller)
                .kind(TxKind::Create)
                .data(deploy_bytecode)
                .gas_limit(1_000_000)
                .build()
                .unwrap(),
        )
        .unwrap();

    assert!(
        deploy_result.is_success(),
        "deploy should succeed: {deploy_result:?}"
    );
    let contract_address = deploy_result
        .created_address()
        .expect("contract should be created");

    // Step 2: Call the deployed contract (triggers PUSH1 7 -> DOUBLE -> SSTORE)
    let call_result = evm
        .transact(
            TxEnv::builder()
                .caller(caller)
                .kind(TxKind::Call(contract_address))
                .gas_limit(1_000_000)
                .nonce(1)
                .build()
                .unwrap(),
        )
        .unwrap();

    assert!(
        call_result.result.is_success(),
        "call should succeed: {call_result:?}"
    );

    // Verify: storage slot 0 should contain 14 (7 * 2)
    let contract_state = call_result
        .state
        .get(&contract_address)
        .expect("contract should be in state");
    let slot0 = contract_state
        .storage
        .get::<U256>(&U256::ZERO)
        .expect("slot 0 should be written");
    assert_eq!(
        slot0.present_value(),
        U256::from(14),
        "DOUBLE(7) should store 14 in slot 0"
/// Funds `addr` with a large balance in a fresh `CacheDB`.
fn funded_cache_db(
    addr: revm::primitives::Address,
) -> revm::database::CacheDB<revm::database::EmptyDB> {
    use revm::database::{CacheDB, EmptyDB};
    use revm::state::AccountInfo;

    let mut db = CacheDB::new(EmptyDB::new());
    db.insert_account_info(
        addr,
        AccountInfo {
            balance: U256::from(10_000_000_000_000_000_000u128),
            ..Default::default()
        },
    );
    db
}

/// T1(create->destroy) -> T2(call the destroyed contract), single shared journal
/// (`transact_one` twice on the same `Evm`, i.e. revm's single-journal, multi-tx
/// execution mode). T1's init code is `PUSH2 0xFFFF; SELFDESTRUCT; STOP` - the
/// contract destroys itself in its own constructor, so it is fully deleted per
/// EIP-6780 (same-tx create+destroy) without ever having runtime code. T2 then
/// calls that address as if invoking a function on it.
///
/// Also asserts the account's *internal bookkeeping* (`AccountStatus`) ends up
/// identical to the standalone-journal version of the same scenario below -
/// see the fix in `load_account_optional`'s lazy cold-load wipe, which now
/// clears the global `Created` flag alongside `SelfDestructed` so a
/// shared-journal execution doesn't retain a stale flag that a fresh,
/// finalize-per-tx session would never have set in the first place.
#[test]
fn test_call_after_create_destroy_single_journal() {
    let db = funded_cache_db(BENCH_CALLER);

    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::CANCUN)
        .with_db(db)
        .build_mainnet();

    let result1 = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .kind(TxKind::Create)
                .data(Bytes::copy_from_slice(SELFDESTRUCT_BYTECODE))
                .build_fill(),
        )
        .unwrap();
    assert!(result1.is_success());
    let created_address = result1.created_address().unwrap();

    // Sanity: the constructor genuinely selfdestructed (not just deployed empty code).
    assert!(evm
        .ctx
        .journal_mut()
        .state
        .get(&created_address)
        .unwrap()
        .is_selfdestructed_locally());

    let result2 = evm
        .transact_one(
            TxEnv::builder_for_bench()
                .nonce(1)
                .kind(TxKind::Call(created_address))
                .data(Bytes::from_static(&[0xaa, 0xbb, 0xcc, 0xdd]))
                .build_fill(),
        )
        .unwrap();

    // Calling a destroyed contract must be a harmless no-op: no code left to run.
    assert!(result2.is_success());
    assert_eq!(result2.output().unwrap(), &Bytes::new());

    let target_acc = evm.ctx.journal_mut().state.get(&created_address).unwrap();
    assert_eq!(target_acc.info.code_hash, KECCAK_EMPTY);
    assert_eq!(
        target_acc.status,
        AccountStatus::Touched | AccountStatus::LoadedAsNotExisting
    );
}

/// Same scenario as above, but T1 and T2 run in separate finalize-per-tx
/// sessions (`ExecuteEvm::transact()`'s pattern) sharing only the underlying,
/// persistent `Database` - as opposed to one shared journal across both.
#[test]
fn test_call_after_create_destroy_standalone_journal() {
    use revm::database::DatabaseCommit;

    let db = funded_cache_db(BENCH_CALLER);

    let mut evm1 = Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::CANCUN)
        .with_db(db)
        .build_mainnet();

    let result1 = evm1
        .transact_one(
            TxEnv::builder_for_bench()
                .kind(TxKind::Create)
                .data(Bytes::copy_from_slice(SELFDESTRUCT_BYTECODE))
                .build_fill(),
        )
        .unwrap();
    assert!(result1.is_success());
    let created_address = result1.created_address().unwrap();

    let state1 = evm1.finalize();
    let mut db = evm1.ctx.journal_mut().database.clone();
    db.commit(state1);

    let mut evm2 = Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::CANCUN)
        .with_db(db)
        .build_mainnet();

    let result2 = evm2
        .transact_one(
            TxEnv::builder_for_bench()
                .nonce(1)
                .kind(TxKind::Call(created_address))
                .data(Bytes::from_static(&[0xaa, 0xbb, 0xcc, 0xdd]))
                .build_fill(),
        )
        .unwrap();

    assert!(result2.is_success());
    assert_eq!(result2.output().unwrap(), &Bytes::new());

    let target_acc = evm2.ctx.journal_mut().state.get(&created_address).unwrap();
    assert_eq!(target_acc.info.code_hash, KECCAK_EMPTY);
    assert_eq!(
        target_acc.status,
        AccountStatus::Touched | AccountStatus::LoadedAsNotExisting
    );
}

const EXTCODESIZE_CALLER_BYTECODE: &[u8] = &[
    opcode::CALLER,
    opcode::EXTCODESIZE,
    opcode::POP,
    opcode::STOP,
];

/// Regression test: per EIP-2929, a transaction's own sender is always pre-warmed by that
/// transaction's own validation, so `EXTCODESIZE(CALLER)` inside it must always cost the warm
/// price (100 gas) - regardless of whether an earlier, unrelated transaction already committed
/// to this shared journal (single-journal, multi-tx execution mode).
///
/// T0 is a wholly unrelated transaction from `decoy`, committed to the shared journal first, so
/// that by the time T1 runs, this journal already has committed history - `caller` (T1's sender)
/// has never appeared in it before. If `caller`'s sender-warmth from T1's own validation doesn't
/// survive to the `EXTCODESIZE(CALLER)` a few instructions later, that opcode gets charged the
/// cold surcharge (2600 gas) instead.
///
/// Root cause (fixed): `From<AccountInfo> for Account` (`crates/state/src/lib.rs`) hardcoded
/// `transaction_id: 0` for any account loaded fresh from the database, instead of the journal's
/// real current transaction id. That stamp only accidentally matched when the journal's very
/// first transaction had a real id of 0; once an earlier transaction had already committed and
/// advanced the id, the account's *second* touch within its own transaction (e.g. EXTCODESIZE
/// after validation's own load) was misread as a new transaction touching it for the first time.
#[test]
fn test_sender_extcodesize_stays_warm_after_prior_committed_tx() {
    use revm::state::AccountInfo;

    let decoy = address!("0x2000000000000000000000000000000000000000");
    let caller = address!("0x1000000000000000000000000000000000000000");
    let probe = address!("0x4000000000000000000000000000000000000000");

    let mut db = funded_cache_db(decoy);
    db.insert_account_info(
        caller,
        AccountInfo {
            balance: U256::from(10_000_000_000_000_000_000u128),
            ..Default::default()
        },
    );
    db.insert_account_info(
        probe,
        AccountInfo {
            code_hash: Bytecode::new_raw(Bytes::from_static(EXTCODESIZE_CALLER_BYTECODE))
                .hash_slow(),
            code: Some(Bytecode::new_raw(Bytes::from_static(
                EXTCODESIZE_CALLER_BYTECODE,
            ))),
            ..Default::default()
        },
    );

    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::CANCUN)
        .with_db(db)
        .build_mainnet();

    let result0 = evm
        .transact_one(TxEnv {
            caller: decoy,
            kind: TxKind::Call(decoy),
            ..Default::default()
        })
        .unwrap();
    assert!(result0.is_success());
    evm.ctx.journal_mut().commit_tx();

    let result1 = evm
        .transact_one(TxEnv {
            caller,
            kind: TxKind::Call(probe),
            ..Default::default()
        })
        .unwrap();
    evm.ctx.journal_mut().commit_tx();

    assert!(result1.is_success());
    // 21000 (intrinsic) + 2 (CALLER) + 100 (EXTCODESIZE, warm) + 2 (POP) + 0 (STOP) = 21104.
    // Comes out 23604 if EXTCODESIZE(CALLER) is incorrectly charged cold (2600) instead.
    assert_eq!(
        result1.gas_used(),
        21104,
        "EXTCODESIZE(CALLER) must be charged the warm price (100 gas): `caller` is T1's own \
         sender and must be pre-warmed by T1's own validation, regardless of T0 having already \
         committed to this shared journal"
    );
}

/// Returns a database holding a funded `sender` whose code is `code`.
fn cache_db_with_sender_code(
    sender: revm::primitives::Address,
    code: Bytecode,
) -> revm::database::CacheDB<revm::database::EmptyDB> {
    use revm::state::AccountInfo;

    let mut db = funded_cache_db(sender);
    db.insert_account_info(
        sender,
        AccountInfo {
            balance: U256::from(10_000_000_000_000_000_000u128),
            code_hash: code.hash_slow(),
            code: Some(code),
            ..Default::default()
        },
    );
    db
}

/// Runs one call from `sender` in `mode` against `db`, with EIP-3607 left enabled in the
/// configuration, and returns the result.
fn transact_from_sender_in_mode(
    db: revm::database::CacheDB<revm::database::EmptyDB>,
    sender: revm::primitives::Address,
    mode: ExecutionMode,
) -> Result<
    revm::context_interface::result::ExecutionResult,
    revm::context_interface::result::EVMError<std::convert::Infallible>,
> {
    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| {
            cfg.spec = SpecId::PRAGUE;
            cfg.execution_mode = mode;
        })
        .with_db(db)
        .build_mainnet();
    evm.transact_one(TxEnv {
        caller: sender,
        kind: TxKind::Call(BENCH_TARGET),
        ..Default::default()
    })
}

/// EIP-3607 refuses a `User` transaction whose sender has code, and does not refuse a sender
/// with code in a mode where the node builds the transaction from chain state: automated
/// transactions, read-only predicate execution and genesis (#4469).
#[test]
fn test_sender_with_code_is_refused_only_in_user_mode() {
    use revm::context_interface::result::{EVMError, InvalidTransaction};

    let sender = address!("0x1000000000000000000000000000000000000001");
    // A single `STOP` is neither empty nor an EIP-7702 delegation designation.
    let code = Bytecode::new_raw(Bytes::from_static(STOP_BYTECODE));

    let user = transact_from_sender_in_mode(
        cache_db_with_sender_code(sender, code.clone()),
        sender,
        ExecutionMode::User,
    );
    assert!(
        matches!(
            user,
            Err(EVMError::Transaction(
                InvalidTransaction::RejectCallerWithCode
            ))
        ),
        "a User transaction from a sender with code must be refused, got: {user:?}"
    );

    for mode in [
        ExecutionMode::Automated,
        ExecutionMode::AutomatedGasless,
        ExecutionMode::ReadOnly,
        ExecutionMode::Genesis,
    ] {
        let result = transact_from_sender_in_mode(
            cache_db_with_sender_code(sender, code.clone()),
            sender,
            mode.clone(),
        );
        assert!(
            matches!(&result, Ok(r) if r.is_success()),
            "a {mode:?} transaction from a sender with code must be executed, got: {result:?}"
        );
    }
}

/// A `User` transaction from a sender whose code is an EIP-7702 delegation designation is
/// executed: the delegation exemption is independent of the execution mode.
#[test]
fn test_delegated_sender_is_served_in_user_mode() {
    let sender = address!("0x1000000000000000000000000000000000000002");
    let result = transact_from_sender_in_mode(
        cache_db_with_sender_code(sender, Bytecode::new_eip7702(BENCH_TARGET)),
        sender,
        ExecutionMode::User,
    );
    assert!(
        matches!(&result, Ok(r) if r.is_success()),
        "a delegated sender must be served in User mode, got: {result:?}"
    );
}

/// An authorization whose authority is a Supra reserved address is skipped: the reserved
/// account gets no code and no nonce bump. Another authorization in the same transaction is
/// applied, and the transaction succeeds (#4534).
#[test]
fn test_eip7702_authorization_from_a_reserved_address_is_skipped() {
    use revm::primitives::supra_constants::u64_to_address;

    let reserved = u64_to_address(0x5355_5005);
    let ordinary = address!("0x1000000000000000000000000000000000000003");
    let delegate_to = address!("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::PRAGUE)
        .with_db(BenchmarkDB::new_bytecode(Bytecode::new_legacy(
            STOP_BYTECODE.into(),
        )))
        .build_mainnet();

    let authorization = |authority| {
        RecoveredAuthorization::new_unchecked(
            Authorization {
                chain_id: U256::ZERO,
                address: delegate_to,
                nonce: 0,
            },
            RecoveredAuthority::Valid(authority),
        )
    };
    let tx = TxEnv::builder_for_bench()
        .tx_type(Some(TransactionType::Eip7702 as u8))
        .authorization_list_recovered(vec![authorization(reserved), authorization(ordinary)])
        .build_fill();

    let result = evm.transact_one(tx).unwrap();
    assert!(result.is_success(), "{result:?}");

    let state = &evm.ctx.journal_mut().state;
    if let Some(reserved_after) = state.get(&reserved) {
        assert_eq!(
            reserved_after.info.nonce, 0,
            "the reserved authority's nonce must not change"
        );
        assert_eq!(
            reserved_after.info.code_hash, KECCAK_EMPTY,
            "the reserved authority must not be delegated"
        );
    }
    let ordinary_after = state
        .get(&ordinary)
        .expect("the ordinary authority's account is loaded by the authorization");
    assert_eq!(ordinary_after.info.nonce, 1);
    assert_eq!(
        ordinary_after.info.code,
        Some(Bytecode::new_eip7702(delegate_to)),
        "the ordinary authority must be delegated"
    );
}
