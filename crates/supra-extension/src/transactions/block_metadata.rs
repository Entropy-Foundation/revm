//! Definition of the block metadata transaction which will be executed for every block
//! to aid block based checks to assist chain regular operations

use crate::errors::SupraExtensionError;
use crate::blockPrologueCall;
use crate::value_or_error;
use alloy::primitives::{Address, Bytes, ChainId, B256, U256};
use alloy_consensus::transaction::Transaction;
use alloy_eips::eip2718::Typed2718;
use alloy_sol_types::SolCall;
use context::transaction::{AccessList, SignedAuthorization};
use context::TransactionType;
use primitives::eip7825::TX_GAS_LIMIT_CAP;
use primitives::supra_constants::VM_SIGNER;
use primitives::TxKind;

/// EVM system transaction generated based on the block sent for execution.
/// Will trigger `BlockMeta::block_prologue` supra-evm SC API execution to meet
/// other `supra-evm` SC checks requiring per-block execution.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
pub struct BlockMetadata {
    /// ID of the chain in scope of which block is being executed
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    pub chain_id: ChainId,
    /// Sender of the transaction. By default, will be agreed @evm_vm_signer
    pub sender: Address,
    /// A height of the block based on which this transaction is created
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    pub height: u64,
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

impl Transaction for BlockMetadata {
    #[inline]
    fn chain_id(&self) -> Option<ChainId> {
        Some(self.chain_id)
    }

    #[inline]
    fn nonce(&self) -> u64 {
        self.height
    }

    #[inline]
    fn gas_limit(&self) -> u64 {
        TX_GAS_LIMIT_CAP
    }

    #[inline]
    fn gas_price(&self) -> Option<u128> {
        None
    }

    #[inline]
    fn max_fee_per_gas(&self) -> u128 {
        0
    }

    #[inline]
    fn max_priority_fee_per_gas(&self) -> Option<u128> {
        Some(0)
    }

    #[inline]
    fn max_fee_per_blob_gas(&self) -> Option<u128> {
        None
    }

    #[inline]
    fn priority_fee_or_price(&self) -> u128 {
        0
    }

    fn effective_gas_price(&self, _base_fee: Option<u64>) -> u128 {
        0
    }

    #[inline]
    fn is_dynamic_fee(&self) -> bool {
        false
    }

    #[inline]
    fn kind(&self) -> TxKind {
        TxKind::Call(self.to)
    }

    #[inline]
    fn is_create(&self) -> bool {
        false
    }

    #[inline]
    fn value(&self) -> U256 {
        U256::from(0)
    }

    #[inline]
    fn input(&self) -> &Bytes {
        &self.input
    }

    #[inline]
    fn access_list(&self) -> Option<&AccessList> {
        None
    }

    #[inline]
    fn blob_versioned_hashes(&self) -> Option<&[B256]> {
        None
    }

