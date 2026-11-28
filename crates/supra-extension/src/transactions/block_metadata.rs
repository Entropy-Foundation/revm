//! Definition of the block metadata transaction which will be executed for every block
//! to aid block based checks to assist chain regular operations

use crate::blockPrologueCall;
use crate::errors::SupraExtensionError;
use crate::transactions::fixed_price_effective_tip;
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

/// Default Gas limit used for the block metadata transaction.
pub const DEFAULT_BLOCK_METADATA_GAS_LIMIT: u64 = TX_GAS_LIMIT_CAP;

/// EVM system transaction generated based on the block sent for execution.
/// Will trigger `BlockMeta::block_prologue` supra-evm SC API execution to meet
/// other `supra-evm` SC checks requiring per-block execution.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
pub struct BlockMetadata {
    /// ID of the chain in scope of which block is being executed
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    chain_id: ChainId,
    /// Sender of the transaction. By default, will be agreed @evm_vm_signer
    sender: Address,
    /// A height of the block based on which this transaction is created
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    height: u64,
    /// Hash of the block being executed
    block_hash: B256,
    /// Block creation timestamp in seconds
    timestamp: U256,
    /// The 160-bit address of the message call’s recipient
    #[cfg_attr(feature = "serde", serde(default))]
    to: Address,
    /// An unlimited size byte array specifying the
    /// input data of the message call.
    input: Bytes,
    /// Gas limit for this transaction, resolved from `BlockMeta.blockPrologueGasCap`.
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    gas_limit: u64,
    /// Gas limit of the block, the value the `GASLIMIT` opcode returns while the block executes.
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    block_gas_limit: u64,
    /// Base fee per gas of the block, the value the `BASEFEE` opcode returns while the block
    /// executes and the lowest gas price its EVM transactions pay.
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    base_fee_per_gas: u64,
}

/// Read access to the fields of the transaction.
impl BlockMetadata {
    /// Id of the EVM chain the transaction was built for. [`Transaction::chain_id`] reports it as
    /// `Some`.
    #[inline]
    pub fn evm_chain_id(&self) -> ChainId {
        self.chain_id
    }

    /// Address the transaction calls. [`Transaction::kind`] reports it as [`TxKind::Call`], and
    /// [`Transaction::to`] as `Some`.
    #[inline]
    pub fn target(&self) -> Address {
        self.to
    }

    /// Sender of the transaction, [`VM_SIGNER`] for a transaction built by [`BlockMetadataBuilder`].
    #[inline]
    pub fn sender(&self) -> Address {
        self.sender
    }

    /// Height of the block the transaction was built for. [`Transaction::nonce`] reports the same
    /// value.
    #[inline]
    pub fn height(&self) -> u64 {
        self.height
    }

    /// Hash of the block the transaction was built for.
    #[inline]
    pub fn block_hash(&self) -> B256 {
        self.block_hash
    }

    /// Creation timestamp of the block the transaction was built for, in seconds.
    #[inline]
    pub fn timestamp(&self) -> U256 {
        self.timestamp
    }

    /// Gas limit of the block, the value the `GASLIMIT` opcode returns while the block executes.
    #[inline]
    pub fn block_gas_limit(&self) -> u64 {
        self.block_gas_limit
    }

