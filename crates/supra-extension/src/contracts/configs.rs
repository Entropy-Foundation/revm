//! Configurations to generate genesis transactions

use crate::transactions::block_metadata::BLOCK_METADATA_GAS_LIMIT;
use primitives::Address;
use serde::{Deserialize, Serialize};

/// Maximum number of automation tasks that the registry can hold.
/// The limit is deduced by running a benchmark for `monitorCycleEnd` automation registry function
/// which tracks automation cycle end and prepares the transaction state for graceful cycle transaction handling.
/// It is registered to be executed as part of the `BlockMeta::blockPrologue`.
/// The internal system `BlockMetadata` transaction generated and executed by consensus layer
/// specifies the gas limit for it to be [`BLOCK_METADATA_GAS_LIMIT`]. Taking into account the fact the
/// registered entries are limited with gas-cap in scope of `BlockMeta::blockPrologue`,
/// the results of the benchmark and need to keep buffer for future entries of the `BlockMeta::blockPrologue`
/// the limit of 200 tasks is specified.
///
//   ┌───────────┬──────────────────────────────┐
//   │ Tasks (N) │           Gas used           │
//   ├───────────┼──────────────────────────────┤
//   │ 50        │ 1,201,348                    │
//   ├───────────┼──────────────────────────────┤
//   │ 100       │ 2,344,564                    │
//   ├───────────┼──────────────────────────────┤
//   │ 150       │ 3,487,790                    │
//   ├───────────┼──────────────────────────────┤
//   │ 200       │ 4,632,120                    │
//   ├───────────┼──────────────────────────────┤
//   │ 250       │ 5,775,366                    │
//   ├───────────┼──────────────────────────────┤
//   │ 300       │ 6,918,621                    │
//   ├───────────┼──────────────────────────────┤
//   │ 350       │ 8,061,886                    │
//   ├───────────┼──────────────────────────────┤
//   │ 720       │ 16,522,351                   │
//   ├───────────┼──────────────────────────────┤
//   │ 800       │ 18,351,711 ⚠️ exceeds budget  │
//   └───────────┴──────────────────────────────┘
//
// (Figures from `forge test --match-contract MonitorCycleEndGasTest -vv` in
// solidity/supra_contracts/test/MonitorCycleEndGas.t.sol, re-run after the
// `expectedTasksToBeProcessed` storage layout was optimized, roughly halving the per-task cost.
// That same run's `testMonitorCycleEndGas_BoundaryScan` binary-searches the exact
// safe ceiling: 731 tasks stay under BLOCK_METADATA_GAS_LIMIT, 732 exceeds it.
// 200 is kept far below that ceiling deliberately, as buffer for other future
// `BlockMeta::blockPrologue` entries and for the 63/64 forwarding-rule margin
// applied on top of BLOCK_METADATA_GAS_LIMIT (see `GenesisTransactionGeneratorConfig::is_valid`).
pub const MAX_SUPPORTED_AUTOMATION_TASKS: u16 = 200;

