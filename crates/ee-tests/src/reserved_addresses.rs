//! Supra reserved addresses inside execution (smr-moonshot#3117).
//!
//! The reserved range is `0x…53555000`–`0x…535550FF`. Inside execution, in every execution mode:
//! - bytecode never executes at a reserved address, whether as the executing account or as the
//!   account the code is loaded from;
//! - bytecode at a reserved address is never the target of an EIP-7702 delegation;
//! - value reaches a reserved address only through a call to a precompile registered there whose
//!   provider declares, through `PrecompileProvider::accepts_value`, that it accepts value;
//! - a reserved address is never the beneficiary of `SELFDESTRUCT`.
//!
//! Every refusal reports `ReservedAddressTarget`. `VM_SIGNER` remains the `msg.sender` that a
//! System transaction's `DELEGATECALL` preserves.

use revm::{
    bytecode::opcode,
    context::{Context, ContextTr, TxEnv},
    context_interface::{
        cfg::ExecutionMode,
        result::{EVMError, ExecutionResult, HaltReason},
    },
    database::{CacheDB, EmptyDB},
    handler::{EthPrecompiles, PrecompileProvider},
    interpreter::{InputsImpl, InterpreterResult},
    precompile::{Precompile, PrecompileId, PrecompileOutput, PrecompileResult, Precompiles},
    primitives::{
        address, b256,
        hardfork::SpecId,
        supra_constants::{u64_to_address, TX_HASH_ADDRESS, VM_SIGNER},
        Address, Bytes, TxKind, B256, U256,
    },
    state::{AccountInfo, Bytecode},
    ExecuteEvm, MainBuilder, MainContext,
};
use std::{convert::Infallible, sync::OnceLock};

/// A reserved address with a precompile registered by [`precompiles`] that
/// [`TestPrecompiles`] declares value-accepting. It stands in for a node-defined precompile that
/// accounts for the value it receives.
const RESERVED_PRECOMPILE: Address = u64_to_address(0x5355_5002);

/// A reserved address with a precompile registered by [`precompiles`] that does not accept
/// value. It stands in for a node-defined precompile that only reads.
const RESERVED_READ_ONLY_PRECOMPILE: Address = u64_to_address(0x5355_5003);

/// The last address of the reserved range. Nothing is registered there.
const RESERVED_UNASSIGNED: Address = u64_to_address(0x5355_50FF);

/// Reserved addresses seeded with code by the tests: plain bytecode, an EIP-7702 delegation
/// designation to an account with code, and one to an account without code.
const RESERVED_WITH_CODE: Address = u64_to_address(0x5355_5005);
const RESERVED_WITH_DELEGATION: Address = u64_to_address(0x5355_5006);
const RESERVED_WITH_EMPTY_DELEGATION: Address = u64_to_address(0x5355_5007);

/// The addresses on either side of the reserved range.
const BELOW_RESERVED: Address = u64_to_address(0x5355_4FFF);
const ABOVE_RESERVED: Address = u64_to_address(0x5355_5100);

/// Sender of every transaction except a System one, whose sender is `VM_SIGNER`.
const SENDER: Address = address!("0x1000000000000000000000000000000000000001");
/// The contract a test's transaction calls.
const ENTRY: Address = address!("0x1000000000000000000000000000000000000002");
/// A contract the entry contract calls or delegates to.
const CALLEE: Address = address!("0x1000000000000000000000000000000000000003");
/// An account outside the reserved range whose EIP-7702 delegation designation points to
/// [`RESERVED_WITH_CODE`].
const DELEGATING_TO_RESERVED: Address = address!("0x1000000000000000000000000000000000000004");
/// An account outside the reserved range that never holds code.
const EMPTY_ACCOUNT: Address = address!("0x1000000000000000000000000000000000000005");

/// Balance of every funded account.
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

