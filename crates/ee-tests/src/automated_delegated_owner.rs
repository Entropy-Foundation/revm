//! Automated transactions whose task owner is an EIP-7702 delegated account (smr-moonshot#5152).
//!
//! The sender of an automated transaction is the task owner, and an owner may be an EOA that
//! holds an EIP-7702 delegation designation (`0xef0100 || address`). In the `Automated` and
//! `AutomatedGasless` execution modes:
//! - the owner is accepted as the sender: EIP-3607 is enforced only in `User` mode, see
//!   `ExecutionMode::enforces_eip3607`;
//! - a call to the owner runs the delegated code in the owner's context;
//! - the owner's nonce is unchanged by the transaction. An automated transaction carries no
//!   authorization list, the caller's nonce is not bumped (`ExecutionMode::updates_nonce`), and
//!   `CREATE`/`CREATE2` are refused (`ExecutionMode::supports_contract_creation`), so nothing in
//!   the transaction moves it. An EIP-7702 authorization the owner signed against its current
//!   nonce therefore stays valid across the owner's automated transactions.
//!
//! The transactions are built with `supra_extension`'s `AutomatedTransactionBuilder` and turned
//! into a `TxEnv` the way the node does, so the tests exercise the transaction type the node
//! executes rather than a hand-written environment.

use alloy_consensus::Transaction as AlloyTransaction;
use alloy_eips::eip2718::Typed2718;
use revm::{
    bytecode::opcode,
    context::{Context, TxEnv},
    context_interface::{cfg::ExecutionMode, result::ExecutionResult},
    database::{CacheDB, EmptyDB},
    primitives::{address, b256, hardfork::SpecId, Address, Bytes, TxKind, B256, U256},
    state::{AccountInfo, Bytecode, EvmState},
    ExecuteEvm, MainBuilder, MainContext,
};
use supra_extension::transactions::automated_transaction::{
    AutomatedTransaction, AutomatedTransactionBuilder, AutomatedTransactionType, BuildResult,
};

/// The task owner: an EOA holding an EIP-7702 delegation designation to [`DELEGATE`].
const OWNER: Address = address!("0x2000000000000000000000000000000000000001");

/// The contract [`OWNER`] delegates to. Each test seeds it with the code under test.
const DELEGATE: Address = address!("0x2000000000000000000000000000000000000002");

/// The owner's nonce before the transaction. Non-zero so that a nonce left at its starting value
/// is distinguishable from an account that was never written.
const OWNER_NONCE: u64 = 5;

/// The task index, which an automated transaction carries as its nonce. It differs from
/// [`OWNER_NONCE`]: modes that do not update the nonce do not check it against the sender's.
const TASK_INDEX: u64 = 42;

/// Balance of [`OWNER`]; it covers `GAS_LIMIT * GAS_PRICE` for the paid (UST) transaction.
const OWNER_FUNDS: u64 = 1_000_000_000_000;
const GAS_LIMIT: u64 = 1_000_000;
/// Scheduled price of the paid (UST) transaction. The block's base fee is zero in these tests,
/// so any price passes the base-fee floor.
const GAS_PRICE: u128 = 10;
const CHAIN_ID: u64 = 1;
const REGISTRATION_HASH: B256 =
    b256!("0x00000000000000000000000000000000000000000000000000000000000000aa");

/// Delegated code that records that it ran: `SSTORE(1, 1)` in the executing account's storage,
/// which is the owner's when the owner is called.
const MARK_RAN: [u8; 6] = [
    opcode::PUSH1,
    0x01, // value
    opcode::PUSH1,
    0x01, // key
    opcode::SSTORE,
    opcode::STOP,
];

/// The automated execution modes, each paired with the automated transaction type the node runs
/// in it: a paid task (UST) in `Automated`, a gasless task (GST) in `AutomatedGasless`.
const AUTOMATED_MODES: [(ExecutionMode, AutomatedTransactionType); 2] = [
    (ExecutionMode::Automated, AutomatedTransactionType::UST),
    (
        ExecutionMode::AutomatedGasless,
        AutomatedTransactionType::GST,
    ),
];