/// Default maximum allowable duration (in seconds) from the registration time that a user
/// automation task can run. Set to 7 days.
pub const DEFAULT_TASK_DURATION_CAP_SECS: u64 = 604800;
/// Default maximum gas allocation for automation tasks per cycle.
pub const DEFAULT_REGISTRY_MAX_GAS_CAP: u128 = 8_000_000;
/// Default base fee per second for the full capacity of the automation registry, measured in
/// wei/sec. Equivalent to 0.004 SUPRA normalized based on the supra denominator between move
/// and evm currency.
pub const DEFAULT_AUTOMATION_BASE_FEE_WEI_PER_SEC: u128 = 1_714_530_600_000;
/// Default flat registration fee charged for each task. Equivalent to 0.05 SUPRA normalized
/// based on the supra denominator between move and evm currency.
pub const DEFAULT_FLAT_REGISTRATION_FEE_WEI: u128 = 21_431_633_000_000;
/// Default percentage representing the acceptable upper limit of committed gas amount relative
/// to `registry_max_gas_cap`.
pub const DEFAULT_CONGESTION_THRESHOLD_PERCENTAGE: u8 = 50;
/// Default base fee per second for the full capacity of the automation registry when the
/// congestion threshold is exceeded. Equivalent to 0.004 SUPRA normalized based on the supra
/// denominator between move and evm currency.
pub const DEFAULT_CONGESTION_BASE_FEE_WEI_PER_SEC: u128 = 1_714_530_600_000;
/// Default exponent that the congestion fee increases by exponentially.
pub const DEFAULT_CONGESTION_EXPONENT: u8 = 6;
/// Default maximum number of tasks that the registry can hold.
/// `task_capacity + sys_task_capacity` must not exceed [`MAX_SUPPORTED_AUTOMATION_TASKS`].
pub const DEFAULT_TASK_CAPACITY: u16 = 160;
/// Default automation cycle duration in seconds.
pub const DEFAULT_CYCLE_DURATION_SECS: u64 = 600;
/// Default maximum allowable duration (in seconds) from the registration time that a system
/// automation task can run. Set to ~1 month.
pub const DEFAULT_SYS_TASK_DURATION_CAP_SECS: u64 = 2626560;
/// Default maximum gas allocation for system automation tasks per cycle.
pub const DEFAULT_SYS_REGISTRY_MAX_GAS_CAP: u128 = 2_000_000;
/// Default maximum number of system tasks that the registry can hold.
pub const DEFAULT_SYS_TASK_CAPACITY: u16 = 40;
/// Default flag indicating whether the automation feature is enabled at startup.
pub const DEFAULT_ENABLE_AUTOMATION_FEATURE: bool = true;

/// Configuration parameters for Automation Registry contracts initialization
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutomationRegistryConfigV1 {
    /// Maximum allowable duration (in seconds) from the registration time that a user automation task can run.
    pub task_duration_cap_secs: u64,
    /// Maximum gas allocation for automation tasks per cycle.
    pub registry_max_gas_cap: u128,
    /// Base fee per second for the full capacity of the automation registry, measured in wei/sec.
    pub automation_base_fee_wei_per_sec: u128,
    /// Flat registration fee charged by default for each task.
    pub flat_registration_fee_wei: u128,
    /// Percentage representing the acceptable upper limit of committed gas amount relative to registry_max_gas_cap.
    pub congestion_threshold_percentage: u8,
    /// Base fee per second for the full capacity of the automation registry when the congestion threshold is exceeded.
    pub congestion_base_fee_wei_per_sec: u128,
    /// The congestion fee increases exponentially based on this value.
    pub congestion_exponent: u8,
    /// Maximum number of tasks that the registry can hold.
    pub task_capacity: u16,
    /// Automation cycle duration in seconds.
    pub cycle_duration_secs: u64,
    /// Maximum allowable duration (in seconds) from the registration time that a system automation task can run.
    pub sys_task_duration_cap_secs: u64,
    /// Maximum gas allocation for system automation tasks per cycle.
    pub sys_registry_max_gas_cap: u128,
    /// Maximum number of system tasks that the registry can hold.
    pub sys_task_capacity: u16,
    /// Indicates whether the automation feature is enabled at startup
    pub enable_automation_feature: bool,
}

impl AutomationRegistryConfigV1 {
    /// Checks whether the config is valid to create non-failable transactions.
    pub fn is_valid(&self) -> Result<(), anyhow::Error> {
        if self.task_duration_cap_secs == 0 || self.sys_task_duration_cap_secs == 0 {
            return Err(anyhow::anyhow!(
                "[System] Task duration cap must be positive"
            ));
        }
        if self.registry_max_gas_cap == 0 || self.sys_registry_max_gas_cap == 0 {
            return Err(anyhow::anyhow!(
                "[System] Registry max gas cap must be positive"
            ));
        }
        if self.cycle_duration_secs > self.task_duration_cap_secs
            || self.cycle_duration_secs > self.sys_task_duration_cap_secs
        {
            return Err(anyhow::anyhow!(
                "[System] Task duration cap should be greater than cycle duration"
            ));
        }
        if self.congestion_threshold_percentage > 100 {
            return Err(anyhow::anyhow!(
                "Congestion threshold percentage should be less or equal to 100"
            ));
        }
        if self.sys_task_capacity == 0 || self.task_capacity == 0 {
            return Err(anyhow::anyhow!("Task capacity cannot be 0"));
        }
        if self.congestion_exponent == 0 {
            return Err(anyhow::anyhow!("Congestion exponent cannot be 0"));
        }
        if self.sys_task_capacity.saturating_add(self.task_capacity)
            > MAX_SUPPORTED_AUTOMATION_TASKS
        {
            return Err(anyhow::anyhow!(
                "Total supported task capacity exceeded: {MAX_SUPPORTED_AUTOMATION_TASKS}"
            ));
        }
        Ok(())
    }
}