/// The Prague precompile set, which includes the transaction-hash precompile, with precompiles
/// added at [`RESERVED_PRECOMPILE`] and [`RESERVED_READ_ONLY_PRECOMPILE`] that return no output
/// and accept any input.
fn precompiles() -> &'static Precompiles {
    static PRECOMPILES: OnceLock<Precompiles> = OnceLock::new();
    PRECOMPILES.get_or_init(|| {
        fn accept(_input: &[u8], _gas_limit: u64) -> PrecompileResult {
            Ok(PrecompileOutput::new(0, Bytes::new()))
        }
        let mut precompiles = Precompiles::prague().clone();
        precompiles.extend([
            Precompile::new(
                PrecompileId::custom("reserved-test"),
                RESERVED_PRECOMPILE,
                accept,
            ),
            Precompile::new(
                PrecompileId::custom("reserved-read-only-test"),
                RESERVED_READ_ONLY_PRECOMPILE,
                accept,
            ),
        ]);
        precompiles
    })
}

/// [`EthPrecompiles`] over [`precompiles`], with [`RESERVED_PRECOMPILE`] declared
/// value-accepting, as a node's provider declares its settlement precompile. Every other method
/// is delegated unchanged, so the remaining reserved precompiles keep the default of accepting
/// no value.
struct TestPrecompiles(EthPrecompiles);

impl<CTX: ContextTr> PrecompileProvider<CTX> for TestPrecompiles {
    type Output = InterpreterResult;

    fn set_spec(&mut self, spec: <CTX::Cfg as revm::context::Cfg>::Spec) -> bool {
        <EthPrecompiles as PrecompileProvider<CTX>>::set_spec(&mut self.0, spec)
    }

    fn run(
        &mut self,
        context: &mut CTX,
        address: &Address,
        inputs: &InputsImpl,
        is_static: bool,
        gas_limit: u64,
    ) -> Result<Option<Self::Output>, String> {
        self.0.run(context, address, inputs, is_static, gas_limit)
    }

    fn warm_addresses(&self) -> Box<impl Iterator<Item = Address>> {
        self.0.warm_addresses()
    }

    fn contains(&self, address: &Address) -> bool {
        self.0.contains(address)
    }

    fn accepts_value(&self, address: &Address) -> bool {
        *address == RESERVED_PRECOMPILE
    }
}

/// Code that calls `target` with `op` and returns 64 bytes: the first 32 bytes the callee
/// returned (zero if it returned none), then the call's success flag.
///
/// `value` is passed for `CALL` and `CALLCODE` and ignored for `DELEGATECALL` and `STATICCALL`,
/// which take no value operand.
fn call_and_report(op: u8, target: Address, value: U256) -> Bytecode {
    // Operands are pushed in reverse: retSize, retOffset, argsSize, argsOffset, [value,] address,
    // gas.
    let mut code = vec![
        opcode::PUSH1,
        32,
        opcode::PUSH1,
        0,
        opcode::PUSH1,
        0,
        opcode::PUSH1,
        0,
    ];
    if matches!(op, opcode::CALL | opcode::CALLCODE) {
        code.push(opcode::PUSH32);
        code.extend_from_slice(&value.to_be_bytes::<32>());
    }
    code.push(opcode::PUSH20);
    code.extend_from_slice(target.as_slice());
    code.push(opcode::GAS);
    code.push(op);
    // Store the success flag after the returned word, and return both.
    code.extend_from_slice(&[
        opcode::PUSH1,
        32,
        opcode::MSTORE,
        opcode::PUSH1,
        64,
        opcode::PUSH1,
        0,
        opcode::RETURN,
    ]);
    Bytecode::new_raw(Bytes::from(code))
}

/// Code that self-destructs to `beneficiary`.
fn selfdestruct_to(beneficiary: Address) -> Bytecode {
    let mut code = vec![opcode::PUSH20];
    code.extend_from_slice(beneficiary.as_slice());
    code.push(opcode::SELFDESTRUCT);
    Bytecode::new_raw(Bytes::from(code))
}

/// Code that returns `msg.sender` as a 32-byte word.
fn return_caller() -> Bytecode {
    Bytecode::new_raw(Bytes::from_static(&[
        opcode::CALLER,
        opcode::PUSH1,
        0,
        opcode::MSTORE,
        opcode::PUSH1,
        32,
        opcode::PUSH1,
        0,
        opcode::RETURN,
    ]))
}

