//! Automation registry transaction record definition to assist automation bookkeeping.

use crate::errors::SupraExtensionError;
use crate::{processTasksCall, removeRegisteredTaskCall, value_or_error};
use alloy::eips::eip2930::AccessList;
use alloy::primitives::{Address, Bytes, ChainId, TxKind, B256, U256};
use alloy_consensus::constants::SELECTOR_LEN;
use alloy_consensus::transaction::Transaction;
use alloy_eips::eip2718::Typed2718;
use alloy_sol_types::SolCall;
use context::transaction::SignedAuthorization;
use context::TransactionType;
use enum_kinds::EnumKind;
use primitives::supra_constants::VM_SIGNER;

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
/// Transaction representing automation transaction record which will trigger automation task processing
/// during cycle transitions assisting automation bookkeeping flow.
pub struct AutomationRegistryRecord {
    /// Address of the transaction sender. By default, it will be [`VM_SIGNER`] reserved addressed by supra.
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

impl AutomationRegistryRecord {
    /// Attempts to convert input bytes of [`AutomationRegistryRecord`] to [`AutomationRegistryAction`]
    pub fn try_convert_to_action(&self) -> Result<AutomationRecordAction, SupraExtensionError> {
        if self.input.len() < SELECTOR_LEN {
            return Err(SupraExtensionError::InvalidAutomationRecord(
                "Invalid input, not enough bytes for selector".to_string(),
            ));
        };
        let selector = &self.input[..SELECTOR_LEN];
        if removeRegisteredTaskCall::SELECTOR.as_slice().eq(selector) {
            removeRegisteredTaskCall::abi_decode(&self.input)
                .map_err(SupraExtensionError::from)
                .map(AutomationRecordAction::Remove)
        } else if processTasksCall::SELECTOR.as_slice().eq(selector) {
            processTasksCall::abi_decode(&self.input)
                .map_err(SupraExtensionError::from)
                .map(AutomationRecordAction::Process)
        } else {
            Err(SupraExtensionError::InvalidAutomationRecord(format!(
                "Unrecognized selector: {selector:?}"
            )))
        }
    }

    /// Attempts to deduce [`AutomationRecordActionTag`] form input bytes of [`AutomationRegistryRecord`]
    pub fn try_get_action_tag(&self) -> Result<AutomationRecordActionTag, SupraExtensionError> {
        if self.input.len() < SELECTOR_LEN {
            return Err(SupraExtensionError::InvalidAutomationRecord(
                "Invalid input, not enough bytes for selector".to_string(),
            ));
        };
        let selector = &self.input[..SELECTOR_LEN];
        if removeRegisteredTaskCall::SELECTOR.as_slice().eq(selector) {
            Ok(AutomationRecordActionTag::Remove)
        } else if processTasksCall::SELECTOR.as_slice().eq(selector) {
            Ok(AutomationRecordActionTag::Process)
        } else {
            Err(SupraExtensionError::InvalidAutomationRecord(format!(
                "Unrecognized selector: {selector:?}"
            )))
        }
    }

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
#[derive(Clone, Debug, PartialEq, Eq, Hash, EnumKind)]
#[enum_kind(AutomationRecordActionTag)]
pub enum AutomationRecordAction {
    /// Process the tasks during cycle transition.
    Process(processTasksCall),
    /// Remove the task with specified index due to the reason provided by the runtime.
    Remove(removeRegisteredTaskCall),
}

impl AutomationRecordAction {

    /// Crate process action with provided cycle index and list of task indexes to be processed.
    pub fn process(cycle_index: u64, task_indexes: Vec<u64>) -> Self {
        Self::Process( processTasksCall {
            _cycleIndex: cycle_index,
            _taskIndexes: task_indexes.into_iter().map(U256::from).collect(),
        })
    }

    /// Crate remove action with provided cycle index and list of task indexes to be processed.
    pub fn remove(cycle_index: u64, task_index: u64, reason: String) -> Self {
        Self::Remove( removeRegisteredTaskCall {
            _cycleIndex: cycle_index,
            _taskIndex: task_index,
            _reason: reason,
        })
    }

