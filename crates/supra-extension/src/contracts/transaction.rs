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
    /// Amount to mint to the contract address if the transaction deploys a contract.
    value: u128,
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
        Self::new(sender, nonce, 0, data, TxKind::Create, Some(deploy_address))
    }

    /// Creates a new genesis transaction with the given parameters to deploy a contract via create2 API.
    pub fn create2(sender: Address, salt: &str, data: Vec<u8>, nonce: u64) -> Self {
        let salt_hash = keccak256(salt);
        let deploy_address = CREATE2_FACTORY_ADDRESS.create2_from_code(salt_hash, &data.as_slice());
        let call_data = [salt_hash.to_vec(), data].concat();
        Self::new(
            sender,
            nonce,
            0,
            call_data,
            TxKind::Call(CREATE2_FACTORY_ADDRESS),
            Some(deploy_address),
        )
    }

    /// Creates a new genesis transaction with the given parameters to deploy a contract via create2 API.
    pub fn create2_with_value(
        sender: Address,
        salt: &str,
        data: Vec<u8>,
        nonce: u64,
        value: u128,
    ) -> Self {
        let salt_hash = keccak256(salt);
        let deploy_address = CREATE2_FACTORY_ADDRESS.create2_from_code(salt_hash, &data.as_slice());
        let call_data = [salt_hash.to_vec(), data].concat();
        Self::new(
            sender,
            nonce,
            value,
            call_data,
            TxKind::Call(CREATE2_FACTORY_ADDRESS),
            Some(deploy_address),
        )
    }

    /// Creates a new genesis call transaction with the given parameters.
    pub fn call(sender: Address, target: Address, data: Vec<u8>, nonce: u64) -> Self {
        Self::new(sender, nonce, 0, data, TxKind::Call(target), None)
    }

    /// Creates a new genesis call transaction with the given parameters including value.
    pub fn call_with_value(
        sender: Address,
        target: Address,
        data: Vec<u8>,
        nonce: u64,
        value: u128,
    ) -> Self {
        Self::new(sender, nonce, value, data, TxKind::Call(target), None)
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
            .field("value", &self.value)
            .finish()
    }
}

/// Custom contract tag to be used by upper layer to configure a custom genesis contract transactions.
#[derive(Debug, Hash, PartialEq, Eq, Serialize, Deserialize, Constructor)]
pub struct ContractCustomTag {
    /// Nonce of the contract deployment.
    pub nonce: u64,
    /// Contract name, used as a tag
    pub name: String,
}

/// Order custom contracts by the nonce.
impl Ord for ContractCustomTag {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        match self.nonce.cmp(&other.nonce) {
            Ordering::Equal => self.name.cmp(&other.name),
            r => r,
        }
    }
}

impl PartialOrd for ContractCustomTag {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Display for ContractCustomTag {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.name)
    }
}

/// Genesis transaction tags which also guide deployment/execution order
#[derive(Debug, Hash, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[allow(missing_docs)]
#[repr(u8)]
pub enum GenesisTransactionTags {
    // Canonical EVM singleton predeploys: well-known third-party contracts the wider
    // EVM ecosystem/tooling expects at fixed addresses. Independent of Supra's own
    // system/application contracts below, and of each other, but placed first since
    // that's also their actual deployment order: this enum's derived `Ord` compares
    // by discriminant (the explicit `= N` value), and that `Ord` governs the
    // BTreeMap iteration order genesis transactions are executed in — while serde's
    // encoding of this enum keys off declaration position instead, ignoring `= N`
    // entirely. The two currently coincide only because the discriminants are dense
    // and assigned in the same order as the declarations.
    // NOTE: the discriminants and the declaration order must be kept in lockstep.
    // Renumbering the `= N` values without reordering the variants (or vice versa)
    // silently changes deployment/execution order without changing serde's index,
    // or changes serde's index without changing deployment order — either way a
    // silent divergence. Only ever append new variants; never renumber or reorder
    // existing ones once this chain has live deployments depending on either.
    Create2Factory = 0,
    Multicall3 = 1,
    SingletonFactory = 2,
    CreateX = 3,
    Erc1820Registry = 4,

    // Main system and foundation contracts
    MultisigWalletImpl = 5,
    MultisigBeacon = 6,
    FoundationWallet = 7,
    Erc20SupraImpl = 8,
    Erc20Supra = 9,
    Erc20SupraHandlerImpl = 10,
    Erc20SupraHandler = 11,
    BlockMetadataImpl = 12,
    BlockMetadata = 13,

