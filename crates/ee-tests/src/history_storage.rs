//! The EIP-2935 block-hash history contract on SupraEVM (smr-moonshot#4888).
//!
//! The genesis deploys the contract byte-identical to Ethereum's at its canonical address, and the
//! node writes the parent block's hash into it before every block with a system call from the
//! EIP's system address. These tests execute both on the paths the node uses:
//! - the genesis transaction from `supra_extension`, in `ExecutionMode::Genesis`;
//! - the history write from `history_storage_write_tx_env`, in `ExecutionMode::System`, through
//!   `Handler::validate_caller` and then `Handler::run_system_call`, as the node runs every
//!   System transaction.
//!
//! They also state who may send from the system address: it is a sender of System transactions
//! only, and an ordinary account in every other respect.

use revm::{
    context::{Context, ContextSetters, ContextTr, TxEnv},
    context_interface::{
        cfg::ExecutionMode,
        result::{EVMError, ExecutionResult, InvalidTransaction, Output, SuccessReason},
        transaction::{Authorization, RecoveredAuthority, RecoveredAuthorization, TransactionType},
    },
    database::{CacheDB, EmptyDB},
    handler::{EthFrame, Handler, MainnetContext, MainnetEvm, MainnetHandler},
    interpreter::interpreter::EthInterpreter,
    primitives::{
        address,
        eip2935::{HISTORY_SERVE_WINDOW, HISTORY_STORAGE_ADDRESS, SYSTEM_ADDRESS},
        eip7825::TX_GAS_LIMIT_CAP,
        hardfork::SpecId,
        keccak256,
        supra_constants::{is_supra_reserved, VM_SIGNER},
        Address, Bytes, TxKind, B256, KECCAK_EMPTY, U256,
    },
    state::{AccountInfo, Bytecode},
    DatabaseCommit, DatabaseRef, ExecuteCommitEvm, ExecuteEvm, MainBuilder, MainContext,
};
use std::convert::Infallible;
use supra_extension::{
    contracts::canonical_singletons::{
        generate_history_storage_transaction, HISTORY_STORAGE_CODE, HISTORY_STORAGE_DEPLOYER,
    },
    transactions::history_storage::{history_storage_slot, history_storage_write_tx_env},
};

/// Sender of the user transactions in these tests.
const SENDER: Address = address!("0x1000000000000000000000000000000000000001");
/// An account without code, the target of the sender matrix.
const EMPTY_ACCOUNT: Address = address!("0x1000000000000000000000000000000000000005");
/// Balance of [`SENDER`].
const FUNDS: u128 = 1_000_000_000_000_000_000;

/// Every execution mode.
const ALL_MODES: [ExecutionMode; 6] = [
    ExecutionMode::User,
    ExecutionMode::Automated,
    ExecutionMode::AutomatedGasless,
    ExecutionMode::ReadOnly,
    ExecutionMode::System,
    ExecutionMode::Genesis,
];

type Db = CacheDB<EmptyDB>;
type TestEvm = MainnetEvm<MainnetContext<Db>>;
type TestError = EVMError<Infallible>;

/// A Prague EVM over a database in which only [`SENDER`] is funded.
fn new_evm() -> TestEvm {
    let mut db = Db::default();
    db.insert_account_info(SENDER, AccountInfo::from_balance(U256::from(FUNDS)));
    Context::mainnet()
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::PRAGUE)
        .with_db(db)
        .build_mainnet()
}

/// Executes `tx` in `mode` and commits its state, on the path the node takes for that mode: a
/// System transaction is checked by `validate_caller` and run by `run_system_call`; every other
/// transaction runs the full handler.
fn execute_commit(
    evm: &mut TestEvm,
    mode: ExecutionMode,
    tx: TxEnv,
) -> Result<ExecutionResult, TestError> {
    evm.ctx.cfg.execution_mode = mode.clone();
    if mode.is_system() {
        evm.ctx.set_tx(tx);
        let mut handler = MainnetHandler::<TestEvm, TestError, EthFrame<EthInterpreter>>::default();
        let result = handler
            .validate_caller(evm)
            .and_then(|()| handler.run_system_call(evm));
        // As on the node, the journal is finalized whatever the outcome, and committed only for a
        // result.
        let state = evm.finalize();
        if result.is_ok() {
            evm.ctx.db_mut().commit(state);
        }
        result
    } else {
        evm.transact_commit(tx)
    }
}

/// Deploys the history contract from the genesis transaction `supra_extension` generates.
fn deploy_history_contract(evm: &mut TestEvm) {
    let genesis = generate_history_storage_transaction();
    let tx = TxEnv {
        caller: *genesis.sender(),
        nonce: *genesis.nonce(),
        kind: *genesis.kind(),
        data: Bytes::from(genesis.data().clone()),
        gas_limit: TX_GAS_LIMIT_CAP,
        ..Default::default()
    };
    let result = execute_commit(evm, ExecutionMode::Genesis, tx).expect("genesis executes");
    assert!(result.is_success(), "genesis deployment failed: {result:?}");
}

