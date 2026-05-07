//! Encloses data representing genesis contracts.

use derive_getters::{Dissolve, Getters};
use derive_more::Constructor;
use primitives::{keccak256, Address, TxKind, address, hex};
use std::fmt::{Debug, Display};
use serde::{Serialize, Deserialize};
use serde_with::hex::Hex ;
use serde_with::serde_as;


/// The address that deploys the default CREATE2 deployer contract.
pub const CREATE2_FACTORY_OWNER: Address =
    address!("0x3fAB184622Dc19b6109349B94811493BF2a45362");

/// The default CREATE2 FACTORY contract address. Assumed deployed by [CREATE2_FACTORY_OWNER] with nonce 0
pub const CREATE2_FACTORY_ADDRESS: Address =
    address!("0x4e59b44847b379578588920ca78fbf26c0b4956c");

/// The init-code of the default CREATE2 FACTORY widely used in community
/// Retrieved from https://github.com/Arachnid/deterministic-deployment-proxy
pub const CREATE2_FACTORY_CODE: &[u8] = &hex!(
    "604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
);

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
    deploy_address: Address,
}

impl GenesisTransaction {
    /// Creates a new genesis transaction with the given parameters to deploy a contract via standard create API.
    pub fn create(
        sender: Address,
        data: Vec<u8>,
        nonce: u64,
        deploy_address: Address,
    ) -> Self {
        Self::new (
            sender,
            nonce,
            0,
            data,
            TxKind::Create,
            deploy_address,
        )
    }

    /// Creates a new genesis transaction with the given parameters to deploy a contract via create2 API.
    pub fn create2(
        sender: Address,
        salt: &str,
        data: Vec<u8>,
        nonce: u64,
    ) -> Self {
        let salt_hash = keccak256(salt);
        let deploy_address = CREATE2_FACTORY_ADDRESS.create2_from_code(salt_hash, &data.as_slice());
        let call_data = [ salt_hash.to_vec(), data].concat();
        Self::new (
            sender,
            nonce,
            0,
            call_data,
            TxKind::Call(CREATE2_FACTORY_ADDRESS),
            deploy_address,
        )
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

/// Genesis transaction tags which also guide deployment/execution order
#[derive(Debug, Hash, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[allow(missing_docs)]
#[repr(u8)]
pub enum GenesisTransactionTags {
    Create2Factory = 0,
    // Main system and foundation contracts
    MultisigWalletImpl = 1,
    MultisigBeacon = 2,
    FoundationWallet = 3,
    Erc20SupraImpl = 4,
    Erc20Supra = 5,
    Erc20SupraHandlerImpl = 6,
    Erc20SupraHandler = 7,
    BlockMetadataImpl = 8,
    BlockMetadata = 9,

    // Automation registry contracts
    DiamondCutFacet = 10,
    DiamondLoupeFacet = 11,
    OwnershipFacet = 12,
    ConfigFacet = 13,
    RegistryFacet = 14,
    CoreFacet = 15,
    DiamondInit = 16,
    Diamond = 17,

    // Supra Nova contracts
    WrappedToken = 18, // Impl
    WrappedTokenFactory = 19, // Beacon
    WrappedTokenFactoryProxy = 20, // Beacon Proxy
    Hypernova = 21,
    HypernovaProxy = 22,
    TokenVault = 23,
    TokenVaultProxy = 24,
    FeeOperator = 25,
    FeeOperatorProxy = 26,
    TokenBridge = 27,
    TokenBridgeProxy = 28,
}

impl Display for GenesisTransactionTags {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self)
    }
}
