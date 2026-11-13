//! `BLOCKHASH` served from the EIP-2935 history contract (smr-moonshot#4887).
//!
//! With `BlockHashSource::HistoryContract` the host answers `BLOCKHASH(n)` from slot
//! `n % HISTORY_SERVE_WINDOW` of the history contract, through the journal first and without
//! warming the slot; a zero slot from the configured floor up is referred to
//! `Database::block_hash`. These tests run a probe contract that executes `BLOCKHASH(n)` and then calls
//! the history contract's `get(n)` twice, so each run shows both the hash and whether the
//! `BLOCKHASH` read warmed the contract's account or slot.

use crate::history_storage::{
    deploy_history_contract, execute_commit, hash_of, new_evm, write_history, TestError, TestEvm,
    SENDER,
};
use revm::{
    context::{Context, ContextSetters, ContextTr, TxEnv},
    context_interface::{
        cfg::{BlockHashSource, Cfg, ExecutionMode},
        result::{EVMError, ExecutionResult},
    },
    database::CacheDB,
    database_interface::DBErrorMarker,
    handler::{EthFrame, Handler, MainnetHandler},
    interpreter::interpreter::EthInterpreter,
    primitives::{
        address,
        eip2935::{HISTORY_SERVE_WINDOW, HISTORY_STORAGE_ADDRESS},
        hardfork::SpecId,
        Address, Bytes, TxKind, B256, U256,
    },
    state::{AccountInfo, Bytecode},
    DatabaseRef, ExecuteEvm, MainBuilder, MainContext,
};
use std::{error::Error, fmt};
use supra_extension::transactions::history_storage::history_storage_write_tx_env;

/// Address of the probe contract.
const PROBE: Address = address!("0x1000000000000000000000000000000000000010");

/// The difference in gas between the first and the second `get` call of the probe when the first
/// finds the history contract's account and slot cold: (2600 - 100) for the account (EIP-2929)
/// plus (2100 - 100) for the slot.
const COLD_MINUS_WARM: u64 = 2500 + 2000;

/// Runtime code of the probe. With the 32-byte word `n` as input it:
/// - stores `BLOCKHASH(n)` at memory 0x00 and `n` at 0x20;
/// - calls `get(n)` on the history contract with `STATICCALL`, writing the output to 0x40, and
///   stores the gas the call consumed at 0x60;
/// - calls `get(n)` again and stores the gas of the second call at 0x80;
/// - returns memory `[0x00, 0xa0)`.
fn probe_code() -> Bytes {
    // GAS, STATICCALL(GAS, history, 0x20, 0x20, 0x40, 0x20), POP, GAS, SWAP1, SUB, MSTORE(at)
    let measured_get = |at: u8| {
        let mut code = vec![
            0x5a, // GAS
            0x60, 0x20, // PUSH1 0x20  retLength
            0x60, 0x40, // PUSH1 0x40  retOffset
            0x60, 0x20, // PUSH1 0x20  argsLength
            0x60, 0x20, // PUSH1 0x20  argsOffset
            0x73, // PUSH20 history contract
        ];
        code.extend_from_slice(HISTORY_STORAGE_ADDRESS.as_slice());
        code.extend_from_slice(&[
            0x5a, // GAS
            0xfa, // STATICCALL
            0x50, // POP
            0x5a, // GAS
            0x90, // SWAP1
            0x03, // SUB
            0x60, at,   // PUSH1 at
            0x52, // MSTORE
        ]);
        code
    };
    let mut code = vec![
        // Expands memory to 0xa0 bytes first, so neither get call pays for memory expansion.
        0x5f, 0x60, 0x80, 0x52, // PUSH0 PUSH1 0x80 MSTORE
        0x5f, 0x35, // PUSH0 CALLDATALOAD          n
        0x80, // DUP1                              n n
        0x40, // BLOCKHASH                         h n
        0x5f, 0x52, // PUSH0 MSTORE                n
        0x60, 0x20, 0x52, // PUSH1 0x20 MSTORE
    ];
    code.extend(measured_get(0x60));
    code.extend(measured_get(0x80));
    code.extend_from_slice(&[
        0x60, 0xa0, // PUSH1 0xa0
        0x5f, // PUSH0
        0xf3, // RETURN
    ]);
    Bytes::from(code)
}

