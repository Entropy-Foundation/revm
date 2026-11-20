//! Administration of the automation registry Diamond as genesis deploys it
//! (Entropy-Foundation/smr-moonshot#4975).
//!
//! These tests run every genesis transaction `supra_extension` generates, in
//! `ExecutionMode::Genesis`, and then administer the Diamond the way the chain does: the foundation
//! multisig wallet, which genesis makes the Diamond's owner, submits and executes the owner-only
//! calls, and every other account sends ordinary `User` transactions. In release-profile builds
//! this is the shipped genesis bytecode: `supra_contracts` is compiled with the `production`
//! Foundry profile only when Cargo's profile is release, and with the `default` profile otherwise.
//!
//! The rules they state:
//! - ownership moves in two steps: `transferOwnership` nominates, the nominee's `acceptOwnership`
//!   completes, and only the nominee can complete;
//! - a `diamondCut` Remove action naming an administration selector is refused.

use alloy_sol_types::{sol, SolCall, SolError};
use revm::{
    context::{Context, ContextTr, TxEnv},
    context_interface::{cfg::ExecutionMode, result::ExecutionResult},
    database::{CacheDB, EmptyDB},
    handler::{MainnetContext, MainnetEvm},
    primitives::{address, hardfork::SpecId, Address, Bytes, TxKind, U256},
    state::AccountInfo,
    DatabaseRef, ExecuteCommitEvm, ExecuteEvm, MainBuilder, MainContext,
};
use supra_extension::contracts::{
    configs::{AutomationRegistryConfigV1, GenesisTransactionGeneratorConfig},
    generator::GenesisTransactionGenerator,
    transaction::GenesisTransactionTags,
};

sol! {
    /// The Diamond's ownership API: IERC173 plus IOwnable2Step.
    interface IDiamondOwnership {
        function owner() external view returns (address);
        function pendingOwner() external view returns (address);
        function transferOwnership(address newOwner) external;
        function acceptOwnership() external;
    }

    /// ERC-165, served by the Diamond's DiamondLoupeFacet.
    interface IERC165 {
        function supportsInterface(bytes4 interfaceId) external view returns (bool);
    }

    /// EIP-2535 diamondCut, served by the Diamond's DiamondCutFacet.
    interface IDiamondCut {
        enum FacetCutAction { Add, Replace, Remove }
        struct FacetCut {
            address facetAddress;
            FacetCutAction action;
            bytes4[] functionSelectors;
        }
        function diamondCut(FacetCut[] calldata cut, address init, bytes calldata data) external;
    }

    /// The part of the foundation wallet's API a governance action goes through.
    interface IMultiSignatureWallet {
        function submitTransaction(address to, uint256 value, uint64 timeoutDuration, bytes data) external payable;
        function executeTransaction(uint256 txIndex, bytes32 contentHash) external returns (bytes memory);
        function getNextTransactionIndex() external view returns (uint256);
        function hashTransactionContent(address to, uint256 value, bytes data) external pure returns (bytes32);
    }

    /// LibDiamond's errors these tests expect.
    error MustBeContractOwner();
    error MustBePendingOwner();
    error CannotRemoveProtectedFunction(bytes4 selector);

    /// MultiSignatureWallet's wrapper around a reverted governance call.
    error ExecutionFailed(bytes data);
}

/// The single owner of the foundation wallet in these tests, with a threshold of one, so that a
/// submission by this account is also the confirmation that lets it execute.
const WALLET_OWNER: Address = address!("0x2000000000000000000000000000000000000001");
/// The account the foundation wallet nominates as the Diamond's next owner.
const NOMINEE: Address = address!("0x2000000000000000000000000000000000000002");
/// An account with no role.
const STRANGER: Address = address!("0x2000000000000000000000000000000000000003");
/// Balance of each test account; ample for the transactions they send.
const FUNDS: u128 = 1_000_000_000_000_000_000_000;
/// Gas limit of every transaction here; the Diamond's deployment is the largest of them.
const GAS_LIMIT: u64 = 30_000_000;
/// Block timestamp the tests run at. Genesis starts the first automation cycle at this time.
const TIMESTAMP: u64 = 1_700_000_000;
/// Governance timeout the wallet submissions use; within the wallet's default maximum.
const SUBMISSION_TIMEOUT_SECS: u64 = 3_600;
/// ERC-165 identifier of IOwnable2Step: `pendingOwner() ^ acceptOwnership()`.
const IOWNABLE2STEP_INTERFACE_ID: [u8; 4] = xor_selectors(
    IDiamondOwnership::pendingOwnerCall::SELECTOR,
    IDiamondOwnership::acceptOwnershipCall::SELECTOR,
);