/// A database with both senders funded, the entry contract funded with `entry_code`, and every
/// account in `accounts` holding the given code and no balance.
fn db_with(entry_code: Bytecode, accounts: &[(Address, Bytecode)]) -> CacheDB<EmptyDB> {
    let mut db = CacheDB::new(EmptyDB::new());
    for sender in [SENDER, VM_SIGNER] {
        db.insert_account_info(
            sender,
            AccountInfo {
                balance: U256::from(FUNDS),
                ..Default::default()
            },
        );
    }
    db.insert_account_info(
        ENTRY,
        AccountInfo {
            balance: U256::from(FUNDS),
            code_hash: entry_code.hash_slow(),
            code: Some(entry_code),
            ..Default::default()
        },
    );
    for (addr, code) in accounts {
        db.insert_account_info(
            *addr,
            AccountInfo {
                code_hash: code.hash_slow(),
                code: Some(code.clone()),
                ..Default::default()
            },
        );
    }
    db
}

/// The outcome of one transaction, with the balances of the accounts the test asked about as
/// they stand afterwards: from the journal for an account the run loaded, and from the database
/// for one it did not.
struct Run {
    result: Result<ExecutionResult, EVMError<Infallible>>,
    balances: Vec<U256>,
    entry_code: Option<Bytecode>,
}

impl Run {
    /// The successful result, panicking with `context` if the transaction did not succeed.
    fn success(&self, context: &str) -> &ExecutionResult {
        match &self.result {
            Ok(result) if result.is_success() => result,
            other => panic!("{context}: expected success, got {other:?}"),
        }
    }

    /// The word the entry contract's callee returned, and the call's success flag.
    fn reported(&self, context: &str) -> (B256, bool) {
        let output = self
            .success(context)
            .output()
            .expect("a successful call carries output");
        assert_eq!(output.len(), 64, "{context}: unexpected output {output}");
        let flag = U256::from_be_slice(&output[32..]);
        assert!(flag <= U256::from(1), "{context}: flag {flag}");
        (B256::from_slice(&output[..32]), flag == U256::from(1))
    }

    /// Asserts that the transaction halted with `ReservedAddressTarget`.
    fn assert_reserved_halt(&self, context: &str) {
        assert!(
            matches!(
                &self.result,
                Ok(ExecutionResult::Halt {
                    reason: HaltReason::ReservedAddressTarget,
                    ..
                })
            ),
            "{context}: expected a ReservedAddressTarget halt, got {:?}",
            self.result
        );
    }
}

/// Runs one transaction in `mode` from the sender that mode admits, to `to` with `value`, and
/// reports the journal balances of `watched`.
fn run(
    mode: ExecutionMode,
    db: CacheDB<EmptyDB>,
    to: Address,
    value: U256,
    tx_hash: B256,
    watched: &[Address],
) -> Run {
    let caller = if mode.is_system() { VM_SIGNER } else { SENDER };
    let initial_balances: Vec<U256> = watched
        .iter()
        .map(|addr| {
            db.cache
                .accounts
                .get(addr)
                .map(|account| account.info.balance)
                .unwrap_or_default()
        })
        .collect();
    let mut evm = Context::mainnet()
        .modify_cfg_chained(|cfg| {
            cfg.spec = SpecId::PRAGUE;
            cfg.execution_mode = mode;
        })
        .with_db(db)
        .build_mainnet()
        .with_precompiles(TestPrecompiles(EthPrecompiles {
            precompiles: precompiles(),
            spec: SpecId::PRAGUE,
        }));
    let result = evm.transact_one(TxEnv {
        caller,
        kind: TxKind::Call(to),
        value,
        gas_limit: 1_000_000,
        tx_hash,
        ..Default::default()
    });
    let state = &evm.ctx.journal_mut().state;
    let balances = watched
        .iter()
        .zip(initial_balances)
        .map(|(addr, initial)| {
            state
                .get(addr)
                .map_or(initial, |account| account.info.balance)
        })
        .collect();
    let entry_code = state
        .get(&ENTRY)
        .and_then(|account| account.info.code.clone());
    Run {
        result,
        balances,
        entry_code,
    }
}

