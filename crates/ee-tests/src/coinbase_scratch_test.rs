use revm::{
    context::ContextTr,
    context::TxEnv,
    database::{CacheDB, EmptyDB},
    primitives::{address, hardfork::SpecId, Address, Bytes, TxKind, U256},
    state::AccountInfo,
    Context, ExecuteEvm, MainBuilder, MainContext,
};

/// Deploys `PUSH20 <target>; BALANCE; STOP` - a contract whose only job is
/// to report the gas cost of a single BALANCE access to `target`.
fn balance_check_bytecode(target: Address) -> Vec<u8> {
    let mut code = vec![0x73]; // PUSH20
    code.extend_from_slice(target.as_slice());
    code.push(0x31); // BALANCE
    code.push(0x00); // STOP
    code
}

fn setup_evm(
    caller: Address,
    contract: Address,
    balance_target: Address,
) -> revm::MainnetEvm<Context<revm::context::BlockEnv, revm::context::TxEnv, revm::context::CfgEnv, CacheDB<EmptyDB>>> {
    let mut db = CacheDB::new(EmptyDB::default());

    db.insert_account_info(
        caller,
        AccountInfo {
            balance: U256::from(10_u128.pow(18)),
            ..Default::default()
        },
    );

    let code = balance_check_bytecode(balance_target);
    db.insert_account_info(
        contract,
        AccountInfo {
            code_hash: revm::primitives::keccak256(&code),
            code: Some(revm::bytecode::Bytecode::new_raw(Bytes::from(code))),
            ..Default::default()
        },
    );

    Context::mainnet()
        .with_db(db)
        .modify_cfg_chained(|cfg| cfg.spec = SpecId::PRAGUE)
        .build_mainnet()
}

/// Regression test for the reviewer-reported gas deviation: EIP-3651 makes
/// COINBASE warm at the start of *every* transaction. In revm's
/// single-journal, multi-tx execution mode (`commit_tx()` between
/// transactions sharing one journal), the coinbase account gets inserted
/// into `state` by the first transaction that touches it, and every later
/// transaction's access went through `load_account_optional`'s `Occupied`
/// branch - which only checked the account's own stale `transaction_id`
/// stamp, never the perpetually-pre-warmed `warm_addresses` set. So every
/// transaction after the first paid a full cold access (2600 gas) for
/// COINBASE instead of the warm 100 gas EIP-3651 guarantees.
#[test]
fn coinbase_stays_warm_across_consecutive_txs() {
    let caller = address!("1000000000000000000000000000000000000000");
    let coinbase = Address::ZERO;
    let contract = address!("3000000000000000000000000000000000000000");

    let mut evm = setup_evm(caller, contract, coinbase);

    let mut tx = TxEnv {
        caller,
        kind: TxKind::Call(contract),
        ..Default::default()
    };

    let result1 = evm.transact_one(tx.clone()).unwrap();
    evm.ctx.journal_mut().commit_tx();

    tx.nonce = 1;
    let result2 = evm.transact_one(tx).unwrap();
    evm.ctx.journal_mut().commit_tx();

    assert_eq!(
        result1.gas_used(),
        result2.gas_used(),
        "gas used must be identical for two identical contract calls in the same block - \
         COINBASE must be warm at the start of every transaction, per EIP-3651"
    );
}

/// Companion to the test above: guards against an over-broad fix. Ordinary
/// addresses (not COINBASE, not a precompile) must still correctly reset to
/// cold at the start of every transaction, per standard EIP-2929 semantics -
/// warmth from an earlier transaction touching the same address must not
/// leak into a later one just because the account object persists in the
/// shared journal's `state` map.
#[test]
fn ordinary_address_is_cold_every_tx() {
    let caller = address!("1000000000000000000000000000000000000000");
    let ordinary = address!("4444444444444444444444444444444444444444");
    let contract = address!("3000000000000000000000000000000000000000");

    let mut evm = setup_evm(caller, contract, ordinary);

    let mut tx = TxEnv {
        caller,
        kind: TxKind::Call(contract),
        ..Default::default()
    };

    let result1 = evm.transact_one(tx.clone()).unwrap();
    evm.ctx.journal_mut().commit_tx();

    tx.nonce = 1;
    let result2 = evm.transact_one(tx).unwrap();
    evm.ctx.journal_mut().commit_tx();

    assert_eq!(
        result1.gas_used(),
        result2.gas_used(),
        "an ordinary address should cost the same (cold) in both transactions"
    );
    assert_eq!(
        result1.gas_used(),
        23603,
        "sanity: this must be the COLD BALANCE cost, not the warm one - otherwise this test \
         would pass even if the fix incorrectly made every address stay warm across transactions"
    );
}