const fn xor_selectors(a: [u8; 4], b: [u8; 4]) -> [u8; 4] {
    [a[0] ^ b[0], a[1] ^ b[1], a[2] ^ b[2], a[3] ^ b[3]]
}

type Db = CacheDB<EmptyDB>;
type TestEvm = MainnetEvm<MainnetContext<Db>>;

/// A chain right after genesis, with the addresses the tests use.
struct Chain {
    evm: TestEvm,
    diamond: Address,
    wallet: Address,
}

impl Chain {
    /// Runs every genesis transaction, in the order genesis sends them, with the automation
    /// registry included and a one-of-one foundation wallet owned by [`WALLET_OWNER`].
    fn after_genesis() -> Self {
        let mut db = Db::default();
        for account in [WALLET_OWNER, NOMINEE, STRANGER] {
            db.insert_account_info(account, AccountInfo::from_balance(U256::from(FUNDS)));
        }
        let mut evm = Context::mainnet()
            .modify_cfg_chained(|cfg| cfg.spec = SpecId::PRAGUE)
            .modify_block_chained(|block| {
                block.timestamp = U256::from(TIMESTAMP);
                block.gas_limit = GAS_LIMIT;
            })
            .with_db(db)
            .build_mainnet();

        let genesis = GenesisTransactionGenerator::default()
            .prepare_genesis_transactions(GenesisTransactionGeneratorConfig {
                foundation_owners: vec![WALLET_OWNER],
                foundation_threshold: 1,
                full_set: true,
                automation_config: Some(AutomationRegistryConfigV1::default().into()),
                block_prologue_gas_cap: 100_000,
            })
            .expect("genesis transactions are generated");

        // The map is ordered by deployment rank, which is the order genesis sends them in.
        for (tag, txn) in &genesis {
            evm.ctx.cfg.execution_mode = ExecutionMode::Genesis;
            let result = evm
                .transact_commit(TxEnv {
                    caller: *txn.sender(),
                    nonce: *txn.nonce(),
                    kind: *txn.kind(),
                    data: Bytes::from(txn.data().clone()),
                    gas_limit: GAS_LIMIT,
                    ..Default::default()
                })
                .unwrap_or_else(|e| panic!("genesis transaction {tag} is valid: {e:?}"));
            assert!(
                result.is_success(),
                "genesis transaction {tag} failed: {result:?}"
            );
        }

        let deployed_at = |tag: GenesisTransactionTags| -> Address {
            genesis
                .get(&tag)
                .and_then(|txn| *txn.deploy_address())
                .unwrap_or_else(|| panic!("genesis deploys {tag}"))
        };
        Self {
            diamond: deployed_at(GenesisTransactionTags::Diamond),
            wallet: deployed_at(GenesisTransactionTags::FoundationWallet),
            evm,
        }
    }

    /// The `User` transaction calling `to` with `data` from `caller`, with the nonce read from the
    /// committed state.
    fn tx(&mut self, caller: Address, to: Address, data: Vec<u8>) -> TxEnv {
        self.evm.ctx.cfg.execution_mode = ExecutionMode::User;
        let nonce = self
            .evm
            .ctx
            .db()
            .basic_ref(caller)
            .expect("in-memory read")
            .map_or(0, |info| info.nonce);
        TxEnv {
            caller,
            nonce,
            kind: TxKind::Call(to),
            data: Bytes::from(data),
            gas_limit: GAS_LIMIT,
            ..Default::default()
        }
    }

    /// Sends a `User` transaction calling `to` with `data` from `caller`, commits it and returns
    /// its result.
    fn send(&mut self, caller: Address, to: Address, data: Vec<u8>) -> ExecutionResult {
        let tx = self.tx(caller, to, data);
        self.evm
            .transact_commit(tx)
            .expect("the test transactions are valid")
    }

