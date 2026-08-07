use revm::{
    context::ContextTr,
    context::TxEnv,
    context_interface::transaction::{AccessList, AccessListItem, TransactionType},
    database::{CacheDB, EmptyDB},
    primitives::{address, hardfork::SpecId, Bytes, TxKind, U256},
    state::AccountInfo,
    Context, ExecuteEvm, MainBuilder, MainContext,
};

/// Regression test: EIP-2930 access lists pre-warm addresses/storage keys
/// for the *current transaction only*. In revm's single-journal, multi-tx
/// execution mode, an access-listed address gets inserted into the shared
/// `state` map by the transaction that declares it - this test confirms
/// that insertion does not leak warmth into a *later*, unrelated
/// transaction that does not itself declare the address in its own access
/// list (unlike the COINBASE/precompile case, access-listed addresses are
/// never added to the perpetually-pre-warmed `warm_addresses` set, so the
/// fix for the COINBASE gas deviation must not - and does not - affect this
/// path).
#[test]
fn access_list_warmth_does_not_leak_into_later_tx() {
    let mut db = CacheDB::new(EmptyDB::default());

    let caller = address!("1000000000000000000000000000000000000000");
    let listed_addr = address!("5555555555555555555555555555555555555555");
    let contract = address!("3000000000000000000000000000000000000000");

    db.insert_account_info(
        caller,
        AccountInfo {
            balance: U256::from(10_u128.pow(18)),
            ..Default::default()
        },
    );

    let mut code = vec![0x73]; // PUSH20
    code.extend_from_slice(listed_addr.as_slice());
    code.push(0x31); // BALANCE
    code.push(0x00); // STOP

    db.insert_account_info(
        contract,
        AccountInfo {
            code_hash: revm::primitives::keccak256(&code),
            code: Some(revm::bytecode::Bytecode::new_raw(Bytes::from(code))),
            ..Default::default()
        },
    );

    let mut evm = Context::mainnet()
        .with_db(db)
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::PRAGUE)
        .build_mainnet();

    // T1: access list includes `listed_addr` - pre-warms it for T1 only.
    let tx1 = TxEnv {
        caller,
        kind: TxKind::Call(contract),
        gas_limit: 1_000_000,
        tx_type: TransactionType::Eip2930 as u8,
        access_list: AccessList(vec![AccessListItem {
            address: listed_addr,
            storage_keys: vec![],
        }]),
        ..Default::default()
    };

    let result1 = evm.transact_one(tx1).unwrap();
    evm.ctx.journal_mut().commit_tx();

    // T2: plain legacy tx, no access list, same BALANCE(listed_addr) call.
    let tx2 = TxEnv {
        caller,
        kind: TxKind::Call(contract),
        gas_limit: 1_000_000,
        nonce: 1,
        ..Default::default()
    };

    let result2 = evm.transact_one(tx2).unwrap();
    evm.ctx.journal_mut().commit_tx();

    // T2 must pay the full cold-access cost for `listed_addr` - identical to
    // an ordinary address that was never access-listed by anyone (23603,
    // per the `ordinary_address_is_cold_every_tx` sibling test) - proving
    // T1's access list left no residual warmth behind.
    assert_eq!(
        result2.gas_used(),
        23603,
        "T2 (no access list of its own) must pay the full cold access cost for \
         `listed_addr`, not inherit warmth from T1's access list"
    );

    // T1 itself should be cheaper than a cold access by exactly 100 gas:
    // -2500 (BALANCE opcode now warm instead of cold) + 2400 (EIP-2930's
    // upfront per-address access-list declaration cost) = -100.
    assert_eq!(
        result1.gas_used(),
        23503,
        "T1's own access list should make its BALANCE access warm, net of the \
         upfront access-list declaration cost"
    );
}