/// What one run of the probe returned.
#[derive(Debug)]
struct Probe {
    /// `BLOCKHASH(n)`.
    block_hash: B256,
    /// The output of the history contract's `get(n)`; zero if it reverted.
    get: B256,
    /// Gas consumed by the first `get` call.
    first_get_gas: u64,
    /// Gas consumed by the second `get` call.
    second_get_gas: u64,
}

impl Probe {
    fn decode(result: &ExecutionResult) -> Self {
        assert!(result.is_success(), "the probe must succeed: {result:?}");
        let out = result.output().expect("a call has output");
        assert_eq!(out.len(), 0xa0, "probe output: {out:?}");
        let word = |i: usize| B256::from_slice(&out[i * 32..(i + 1) * 32]);
        let gas = |i: usize| u64::try_from(U256::from_be_bytes(word(i).0)).expect("gas fits u64");
        Self {
            block_hash: word(0),
            get: word(2),
            first_get_gas: gas(3),
            second_get_gas: gas(4),
        }
    }

    /// Asserts that the first `get` call found the history contract's account and slot cold, so
    /// the `BLOCKHASH` read before it warmed neither.
    fn assert_history_was_cold(&self) {
        assert_eq!(
            self.first_get_gas - self.second_get_gas,
            COLD_MINUS_WARM,
            "the first get call must find the account and the slot cold: {self:?}"
        );
    }
}

/// A Prague EVM with the history contract deployed at genesis, the probe installed, and the block
/// hash source set to `source`.
fn new_probe_evm(source: BlockHashSource) -> TestEvm {
    let mut evm = new_evm();
    deploy_history_contract(&mut evm);
    evm.ctx.db_mut().insert_account_info(
        PROBE,
        AccountInfo::from_bytecode(Bytecode::new_raw(probe_code())),
    );
    evm.ctx.cfg.set_block_hash_source(source);
    evm
}

/// The probe call for `BLOCKHASH(n)` from [`SENDER`], with its committed nonce.
fn probe_tx(evm: &TestEvm, n: u64) -> TxEnv {
    let nonce = evm
        .ctx
        .db()
        .basic_ref(SENDER)
        .expect("in-memory read")
        .map_or(0, |info| info.nonce);
    TxEnv {
        caller: SENDER,
        nonce,
        kind: TxKind::Call(PROBE),
        data: Bytes::from(U256::from(n).to_be_bytes::<32>().to_vec()),
        gas_limit: 1_000_000,
        ..Default::default()
    }
}

/// Runs the probe for `BLOCKHASH(n)` in a User transaction in the block at `height`, and commits
/// it.
fn run_probe(evm: &mut TestEvm, height: u64, n: u64) -> Result<ExecutionResult, TestError> {
    evm.ctx.block.number = U256::from(height);
    let tx = probe_tx(evm, n);
    execute_commit(evm, ExecutionMode::User, tx)
}

/// The history write of the block at `height` and a later transaction of the same block share the
/// journal: the write is not in the database when the transaction runs. `BLOCKHASH(height - 1)` is
/// served from the journal, not from the stale value the database holds for the same slot, and
/// agrees with the contract's `get`.
#[test]
fn the_current_block_history_write_is_served_from_the_journal() {
    let height = 10;
    let mut evm = new_probe_evm(BlockHashSource::HistoryContract { floor: 0 });
    let slot = U256::from((height - 1) % HISTORY_SERVE_WINDOW);
    let stale = U256::from_be_bytes(B256::repeat_byte(0x5e).0);
    evm.ctx
        .db_mut()
        .insert_account_storage(HISTORY_STORAGE_ADDRESS, slot, stale)
        .expect("in-memory write");

    // The history write, left in the journal as the node leaves it until the block is finalized.
    evm.ctx.block.number = U256::from(height);
    evm.ctx.cfg.execution_mode = ExecutionMode::System;
    evm.ctx.set_tx(
        history_storage_write_tx_env(height, hash_of(height - 1)).expect("height has a parent"),
    );
    let mut handler = MainnetHandler::<TestEvm, TestError, EthFrame<EthInterpreter>>::default();
    handler
        .validate_caller(&evm)
        .expect("the system address is a System sender");
    let write = handler
        .run_system_call(&mut evm)
        .expect("the history write executes");
    assert!(write.is_success(), "{write:?}");
    assert_eq!(
        evm.ctx
            .db()
            .storage_ref(HISTORY_STORAGE_ADDRESS, slot)
            .expect("in-memory read"),
        stale,
        "the write is not in the database yet"
    );

    // A User transaction of the same block, in the same journal.
    evm.ctx.cfg.execution_mode = ExecutionMode::User;
    let tx = probe_tx(&evm, height - 1);
    let result = evm.transact_one(tx).expect("the probe executes");
    let probe = Probe::decode(&result);
    assert_eq!(probe.block_hash, hash_of(height - 1));
    assert_eq!(probe.get, hash_of(height - 1));
    probe.assert_history_was_cold();
    let _ = evm.finalize();
}