impl Default for AutomationRegistryConfigV1 {
    fn default() -> Self {
        Self {
            task_duration_cap_secs: DEFAULT_TASK_DURATION_CAP_SECS,
            registry_max_gas_cap: DEFAULT_REGISTRY_MAX_GAS_CAP,
            automation_base_fee_wei_per_sec: DEFAULT_AUTOMATION_BASE_FEE_WEI_PER_SEC,
            flat_registration_fee_wei: DEFAULT_FLAT_REGISTRATION_FEE_WEI,
            congestion_threshold_percentage: DEFAULT_CONGESTION_THRESHOLD_PERCENTAGE,
            congestion_base_fee_wei_per_sec: DEFAULT_CONGESTION_BASE_FEE_WEI_PER_SEC,
            congestion_exponent: DEFAULT_CONGESTION_EXPONENT,
            task_capacity: DEFAULT_TASK_CAPACITY,
            cycle_duration_secs: DEFAULT_CYCLE_DURATION_SECS,
            sys_task_duration_cap_secs: DEFAULT_SYS_TASK_DURATION_CAP_SECS,
            sys_registry_max_gas_cap: DEFAULT_SYS_REGISTRY_MAX_GAS_CAP,
            sys_task_capacity: DEFAULT_SYS_TASK_CAPACITY,
            enable_automation_feature: DEFAULT_ENABLE_AUTOMATION_FEATURE,
        }
    }
}

/// Configuration parameters for Automation Registry contracts initialization
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AutomationRegistryConfig {
    /// First version of the evm automation registry contract configurations
    V1(AutomationRegistryConfigV1),
}

impl AutomationRegistryConfig {
    /// Returns [AutomationRegistryConfigV1] if the variant is [Self::V1]
    pub fn v1(&self) -> Option<&AutomationRegistryConfigV1> {
        let Self::V1(config) = self;
        Some(config)
    }

    /// Checks validity of automation registry configuration.
    pub fn is_valid(&self) -> Result<(), anyhow::Error> {
        let Self::V1(v1) = self;
        v1.is_valid()
    }
}

impl From<AutomationRegistryConfigV1> for AutomationRegistryConfig {
    fn from(config: AutomationRegistryConfigV1) -> Self {
        Self::V1(config)
    }
}

/// Genesis Transaction generator configuration details
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenesisTransactionGeneratorConfig {
    /// List of EOAs to set up multisig foundation wallet.
    pub foundation_owners: Vec<Address>,
    /// Threshold of the foundation multisig wallet.
    pub foundation_threshold: u64,
    /// Flag indicating whether full set of genesis transaction should be generated or only mandatory once.
    pub full_set: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    /// Automation configuration parameters (optional, uses defaults if None).
    pub automation_config: Option<AutomationRegistryConfig>,
    /// Initial native tokens to be minted to ERC20Supra handler contract
    pub initial_native_token: u128,
    /// Gas cap for block-prologue/block-metadata transaction.
    pub block_prologue_gas_cap: u64,
}