/// A distinct stand-in for the hash of block `number`.
fn hash_of(number: u64) -> B256 {
    keccak256(number.to_be_bytes())
}

/// Runs the history write of the block at `height` and returns its result.
fn write_history(evm: &mut TestEvm, height: u64) -> Result<ExecutionResult, TestError> {
    evm.ctx.block.number = U256::from(height);
    let tx = history_storage_write_tx_env(height, hash_of(height - 1))
        .expect("every height the tests write has a parent");
    execute_commit(evm, ExecutionMode::System, tx)
}

/// The value of the history contract's slot `slot` in the committed state.
fn history_slot(evm: &TestEvm, slot: U256) -> U256 {
    evm.ctx
        .db()
        .storage_ref(HISTORY_STORAGE_ADDRESS, slot)
        .expect("in-memory read")
}

/// Calls the history contract's `get` with `input` from [`SENDER`] in a User transaction, in the
/// block at `height`.
fn call_get(evm: &mut TestEvm, height: u64, input: Bytes) -> ExecutionResult {
    evm.ctx.block.number = U256::from(height);
    evm.ctx.cfg.execution_mode = ExecutionMode::User;
    let nonce = evm
        .ctx
        .db()
        .basic_ref(SENDER)
        .expect("in-memory read")
        .map_or(0, |info| info.nonce);
    evm.transact_commit(TxEnv {
        caller: SENDER,
        nonce,
        kind: TxKind::Call(HISTORY_STORAGE_ADDRESS),
        data: input,
        gas_limit: 100_000,
        ..Default::default()
    })
    .expect("a get call is a valid transaction")
}

/// The genesis puts the EIP's runtime code at the canonical address, with account nonce 1, and
/// consumes the deployer's nonce 0.
#[test]
fn genesis_deploys_the_history_contract() {
    let mut evm = new_evm();
    deploy_history_contract(&mut evm);

    let account = evm
        .ctx
        .db()
        .basic_ref(HISTORY_STORAGE_ADDRESS)
        .expect("in-memory read")
        .expect("the history contract exists");
    let code = evm
        .ctx
        .db()
        .code_by_hash_ref(account.code_hash)
        .expect("in-memory read");
    // The init-code is a 9-byte constructor that returns the 83 bytes after it; supra-extension's
    // own tests compare those bytes with the runtime code alloy publishes for the contract.
    assert_eq!(
        code.original_byte_slice(),
        &HISTORY_STORAGE_CODE[9..],
        "the deployed code is the runtime part of the EIP's init-code"
    );
    assert_eq!(code.original_byte_slice().len(), 83);
    assert_eq!(account.nonce, 1);

    let deployer = evm
        .ctx
        .db()
        .basic_ref(HISTORY_STORAGE_DEPLOYER)
        .expect("in-memory read")
        .expect("the deployer account exists");
    assert_eq!(deployer.nonce, 1);
}