    /// Converts to vector of task indexes to be handled by action.
    pub fn into_task_indexes(self) -> Vec<u64> {
        match self {
            AutomationRecordAction::Process(task) => task
                ._taskIndexes
                .iter()
                .map(|t| t.saturating_to::<u64>())
                .collect(),
            AutomationRecordAction::Remove(task) => vec![task._taskIndex],
        }
    }

    /// Number of tasks to be handled by action.
    pub fn task_count(&self) -> usize {
        match self {
            AutomationRecordAction::Process(task) => task._taskIndexes.len(),
            AutomationRecordAction::Remove { .. } => 1,
        }
    }

    /// Flattens action to be single task if multiple tasks are configured to be processed.
    pub fn flatten(self) -> Vec<Self> {
        match self {
            AutomationRecordAction::Process(task) => {
                let cycle_index = task._cycleIndex;
                task._taskIndexes
                    .into_iter()
                    .map(|t| {
                        AutomationRecordAction::Process(processTasksCall {
                            _cycleIndex: cycle_index,
                            _taskIndexes: vec![t],
                        })
                    })
                    .collect()
            }
            AutomationRecordAction::Remove { .. } => vec![self],
        }
    }

    /// Returns minimum and maximum task indexes configured to be processed.
    pub fn task_range(&self) -> (u64, u64) {
        match self {
            AutomationRecordAction::Process(task) => (
                task._taskIndexes
                    .iter()
                    .min()
                    .map(|t| t.saturating_to::<u64>())
                    .unwrap_or(u64::MAX),
                task._taskIndexes
                    .iter()
                    .max()
                    .map(|t| t.saturating_to::<u64>())
                    .unwrap_or(u64::MAX),
            ),
            AutomationRecordAction::Remove(task) => (task._taskIndex, task._taskIndex),
        }
    }

    fn set_cycle_index(&mut self, cycle_index: u64) {
        match self {
            AutomationRecordAction::Process(task) => task._cycleIndex = cycle_index,
            AutomationRecordAction::Remove(task) => task._cycleIndex = cycle_index,
        }
    }