    /// Base fee per gas of the block, the value the `BASEFEE` opcode returns while the block
    /// executes.
    #[inline]
    pub fn base_fee_per_gas(&self) -> u64 {
        self.base_fee_per_gas
    }
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
        self.gas_limit
    }

    /// `Some(0)`: a block-metadata transaction is a gasless system transaction with a fixed price of
    /// zero. It is reported the way a fixed-price (EIP-2930) transaction is, which is the shape the
    /// RPC presents it in: one gas price, no priority fee, and not a dynamic-fee transaction. Its
    /// type, [`Typed2718::ty`], is EIP-2930 as well. revm skips the base-fee floor for an execution
    /// mode that charges no gas, so the zero price runs at any base fee.
    #[inline]
    fn gas_price(&self) -> Option<u128> {
        Some(0)
    }

    #[inline]
    fn max_fee_per_gas(&self) -> u128 {
        0
    }

    /// `None`: a fixed-price transaction offers no priority fee; see [`Self::gas_price`].
    #[inline]
    fn max_priority_fee_per_gas(&self) -> Option<u128> {
        None
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

    /// Always `Some(0)`: the transaction runs at a price of zero at any base fee, because revm skips
    /// the base-fee floor for an execution mode that charges no gas; see
    /// [`fixed_price_effective_tip`].
    #[inline]
    fn effective_tip_per_gas(&self, base_fee: u64) -> Option<u128> {
        fixed_price_effective_tip(self.max_fee_per_gas(), base_fee)
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
    /// EIP-2930, the fixed-price type; see [`Transaction::gas_price`] on this type.
    fn ty(&self) -> u8 {
        TransactionType::Eip2930 as u8
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
    gas_limit: Option<u64>,
    block_gas_limit: Option<u64>,
    base_fee_per_gas: Option<u64>,
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
            gas_limit: None,
            block_gas_limit: None,
            base_fee_per_gas: None,
        }
    }

    /// Address this transaction was built to target, i.e. the `BlockMeta` contract address.
    pub fn to(&self) -> Address {
        self.to
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

    pub fn gas_limit(mut self, gas_limit: u64) -> Self {
        self.gas_limit = Some(gas_limit);
        self
    }

    pub fn block_gas_limit(mut self, block_gas_limit: u64) -> Self {
        self.block_gas_limit = Some(block_gas_limit);
        self
    }

    pub fn base_fee_per_gas(mut self, base_fee_per_gas: u64) -> Self {
        self.base_fee_per_gas = Some(base_fee_per_gas);
        self
    }

    pub fn build(self) -> Result<BlockMetadata, SupraExtensionError> {
        let Self {
            to,
            height,
            block_hash,
            timestamp,
            chain_id,
            gas_limit,
            block_gas_limit,
            base_fee_per_gas,
        } = self;
        let height = value_or_error!(BlockMetadataBuilder, "height", height);
        let block_hash = value_or_error!(BlockMetadataBuilder, "block_hash", block_hash);
        let timestamp = value_or_error!(BlockMetadataBuilder, "timestamp", timestamp);
        let chain_id = value_or_error!(BlockMetadataBuilder, "chain_id", chain_id);
        let gas_limit = value_or_error!(BlockMetadataBuilder, "gas_limit", gas_limit);
        let block_gas_limit =
            value_or_error!(BlockMetadataBuilder, "block_gas_limit", block_gas_limit);
        let base_fee_per_gas =
            value_or_error!(BlockMetadataBuilder, "base_fee_per_gas", base_fee_per_gas);

        Ok(BlockMetadata {
            chain_id,
            sender: VM_SIGNER,
            height,
            block_hash,
            timestamp,
            to,
            input: Self::get_block_prologue(),
            gas_limit,
            block_gas_limit,
            base_fee_per_gas,
        })
    }

    fn get_block_prologue() -> Bytes {
        Bytes::from(blockPrologueCall.abi_encode())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::errors::SupraExtensionError;
    use alloy::primitives::{address, b256, Address, B256, U256};
    use alloy_consensus::transaction::Transaction;
    use alloy_eips::eip2718::Typed2718;
    use primitives::supra_constants::VM_SIGNER;

    const REGISTRY: Address = address!("1111111111111111111111111111111111111111");
    const CHAIN_ID: u64 = 6;
    const HEIGHT: u64 = 42;
    const BLOCK_HASH: B256 =
        b256!("abababababababababababababababababababababababababababababababab");
    const TIMESTAMP: u64 = 1_700_000_000;
    const GAS_LIMIT: u64 = 12_345_678;
    const BLOCK_GAS_LIMIT: u64 = 500_000_000;
    const BASE_FEE_PER_GAS: u64 = 100_000_000_000;

    fn full_builder() -> BlockMetadataBuilder {
        BlockMetadataBuilder::new(REGISTRY)
            .height(HEIGHT)
            .block_hash(BLOCK_HASH)
            .timestamp(U256::from(TIMESTAMP))
            .chain_id(CHAIN_ID)
            .gas_limit(GAS_LIMIT)
            .block_gas_limit(BLOCK_GAS_LIMIT)
            .base_fee_per_gas(BASE_FEE_PER_GAS)
    }

    // ── Builder: successful build ─────────────────────────────────────────────

    #[test]
    fn build_sets_all_fields_correctly() {
        let meta = full_builder().build().unwrap();

        assert_eq!(meta.sender(), VM_SIGNER);
        assert_eq!(meta.evm_chain_id(), CHAIN_ID);
        assert_eq!(meta.height(), HEIGHT);
        assert_eq!(meta.block_hash(), BLOCK_HASH);
        assert_eq!(meta.timestamp(), U256::from(TIMESTAMP));
        assert_eq!(meta.target(), REGISTRY);
        assert_eq!(meta.gas_limit(), GAS_LIMIT);
        assert_eq!(meta.block_gas_limit(), BLOCK_GAS_LIMIT);
        assert_eq!(meta.base_fee_per_gas(), BASE_FEE_PER_GAS);
    }

    #[test]
    fn builder_to_returns_target_address() {
        assert_eq!(BlockMetadataBuilder::new(REGISTRY).to(), REGISTRY);
    }

    #[test]
    fn build_input_matches_block_prologue_abi_encoding() {
        use crate::blockPrologueCall;
        use alloy_sol_types::SolCall;
        let meta = full_builder().build().unwrap();
        assert_eq!(
            meta.input.as_ref(),
            blockPrologueCall.abi_encode().as_slice()
        );
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
        assert!(
            matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "block_hash")
        );

        let err = BlockMetadataBuilder::new(REGISTRY)
            .height(HEIGHT)
            .block_hash(BLOCK_HASH)
            .chain_id(CHAIN_ID)
            .build()
            .unwrap_err();
        assert!(
            matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "timestamp")
        );

        let err = BlockMetadataBuilder::new(REGISTRY)
            .height(HEIGHT)
            .block_hash(BLOCK_HASH)
            .timestamp(U256::from(TIMESTAMP))
            .build()
            .unwrap_err();
        assert!(
            matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "chain_id")
        );

        let err = BlockMetadataBuilder::new(REGISTRY)
            .height(HEIGHT)
            .block_hash(BLOCK_HASH)
            .timestamp(U256::from(TIMESTAMP))
            .chain_id(CHAIN_ID)
            .block_gas_limit(BLOCK_GAS_LIMIT)
            .base_fee_per_gas(BASE_FEE_PER_GAS)
            .build()
            .unwrap_err();
        assert!(
            matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "gas_limit")
        );

        let err = BlockMetadataBuilder::new(REGISTRY)
            .height(HEIGHT)
            .block_hash(BLOCK_HASH)
            .timestamp(U256::from(TIMESTAMP))
            .chain_id(CHAIN_ID)
            .gas_limit(GAS_LIMIT)
            .base_fee_per_gas(BASE_FEE_PER_GAS)
            .build()
            .unwrap_err();
        assert!(
            matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "block_gas_limit")
        );

        let err = BlockMetadataBuilder::new(REGISTRY)
            .height(HEIGHT)
            .block_hash(BLOCK_HASH)
            .timestamp(U256::from(TIMESTAMP))
            .chain_id(CHAIN_ID)
            .gas_limit(GAS_LIMIT)
            .block_gas_limit(BLOCK_GAS_LIMIT)
            .build()
            .unwrap_err();
        assert!(
            matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "base_fee_per_gas")
        );
    }

    /// Fixes the serde forms of a fully populated [`BlockMetadata`]. smr-moonshot hashes the
    /// transaction over its BCS serialization through serde. BCS is not a dependency of this crate,
    /// so this test fixes two other serde forms:
    /// - JSON, a human-readable form, which fixes the field names and order and the hex forms of the
    ///   numeric fields;
    /// - bincode, a non-human-readable form as BCS is. `alloy_serde::quantity` and `U256` serialize
    ///   differently for the two kinds of serializer, and `alloy_serde` leaves its non-human-readable
    ///   form unspecified.
    ///
    /// The test fails when a dependency upgrade (the revm 43 sync, smr-moonshot#4046, or a later
    /// one) changes either form, and with it possibly the bytes the transaction's hash covers.
    #[cfg(feature = "serde")]
    #[test]
    fn serde_forms_are_fixed() {
        let meta = full_builder().build().unwrap();

        let json = concat!(
            r#"{"chainId":"0x6","#,
            r#""sender":"0x0000000000000000000000000000000053555000","#,
            r#""height":"0x2a","#,
            r#""blockHash":"0xabababababababababababababababababababababababababababababababab","#,
            r#""timestamp":"0x6553f100","#,
            r#""to":"0x1111111111111111111111111111111111111111","#,
            r#""input":"0x7ded091b","#,
            r#""gasLimit":"0xbc614e","#,
            r#""blockGasLimit":"0x1dcd6500","#,
            r#""baseFeePerGas":"0x174876e800"}"#,
        );
        assert_eq!(serde_json::to_string(&meta).unwrap(), json);
        assert_eq!(serde_json::from_str::<BlockMetadata>(json).unwrap(), meta);

        let config = bincode::config::standard();
        let binary = bincode::serde::encode_to_vec(&meta, config).unwrap();
        let expected_binary = concat!(
            "080000000000000006",
            "140000000000000000000000000000000053555000",
            "08000000000000002a",
            "20abababababababababababababababababababababababababababababababab",
            "20000000000000000000000000000000000000000000000000000000006553f100",
            "141111111111111111111111111111111111111111",
            "047ded091b",
            "080000000000bc614e",
            "08000000001dcd6500",
            "08000000174876e800",
        );
        assert_eq!(alloy::hex::encode(&binary), expected_binary);
        let (decoded, _) =
            bincode::serde::decode_from_slice::<BlockMetadata, _>(&binary, config).unwrap();
        assert_eq!(decoded, meta);
    }

    // ── Transaction trait impl ────────────────────────────────────────────────

    #[test]
    fn transaction_trait_field_accessors() {
        let meta = full_builder().build().unwrap();

        assert_eq!(meta.chain_id(), Some(CHAIN_ID));
        assert_eq!(meta.nonce(), HEIGHT); // nonce == height
        assert_eq!(meta.gas_limit(), GAS_LIMIT);
        assert_eq!(meta.gas_price(), Some(0));
        assert_eq!(meta.max_fee_per_gas(), 0);
        assert_eq!(meta.max_priority_fee_per_gas(), None);
        // Runs at any base fee, so the tip is zero rather than `None`.
        assert_eq!(meta.effective_tip_per_gas(0), Some(0));
        assert_eq!(meta.effective_tip_per_gas(9_999), Some(0));
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
        assert_eq!(meta.ty(), TransactionType::Eip2930 as u8);
    }

    // ── Builder: values that do not set the sender or the calldata ────────────

    #[test]
    fn build_from_zero_values_keeps_sender_and_calldata() {
        let meta = BlockMetadataBuilder::new(Address::ZERO)
            .height(0)
            .block_hash(B256::ZERO)
            .timestamp(U256::ZERO)
            .chain_id(0)
            .gas_limit(0)
            .block_gas_limit(0)
            .base_fee_per_gas(0)
            .build()
            .unwrap();
        assert_eq!(meta.sender(), VM_SIGNER);
        assert_eq!(
            meta.input().as_ref(),
            crate::blockPrologueCall.abi_encode().as_slice()
        );
    }
}