/// An inner `CALL` that moves value to a reserved address with no value-accepting precompile is
/// refused in every mode, and no value moves. This includes reserved precompiles that the
/// provider does not declare value-accepting.
#[test]
fn inner_value_call_to_a_reserved_address_is_refused_in_every_mode() {
    for target in [
        VM_SIGNER,
        TX_HASH_ADDRESS,
        RESERVED_READ_ONLY_PRECOMPILE,
        RESERVED_UNASSIGNED,
    ] {
        for mode in ALL_MODES {
            let context = format!("{mode:?} CALL with value to {target}");
            let run = run(
                mode,
                db_with(call_and_report(opcode::CALL, target, U256::from(1)), &[]),
                ENTRY,
                U256::ZERO,
                B256::ZERO,
                &[ENTRY, target],
            );
            let (_, called) = run.reported(&context);
            assert!(!called, "{context}: the call must fail");
            // `VM_SIGNER` is also a funded sender in this database.
            let target_funds = if target == VM_SIGNER {
                U256::from(FUNDS)
            } else {
                U256::ZERO
            };
            assert_eq!(
                run.balances,
                [U256::from(FUNDS), target_funds],
                "{context}: no value may move"
            );
        }
    }
}

/// A zero-value `CALL` to `VM_SIGNER` moves nothing and runs no code, and succeeds.
#[test]
fn zero_value_call_to_vm_signer_succeeds() {
    let run = run(
        ExecutionMode::User,
        db_with(call_and_report(opcode::CALL, VM_SIGNER, U256::ZERO), &[]),
        ENTRY,
        U256::ZERO,
        B256::ZERO,
        &[],
    );
    let (_, called) = run.reported("zero-value CALL to VM_SIGNER");
    assert!(called);
}

/// Value reaches a reserved precompile that the provider declares value-accepting, in every mode
/// that keeps its changes.
#[test]
fn value_call_to_a_precompile_at_a_reserved_address_is_accepted() {
    for mode in ALL_MODES.into_iter().filter(|mode| !mode.is_read_only()) {
        let context = format!("{mode:?} CALL with value to the reserved precompile");
        let run = run(
            mode,
            db_with(
                call_and_report(opcode::CALL, RESERVED_PRECOMPILE, U256::from(1)),
                &[],
            ),
            ENTRY,
            U256::ZERO,
            B256::ZERO,
            &[RESERVED_PRECOMPILE],
        );
        let (_, called) = run.reported(&context);
        assert!(called, "{context}: the call must succeed");
        assert_eq!(run.balances, [U256::from(1)], "{context}");
    }
}

/// Value reaches the addresses on either side of the reserved range.
#[test]
fn value_call_outside_the_reserved_range_is_accepted() {
    for target in [BELOW_RESERVED, ABOVE_RESERVED] {
        let context = format!("CALL with value to {target}");
        let run = run(
            ExecutionMode::User,
            db_with(call_and_report(opcode::CALL, target, U256::from(1)), &[]),
            ENTRY,
            U256::ZERO,
            B256::ZERO,
            &[target],
        );
        let (_, called) = run.reported(&context);
        assert!(called, "{context}: the call must succeed");
        assert_eq!(run.balances, [U256::from(1)], "{context}");
    }
}

/// A transaction that sends value to `VM_SIGNER` halts, and no value moves.
#[test]
fn transaction_value_to_vm_signer_is_refused() {
    let run = run(
        ExecutionMode::User,
        db_with(return_caller(), &[]),
        VM_SIGNER,
        U256::from(1),
        B256::ZERO,
        &[SENDER, VM_SIGNER],
    );
    run.assert_reserved_halt("transaction with value to VM_SIGNER");
    // The gas price is zero, so the sender pays nothing for the halted transaction.
    assert_eq!(run.balances, [U256::from(FUNDS), U256::from(FUNDS)]);
}