    /// Calls a view function of the contract at `to` and decodes its return value. The call is
    /// executed without committing, so reads leave the chain state (nonces included) unchanged.
    fn view_at<C: SolCall>(&mut self, to: Address, call: C) -> C::Return {
        let tx = self.tx(STRANGER, to, call.abi_encode());
        let result = self
            .evm
            .transact(tx)
            .expect("the view call is a valid transaction")
            .result;
        C::abi_decode_returns(&expect_success(result)).expect("view output decodes")
    }

    /// Calls a view function of the Diamond and decodes its return value.
    fn view<C: SolCall>(&mut self, call: C) -> C::Return {
        let diamond = self.diamond;
        self.view_at(diamond, call)
    }

    fn owner(&mut self) -> Address {
        self.view(IDiamondOwnership::ownerCall {})
    }

    fn pending_owner(&mut self) -> Address {
        self.view(IDiamondOwnership::pendingOwnerCall {})
    }

    /// Has the foundation wallet call the Diamond with `data`: [`WALLET_OWNER`] submits the
    /// action, which also confirms it, and executes it. Returns the result of the execution.
    fn govern(&mut self, data: Vec<u8>) -> ExecutionResult {
        let (diamond, wallet) = (self.diamond, self.wallet);
        let index = self.view_at(
            wallet,
            IMultiSignatureWallet::getNextTransactionIndexCall {},
        );
        let content_hash = self.view_at(
            wallet,
            IMultiSignatureWallet::hashTransactionContentCall {
                to: diamond,
                value: U256::ZERO,
                data: data.clone().into(),
            },
        );
        expect_success(
            self.send(
                WALLET_OWNER,
                wallet,
                IMultiSignatureWallet::submitTransactionCall {
                    to: diamond,
                    value: U256::ZERO,
                    timeoutDuration: SUBMISSION_TIMEOUT_SECS,
                    data: data.into(),
                }
                .abi_encode(),
            ),
        );
        self.send(
            WALLET_OWNER,
            wallet,
            IMultiSignatureWallet::executeTransactionCall {
                txIndex: index,
                contentHash: content_hash,
            }
            .abi_encode(),
        )
    }

    /// Has the foundation wallet nominate `nominee` (zero cancels) through governance.
    fn nominate(&mut self, nominee: Address) -> ExecutionResult {
        self.govern(IDiamondOwnership::transferOwnershipCall { newOwner: nominee }.abi_encode())
    }

    /// Sends `acceptOwnership()` to the Diamond from `caller`.
    fn accept_as(&mut self, caller: Address) -> ExecutionResult {
        let diamond = self.diamond;
        self.send(
            caller,
            diamond,
            IDiamondOwnership::acceptOwnershipCall {}.abi_encode(),
        )
    }

    /// Asserts that `caller` is refused `acceptOwnership()` as not the pending owner.
    fn assert_cannot_accept(&mut self, caller: Address) {
        let revert = expect_revert(self.accept_as(caller));
        assert_eq!(
            revert.as_ref(),
            MustBePendingOwner {}.abi_encode(),
            "{caller} cannot accept"
        );
    }
}

/// The output of a successful call; panics with the result otherwise.
fn expect_success(result: ExecutionResult) -> Bytes {
    match result {
        ExecutionResult::Success { output, .. } => output.into_data(),
        other => panic!("expected success, got {other:?}"),
    }
}

/// The revert data of a reverted call; panics with the result otherwise.
fn expect_revert(result: ExecutionResult) -> Bytes {
    match result {
        ExecutionResult::Revert { output, .. } => output,
        other => panic!("expected a revert, got {other:?}"),
    }
}

/// The revert data a governance call reverted with inside the foundation wallet, which wraps it in
/// `ExecutionFailed(bytes)`.
fn governance_revert(result: ExecutionResult) -> Bytes {
    let data = expect_revert(result);
    ExecutionFailed::abi_decode(&data)
        .expect("the wallet reports a failed governance call as ExecutionFailed")
        .data
}

