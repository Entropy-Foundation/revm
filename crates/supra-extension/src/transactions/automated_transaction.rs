use alloy::eips::eip2930::AccessList;
use alloy::primitives::{Address, Bytes, ChainId, B256, U256};
use alloy_eips::eip2718::Typed2718;
use context::TransactionType;
use crate::transactions::automation_record::AutomationRegistryRecord;

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum AutomatedTransactionType {
    /// User submitted automation task based
    #[default]
    UST,
    /// Governance submitted/authorized automation task based. Will be gasless transaction
    GST
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
pub struct AutomatedTransaction {
    /// Height of the block in scope of which this transaction is being executed.
    pub block_height: u64,
    /// Hash of the transaction which registered an automation task based on which this transaction is created.
    pub registration_hash: B256,
    pub sender: Address,
    /// Type of the automated transaction.
    pub txn_type: AutomatedTransactionType,
    /// Chain id.
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    pub chain_id: ChainId,
    /// A scalar value equal to the automation task index based on which this transaction is created.
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    pub nonce: u64,
    /// A scalar value equal to the maximum
    /// amount of gas that should be used in executing
    /// this transaction. This is paid up-front, before any
    /// computation is done and may not be increased
    /// later; formally Tg.
    #[cfg_attr(
        feature = "serde",
        serde(with = "alloy_serde::quantity", rename = "gas", alias = "gasLimit")
    )]
    pub gas_limit: u64,
    /// A scalar value equal to the maximum
    /// amount of gas that should be used in executing
    /// this transaction.
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    pub max_fee_per_gas: u128,
    /// The 160-bit address of the message call’s recipient or, for a contract creation
    /// transaction, ∅, used here to denote the only member of B0 ; formally Tt.
    #[cfg_attr(feature = "serde", serde(default))]
    pub to: Address,
    /// A scalar value equal to the number of Wei to
    /// be transferred to the message call’s recipient or,
    /// in the case of contract creation, as an endowment
    /// to the newly created account; formally Tv.
    pub value: U256,
    /// The accessList specifies a list of addresses and storage keys;
    /// these addresses and storage keys are added into the `accessed_addresses`
    /// and `accessed_storage_keys` global sets (introduced in EIP-2929).
    /// A gas cost is charged, though at a discount relative to the cost of
    /// accessing outside the list.
    // Deserialize with `alloy_serde::null_as_default` to also accept a `null` value
    // instead of an (empty) array. This is due to certain RPC providers (e.g., Filecoin's)
    // sometimes returning `null` instead of an empty array `[]`.
    // More details in <https://github.com/alloy-rs/alloy/pull/2450>.
    #[cfg_attr(feature = "serde", serde(deserialize_with = "alloy_serde::null_as_default"))]
    pub access_list: AccessList,
    /// Input has two uses depending if `to` field is Create or Call.
    /// pub init: An unlimited size byte array specifying the
    /// EVM-code for the account initialisation procedure CREATE,
    /// data: An unlimited size byte array specifying the
    /// input data of the message call, formally Td.
    pub input: Bytes,
}

impl Typed2718 for AutomationRegistryRecord {
    fn ty(&self) -> u8 {
        TransactionType::Eip1559 as u8
    }
}

impl AutomatedTransaction {
    pub fn is_gasless(&self) -> bool {
        matches!(self.txn_type, AutomatedTransactionType::GST)
    }
}

/// Evm automated transaction to be scheduled for execution.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct AutomatedTransactionDetails {
    /// Transaction details
    pub txn: AutomatedTransaction,
    pub priority: u64,
}