    /// Converts into abi encoded bytes.
    pub  fn into_bytes(self) -> Bytes {
        match self {
            AutomationRecordAction::Process(task) => task.abi_encode().into(),
            AutomationRecordAction::Remove(task) => task.abi_encode().into(),
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
        self.action = Some(AutomationRecordAction::process(u64::MAX, task_indexes));
        self
    }

    pub fn remove_task(mut self, task_index: u64, reason: String) -> Self {
        self.action = Some(AutomationRecordAction::remove(u64::MAX, task_index, reason));
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
        let mut action = value_or_error!(AutomationRecordBuilder, "action", action);
        action.set_cycle_index(cycle_index);
        let input = action.into_bytes();

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

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::address;
    use alloy_consensus::transaction::Transaction;
    use primitives::supra_constants::VM_SIGNER;

    const REGISTRY_ADDR: Address = address!("0000000000000000000000000000000000001234");
    const CHAIN_ID: ChainId = 6;
    const BLOCK_HEIGHT: u64 = 100;
    const NONCE: u64 = 3;
    const GAS_LIMIT: u64 = 500_000;
    const CYCLE_INDEX: u64 = 42;

    fn get_process_tasks_payload(_cycle_index: u64, _task_indexes: Vec<u64>) -> Bytes {
        let process_task_call = processTasksCall {
            _cycleIndex: _cycle_index,
            _taskIndexes: _task_indexes.into_iter().map(U256::from).collect(),
        };
        Bytes::from(process_task_call.abi_encode())
    }

    fn get_remove_tasks_payload(cycle_index: u64, task_index: u64, reason: String) -> Bytes {
        let remove_tasks_call = removeRegisteredTaskCall {
            _cycleIndex: cycle_index,
            _taskIndex: task_index,
            _reason: reason,
        };
        Bytes::from(remove_tasks_call.abi_encode())
    }

    fn base_builder() -> AutomationRecordBuilder {
        AutomationRecordBuilder::new(REGISTRY_ADDR)
            .with_chain_id(CHAIN_ID)
            .with_block_height(BLOCK_HEIGHT)
            .with_nonce(NONCE)
            .with_gas_limit(GAS_LIMIT)
            .with_cycle_index(CYCLE_INDEX)
    }

    // ── Builder: successful builds ────────────────────────────────────────────

    #[test]
    fn build_process_record_sets_all_fields() {
        let record = base_builder()
            .process_task_indexes(vec![1, 2, 3])
            .build()
            .unwrap();

        assert_eq!(record.sender, VM_SIGNER);
        assert_eq!(record.chain_id, CHAIN_ID);
        assert_eq!(record.block_height, BLOCK_HEIGHT);
        assert_eq!(record.nonce, NONCE);
        assert_eq!(record.gas_limit, GAS_LIMIT);
        assert_eq!(record.to, REGISTRY_ADDR);
        assert!(!record.input.is_empty());
    }

    #[test]
    fn build_remove_record_sets_all_fields() {
        let record = base_builder()
            .remove_task(7, "expired".to_string())
            .build()
            .unwrap();

        assert_eq!(record.sender, VM_SIGNER);
        assert_eq!(record.chain_id, CHAIN_ID);
        assert_eq!(record.block_height, BLOCK_HEIGHT);
        assert_eq!(record.nonce, NONCE);
        assert_eq!(record.gas_limit, GAS_LIMIT);
        assert_eq!(record.to, REGISTRY_ADDR);
        assert!(!record.input.is_empty());
    }

    #[test]
    fn build_process_record_with_empty_task_list() {
        let record = base_builder().process_task_indexes(vec![]).build().unwrap();
        assert!(!record.input.is_empty()); // selector + ABI-encoded empty array still produces bytes
    }

    // ── Builder: missing mandatory field errors ───────────────────────────────

    #[test]
    fn build_missing_block_height_returns_error() {
        let err = AutomationRecordBuilder::new(REGISTRY_ADDR)
            .with_chain_id(CHAIN_ID)
            .with_nonce(NONCE)
            .with_gas_limit(GAS_LIMIT)
            .with_cycle_index(CYCLE_INDEX)
            .process_task_indexes(vec![1])
            .build()
            .unwrap_err();
        assert!(
            matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "block_height")
        );
    }

    #[test]
    fn build_missing_nonce_returns_error() {
        let err = AutomationRecordBuilder::new(REGISTRY_ADDR)
            .with_chain_id(CHAIN_ID)
            .with_block_height(BLOCK_HEIGHT)
            .with_gas_limit(GAS_LIMIT)
            .with_cycle_index(CYCLE_INDEX)
            .process_task_indexes(vec![1])
            .build()
            .unwrap_err();
        assert!(matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "nonce"));
    }

    #[test]
    fn build_missing_gas_limit_returns_error() {
        let err = AutomationRecordBuilder::new(REGISTRY_ADDR)
            .with_chain_id(CHAIN_ID)
            .with_block_height(BLOCK_HEIGHT)
            .with_nonce(NONCE)
            .with_cycle_index(CYCLE_INDEX)
            .process_task_indexes(vec![1])
            .build()
            .unwrap_err();
        assert!(
            matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "gas_limit")
        );
    }

    #[test]
    fn build_missing_cycle_index_returns_error() {
        let err = AutomationRecordBuilder::new(REGISTRY_ADDR)
            .with_chain_id(CHAIN_ID)
            .with_block_height(BLOCK_HEIGHT)
            .with_nonce(NONCE)
            .with_gas_limit(GAS_LIMIT)
            .process_task_indexes(vec![1])
            .build()
            .unwrap_err();
        assert!(
            matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "cycle_index")
        );
    }