/// A hash committed to the database by an earlier block's history write is served, and the read
/// warms neither the history contract's account nor its slot.
#[test]
fn a_hash_in_the_database_is_served_without_warming() {
    let mut evm = new_probe_evm(BlockHashSource::HistoryContract { floor: 0 });
    for height in 1..=20 {
        write_history(&mut evm, height).expect("the write executes");
    }
    // In block 20, whose write has landed, ask for block 7.
    let probe = Probe::decode(&run_probe(&mut evm, 20, 7).expect("the probe executes"));
    assert_eq!(probe.block_hash, hash_of(7));
    assert_eq!(probe.get, hash_of(7));
    probe.assert_history_was_cold();
}

/// A zero slot for a block below the floor is a height no block of this EVM recorded: `BLOCKHASH`
/// returns zero and the transaction succeeds, although the database's `block_hash` is non-zero for
/// every height. The block just below the floor is the boundary.
#[test]
fn a_zero_slot_below_the_floor_is_a_zero_hash() {
    let mut evm = new_probe_evm(BlockHashSource::HistoryContract { floor: 50 });
    let result = run_probe(&mut evm, 50, 49).expect("the probe executes");
    let probe = Probe::decode(&result);
    assert_eq!(probe.block_hash, B256::ZERO);
}

/// The error of [`NoBlockHashesDb`]'s `block_hash`, carrying the height asked for.
#[derive(Debug, PartialEq, Eq)]
struct NoBlockHashes(u64);

impl fmt::Display for NoBlockHashes {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "no block hash for height {}", self.0)
    }
}

impl Error for NoBlockHashes {}

impl DBErrorMarker for NoBlockHashes {}

/// An empty backing database whose `block_hash` fails for every height, as a host database that
/// does not serve block hashes does.
#[derive(Debug, Default)]
struct NoBlockHashesDb;

impl DatabaseRef for NoBlockHashesDb {
    type Error = NoBlockHashes;

    fn basic_ref(&self, _address: Address) -> Result<Option<AccountInfo>, Self::Error> {
        Ok(None)
    }

    fn code_by_hash_ref(&self, _code_hash: B256) -> Result<Bytecode, Self::Error> {
        Ok(Bytecode::default())
    }

    fn storage_ref(&self, _address: Address, _index: U256) -> Result<U256, Self::Error> {
        Ok(U256::ZERO)
    }

    fn block_hash_ref(&self, number: u64) -> Result<B256, Self::Error> {
        Err(NoBlockHashes(number))
    }
}

/// The heights at or above the floor whose slot is zero, as `(floor, height of the block, n)`: the
/// floor itself, a height above it, and a height whose slot wraps (block 8191 + 9 reads slot 9).
const UNRECORDED: [(u64, u64, u64); 3] = [
    (49, 50, 49),
    (0, 50, 49),
    (0, HISTORY_SERVE_WINDOW + 10, HISTORY_SERVE_WINDOW + 9),
];