    // Automation registry contracts
    DiamondCutFacet = 14,
    DiamondLoupeFacet = 15,
    OwnershipFacet = 16,
    ConfigFacet = 17,
    RegistryFacet = 18,
    CoreFacet = 19,
    DiamondInit = 20,
    Diamond = 21,

    // Custom contracts injected by application layer
    Custom(ContractCustomTag),
}

impl Display for GenesisTransactionTags {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GenesisTransactionTags::Custom(custom_tag) => write!(f, "{}", custom_tag),
            _ => write!(f, "{:?}", self),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use primitives::address;

    const SENDER: Address = address!("0x0000000000000000000000000000000000000001");
    const TARGET: Address = address!("0x0000000000000000000000000000000000000002");
    const DEPLOY_ADDR: Address = address!("0x0000000000000000000000000000000000000003");

    #[test]
    fn check_tag_ordering() {
        let tag1 = ContractCustomTag {
            nonce: 1,
            name: "2test".to_string(),
        };
        let tag11 = ContractCustomTag {
            nonce: 1,
            name: "1test".to_string(),
        };
        let tag2 = ContractCustomTag {
            nonce: 2,
            name: "1test".to_string(),
        };
        let tag2_sibling = ContractCustomTag {
            nonce: 2,
            name: "1test".to_string(),
        };
        let tag2_diff_name = ContractCustomTag {
            nonce: 2,
            name: "2test".to_string(),
        };

        assert!(tag1 < tag2);
        assert!(tag11 < tag2);
        assert_eq!(tag2, tag2_sibling);
        assert_eq!(tag2.cmp(&tag2_sibling), Ordering::Equal);
        assert!(tag2 < tag2_diff_name);
    }

    #[test]
    fn create_sets_fields_correctly() {
        let data = vec![0xde, 0xad, 0xbe, 0xef];
        let nonce = 7u64;

        let txn = GenesisTransaction::create(SENDER, data.clone(), nonce, DEPLOY_ADDR);

        assert_eq!(*txn.sender(), SENDER);
        assert_eq!(*txn.nonce(), nonce);
        assert_eq!(*txn.data(), data);
        // Plain create carries no value.
        assert_eq!(*txn.value(), 0u128);
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
        // Plain call carries no value.
        assert_eq!(*txn.value(), 0u128);
        assert_eq!(*txn.kind(), TxKind::Call(TARGET));
        // Call transactions have no pre-computed deploy address.
        assert_eq!(*txn.deploy_address(), None);
    }

    #[test]
    fn call_with_value_sets_fields_correctly() {
        let data = vec![0x01, 0x02];
        let nonce = 5u64;
        let value = 1_000_000u128;

        let txn = GenesisTransaction::call_with_value(SENDER, TARGET, data.clone(), nonce, value);

        assert_eq!(*txn.sender(), SENDER);
        assert_eq!(*txn.nonce(), nonce);
        assert_eq!(*txn.data(), data);
        assert_eq!(*txn.value(), value);
        assert_eq!(*txn.kind(), TxKind::Call(TARGET));
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
        assert_eq!(*txn.value(), 0u128);
        assert_eq!(*txn.kind(), TxKind::Call(CREATE2_FACTORY_ADDRESS));

        // The factory call-data is salt_hash ++ bytecode.
        let salt_hash = keccak256(salt);
        let expected_data = [salt_hash.to_vec(), bytecode.clone()].concat();
        assert_eq!(*txn.data(), expected_data);

        // The deploy address is deterministically derived from the factory address, salt, and code.
        let expected_deploy = CREATE2_FACTORY_ADDRESS.create2_from_code(salt_hash, &bytecode);
        assert_eq!(*txn.deploy_address(), Some(expected_deploy));
    }

    #[test]
    fn create2_with_value_sets_fields_correctly() {
        let salt = "salted_contract";
        let bytecode = vec![0xAB, 0xCD];
        let nonce = 2u64;
        let value = 42u128;

        let txn =
            GenesisTransaction::create2_with_value(SENDER, salt, bytecode.clone(), nonce, value);

        assert_eq!(*txn.sender(), SENDER);
        assert_eq!(*txn.nonce(), nonce);
        assert_eq!(*txn.value(), value);
        assert_eq!(*txn.kind(), TxKind::Call(CREATE2_FACTORY_ADDRESS));

        let salt_hash = keccak256(salt);
        let expected_data = [salt_hash.to_vec(), bytecode.clone()].concat();
        assert_eq!(*txn.data(), expected_data);

        let expected_deploy = CREATE2_FACTORY_ADDRESS.create2_from_code(salt_hash, &bytecode);
        assert_eq!(*txn.deploy_address(), Some(expected_deploy));
    }
}