/// Delegated code that writes the [`MARK_RAN`] marker, then runs `create_op` (`CREATE` or
/// `CREATE2`) with empty init code and stores the address it pushes in slot 0.
///
/// Slot 0 holds the created address when the creation succeeds and zero when it is refused.
/// Slot 1 shows the code started. The code ends with the slot-0 store, so a successful
/// transaction shows it ran to its end: a zero in slot 0 is the refusal, not code that stopped
/// early.
///
/// The marker is written before the creation because a refused creation does not return the
/// gas `CREATE` forwards to it (all but 1/64 of what remains, EIP-150): the frame is left with
/// enough for the slot-0 store, a no-op write of zero, but not for a zero-to-non-zero write.
fn create_then_record(create_op: u8) -> Bytecode {
    // MARK_RAN without its trailing STOP.
    let mut code = MARK_RAN[..MARK_RAN.len() - 1].to_vec();
    // CREATE2 takes a salt below the size; CREATE does not.
    if create_op == opcode::CREATE2 {
        code.extend_from_slice(&[opcode::PUSH1, 0x00]); // salt
    }
    code.extend_from_slice(&[
        opcode::PUSH1,
        0x00, // size: empty init code
        opcode::PUSH1,
        0x00, // offset
        opcode::PUSH1,
        0x00, // value
        create_op,
        opcode::PUSH1,
        0x00, // key
        opcode::SSTORE,
        opcode::STOP,
    ]);
    Bytecode::new_raw(code.into())
}

/// A database with [`OWNER`] holding the delegation designation to [`DELEGATE`], funded and at
/// [`OWNER_NONCE`], and [`DELEGATE`] holding `delegate_code`.
fn db_with_delegated_owner(delegate_code: Bytecode) -> CacheDB<EmptyDB> {
    let mut db = CacheDB::new(EmptyDB::new());
    let designation = Bytecode::new_eip7702(DELEGATE);
    db.insert_account_info(
        OWNER,
        AccountInfo {
            balance: U256::from(OWNER_FUNDS),
            nonce: OWNER_NONCE,
            code_hash: designation.hash_slow(),
            code: Some(designation),
        },
    );
    db.insert_account_info(
        DELEGATE,
        AccountInfo {
            code_hash: delegate_code.hash_slow(),
            code: Some(delegate_code),
            ..Default::default()
        },
    );
    db
}

/// An automated transaction of type `typ`, owned by [`OWNER`] and calling [`OWNER`], as the node
/// builds one from a registered task.
fn automated_transaction(typ: AutomatedTransactionType) -> AutomatedTransaction {
    let builder = AutomatedTransactionBuilder::new()
        .with_typ(typ)
        .with_block_height(1)
        .with_chain_id(CHAIN_ID)
        .with_gas_limit(GAS_LIMIT)
        .with_gas_price(GAS_PRICE)
        .with_gas_price_cap(GAS_PRICE)
        .with_registration_hash(REGISTRATION_HASH)
        .with_task_index(TASK_INDEX)
        .with_owner(OWNER)
        .with_to(OWNER)
        .with_input(Bytes::new());
    match builder
        .build()
        .expect("every mandatory builder field is set above")
    {
        BuildResult::Success(details) => details.txn,
        other => panic!("the scheduled price equals the cap, so the build succeeds: {other:?}"),
    }
}

/// The execution environment for `tx`, built field by field as the node builds it
/// (`FromRecoveredTx<AutomatedTransaction> for TxEnv` in smr-moonshot's `supra_evm::tx`).
///
/// The authorization list is taken from the transaction's own accessor rather than left at its
/// default, so that if an automated transaction ever carried one, these tests would execute it.
fn tx_env(tx: &AutomatedTransaction) -> TxEnv {
    TxEnv {
        tx_type: tx.ty(),
        caller: tx.sender,
        gas_limit: tx.gas_limit,
        gas_price: tx.max_fee_per_gas(),
        gas_priority_fee: tx.max_priority_fee_per_gas(),
        kind: TxKind::Call(tx.to),
        value: tx.value,
        data: tx.input.clone(),
        nonce: tx.nonce,
        chain_id: Some(tx.chain_id),
        access_list: tx.access_list.clone(),
        authorization_list: tx
            .authorization_list()
            .unwrap_or_default()
            .iter()
            .cloned()
            .map(revm::context::either::Either::Left)
            .collect(),
        ..Default::default()
    }
}

/// Runs `tx` in `mode` against `db` and returns the result with the finalized state.
fn execute(mode: ExecutionMode, db: CacheDB<EmptyDB>, tx: TxEnv) -> (ExecutionResult, EvmState) {
    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| {
            cfg.spec = SpecId::PRAGUE;
            cfg.execution_mode = mode.clone();
        })
        .with_db(db)
        .build_mainnet();
    let result = evm
        .transact_one(tx)
        .unwrap_or_else(|error| panic!("{mode:?}: the transaction must execute: {error:?}"));
    (result, evm.finalize())
}

