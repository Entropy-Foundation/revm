use crate::errors::SupraExtensionError;
use crate::supra_contract_bindings::supra_contracts_bindings::SupraContractsBindings::blockPrologueCall;
use crate::value_or_error;
use alloy::primitives::{Address, Bytes, ChainId, B256, U256};
use alloy_sol_types::SolCall;
use primitives::supra_constants::VM_SIGNER;

/// EVM system transaction generated based on the block sent for execution.
/// Will trigger `BlockMeta::block_prologue` supra-evm SC API execution to meat
/// other `supra-evm` SC checks requiring per-block execution.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
pub struct BlockMetadata {
    /// Id of the chain in scope of which block is being executed
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    pub chain_id: ChainId,
    /// Sender of the transaction. By default, will be agreed @evm_vm_signer
    pub sender: Address,
    /// A height of the block based on which this transaction is created
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    pub height: U256,
    /// Hash of the block being executed
    pub block_hash: B256,
    /// Block creation timestamp in seconds
    pub timestamp: U256,
    /// The 160-bit address of the message call’s recipient
    #[cfg_attr(feature = "serde", serde(default))]
    pub to: Address,
    /// An unlimited size byte array specifying the
    /// input data of the message call.
    pub input: Bytes,
}

pub struct BlockMetadataBuilder {
    to: Address,
    height: Option<U256>,
    block_hash: Option<B256>,
    timestamp: Option<U256>,
    chain_id: Option<ChainId>,
}

impl BlockMetadataBuilder {
    pub fn new(to: Address) -> Self {
        Self {
            to,
            height: None,
            block_hash: None,
            timestamp: None,
            chain_id: None,
        }
    }
    pub fn height(mut self, height: U256) -> Self {
        self.height = Some(height);
        self
    }

    pub fn block_hash(mut self, block_hash: B256) -> Self {
        self.block_hash = Some(block_hash);
        self
    }
    pub fn chain_id(mut self, chain_id: u64) -> Self {
        self.chain_id = Some(chain_id);
        self
    }

    pub fn build(self) -> Result<BlockMetadata, SupraExtensionError> {
        let Self {
            to,
            height,
            block_hash,
            timestamp,
            chain_id,
        } = self;
        let height = value_or_error!(BlockMetadataBuilder, "height", height);
        let block_hash = value_or_error!(BlockMetadataBuilder, "block_hash", block_hash);
        let timestamp = value_or_error!(BlockMetadataBuilder, "timestamp", timestamp);
        let chain_id = value_or_error!(BlockMetadataBuilder, "chain_id", chain_id);

        Ok(BlockMetadata {
            chain_id,
            sender: VM_SIGNER,
            height,
            block_hash,
            timestamp,
            to,
            input: Self::get_block_prologue(),
        })
    }

    fn get_block_prologue() -> Bytes {
        Bytes::from(blockPrologueCall.abi_encode())
    }
}