/// `STATICCALL` to the transaction-hash precompile returns the transaction hash.
#[test]
fn staticcall_to_the_tx_hash_precompile_returns_the_hash() {
    let tx_hash = b256!("0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    let run = run(
        ExecutionMode::User,
        db_with(
            call_and_report(opcode::STATICCALL, TX_HASH_ADDRESS, U256::ZERO),
            &[],
        ),
        ENTRY,
        U256::ZERO,
        tx_hash,
        &[],
    );
    let (word, called) = run.reported("STATICCALL to TX_HASH");
    assert!(called);
    assert_eq!(word, tx_hash);
}

/// Every call opcode, used by [`bytecode_at_a_reserved_address_never_executes`].
const CALL_OPS: [u8; 4] = [
    opcode::CALL,
    opcode::CALLCODE,
    opcode::DELEGATECALL,
    opcode::STATICCALL,
];

/// Accounts seeded by the bytecode tests: code at a reserved address, reserved delegation
/// designations to an account with code and to one without, and an ordinary account delegating
/// to the reserved code.
fn code_accounts() -> [(Address, Bytecode); 5] {
    [
        (RESERVED_WITH_CODE, return_caller()),
        (RESERVED_WITH_DELEGATION, Bytecode::new_eip7702(CALLEE)),
        (
            RESERVED_WITH_EMPTY_DELEGATION,
            Bytecode::new_eip7702(EMPTY_ACCOUNT),
        ),
        (
            DELEGATING_TO_RESERVED,
            Bytecode::new_eip7702(RESERVED_WITH_CODE),
        ),
        (CALLEE, return_caller()),
    ]
}

/// Code at a reserved address never executes, in every mode, whether reached as the
/// transaction's target or through any call opcode: plain code, a reserved delegation
/// designation (whatever it points to, including an account without code), and an ordinary
/// account's delegation designation that points to reserved code.
#[test]
fn bytecode_at_a_reserved_address_never_executes() {
    for target in [
        RESERVED_WITH_CODE,
        RESERVED_WITH_DELEGATION,
        RESERVED_WITH_EMPTY_DELEGATION,
        DELEGATING_TO_RESERVED,
    ] {
        for mode in ALL_MODES {
            let context = format!("{mode:?} transaction to {target}");
            run(
                mode.clone(),
                db_with(return_caller(), &code_accounts()),
                target,
                U256::ZERO,
                B256::ZERO,
                &[],
            )
            .assert_reserved_halt(&context);

            for op in CALL_OPS {
                let context = format!("{mode:?} {} to {target}", opcode::OpCode::name_by_op(op));
                let run = run(
                    mode.clone(),
                    db_with(call_and_report(op, target, U256::ZERO), &code_accounts()),
                    ENTRY,
                    U256::ZERO,
                    B256::ZERO,
                    &[],
                );
                let (word, called) = run.reported(&context);
                assert!(!called, "{context}: the call must fail");
                assert_eq!(
                    word,
                    B256::ZERO,
                    "{context}: the callee must return nothing"
                );
            }
        }
    }
}

/// An ordinary account's EIP-7702 delegation to code outside the reserved range still executes,
/// and a delegation to a reserved address without code executes nothing and succeeds, as a
/// delegation to any empty account does.
#[test]
fn delegation_outside_reserved_code_is_executed() {
    const DELEGATING_TO_CALLEE: Address = address!("0x1000000000000000000000000000000000000006");
    const DELEGATING_TO_EMPTY_RESERVED: Address =
        address!("0x1000000000000000000000000000000000000007");
    let accounts = [
        (CALLEE, return_caller()),
        (DELEGATING_TO_CALLEE, Bytecode::new_eip7702(CALLEE)),
        (
            DELEGATING_TO_EMPTY_RESERVED,
            Bytecode::new_eip7702(RESERVED_UNASSIGNED),
        ),
    ];

    let run_code = run(
        ExecutionMode::User,
        db_with(
            call_and_report(opcode::CALL, DELEGATING_TO_CALLEE, U256::ZERO),
            &accounts,
        ),
        ENTRY,
        U256::ZERO,
        B256::ZERO,
        &[],
    );
    let (word, called) = run_code.reported("CALL to an account delegating to CALLEE");
    assert!(called);
    assert_eq!(word, ENTRY.into_word(), "the delegated code must run");

    let run_empty = run(
        ExecutionMode::User,
        db_with(
            call_and_report(opcode::CALL, DELEGATING_TO_EMPTY_RESERVED, U256::ZERO),
            &accounts,
        ),
        ENTRY,
        U256::ZERO,
        B256::ZERO,
        &[],
    );
    let (word, called) =
        run_empty.reported("CALL to an account delegating to an empty reserved address");
    assert!(called);
    assert_eq!(word, B256::ZERO);
}