impl GenesisTransactionGeneratorConfig {
    /// Checks whether the config is valid to create non-failable transactions.
    pub fn is_valid(&self) -> Result<(), anyhow::Error> {
        if self.block_prologue_gas_cap == 0 {
            return Err(anyhow::anyhow!("Block prologue gas cap must be positive"));
        }
        // Cap the block prologue gas cap with [`BLOCK_METADATA_GAS_LIMIT`] of the initial release of SEVM.
        if self.block_prologue_gas_cap > BLOCK_METADATA_GAS_LIMIT {
            return Err(anyhow::anyhow!("Block prologue gas cap must not exceed the default BlockMetadata GasLimit ({BLOCK_METADATA_GAS_LIMIT})"));
        }
        if self.foundation_owners.is_empty() {
            return Err(anyhow::anyhow!("Foundation owners must be provided"));
        }
        if self.foundation_threshold > self.foundation_owners.len() as u64 {
            return Err(anyhow::anyhow!(
                "Foundation threshold must be less or equal the number of owners"
            ));
        }
        if let Some(automation_config) = &self.automation_config {
            automation_config.is_valid()?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use primitives::supra_constants::u64_to_address;

    fn owners(n: u64) -> Vec<Address> {
        (1..=n).map(u64_to_address).collect()
    }

    /// A hand-picked config satisfying every `AutomationRegistryConfigV1::is_valid` rule,
    /// including `task_capacity + sys_task_capacity <= MAX_SUPPORTED_AUTOMATION_TASK`.
    fn valid_automation_config() -> AutomationRegistryConfigV1 {
        AutomationRegistryConfigV1 {
            task_capacity: 100,
            sys_task_capacity: 50,
            ..AutomationRegistryConfigV1::default()
        }
    }

    fn valid_genesis_config() -> GenesisTransactionGeneratorConfig {
        GenesisTransactionGeneratorConfig {
            foundation_owners: owners(3),
            foundation_threshold: 2,
            full_set: false,
            automation_config: None,
            initial_native_token: 1000,
            block_prologue_gas_cap: 100_000,
        }
    }

    // --- AutomationRegistryConfigV1::is_valid ---

    #[test]
    fn valid_automation_config_is_accepted() {
        assert!(valid_automation_config().is_valid().is_ok());
    }

    /// `Default` must stay within `MAX_SUPPORTED_AUTOMATION_TASK` so that
    /// `AutomationRegistryConfigV1::default()` is always a valid config out of the box.
    #[test]
    fn default_automation_config_is_valid() {
        assert!(AutomationRegistryConfigV1::default().is_valid().is_ok());
    }

    #[test]
    fn zero_task_duration_cap_secs_is_rejected() {
        let config = AutomationRegistryConfigV1 {
            task_duration_cap_secs: 0,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn zero_sys_task_duration_cap_secs_is_rejected() {
        let config = AutomationRegistryConfigV1 {
            sys_task_duration_cap_secs: 0,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn zero_registry_max_gas_cap_is_rejected() {
        let config = AutomationRegistryConfigV1 {
            registry_max_gas_cap: 0,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn zero_sys_registry_max_gas_cap_is_rejected() {
        let config = AutomationRegistryConfigV1 {
            sys_registry_max_gas_cap: 0,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn cycle_duration_exceeding_task_duration_cap_is_rejected() {
        let config = AutomationRegistryConfigV1 {
            task_duration_cap_secs: 100,
            cycle_duration_secs: 101,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn cycle_duration_exceeding_sys_task_duration_cap_is_rejected() {
        let config = AutomationRegistryConfigV1 {
            sys_task_duration_cap_secs: 100,
            cycle_duration_secs: 101,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn cycle_duration_equal_to_task_duration_cap_is_accepted() {
        let config = AutomationRegistryConfigV1 {
            task_duration_cap_secs: 100,
            sys_task_duration_cap_secs: 100,
            cycle_duration_secs: 100,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_ok());
    }

    #[test]
    fn congestion_threshold_percentage_over_100_is_rejected() {
        let config = AutomationRegistryConfigV1 {
            congestion_threshold_percentage: 101,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn congestion_threshold_percentage_of_100_is_accepted() {
        let config = AutomationRegistryConfigV1 {
            congestion_threshold_percentage: 100,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_ok());
    }

    #[test]
    fn zero_task_capacity_is_rejected() {
        let config = AutomationRegistryConfigV1 {
            task_capacity: 0,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn zero_sys_task_capacity_is_rejected() {
        let config = AutomationRegistryConfigV1 {
            sys_task_capacity: 0,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn zero_congestion_exponent_is_rejected() {
        let config = AutomationRegistryConfigV1 {
            congestion_exponent: 0,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn task_capacity_sum_exceeding_max_supported_is_rejected() {
        let config = AutomationRegistryConfigV1 {
            task_capacity: 150,
            sys_task_capacity: 51,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn task_capacity_sum_equal_to_max_supported_is_accepted() {
        let config = AutomationRegistryConfigV1 {
            task_capacity: 150,
            sys_task_capacity: 50,
            ..valid_automation_config()
        };
        assert!(config.is_valid().is_ok());
    }

    // --- AutomationRegistryConfig::is_valid (V1 wrapper delegation) ---

    #[test]
    fn config_enum_delegates_to_v1_valid_case() {
        let config: AutomationRegistryConfig = valid_automation_config().into();
        assert!(config.is_valid().is_ok());
    }

    #[test]
    fn config_enum_delegates_to_v1_invalid_case() {
        let v1 = AutomationRegistryConfigV1 {
            registry_max_gas_cap: 0,
            ..valid_automation_config()
        };
        let config: AutomationRegistryConfig = v1.into();
        assert!(config.is_valid().is_err());
    }

    // --- GenesisTransactionGeneratorConfig::is_valid ---

    #[test]
    fn valid_genesis_config_without_automation_is_accepted() {
        assert!(valid_genesis_config().is_valid().is_ok());
    }

    #[test]
    fn zero_block_prologue_gas_cap_is_rejected() {
        let config = GenesisTransactionGeneratorConfig {
            block_prologue_gas_cap: 0,
            ..valid_genesis_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn block_prologue_gas_cap_at_63_64_boundary_is_accepted() {
        let upper_bound = (BLOCK_METADATA_GAS_LIMIT as u128) * 63 / 64;
        let config = GenesisTransactionGeneratorConfig {
            block_prologue_gas_cap: upper_bound as u64,
            ..valid_genesis_config()
        };
        assert!(config.is_valid().is_ok());
    }

    #[test]
    fn block_prologue_gas_cap_above_block_metadata_gas_limit_is_rejected() {
        let upper_bound = BLOCK_METADATA_GAS_LIMIT;
        let config = GenesisTransactionGeneratorConfig {
            block_prologue_gas_cap: (upper_bound + 1) as u64,
            ..valid_genesis_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn empty_foundation_owners_is_rejected() {
        let config = GenesisTransactionGeneratorConfig {
            foundation_owners: vec![],
            ..valid_genesis_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn foundation_threshold_above_owner_count_is_rejected() {
        let config = GenesisTransactionGeneratorConfig {
            foundation_owners: owners(3),
            foundation_threshold: 4,
            ..valid_genesis_config()
        };
        assert!(config.is_valid().is_err());
    }

    #[test]
    fn foundation_threshold_equal_to_owner_count_is_accepted() {
        let config = GenesisTransactionGeneratorConfig {
            foundation_owners: owners(3),
            foundation_threshold: 3,
            ..valid_genesis_config()
        };
        assert!(config.is_valid().is_ok());
    }

    #[test]
    fn foundation_threshold_below_owner_count_is_accepted() {
        let config = GenesisTransactionGeneratorConfig {
            foundation_owners: owners(3),
            foundation_threshold: 1,
            ..valid_genesis_config()
        };
        assert!(config.is_valid().is_ok());
    }

    #[test]
    fn valid_genesis_config_with_valid_automation_is_accepted() {
        let config = GenesisTransactionGeneratorConfig {
            automation_config: Some(valid_automation_config().into()),
            ..valid_genesis_config()
        };
        assert!(config.is_valid().is_ok());
    }

    #[test]
    fn invalid_automation_config_propagates_error() {
        let bad_automation = AutomationRegistryConfigV1 {
            congestion_exponent: 0,
            ..valid_automation_config()
        };
        let config = GenesisTransactionGeneratorConfig {
            automation_config: Some(bad_automation.into()),
            ..valid_genesis_config()
        };
        assert!(config.is_valid().is_err());
    }
}
