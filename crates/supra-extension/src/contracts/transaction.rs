//! Encloses data representing genesis contracts.

use derive_getters::{Dissolve, Getters};
use derive_more::Constructor;
use primitives::Address;
use std::fmt::Debug;

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
    AutomationCoreImpl = 6,
    AutomationCore = 7,
    AutomationRegistryImpl = 8,
    AutomationRegistry = 9,
    AutomationControllerImpl = 10,
    AutomationController = 11,
}
