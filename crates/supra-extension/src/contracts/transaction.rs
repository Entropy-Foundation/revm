//! Encloses data representing genesis contracts.

use crate::contracts::canonical_singletons::CREATE2_FACTORY_ADDRESS;
use derive_getters::{Dissolve, Getters};
use derive_more::Constructor;
use primitives::{keccak256, Address, TxKind};
use serde::{Deserialize, Serialize};
use serde_with::hex::Hex;
use serde_with::serde_as;
use std::cmp::Ordering;
use std::fmt::{Debug, Display};

/// Represents data required to construct genesis contracts deployment transaction
#[serde_as]
#[derive(Clone, Getters, Dissolve, Constructor, Serialize, Deserialize)]
pub struct GenesisTransaction {
    /// Sender of the transaction
    sender: Address,
    /// Expected nonce of the sender account.
    nonce: u64,
    /// Input data of the transaction.
    #[serde_as(as = "Hex")]
    data: Vec<u8>,
    /// Kind of the transaction.
    kind: TxKind,
    /// Pre-computed deploy address of the contract if the transaction deploys a contract.
    deploy_address: Option<Address>,
}

impl GenesisTransaction {
    /// Creates a new genesis transaction with the given parameters to deploy a contract via standard create API.
    pub fn create(sender: Address, data: Vec<u8>, nonce: u64, deploy_address: Address) -> Self {
        Self::new(sender, nonce, data, TxKind::Create, Some(deploy_address))
    }

    /// Creates a new genesis transaction with the given parameters to deploy a contract via create2 API.
    pub fn create2(sender: Address, salt: &str, data: Vec<u8>, nonce: u64) -> Self {
        let salt_hash = keccak256(salt);
        let deploy_address = CREATE2_FACTORY_ADDRESS.create2_from_code(salt_hash, data.as_slice());
        let call_data = [salt_hash.to_vec(), data].concat();
        Self::new(
            sender,
            nonce,
            call_data,
            TxKind::Call(CREATE2_FACTORY_ADDRESS),
            Some(deploy_address),
        )
    }

    /// Creates a new genesis call transaction with the given parameters.
    pub fn call(sender: Address, target: Address, data: Vec<u8>, nonce: u64) -> Self {
        Self::new(sender, nonce, data, TxKind::Call(target), None)
    }
}

impl Debug for GenesisTransaction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GenesisTransaction")
            .field("sender", &self.sender)
            .field("kind", &self.kind)
            .field("data", &self.data.len())
            .field("nonce", &self.nonce)
            .field("deploy_address", &self.deploy_address)
            .finish()
    }
}

/// Genesis transaction tags, which also decide the order the genesis transactions are deployed in.
///
/// The genesis transactions are held in a map keyed by this type, so this type's [`Ord`] is what
/// puts them in order. Each deployer's nonces follow that order, and a `CREATE` address is fixed by
/// the deployer and the nonce, so the order decides the addresses the genesis contracts land at.
///
/// `deployment_rank` states that order and is the only thing that decides it. Declaration
/// order and any discriminant a variant might carry do not enter into it.
///
/// Serde encodes this enum by declaration position, so a variant belongs at the end of the list
/// whatever position it is given in the deployment order.
#[derive(Debug, Hash, PartialEq, Eq, Serialize, Deserialize)]
#[allow(missing_docs)]
pub enum GenesisTransactionTags {
    // Canonical EVM singleton predeploys: well-known third-party contracts the wider
    // EVM ecosystem/tooling expects at fixed addresses. Independent of Supra's own
    // system/application contracts below, and of each other.
    Create2Factory,
    Multicall3,
    SingletonFactory,
    CreateX,
    Erc1820Registry,

    // Main system and foundation contracts
    MultisigWalletImpl,
    MultisigBeacon,
    FoundationWallet,
    Erc20SupraImpl,
    Erc20Supra,
    Erc20SupraHandlerImpl,
    Erc20SupraHandler,
    BlockMetadataImpl,
    BlockMetadata,

    // Automation registry contracts
    DiamondCutFacet,
    DiamondLoupeFacet,
    OwnershipFacet,
    ConfigFacet,
    RegistryFacet,
    CoreFacet,
    DiamondInit,
    Diamond,
}

impl GenesisTransactionTags {
    /// Position of this tag in the genesis deployment order, lowest first.
    ///
    /// Every variant names its position here, so a new variant does not compile until its position
    /// is stated.
    ///
    /// Changing a value here changes the addresses the genesis contracts are deployed at. The order
    /// is pinned by `deployment_order_is_pinned`.
    fn deployment_rank(&self) -> u8 {
        match self {
            Self::Create2Factory => 0,
            Self::Multicall3 => 1,
            Self::SingletonFactory => 2,
            Self::CreateX => 3,
            Self::Erc1820Registry => 4,

            Self::MultisigWalletImpl => 5,
            Self::MultisigBeacon => 6,
            Self::FoundationWallet => 7,
            Self::Erc20SupraImpl => 8,
            Self::Erc20Supra => 9,
            Self::Erc20SupraHandlerImpl => 10,
            Self::Erc20SupraHandler => 11,
            Self::BlockMetadataImpl => 12,
            Self::BlockMetadata => 13,

            Self::DiamondCutFacet => 14,
            Self::DiamondLoupeFacet => 15,
            Self::OwnershipFacet => 16,
            Self::ConfigFacet => 17,
            Self::RegistryFacet => 18,
            Self::CoreFacet => 19,
            Self::DiamondInit => 20,
            Self::Diamond => 21,
        }
    }
}

