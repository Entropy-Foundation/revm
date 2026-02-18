//! Automation registry transaction record definition to assist automation bookkeeping.
use crate::errors::SupraExtensionError;
use crate::supra_contract_bindings::supra_contracts_bindings::SupraContractsBindings::processTasksCall;
use crate::value_or_error;
use alloy::eips::eip2930::AccessList;
use alloy::primitives::{Address, Bytes, ChainId, TxKind, B256, U256};
use alloy_consensus::transaction::Transaction;
use alloy_eips::eip2718::Typed2718;
use alloy_sol_types::SolCall;
use context::transaction::SignedAuthorization;
use context::TransactionType;
use primitives::supra_constants::VM_SIGNER;

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
/// Transaction representing automation transaction record which will trigger automation task processing
/// during cycle transitions assisting automation bookkeeping flow.
pub struct AutomationRegistryRecord {
    /// Address of the transaction sender. By default it will be `@evm_vm_signer` reserved addressed by supra.
    pub sender: Address,
    /// Height of the block in scope of which this transaction is being executed.
    pub block_height: u64,
    /// Chain id.
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    pub chain_id: ChainId,
    /// Index of the automation record being executed in scope of the block.
    #[cfg_attr(feature = "serde", serde(with = "alloy_serde::quantity"))]
    pub nonce: u64,
    /// A scalar value equal to the maximum
    /// amount of gas that should be used in executing
    /// this transaction. Automation record execution will be gas-less, but it still will be guarded
    /// by gas limit.
    #[cfg_attr(
        feature = "serde",
        serde(with = "alloy_serde::quantity", rename = "gas", alias = "gasLimit")
    )]
    pub gas_limit: u64,
    /// The 160-bit address of the message call’s recipient.
    /// It will correspond to the address of the automation-registry/automation-controller SC deployed
    /// by governance.
    #[cfg_attr(feature = "serde", serde(default))]
    pub to: Address,
    /// Expected input data of the transaction
    /// - Selector of automation registry record executor
    /// - Index of the cycle for which automation registry record is scheduled for execution.
    /// - List of the task indexes to be processed
    pub input: Bytes,
}

impl Transaction for AutomationRegistryRecord {
    #[inline]
    fn chain_id(&self) -> Option<ChainId> {
        Some(self.chain_id)
    }

    #[inline]
    fn nonce(&self) -> u64 {
        self.nonce
    }

    #[inline]
    fn gas_limit(&self) -> u64 {
        self.gas_limit
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

impl Typed2718 for AutomationRegistryRecord {
    fn ty(&self) -> u8 {
        TransactionType::Custom as u8
    }
}

/// Builder for [`AutomationRegistryRecord`]
#[derive(Clone, Debug)]
pub struct AutomationRecordBuilder {
    to: Address,
    chain_id: Option<ChainId>,
    block_height: Option<u64>,
    nonce: Option<u64>,
    gas_limit: Option<u64>,
    task_indexes: Option<Vec<u64>>,
    cycle_index: Option<u64>,
}

#[allow(missing_docs)]
impl AutomationRecordBuilder {
    /// New builder with the target address as input.
    pub fn new(to: Address) -> Self {
        Self {
            to,
            chain_id: None,
            block_height: None,
            nonce: None,
            gas_limit: None,
            task_indexes: None,
            cycle_index: None,
        }
    }
    pub fn block_height(mut self, block_height: u64) -> Self {
        self.block_height = Some(block_height);
        self
    }
    pub fn nonce(mut self, nonce: u64) -> Self {
        self.nonce = Some(nonce);
        self
    }

    pub fn gas_limit(mut self, gas_limit: u64) -> Self {
        self.gas_limit = Some(gas_limit);
        self
    }
    pub fn task_indexes(mut self, task_indexes: Vec<u64>) -> Self {
        self.task_indexes = Some(task_indexes);
        self
    }

    pub fn cycle_index(mut self, cycle_index: u64) -> Self {
        self.cycle_index = Some(cycle_index);
        self
    }

    pub fn chain_id(mut self, chain_id: ChainId) -> Self {
        self.chain_id = Some(chain_id);
        self
    }

    pub fn build(self) -> Result<AutomationRegistryRecord, SupraExtensionError> {
        let Self {
            to,
            chain_id,
            block_height,
            nonce,
            gas_limit,
            task_indexes,
            cycle_index,
        } = self;
        let block_height = value_or_error!(AutomationRecordBuilder, "block_height", block_height);
        let nonce = value_or_error!(AutomationRecordBuilder, "nonce", nonce);
        let task_indexes = value_or_error!(AutomationRecordBuilder, "task_indexes", task_indexes);
        let gas_limit = value_or_error!(AutomationRecordBuilder, "gas_limit", gas_limit);
        let cycle_index = value_or_error!(AutomationRecordBuilder, "cycle_index", cycle_index);
        let chain_id = value_or_error!(AutomationRecordBuilder, "chain_id", chain_id);

        Ok(AutomationRegistryRecord {
            sender: VM_SIGNER,
            chain_id,
            block_height,
            nonce,
            gas_limit,
            to,
            input: Self::get_process_tasks_payload(cycle_index, task_indexes),
        })
    }

    fn get_process_tasks_payload(_cycle_index: u64, _task_indexes: Vec<u64>) -> Bytes {
        let process_task_call = processTasksCall {
            _cycleIndex: _cycle_index,
            _taskIndexes: _task_indexes,
        };
        Bytes::from(process_task_call.abi_encode())
    }
}