    #[test]
    fn build_missing_chain_id_returns_error() {
        let err = AutomationRecordBuilder::new(REGISTRY_ADDR)
            .with_block_height(BLOCK_HEIGHT)
            .with_nonce(NONCE)
            .with_gas_limit(GAS_LIMIT)
            .with_cycle_index(CYCLE_INDEX)
            .process_task_indexes(vec![1])
            .build()
            .unwrap_err();
        assert!(
            matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "chain_id")
        );
    }

    #[test]
    fn build_missing_action_returns_error() {
        let err = AutomationRecordBuilder::new(REGISTRY_ADDR)
            .with_chain_id(CHAIN_ID)
            .with_block_height(BLOCK_HEIGHT)
            .with_nonce(NONCE)
            .with_gas_limit(GAS_LIMIT)
            .with_cycle_index(CYCLE_INDEX)
            .build()
            .unwrap_err();
        assert!(matches!(err, SupraExtensionError::MissingBuilderValue(_, ref f) if f == "action"));
    }

    // ── Transaction trait impl ────────────────────────────────────────────────

    #[test]
    fn transaction_trait_field_accessors() {
        let record = base_builder()
            .process_task_indexes(vec![5])
            .build()
            .unwrap();

        assert_eq!(record.chain_id(), Some(CHAIN_ID));
        assert_eq!(record.nonce(), NONCE);
        assert_eq!(record.gas_limit(), GAS_LIMIT);
        assert_eq!(record.gas_price(), None);
        assert_eq!(record.max_fee_per_gas(), 0);
        assert_eq!(record.max_priority_fee_per_gas(), Some(0));
        assert_eq!(record.max_fee_per_blob_gas(), None);
        assert_eq!(record.priority_fee_or_price(), 0);
        assert_eq!(record.effective_gas_price(None), 0);
        assert_eq!(record.effective_gas_price(Some(100)), 0);
        assert!(!record.is_dynamic_fee());
        assert_eq!(record.kind(), TxKind::Call(REGISTRY_ADDR));
        assert!(!record.is_create());
        assert_eq!(record.value(), U256::ZERO);
        assert_eq!(record.access_list(), None);
        assert_eq!(record.blob_versioned_hashes(), None);
        assert_eq!(record.authorization_list(), None);
    }

    #[test]
    fn transaction_input_matches_built_payload() {
        let task_indexes = vec![10u64, 20];
        let record = base_builder()
            .process_task_indexes(task_indexes.clone())
            .build()
            .unwrap();

        let expected = get_process_tasks_payload(CYCLE_INDEX, task_indexes);
        assert_eq!(record.input(), &expected);
    }

    // ── try_convert_to_action ─────────────────────────────────────────────────

    #[test]
    fn convert_process_input_roundtrips() {
        let task_indexes = vec![1u64, 2, 3];
        let record = base_builder()
            .process_task_indexes(task_indexes.clone())
            .build()
            .unwrap();

        let action = record.try_convert_to_action().unwrap();
        let AutomationRecordAction::Process(process) = action else {
            panic!("Expected Process action, got {action:?}");
        };
        assert_eq!(process._cycleIndex, CYCLE_INDEX);
        assert_eq!(
            process._taskIndexes,
            task_indexes.into_iter().map(U256::from).collect::<Vec<_>>()
        );
    }

    #[test]
    fn convert_remove_input_roundtrips() {
        let record = base_builder()
            .remove_task(99, "bad task".to_string())
            .build()
            .unwrap();

        let action = record.try_convert_to_action().unwrap();
        let AutomationRecordAction::Remove(remove) = action else {
            panic!("Expected Remove action, got {action:?}");
        };
        assert_eq!(remove._cycleIndex, CYCLE_INDEX);
        assert_eq!(remove._taskIndex, 99);
        assert_eq!(remove._reason, "bad task".to_string());
    }

    #[test]
    fn convert_empty_input_returns_error() {
        let record = AutomationRegistryRecord {
            input: Bytes::default(),
            ..Default::default()
        };
        assert!(matches!(
            record.try_convert_to_action(),
            Err(SupraExtensionError::InvalidAutomationRecord(_))
        ));
    }

    #[test]
    fn convert_short_input_returns_error() {
        let record = AutomationRegistryRecord {
            input: Bytes::from(vec![0xAB, 0xCD]),
            ..Default::default()
        };
        assert!(matches!(
            record.try_convert_to_action(),
            Err(SupraExtensionError::InvalidAutomationRecord(_))
        ));
    }

    #[test]
    fn convert_unknown_selector_returns_error() {
        let record = AutomationRegistryRecord {
            input: Bytes::from(vec![0xDE, 0xAD, 0xBE, 0xEF, 0x00]),
            ..Default::default()
        };
        assert!(matches!(
            record.try_convert_to_action(),
            Err(SupraExtensionError::InvalidAutomationRecord(_))
        ));
    }

    // ── try_get_action_tag ────────────────────────────────────────────────────

    #[test]
    fn get_action_tag_process() {
        let record = base_builder()
            .process_task_indexes(vec![1])
            .build()
            .unwrap();
        assert_eq!(
            record.try_get_action_tag().unwrap(),
            AutomationRecordActionTag::Process
        );
    }

    #[test]
    fn get_action_tag_remove() {
        let record = base_builder()
            .remove_task(5, "reason".to_string())
            .build()
            .unwrap();
        assert_eq!(
            record.try_get_action_tag().unwrap(),
            AutomationRecordActionTag::Remove
        );
    }

    #[test]
    fn get_action_tag_empty_input_returns_error() {
        let record = AutomationRegistryRecord {
            input: Bytes::default(),
            ..Default::default()
        };
        assert!(matches!(
            record.try_get_action_tag(),
            Err(SupraExtensionError::InvalidAutomationRecord(_))
        ));
    }

    #[test]
    fn get_action_tag_unknown_selector_returns_error() {
        let record = AutomationRegistryRecord {
            input: Bytes::from(vec![0xFF, 0xFF, 0xFF, 0xFF]),
            ..Default::default()
        };
        assert!(matches!(
            record.try_get_action_tag(),
            Err(SupraExtensionError::InvalidAutomationRecord(_))
        ));
    }

    // ── AutomationRecordAction methods ────────────────────────────────────────

    #[test]
    fn action_into_task_indexes_process() {
        let action = AutomationRecordAction::Process(processTasksCall {
            _cycleIndex: 0,
            _taskIndexes: vec![U256::from(10), U256::from(20), U256::from(30)],
        });
        assert_eq!(action.into_task_indexes(), vec![10, 20, 30]);
    }

    #[test]
    fn action_into_task_indexes_remove() {
        let action = AutomationRecordAction::Remove(removeRegisteredTaskCall {
            _taskIndex: 7,
            _reason: String::new(),
            _cycleIndex: 8,
        });
        assert_eq!(action.into_task_indexes(), vec![7]);
    }

    #[test]
    fn action_task_count() {
        let action = AutomationRecordAction::Process(processTasksCall {
            _cycleIndex: 0,
            _taskIndexes: vec![U256::from(10), U256::from(20), U256::from(30)],
        });
        assert_eq!(action.task_count(), 3);

        let action = AutomationRecordAction::Process(processTasksCall {
            _cycleIndex: 0,
            _taskIndexes: vec![],
        });
        assert_eq!(action.task_count(), 0);
        assert_eq!(
            AutomationRecordAction::Remove(removeRegisteredTaskCall {
                _cycleIndex: 4,
                _taskIndex: 2,
                _reason: "".to_string(),
            })
            .task_count(),
            1
        );
    }

    #[test]
    fn action_flatten_process_produces_single_task_actions() {
        let action = AutomationRecordAction::Process(processTasksCall {
            _cycleIndex: 2,
            _taskIndexes: vec![U256::from(1), U256::from(2), U256::from(3)],
        });
        let flat = action.flatten();
        assert_eq!(flat.len(), 3);
        flat.into_iter().enumerate().for_each(|(idx, item)| {
            let AutomationRecordAction::Process(process) = item else {
                panic!("Expected Process action, got {item:?}");
            };
            assert_eq!(process._cycleIndex, 2);
            assert_eq!(process._taskIndexes, vec![U256::from(idx + 1)]);
        });
    }

    #[test]
    fn action_flatten_remove_stays_single() {
        let action = AutomationRecordAction::Remove(removeRegisteredTaskCall {
            _taskIndex: 5,
            _reason: "x".to_string(),
            _cycleIndex: 7,
        });
        let flat = action.clone().flatten();
        assert_eq!(flat.len(), 1);
        assert_eq!(flat[0], action);
    }

    #[test]
    fn action_task_range_process() {
        let action = AutomationRecordAction::Process(processTasksCall {
            _cycleIndex: 0,
            _taskIndexes: vec![U256::from(3), U256::from(1), U256::from(4), U256::from(5)],
        });
        assert_eq!(action.task_range(), (1, 5));
    }

    #[test]
    fn action_task_range_empty_process_returns_max() {
        let action = AutomationRecordAction::Process(processTasksCall {
            _cycleIndex: 0,
            _taskIndexes: vec![],
        });
        assert_eq!(action.task_range(), (u64::MAX, u64::MAX));
    }

    #[test]
    fn action_task_range_remove() {
        let action = AutomationRecordAction::Remove (removeRegisteredTaskCall {
            _taskIndex: 42,
            _reason: String::new(),
            _cycleIndex: 3,
        });
        assert_eq!(action.task_range(), (42, 42));
    }

    // ── AutomationRecordBuilder utility methods ───────────────────────────────

    #[test]
    fn builder_task_count_no_action() {
        let builder = AutomationRecordBuilder::new(REGISTRY_ADDR);
        assert_eq!(builder.task_count(), 0);
    }

    #[test]
    fn builder_task_count_with_action() {
        let builder = base_builder().process_task_indexes(vec![1, 2, 3]);
        assert_eq!(builder.task_count(), 3);
    }

    #[test]
    fn builder_task_range_no_action() {
        let builder = AutomationRecordBuilder::new(REGISTRY_ADDR);
        assert_eq!(builder.task_range(), (u64::MAX, u64::MAX));
    }

    #[test]
    fn builder_task_range_with_action() {
        let builder = base_builder().process_task_indexes(vec![5, 2, 8]);
        assert_eq!(builder.task_range(), (2, 8));
    }

    #[test]
    fn builder_into_task_indexes() {
        let builder = base_builder().process_task_indexes(vec![7, 8, 9]);
        assert_eq!(builder.into_task_indexes(), vec![7, 8, 9]);
    }

    #[test]
    fn builder_into_task_indexes_no_action() {
        let builder = AutomationRecordBuilder::new(REGISTRY_ADDR);
        assert_eq!(builder.into_task_indexes(), Vec::<u64>::new());
    }

    #[test]
    fn builder_flatten_clears_nonce_on_each_part() {
        let builder = base_builder().process_task_indexes(vec![1, 2, 3]);
        let parts = builder.flatten();
        assert_eq!(parts.len(), 3);
        for part in &parts {
            assert!(part.action.is_some());
            assert!(part.nonce.is_none(), "nonce must be cleared after flatten");
        }
    }

    #[test]
    fn builder_flatten_remove_is_single_and_keeps_nonce_cleared() {
        let builder = base_builder().remove_task(10, "r".to_string());
        let parts = builder.flatten();
        assert_eq!(parts.len(), 1);
        assert!(parts[0].nonce.is_none());
    }

    #[test]
    fn builder_flatten_no_action_returns_self() {
        let builder = base_builder();
        let parts = builder.flatten();
        assert_eq!(parts.len(), 1);
    }
}