/// Each block's write stores its parent's hash in slot `(height - 1) % 8191`, across two
/// wrap-arounds of the ring; the first write costs what upstream's EIP-2935 system-call test
/// pins, and touches no account but the contract. `get` then serves exactly the last 8191 block
/// hashes before the block it runs in, and refuses anything else.
#[test]
fn history_writes_fill_the_ring_and_get_serves_the_window() {
    let mut evm = new_evm();
    deploy_history_contract(&mut evm);

    // The first write, inspected before it is committed.
    evm.ctx.block.number = U256::from(1);
    evm.ctx.cfg.execution_mode = ExecutionMode::System;
    evm.ctx
        .set_tx(history_storage_write_tx_env(1, hash_of(0)).expect("height 1 has a parent"));
    let mut handler = MainnetHandler::<TestEvm, TestError, EthFrame<EthInterpreter>>::default();
    handler
        .validate_caller(&evm)
        .expect("the system address is a System sender");
    let first = handler
        .run_system_call(&mut evm)
        .expect("the first write executes");
    assert!(
        matches!(
            &first,
            ExecutionResult::Success {
                reason: SuccessReason::Stop,
                logs,
                output: Output::Call(output),
                ..
            } if logs.is_empty() && output.is_empty()
        ),
        "{first:?}"
    );
    assert_eq!(first.tx_gas_used(), 22143);
    assert_eq!(first.gas().inner_refunded(), 0);
    let state = evm.finalize();
    assert_eq!(
        state.keys().copied().collect::<Vec<_>>(),
        vec![HISTORY_STORAGE_ADDRESS],
        "the write touches the history contract only"
    );
    evm.ctx.db_mut().commit(state);
    assert_eq!(
        history_slot(&evm, U256::ZERO),
        U256::from_be_bytes(hash_of(0).0)
    );

    // Two full turns of the ring and one more block.
    let last = 2 * HISTORY_SERVE_WINDOW + 2;
    for height in 2..=last {
        let result = write_history(&mut evm, height).expect("the write executes");
        assert!(result.is_success(), "write at {height} failed: {result:?}");
        let slot = U256::from((height - 1) % HISTORY_SERVE_WINDOW);
        assert_eq!(history_storage_slot(height - 1), slot);
        assert_eq!(
            history_slot(&evm, slot),
            U256::from_be_bytes(hash_of(height - 1).0),
            "slot of block {}",
            height - 1
        );
        // The wrap-arounds: the hash of block 8191 replaces block 0's in slot 0, and the hash of
        // block 16382 replaces block 8191's.
        if height == HISTORY_SERVE_WINDOW + 1 || height == 2 * HISTORY_SERVE_WINDOW + 1 {
            assert_eq!(slot, U256::ZERO);
        }
    }

    // Every slot holds the hash of the most recent block it serves.
    for number in (last - HISTORY_SERVE_WINDOW)..last {
        assert_eq!(
            history_slot(&evm, history_storage_slot(number)),
            U256::from_be_bytes(hash_of(number).0),
            "block {number}"
        );
    }

    // `get` in the block at `last`, whose write has landed: the window is
    // `[last - 8191, last - 1]`.
    let word = |number: u64| Bytes::from(U256::from(number).to_be_bytes::<32>().to_vec());
    for number in [last - 1, last - 2, last - HISTORY_SERVE_WINDOW] {
        let result = call_get(&mut evm, last, word(number));
        assert_eq!(
            result.output().map(|out| out.as_ref()),
            Some(hash_of(number).as_slice()),
            "get({number}) in block {last}: {result:?}"
        );
        assert!(result.is_success());
    }
    for number in [last, last + 1, last - HISTORY_SERVE_WINDOW - 1, 0] {
        let result = call_get(&mut evm, last, word(number));
        assert!(
            matches!(result, ExecutionResult::Revert { .. }),
            "get({number}) in block {last} must revert: {result:?}"
        );
    }
    // The input must be exactly one 32-byte word.
    let in_window = word(last - 1);
    for input in [
        Bytes::new(),
        Bytes::copy_from_slice(&in_window[1..]),
        Bytes::from([in_window.as_ref(), &[0u8]].concat()),
    ] {
        let len = input.len();
        let result = call_get(&mut evm, last, input);
        assert!(
            matches!(result, ExecutionResult::Revert { .. }),
            "get with {len} input bytes must revert: {result:?}"
        );
    }
}

/// A User transaction from the system address could otherwise take the contract's `set` path:
/// it is refused before execution, and the ring is unchanged.
#[test]
fn a_user_transaction_from_the_system_address_cannot_write_the_history() {
    let mut evm = new_evm();
    deploy_history_contract(&mut evm);
    write_history(&mut evm, 1).expect("the write executes");

    evm.ctx.block.number = U256::from(2);
    let forged = TxEnv {
        caller: SYSTEM_ADDRESS,
        kind: TxKind::Call(HISTORY_STORAGE_ADDRESS),
        data: Bytes::copy_from_slice(B256::repeat_byte(0xee).as_slice()),
        gas_limit: 100_000,
        ..Default::default()
    };
    let result = execute_commit(&mut evm, ExecutionMode::User, forged);
    assert!(
        matches!(
            result,
            Err(EVMError::Transaction(
                InvalidTransaction::UnsupportedTransactionSender { sender, .. }
            )) if sender == SYSTEM_ADDRESS
        ),
        "got {result:?}"
    );
    assert_eq!(
        history_slot(&evm, U256::from(1)),
        U256::ZERO,
        "slot 1 stays unwritten"
    );
    assert_eq!(
        history_slot(&evm, U256::ZERO),
        U256::from_be_bytes(hash_of(0).0)
    );
}

/// Who may send in which mode, for a transaction to the history contract: the system address in
/// System mode only; `VM_SIGNER` in System and Genesis mode only; any other sender in every mode
/// but System. The contract is not deployed here, so every executed call is a plain call to an
/// empty account.
#[test]
fn the_system_address_is_a_sender_of_system_transactions_only() {
    for sender in [SYSTEM_ADDRESS, VM_SIGNER, SENDER] {
        for mode in ALL_MODES {
            let expected_ok = if sender == SYSTEM_ADDRESS {
                mode.is_system()
            } else if sender == VM_SIGNER {
                mode.is_system() || mode.is_genesis()
            } else {
                !mode.is_system()
            };
            let mut evm = new_evm();
            let result = execute_commit(
                &mut evm,
                mode.clone(),
                TxEnv {
                    caller: sender,
                    kind: TxKind::Call(HISTORY_STORAGE_ADDRESS),
                    gas_limit: 100_000,
                    ..Default::default()
                },
            );
            if expected_ok {
                assert!(
                    matches!(&result, Ok(r) if r.is_success()),
                    "{sender} in {mode:?} must be executed, got {result:?}"
                );
            } else {
                assert!(
                    matches!(
                        &result,
                        Err(EVMError::Transaction(
                            InvalidTransaction::UnsupportedTransactionSender { sender: s, .. }
                        )) if *s == sender
                    ),
                    "{sender} in {mode:?} must be refused as a sender, got {result:?}"
                );
            }
        }
    }
}

