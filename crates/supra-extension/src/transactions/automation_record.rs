//! Automation registry transaction record definition to assist automation bookkeeping.
use crate::errors::SupraExtensionError;
use crate::{processTasksCall, removeRegisteredTaskCall, value_or_error};
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

/// Action to be preformed automation registry record
#[derive(Clone, Debug)]
pub enum AutomationRecordAction {
    /// Process the tasks during cycle transition.
    Process(Vec<u64>),
    /// Remove the task with specified index due to the reason provided by the runtime.
    Remove {
        /// Index of the task to be removed.
        task_index: u64,
        /// Reason of the removal
        reason: String
    },
}

impl AutomationRecordAction {
    /// Converts to vector of task indexes to be handled by action.
    pub fn into_task_indexes(self) -> Vec<u64> {
        match self {
            AutomationRecordAction::Process(tasks) => tasks,
            AutomationRecordAction::Remove {
                task_index,
                reason: _,
            } => vec![task_index],
        }
    }

    /// List of task indexes to be processed.
    /// If the action is [Self::Remove], None is returned
    pub fn task_indexes(&self) -> Option<&Vec<u64>> {
        match self {
            AutomationRecordAction::Process(tasks) => Some(tasks),
            AutomationRecordAction::Remove { .. } => None,
        }
    }

    /// Number of tasks to be handled by action.
    pub fn task_count(&self) -> usize {
        match self {
            AutomationRecordAction::Process(tasks) => tasks.len(),
            AutomationRecordAction::Remove { .. } => 1,
        }
    }

    /// Flattens action to be single task if multiple tasks are configured to be processed.
    pub fn flatten(self) -> Vec<Self> {
        match self {
            AutomationRecordAction::Process(tasks) => tasks
                .into_iter()
                .map(|t| AutomationRecordAction::Process(vec![t]))
                .collect(),
            AutomationRecordAction::Remove { .. } => vec![self],
        }
    }

    /// Returns minimum and maximum task indexes configured to be processed.
    pub fn task_range(&self) -> (u64, u64) {
        match self {
            AutomationRecordAction::Process(tasks) => (
                tasks.iter().min().cloned().unwrap_or(u64::MAX),
                tasks.iter().max().cloned().unwrap_or(u64::MAX),
            ),
            AutomationRecordAction::Remove { task_index, .. } => (*task_index, *task_index),
        }
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
    cycle_index: Option<u64>,
    action: Option<AutomationRecordAction>,
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
            cycle_index: None,
            action: None,
        }
    }
    pub fn with_block_height(mut self, block_height: u64) -> Self {
        self.block_height = Some(block_height);
        self
    }

    pub fn with_nonce(mut self, nonce: u64) -> Self {
        self.nonce = Some(nonce);
        self
    }

    pub fn with_gas_limit(mut self, gas_limit: u64) -> Self {
        self.gas_limit = Some(gas_limit);
        self
    }
    pub fn process_task_indexes(mut self, task_indexes: Vec<u64>) -> Self {
        self.action = Some(AutomationRecordAction::Process(task_indexes));
        self
    }

    pub fn remove_task(mut self, task_index: u64, reason: String) -> Self {
        self.action = Some(AutomationRecordAction::Remove { task_index, reason });
        self
    }

    pub fn with_cycle_index(mut self, cycle_index: u64) -> Self {
        self.cycle_index = Some(cycle_index);
        self
    }

    pub fn with_chain_id(mut self, chain_id: ChainId) -> Self {
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
            cycle_index,
            action,
        } = self;
        let block_height = value_or_error!(AutomationRecordBuilder, "block_height", block_height);
        let nonce = value_or_error!(AutomationRecordBuilder, "nonce", nonce);
        let gas_limit = value_or_error!(AutomationRecordBuilder, "gas_limit", gas_limit);
        let cycle_index = value_or_error!(AutomationRecordBuilder, "cycle_index", cycle_index);
        let chain_id = value_or_error!(AutomationRecordBuilder, "chain_id", chain_id);
        let action = value_or_error!(AutomationRecordBuilder, "action", action);
        let input = match action {
            AutomationRecordAction::Process(task_indexes) => {
                Self::get_process_tasks_payload(cycle_index, task_indexes)
            }
            AutomationRecordAction::Remove { task_index, reason } => {
                Self::get_remove_tasks_payload(task_index, reason)
            }
        };

        Ok(AutomationRegistryRecord {
            sender: VM_SIGNER,
            chain_id,
            block_height,
            nonce,
            gas_limit,
            to,
            input,
        })
    }

    /// Generates [`AutomationRegistryRecord`] input data to process tasks.
    pub fn get_process_tasks_payload(_cycle_index: u64, _task_indexes: Vec<u64>) -> Bytes {
        let process_task_call = processTasksCall {
            _cycleIndex: _cycle_index,
            _taskIndexes: _task_indexes.into_iter().map(U256::from).collect(),
        };
        Bytes::from(process_task_call.abi_encode())
    }

    /// Generates [`AutomationRegistryRecord`] input data to process tasks.
    pub fn get_remove_tasks_payload(task_index: u64, reason: String) -> Bytes {
        let remove_tasks_call = removeRegisteredTaskCall {
            _taskIndex: task_index,
            _reason: reason,
        };
        Bytes::from(remove_tasks_call.abi_encode())
    }

    pub fn task_count(&self) -> usize {
        self.action.as_ref().map(|a| a.task_count()).unwrap_or(0)
    }

    pub fn flatten(mut self) -> Vec<AutomationRecordBuilder> {
        let Some(action) = self.action.take() else {
            return vec![self];
        };
        let builder_base = self.clone();
        action
            .flatten()
            .into_iter()
            .map(|a| {
                let mut b = builder_base.clone();
                b.action = Some(a);
                b.nonce = None;
                b
            })
            .collect()
    }

    pub fn task_range(&self) -> (u64, u64) {
        self.action
            .as_ref()
            .map(|action| action.task_range())
            .unwrap_or_else(|| (u64::MAX, u64::MAX))
    }

    pub fn into_task_indexes(self) -> Vec<u64> {
        self.action
            .map(|action| action.into_task_indexes())
            .unwrap_or_default()
    }
}
