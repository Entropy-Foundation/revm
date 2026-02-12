//! Configurations to generate genesis transactions

use primitives::Address;

/// Configuration parameters for Automation Registry contracts initialization
#[derive(Debug, Clone)]
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

impl Default for AutomationRegistryConfigV1 {
    fn default() -> Self {
        Self {
            // 7 days
            task_duration_cap_secs: 604800,
            registry_max_gas_cap: 8_000_000,
            // 0.004 SUPRA normalized based on the supra denominator between move and evm currency
            automation_base_fee_wei_per_sec: 1_714_530_600_000,
            // 0.05 SUPRA normalized based on the supra denominator between move and evm currency
            flat_registration_fee_wei: 21_431_633_000_000,
            congestion_threshold_percentage: 50,
            // 0.004 SUPRA normalized based on the supra denominator between move and evm currency
            congestion_base_fee_wei_per_sec: 1_714_530_600_000,
            congestion_exponent: 6,
            task_capacity: 400,
            cycle_duration_secs: 600,
            // ~1 month
            sys_task_duration_cap_secs: 2626560,
            sys_registry_max_gas_cap: 2_000_000,
            sys_task_capacity: 100,
            enable_automation_feature: true,
        }
    }
}

/// Configuration parameters for Automation Registry contracts initialization
#[derive(Debug, Clone)]
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
}

impl From<AutomationRegistryConfigV1> for AutomationRegistryConfig {
    fn from(config: AutomationRegistryConfigV1) -> Self {
        Self::V1(config)
    }
}

/// Genesis Transaction generator configuration details
#[derive(Debug, Clone)]
pub struct GenesisTransactionGeneratorConfig {
    /// List of EOAs to set up multisig foundation wallet.
    pub foundation_owners: Vec<Address>,
    /// Threshold of the foundation multisig wallet.
    pub foundation_threshold: u64,
    /// Flag indicating whether full set of genesis transaction should be generated or only mandatory once.
    pub full_set: bool,
    /// Automation configuration parameters (optional, uses defaults if None).
    pub automation_config: Option<AutomationRegistryConfig>,
}