/// In a System transaction, a contract's `DELEGATECALL` keeps `VM_SIGNER` as `msg.sender`.
#[test]
fn system_delegatecall_keeps_vm_signer_as_msg_sender() {
    let run = run(
        ExecutionMode::System,
        db_with(
            call_and_report(opcode::DELEGATECALL, CALLEE, U256::ZERO),
            &[(CALLEE, return_caller())],
        ),
        ENTRY,
        U256::ZERO,
        B256::ZERO,
        &[],
    );
    let (word, called) = run.reported("System DELEGATECALL");
    assert!(called);
    assert_eq!(word, VM_SIGNER.into_word());
}

/// `SELFDESTRUCT` to a reserved beneficiary, including a registered precompile, halts in every
/// mode: the contract keeps its code and balance, and the beneficiary receives nothing. A caller
/// of the self-destructing contract sees the call fail.
#[test]
fn selfdestruct_to_a_reserved_beneficiary_is_refused_in_every_mode() {
    for beneficiary in [
        VM_SIGNER,
        TX_HASH_ADDRESS,
        RESERVED_PRECOMPILE,
        RESERVED_UNASSIGNED,
    ] {
        // `VM_SIGNER` is also a funded sender in this database.
        let beneficiary_funds = if beneficiary == VM_SIGNER {
            U256::from(FUNDS)
        } else {
            U256::ZERO
        };
        for mode in ALL_MODES {
            let context = format!("{mode:?} SELFDESTRUCT to {beneficiary}");
            let code = selfdestruct_to(beneficiary);
            let run_top = run(
                mode.clone(),
                db_with(code.clone(), &[]),
                ENTRY,
                U256::ZERO,
                B256::ZERO,
                &[ENTRY, beneficiary],
            );
            run_top.assert_reserved_halt(&context);
            assert_eq!(
                run_top.balances,
                [U256::from(FUNDS), beneficiary_funds],
                "{context}: no value may move"
            );
            // A refused SELFDESTRUCT leaves the code in place. In ReadOnly the run is discarded,
            // so the journal no longer holds the account.
            if !mode.is_read_only() {
                assert_eq!(run_top.entry_code, Some(code.clone()), "{context}");
            }

            let context =
                format!("{mode:?} CALL to a contract that self-destructs to {beneficiary}");
            let run_inner = run(
                mode.clone(),
                db_with(
                    call_and_report(opcode::CALL, CALLEE, U256::ZERO),
                    &[(CALLEE, code)],
                ),
                ENTRY,
                U256::ZERO,
                B256::ZERO,
                &[beneficiary],
            );
            let (_, called) = run_inner.reported(&context);
            assert!(!called, "{context}: the call must fail");
            assert_eq!(run_inner.balances, [beneficiary_funds], "{context}");
        }
    }
}

/// `SELFDESTRUCT` to an address on either side of the reserved range credits the beneficiary.
#[test]
fn selfdestruct_outside_the_reserved_range_is_executed() {
    for beneficiary in [BELOW_RESERVED, ABOVE_RESERVED] {
        let context = format!("SELFDESTRUCT to {beneficiary}");
        let run = run(
            ExecutionMode::User,
            db_with(selfdestruct_to(beneficiary), &[]),
            ENTRY,
            U256::ZERO,
            B256::ZERO,
            &[ENTRY, beneficiary],
        );
        run.success(&context);
        assert_eq!(
            run.balances,
            [U256::ZERO, U256::from(FUNDS)],
            "{context}: the balance moves to the beneficiary"
        );
    }
}
