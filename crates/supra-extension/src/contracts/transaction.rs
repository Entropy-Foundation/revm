//! Encloses data representing genesis contracts.

use derive_getters::{Dissolve, Getters};
use primitives::Address;
use std::fmt::Debug;
use derive_more::Constructor;

/// Represents data required to construct genesis contracts deployment transaction
#[derive(Clone, Getters, Dissolve, Constructor)]
pub struct GenesisTransaction {
    sender: Address,
    data: Vec<u8>,
    nonce: u64,
    deploy_address: Address,
}

impl Debug for GenesisTransaction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GenesisTransaction")
            .field("sender", &self.sender)
            .field("data", &self.data.len())
            .field("nonce", &self.nonce)
            .field("deploy_address", &self.deploy_address)
            .finish()
    }
}

/// Genesis transaction tags which also guide deployment/execution order
#[derive(Debug, Hash, PartialEq, Eq, PartialOrd, Ord)]
#[allow(missing_docs)]
pub enum GenesisTransactionTags {
    MultisigWalletImpl = 0,
    MultisigBeacon = 1,
    FoundationWallet = 2,
    Erc20Supra = 3,
    BlockMetadataImpl = 4,
    BlockMetadata = 5,
    AutomationControllerImpl = 6,
    AutomationController = 7,
    AutomationCoreImpl = 8,
    AutomationCore = 9,
    AutomationRegistryImpl = 10,
    AutomationRegistry = 11,
}