/// A zero slot for a block at or above the floor is referred to `Database::block_hash`, and
/// `BLOCKHASH` returns the database's hash.
#[test]
fn a_zero_slot_at_or_above_the_floor_returns_the_database_hash() {
    for (floor, height, n) in UNRECORDED {
        let mut evm = new_probe_evm(BlockHashSource::HistoryContract { floor });
        let from_database = B256::repeat_byte(0xdb);
        evm.ctx
            .db_mut()
            .cache
            .block_hashes
            .insert(U256::from(n), from_database);
        let result = run_probe(&mut evm, height, n).expect("the probe executes");
        let probe = Probe::decode(&result);
        assert_eq!(
            probe.block_hash, from_database,
            "floor {floor}, BLOCKHASH({n}) in block {height}"
        );
    }
}

/// A zero slot for a block at or above the floor is referred to `Database::block_hash`, and its
/// error fails the transaction as a database error.
#[test]
fn a_zero_slot_at_or_above_the_floor_returns_the_database_error() {
    for (floor, height, n) in UNRECORDED {
        // The history contract and the probe are set up over the usual database, whose cache then
        // moves over the database that does not serve block hashes.
        let source = new_probe_evm(BlockHashSource::HistoryContract { floor });
        let tx = probe_tx(&source, n);
        let db = CacheDB {
            cache: source.ctx.db().cache.clone(),
            db: NoBlockHashesDb,
        };
        let mut evm = Context::mainnet()
            .modify_cfg_chained(|cfg| {
                cfg.spec = SpecId::PRAGUE;
                cfg.set_block_hash_source(BlockHashSource::HistoryContract { floor });
            })
            .modify_block_chained(|block| block.number = U256::from(height))
            .with_db(db)
            .build_mainnet();

        let result = evm.transact(tx);
        assert!(
            matches!(&result, Err(EVMError::Database(NoBlockHashes(asked))) if *asked == n),
            "floor {floor}, BLOCKHASH({n}) in block {height}: got {result:?}"
        );
    }
}

/// The default source is `Database::block_hash`; the history contract is not read.
#[test]
fn the_database_source_reads_the_database_block_hash() {
    assert_eq!(
        new_evm().ctx.cfg.block_hash_source(),
        BlockHashSource::Database
    );

    let mut evm = new_evm();
    deploy_history_contract(&mut evm);
    evm.ctx.db_mut().insert_account_info(
        PROBE,
        AccountInfo::from_bytecode(Bytecode::new_raw(probe_code())),
    );
    for height in 1..=20 {
        write_history(&mut evm, height).expect("the write executes");
    }
    let from_database = B256::repeat_byte(0xdb);
    evm.ctx
        .db_mut()
        .cache
        .block_hashes
        .insert(U256::from(7), from_database);

    let probe = Probe::decode(&run_probe(&mut evm, 20, 7).expect("the probe executes"));
    assert_eq!(probe.block_hash, from_database);
    assert_eq!(probe.get, hash_of(7), "the ring holds the other hash");
}

/// The opcode returns zero without asking the host for the current block, a future block, and a
/// block more than 256 blocks back. With an empty ring and floor 0 the host would refer each of
/// these to the database, whose `block_hash` is non-zero for every height.
#[test]
fn heights_outside_the_256_block_range_are_zero_without_a_host_read() {
    let height = 1000;
    for n in [height, height + 1, height - 257, 0] {
        let mut evm = new_probe_evm(BlockHashSource::HistoryContract { floor: 0 });
        let result = run_probe(&mut evm, height, n).expect("the probe executes");
        let probe = Probe::decode(&result);
        assert_eq!(
            probe.block_hash,
            B256::ZERO,
            "BLOCKHASH({n}) in block {height}"
        );
    }

    // The oldest height in the range is asked of the host: its slot is zero, so the host refers it
    // to the database.
    let n = height - 256;
    let mut evm = new_probe_evm(BlockHashSource::HistoryContract { floor: 0 });
    let from_database = B256::repeat_byte(0xdb);
    evm.ctx
        .db_mut()
        .cache
        .block_hashes
        .insert(U256::from(n), from_database);
    let probe = Probe::decode(&run_probe(&mut evm, height, n).expect("the probe executes"));
    assert_eq!(
        probe.block_hash, from_database,
        "BLOCKHASH({n}) in block {height}"
    );
}