    #[inline]
    fn authorization_list(&self) -> Option<&[SignedAuthorization]> {
        None
    }
}
impl Typed2718 for BlockMetadata {
    fn ty(&self) -> u8 {
        TransactionType::Custom as u8
    }
}

/// Builder for [`BlockMetadata`] transaction.
/// All properties are mandatory.
#[derive(Clone, Debug, Default)]
pub struct BlockMetadataBuilder {
    to: Address,
    height: Option<u64>,
    block_hash: Option<B256>,
    timestamp: Option<U256>,
    chain_id: Option<ChainId>,
}

#[allow(missing_docs)]
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
    pub fn height(mut self, height: u64) -> Self {
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

    pub fn timestamp(mut self, timestamp: U256) -> Self {
        self.timestamp = Some(timestamp);
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

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::{address, b256, Address, B256, U256};
    use alloy_consensus::transaction::Transaction;
    use alloy_eips::eip2718::Typed2718;
    use crate::errors::SupraExtensionError;
    use primitives::eip7825::TX_GAS_LIMIT_CAP;
    use primitives::supra_constants::VM_SIGNER;

    const REGISTRY: Address = address!("1111111111111111111111111111111111111111");
    const CHAIN_ID: u64 = 6;
    const HEIGHT: u64 = 42;
    const BLOCK_HASH: B256 = b256!("abababababababababababababababababababababababababababababababab");
    const TIMESTAMP: u64 = 1_700_000_000;

    fn full_builder() -> BlockMetadataBuilder {
        BlockMetadataBuilder::new(REGISTRY)
            .height(HEIGHT)
            .block_hash(BLOCK_HASH)
            .timestamp(U256::from(TIMESTAMP))
            .chain_id(CHAIN_ID)
    }

    // ── Builder: successful build ─────────────────────────────────────────────

    #[test]
    fn build_sets_all_fields_correctly() {
        let meta = full_builder().build().unwrap();

        assert_eq!(meta.sender, VM_SIGNER);
        assert_eq!(meta.chain_id, CHAIN_ID);
        assert_eq!(meta.height, HEIGHT);
        assert_eq!(meta.block_hash, BLOCK_HASH);
        assert_eq!(meta.timestamp, U256::from(TIMESTAMP));
        assert_eq!(meta.to, REGISTRY);
    }

    #[test]
    fn build_input_matches_block_prologue_abi_encoding() {
        use crate::blockPrologueCall;
        use alloy_sol_types::SolCall;
        let meta = full_builder().build().unwrap();
        assert_eq!(meta.input.as_ref(), blockPrologueCall.abi_encode().as_slice());
    }

    // ── Builder: missing mandatory field errors ───────────────────────────────

    #[test]
    fn build_missing_mandatory_field_returns_error() {
        let err = BlockMetadataBuilder::new(REGISTRY)
            .block_hash(BLOCK_HASH)
            .timestamp(U256::from(TIMESTAMP))
            .chain_id(CHAIN_ID)
            .build()
            .unwrap_err();
        assert!(matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "height"));

        let err = BlockMetadataBuilder::new(REGISTRY)
            .height(HEIGHT)
            .timestamp(U256::from(TIMESTAMP))
            .chain_id(CHAIN_ID)
            .build()
            .unwrap_err();
        assert!(matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "block_hash"));

        let err = BlockMetadataBuilder::new(REGISTRY)
            .height(HEIGHT)
            .block_hash(BLOCK_HASH)
            .chain_id(CHAIN_ID)
            .build()
            .unwrap_err();
        assert!(matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "timestamp"));
        
        let err = BlockMetadataBuilder::new(REGISTRY)
            .height(HEIGHT)
            .block_hash(BLOCK_HASH)
            .timestamp(U256::from(TIMESTAMP))
            .build()
            .unwrap_err();
        assert!(matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "chain_id"));
    }

    // ── Transaction trait impl ────────────────────────────────────────────────

    #[test]
    fn transaction_trait_field_accessors() {
        let meta = full_builder().build().unwrap();

        assert_eq!(meta.chain_id(), Some(CHAIN_ID));
        assert_eq!(meta.nonce(), HEIGHT);           // nonce == height
        assert_eq!(meta.gas_limit(), TX_GAS_LIMIT_CAP);
        assert_eq!(meta.gas_price(), None);
        assert_eq!(meta.max_fee_per_gas(), 0);
        assert_eq!(meta.max_priority_fee_per_gas(), Some(0));
        assert_eq!(meta.max_fee_per_blob_gas(), None);
        assert_eq!(meta.priority_fee_or_price(), 0);
        assert_eq!(meta.effective_gas_price(None), 0);
        assert_eq!(meta.effective_gas_price(Some(9_999)), 0);
        assert!(!meta.is_dynamic_fee());
        assert_eq!(meta.kind(), TxKind::Call(REGISTRY));
        assert!(!meta.is_create());
        assert_eq!(meta.value(), U256::ZERO);
        assert_eq!(meta.access_list(), None);
        assert_eq!(meta.blob_versioned_hashes(), None);
        assert_eq!(meta.authorization_list(), None);

        assert_eq!(meta.input(), &meta.input);
        assert_eq!(meta.ty(), 0xFF); // TransactionType::Custom
    }

    // ── BlockMetadata default ─────────────────────────────────────────────────

    #[test]
    fn default_produces_zero_values() {
        let meta = BlockMetadata::default();
        assert_eq!(meta.chain_id, 0);
        assert_eq!(meta.sender, Address::ZERO);
        assert_eq!(meta.height, 0);
        assert_eq!(meta.block_hash, B256::ZERO);
        assert_eq!(meta.timestamp, U256::ZERO);
        assert_eq!(meta.to, Address::ZERO);
        assert!(meta.input.is_empty());
    }
}