/// The owner's nonce, code and storage slot `key` in `state`. The owner is the transaction's
/// sender, so the run always loads it.
fn owner_after(state: &EvmState, key: u64) -> (u64, Option<Bytecode>, U256) {
    let owner = state
        .get(&OWNER)
        .expect("the sender is loaded by every transaction");
    let slot = owner
        .storage
        .get(&U256::from(key))
        .map(|slot| slot.present_value)
        .unwrap_or_default();
    (owner.info.nonce, owner.info.code.clone(), slot)
}

/// An automated transaction carries no EIP-7702 authorization list, so it can neither set nor
/// change a delegation, and it is an EIP-2930 transaction, not an EIP-7702 one.
#[test]
fn automated_transaction_carries_no_authorization_list() {
    for (_, typ) in AUTOMATED_MODES {
        let tx = automated_transaction(typ);
        assert_eq!(tx.authorization_list(), None, "{typ:?}");
        assert_eq!(tx.ty(), revm::context::TransactionType::Eip2930 as u8);
        assert!(tx_env(&tx).authorization_list.is_empty(), "{typ:?}");
    }
}

/// A task owner with an EIP-7702 delegation is accepted as the sender of its automated
/// transaction, a call to it runs the delegated code in its context, and the transaction leaves
/// its nonce and its delegation designation unchanged.
#[test]
fn delegated_owner_runs_its_delegated_code_without_a_nonce_change() {
    for (mode, typ) in AUTOMATED_MODES {
        let (result, state) = execute(
            mode.clone(),
            db_with_delegated_owner(Bytecode::new_raw(MARK_RAN.to_vec().into())),
            tx_env(&automated_transaction(typ)),
        );
        assert!(result.is_success(), "{mode:?}: {result:?}");

        let (nonce, code, ran) = owner_after(&state, 1);
        assert_eq!(ran, U256::from(1), "{mode:?}: the delegated code must run");
        assert_eq!(
            nonce, OWNER_NONCE,
            "{mode:?}: the owner's nonce must not change"
        );
        assert_eq!(
            code,
            Some(Bytecode::new_eip7702(DELEGATE)),
            "{mode:?}: the owner's delegation designation must not change"
        );
    }
}

/// Delegated code running in the owner's context cannot create a contract in an automated
/// transaction, so it cannot move the owner's nonce: `CREATE` and `CREATE2` push zero, the code
/// continues, and the owner's nonce is unchanged.
///
/// The same code in a `User` transaction from the owner creates the contract and moves the
/// nonce, which shows that the automated-mode assertions are able to see a nonce change.
#[test]
fn create_from_a_delegated_owner_is_refused_and_leaves_its_nonce() {
    for create_op in [opcode::CREATE, opcode::CREATE2] {
        let op_name = opcode::OpCode::name_by_op(create_op);
        for (mode, typ) in AUTOMATED_MODES {
            let context = format!("{mode:?} {op_name}");
            let (result, state) = execute(
                mode.clone(),
                db_with_delegated_owner(create_then_record(create_op)),
                tx_env(&automated_transaction(typ)),
            );
            // Success means the delegated code ran to its final store; see `create_then_record`.
            assert!(result.is_success(), "{context}: {result:?}");

            let (nonce, _, created) = owner_after(&state, 0);
            let (_, _, ran) = owner_after(&state, 1);
            assert_eq!(ran, U256::from(1), "{context}: the delegated code must run");
            assert_eq!(
                created,
                U256::ZERO,
                "{context}: the creation must be refused"
            );
            assert_eq!(
                nonce, OWNER_NONCE,
                "{context}: the owner's nonce must not change"
            );
        }

        // Control: a User transaction from the owner with the same delegated code. The
        // transaction bumps the sender's nonce once and the creation bumps it again.
        let user_tx = TxEnv {
            caller: OWNER,
            kind: TxKind::Call(OWNER),
            gas_limit: GAS_LIMIT,
            nonce: OWNER_NONCE,
            chain_id: Some(CHAIN_ID),
            ..Default::default()
        };
        let (result, state) = execute(
            ExecutionMode::User,
            db_with_delegated_owner(create_then_record(create_op)),
            user_tx,
        );
        assert!(result.is_success(), "User {op_name}: {result:?}");
        let (nonce, _, created) = owner_after(&state, 0);
        assert_ne!(
            created,
            U256::ZERO,
            "User {op_name}: the creation must succeed"
        );
        assert_eq!(
            nonce,
            OWNER_NONCE + 2,
            "User {op_name}: the transaction and the creation each bump the nonce"
        );
    }
}
