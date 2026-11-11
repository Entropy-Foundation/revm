//! The journal's self-destruct total, `JournalInner::selfdestruct_burn`, must equal
//! the native value that leaves the EVM through self-destructed accounts. These
//! tests run real bytecode through the handler in one journal, commit the finalized
//! state to a `CacheDB`, and compare the fall in the sum of all balances with the
//! total the journal reports.
//!
//! Gas is free in every transaction, so a fall in the sum of balances is value
//! destroyed by self-destructs and by nothing else.

use revm::{
    context::{ContextTr, TxEnv},
    database::{CacheDB, EmptyDB},
    primitives::{hardfork::SpecId, Address, Bytes, TxKind, U256},
    state::AccountInfo,
    Context, DatabaseCommit, ExecuteEvm, MainBuilder, MainContext,
};

const CALLER: Address = Address::with_last_byte(0xca);
const CALLER_FUNDS: u64 = 1_000_000;
/// Value the creating transaction sends to the contract it deploys.
const PARENT_VALUE: u8 = 0x80;
/// Value the deployed contract gives the child it creates.
const CHILD_ENDOWMENT: u8 = 0x30;
/// Value the deployed contract pays the child after creating it.
const CHILD_PAYMENT: u8 = 0x11;

/// `CALLER SELFDESTRUCT`: returns the child's balance to its creator.
const SELFDESTRUCT_TO_CREATOR: [u8; 2] = [0x33, 0xff];
/// `ADDRESS SELFDESTRUCT`: names the child itself as beneficiary.
const SELFDESTRUCT_TO_SELF: [u8; 2] = [0x30, 0xff];

/// Initcode that `CREATE`s a child running `child_initcode` with
/// `CHILD_ENDOWMENT`, leaving the child's address on the stack.
fn create_child(child_initcode: [u8; 2]) -> Vec<u8> {
    vec![
        0x61,
        child_initcode[0],
        child_initcode[1], // PUSH2 child initcode
        0x60,
        0x00, // PUSH1 0
        0x52, // MSTORE: the initcode is in memory bytes 30..32
        0x60,
        0x02, // PUSH1 2: size
        0x60,
        0x1e, // PUSH1 30: offset
        0x60,
        CHILD_ENDOWMENT, // PUSH1 value
        0xf0,            // CREATE
    ]
}

/// Initcode that creates a child running `child_initcode`, then `CALL`s the child
/// with `CHILD_PAYMENT`, then stops.
fn create_child_then_pay_it(child_initcode: [u8; 2]) -> Bytes {
    let mut code = create_child(child_initcode);
    code.extend_from_slice(&[
        0x60,
        0x00, // PUSH1 0: retSize
        0x60,
        0x00, // PUSH1 0: retOffset
        0x60,
        0x00, // PUSH1 0: argsSize
        0x60,
        0x00, // PUSH1 0: argsOffset
        0x60,
        CHILD_PAYMENT, // PUSH1 value
        0x85,          // DUP6: the child's address
        0x5a,          // GAS
        0xf1,          // CALL
        0x50,          // POP the call's success flag
        0x50,          // POP the child's address
        0x00,          // STOP
    ]);
    code.into()
}

/// Initcode that creates a child running `child_initcode`, then self-destructs
/// with the child as beneficiary.
fn create_child_then_selfdestruct_to_it(child_initcode: [u8; 2]) -> Bytes {
    let mut code = create_child(child_initcode);
    code.push(0xff); // SELFDESTRUCT to the child's address
    code.into()
}

fn parent_address() -> Address {
    CALLER.create(0)
}

/// A contract's first `CREATE` uses nonce 1.
fn child_address() -> Address {
    parent_address().create(1)
}

fn deploy(initcode: Bytes) -> TxEnv {
    TxEnv {
        caller: CALLER,
        kind: TxKind::Create,
        value: U256::from(PARENT_VALUE),
        data: initcode,
        nonce: 0,
        ..Default::default()
    }
}

fn total_balance(db: &CacheDB<EmptyDB>) -> U256 {
    db.cache
        .accounts
        .values()
        .fold(U256::ZERO, |sum, account| sum + account.info.balance)
}

/// Runs `txs` in one journal, as Supra runs a block, commits the finalized state,
/// and returns the fall in the sum of all balances together with the total the
/// journal reports as destroyed.
fn destroyed_and_reported(txs: Vec<TxEnv>) -> (U256, U256) {
    let mut db = CacheDB::new(EmptyDB::default());
    db.insert_account_info(
        CALLER,
        AccountInfo {
            balance: U256::from(CALLER_FUNDS),
            ..Default::default()
        },
    );
    let mut evm = Context::mainnet()
        .with_db(db)
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::PRAGUE)
        .build_mainnet();
    let before = total_balance(evm.ctx.db_ref());

    for tx in txs {
        let result = evm.transact_one(tx).expect("the transaction is valid");
        assert!(result.is_success(), "transaction failed: {result:?}");
    }
    let state = evm.finalize();
    evm.ctx.db_mut().commit(state);

    let after = total_balance(evm.ctx.db_ref());
    let reported = evm.ctx.journal_mut().take_selfdestruct_burn();
    (before - after, reported)
}

/// A child that returns its balance to its creator and is then paid is deleted
/// with the payment.
#[test]
fn burn_covers_value_paid_to_a_selfdestructed_contract() {
    let (destroyed, reported) = destroyed_and_reported(vec![deploy(create_child_then_pay_it(
        SELFDESTRUCT_TO_CREATOR,
    ))]);

    assert_eq!(destroyed, U256::from(CHILD_PAYMENT));
    assert_eq!(reported, destroyed);
}

/// A child that names itself as beneficiary destroys its endowment at the opcode,
/// and is then deleted with the payment.
#[test]
fn burn_covers_self_targeting_selfdestruct_and_later_payment() {
    let (destroyed, reported) =
        destroyed_and_reported(vec![deploy(create_child_then_pay_it(SELFDESTRUCT_TO_SELF))]);

    assert_eq!(destroyed, U256::from(CHILD_ENDOWMENT + CHILD_PAYMENT));
    assert_eq!(reported, destroyed);
}

/// A contract that self-destructs to a beneficiary which has already
/// self-destructed in the same transaction moves its balance into an account that
/// is deleted.
#[test]
fn burn_covers_selfdestruct_to_a_selfdestructed_beneficiary() {
    let (destroyed, reported) = destroyed_and_reported(vec![deploy(
        create_child_then_selfdestruct_to_it(SELFDESTRUCT_TO_CREATOR),
    )]);

    assert_eq!(destroyed, U256::from(PARENT_VALUE));
    assert_eq!(reported, destroyed);
}

/// A later transaction in the same journal that loads the self-destructed child
/// deletes it there rather than at finalize; the total is the same.
#[test]
fn burn_covers_a_selfdestructed_contract_loaded_by_a_later_transaction() {
    let touch_child = TxEnv {
        caller: CALLER,
        kind: TxKind::Call(child_address()),
        nonce: 1,
        ..Default::default()
    };
    let (destroyed, reported) = destroyed_and_reported(vec![
        deploy(create_child_then_pay_it(SELFDESTRUCT_TO_CREATOR)),
        touch_child,
    ]);

    assert_eq!(destroyed, U256::from(CHILD_PAYMENT));
    assert_eq!(reported, destroyed);
}