/// Order genesis transactions by the position `deployment_rank` gives their tag.
impl Ord for GenesisTransactionTags {
    fn cmp(&self, other: &Self) -> Ordering {
        self.deployment_rank().cmp(&other.deployment_rank())
    }
}

impl PartialOrd for GenesisTransactionTags {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Display for GenesisTransactionTags {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use primitives::address;
    use std::collections::BTreeMap;

    const SENDER: Address = address!("0x0000000000000000000000000000000000000001");
    const TARGET: Address = address!("0x0000000000000000000000000000000000000002");
    const DEPLOY_ADDR: Address = address!("0x0000000000000000000000000000000000000003");

    /// The order the genesis transactions are deployed in, which decides the addresses the genesis
    /// contracts land at. A change to it is a change to genesis state, so it belongs in this list
    /// before it belongs anywhere else.
    #[test]
    fn deployment_order_is_pinned() {
        let order = [
            GenesisTransactionTags::Create2Factory,
            GenesisTransactionTags::Multicall3,
            GenesisTransactionTags::SingletonFactory,
            GenesisTransactionTags::CreateX,
            GenesisTransactionTags::Erc1820Registry,
            GenesisTransactionTags::MultisigWalletImpl,
            GenesisTransactionTags::MultisigBeacon,
            GenesisTransactionTags::FoundationWallet,
            GenesisTransactionTags::Erc20SupraImpl,
            GenesisTransactionTags::Erc20Supra,
            GenesisTransactionTags::Erc20SupraHandlerImpl,
            GenesisTransactionTags::Erc20SupraHandler,
            GenesisTransactionTags::BlockMetadataImpl,
            GenesisTransactionTags::BlockMetadata,
            GenesisTransactionTags::DiamondCutFacet,
            GenesisTransactionTags::DiamondLoupeFacet,
            GenesisTransactionTags::OwnershipFacet,
            GenesisTransactionTags::ConfigFacet,
            GenesisTransactionTags::RegistryFacet,
            GenesisTransactionTags::CoreFacet,
            GenesisTransactionTags::DiamondInit,
            GenesisTransactionTags::Diamond,
        ];

        // Ranks that are dense and ascending: every tag has a position of its own, and the
        // positions are the ones listed above.
        let ranks: Vec<u8> = order.iter().map(|tag| tag.deployment_rank()).collect();
        let expected: Vec<u8> = (0..order.len() as u8).collect();
        assert_eq!(ranks, expected);

        // A map keyed by these tags yields them in that order, which is how the genesis
        // transactions reach the executor.
        let map: BTreeMap<&GenesisTransactionTags, ()> =
            order.iter().rev().map(|tag| (tag, ())).collect();
        let iterated: Vec<&GenesisTransactionTags> = map.keys().copied().collect();
        assert_eq!(iterated, order.iter().collect::<Vec<_>>());
    }

    #[test]
    fn create_sets_fields_correctly() {
        let data = vec![0xde, 0xad, 0xbe, 0xef];
        let nonce = 7u64;

        let txn = GenesisTransaction::create(SENDER, data.clone(), nonce, DEPLOY_ADDR);

        assert_eq!(*txn.sender(), SENDER);
        assert_eq!(*txn.nonce(), nonce);
        assert_eq!(*txn.data(), data);
        assert_eq!(*txn.kind(), TxKind::Create);
        assert_eq!(*txn.deploy_address(), Some(DEPLOY_ADDR));
    }

    #[test]
    fn call_sets_fields_correctly() {
        let data = vec![0xca, 0xfe, 0xba, 0xbe];
        let nonce = 3u64;

        let txn = GenesisTransaction::call(SENDER, TARGET, data.clone(), nonce);

        assert_eq!(*txn.sender(), SENDER);
        assert_eq!(*txn.nonce(), nonce);
        assert_eq!(*txn.data(), data);
        assert_eq!(*txn.kind(), TxKind::Call(TARGET));
        // Call transactions have no pre-computed deploy address.
        assert_eq!(*txn.deploy_address(), None);
    }

    #[test]
    fn create2_sets_fields_correctly() {
        let salt = "my_salt";
        let bytecode = vec![0x60, 0x00, 0x60, 0x00];
        let nonce = 1u64;

        let txn = GenesisTransaction::create2(SENDER, salt, bytecode.clone(), nonce);

        // create2 wraps the call to the CREATE2 factory, so kind must target it.
        assert_eq!(*txn.sender(), SENDER);
        assert_eq!(*txn.nonce(), nonce);
        assert_eq!(*txn.kind(), TxKind::Call(CREATE2_FACTORY_ADDRESS));

        // The factory call-data is salt_hash ++ bytecode.
        let salt_hash = keccak256(salt);
        let expected_data = [salt_hash.to_vec(), bytecode.clone()].concat();
        assert_eq!(*txn.data(), expected_data);

        // The deploy address is deterministically derived from the factory address, salt, and code.
        let expected_deploy = CREATE2_FACTORY_ADDRESS.create2_from_code(salt_hash, &bytecode);
        assert_eq!(*txn.deploy_address(), Some(expected_deploy));
    }
}