/// Genesis gives the Diamond the foundation wallet as owner, with no nomination pending, and
/// registers both ownership interfaces for ERC-165.
#[test]
fn genesis_diamond_is_owned_by_the_foundation_wallet_with_no_pending_owner() {
    let mut chain = Chain::after_genesis();
    let (wallet, diamond) = (chain.wallet, chain.diamond);

    assert_eq!(chain.owner(), wallet);
    assert_eq!(chain.pending_owner(), Address::ZERO);

    for interface_id in [[0x7f, 0x58, 0x28, 0xd0], IOWNABLE2STEP_INTERFACE_ID] {
        let supported = chain.view_at(
            diamond,
            IERC165::supportsInterfaceCall {
                interfaceId: interface_id.into(),
            },
        );
        assert!(supported, "interface {interface_id:02x?} is registered");
    }
}

/// The foundation wallet nominates an account through governance; nominating zero cancels it.
/// Ownership moves only when the current nominee accepts, and only that account can.
#[test]
fn ownership_moves_when_the_nominee_accepts() {
    let mut chain = Chain::after_genesis();
    let (wallet, diamond) = (chain.wallet, chain.diamond);

    // A cancelled nomination cannot be accepted.
    expect_success(chain.nominate(NOMINEE));
    expect_success(chain.nominate(Address::ZERO));
    assert_eq!(chain.pending_owner(), Address::ZERO);
    chain.assert_cannot_accept(NOMINEE);
    assert_eq!(chain.owner(), wallet);

    expect_success(chain.nominate(NOMINEE));
    assert_eq!(chain.owner(), wallet, "nominating does not move ownership");
    assert_eq!(chain.pending_owner(), NOMINEE);

    // Neither a third party nor the nominee can act as owner before acceptance.
    for caller in [STRANGER, NOMINEE] {
        let revert = expect_revert(chain.send(
            caller,
            diamond,
            IDiamondOwnership::transferOwnershipCall { newOwner: caller }.abi_encode(),
        ));
        assert_eq!(revert.as_ref(), MustBeContractOwner {}.abi_encode());
    }

    // Only the nominee can accept.
    chain.assert_cannot_accept(STRANGER);
    expect_success(chain.accept_as(NOMINEE));
    assert_eq!(chain.owner(), NOMINEE);
    assert_eq!(chain.pending_owner(), Address::ZERO);

    // The previous owner, the foundation wallet, is now refused owner-only calls.
    let inner = governance_revert(chain.nominate(wallet));
    assert_eq!(inner.as_ref(), MustBeContractOwner {}.abi_encode());
}

/// A governance `diamondCut` that removes any administration selector is refused, and the
/// Diamond's administration keeps working afterwards.
#[test]
fn removing_an_administration_selector_is_refused() {
    let mut chain = Chain::after_genesis();

    let admin_selectors = [
        IDiamondCut::diamondCutCall::SELECTOR,
        IDiamondOwnership::ownerCall::SELECTOR,
        IDiamondOwnership::transferOwnershipCall::SELECTOR,
        IDiamondOwnership::pendingOwnerCall::SELECTOR,
        IDiamondOwnership::acceptOwnershipCall::SELECTOR,
    ];
    for selector in admin_selectors {
        let cut = IDiamondCut::diamondCutCall {
            cut: vec![IDiamondCut::FacetCut {
                facetAddress: Address::ZERO,
                action: IDiamondCut::FacetCutAction::Remove,
                functionSelectors: vec![selector.into()],
            }],
            init: Address::ZERO,
            data: Bytes::new(),
        };
        let inner = governance_revert(chain.govern(cut.abi_encode()));
        assert_eq!(
            inner.as_ref(),
            CannotRemoveProtectedFunction {
                selector: selector.into()
            }
            .abi_encode(),
            "Remove of {selector:02x?} is refused"
        );
    }

    // The administration path is intact: the wallet can still cut (an empty cut) and nominate.
    let empty_cut = IDiamondCut::diamondCutCall {
        cut: vec![],
        init: Address::ZERO,
        data: Bytes::new(),
    };
    expect_success(chain.govern(empty_cut.abi_encode()));
    expect_success(chain.nominate(NOMINEE));
    assert_eq!(chain.pending_owner(), NOMINEE);
}