/// In System mode the system address sends the history write only: a System transaction from it
/// to any other target, a contract creation included, is refused as a sender, while `VM_SIGNER`
/// passes the sender check for the same transactions (what execution then does with a System
/// creation is outside this test).
#[test]
fn the_system_address_sends_no_system_transaction_but_the_history_write() {
    for kind in [
        TxKind::Call(EMPTY_ACCOUNT),
        TxKind::Call(VM_SIGNER),
        TxKind::Call(SYSTEM_ADDRESS),
        TxKind::Create,
    ] {
        let tx = |caller| TxEnv {
            caller,
            kind,
            gas_limit: 100_000,
            ..Default::default()
        };

        let mut evm = new_evm();
        let result = execute_commit(&mut evm, ExecutionMode::System, tx(SYSTEM_ADDRESS));
        assert!(
            matches!(
                &result,
                Err(EVMError::Transaction(
                    InvalidTransaction::UnsupportedTransactionSender { sender, msg }
                )) if *sender == SYSTEM_ADDRESS && msg.contains("TxnHash")
            ),
            "the system address must not send a System transaction to {kind:?}, got {result:?}"
        );

        let mut evm = new_evm();
        let result = execute_commit(&mut evm, ExecutionMode::System, tx(VM_SIGNER));
        assert!(
            result.is_ok(),
            "VM_SIGNER is a sender of a System transaction to {kind:?}, got {result:?}"
        );
    }
}

/// An EIP-7702 authorization whose authority is the system address is skipped: the address gets
/// no code and no nonce bump. Another authorization in the same transaction is applied, and the
/// transaction succeeds.
#[test]
fn an_eip7702_authorization_from_the_system_address_is_skipped() {
    let ordinary = address!("0x1000000000000000000000000000000000000003");
    let delegate_to = address!("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
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

    let mut evm = new_evm();
    let result = execute_commit(
        &mut evm,
        ExecutionMode::User,
        TxEnv::builder()
            .caller(SENDER)
            .kind(TxKind::Call(EMPTY_ACCOUNT))
            .gas_limit(1_000_000)
            .tx_type(Some(TransactionType::Eip7702 as u8))
            .authorization_list_recovered(vec![
                authorization(SYSTEM_ADDRESS),
                authorization(ordinary),
            ])
            .build_fill(),
    )
    .expect("a transaction with authorizations is valid");
    assert!(result.is_success(), "{result:?}");

    let db = evm.ctx.db();
    if let Some(system_after) = db.basic_ref(SYSTEM_ADDRESS).expect("in-memory read") {
        assert_eq!(
            system_after.nonce, 0,
            "the system address's nonce must not change"
        );
        assert_eq!(
            system_after.code_hash, KECCAK_EMPTY,
            "the system address must not be delegated"
        );
    }
    let ordinary_after = db
        .basic_ref(ordinary)
        .expect("in-memory read")
        .expect("the ordinary authority's account is written by the authorization");
    assert_eq!(ordinary_after.nonce, 1);
    assert_eq!(
        ordinary_after.code_hash,
        Bytecode::new_eip7702(delegate_to).hash_slow(),
        "the ordinary authority must be delegated"
    );
}

/// The system address is not a Supra reserved address, and is an ordinary account otherwise:
/// a User transaction may send value to it, as on Ethereum.
#[test]
fn the_system_address_accepts_value_like_any_account() {
    assert!(!is_supra_reserved(&SYSTEM_ADDRESS));

    let mut evm = new_evm();
    let result = execute_commit(
        &mut evm,
        ExecutionMode::User,
        TxEnv {
            caller: SENDER,
            kind: TxKind::Call(SYSTEM_ADDRESS),
            value: U256::from(7),
            gas_limit: 100_000,
            ..Default::default()
        },
    )
    .expect("a value transfer is a valid transaction");
    assert!(result.is_success(), "{result:?}");
    let balance = evm
        .ctx
        .db()
        .basic_ref(SYSTEM_ADDRESS)
        .expect("in-memory read")
        .map(|info| info.balance);
    assert_eq!(balance, Some(U256::from(7)));
}
