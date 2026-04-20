//! Configurations to generate genesis transactions

use serde::{Deserialize, Serialize};
use primitives::{address, Address};

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
}

impl From<AutomationRegistryConfigV1> for AutomationRegistryConfig {
    fn from(config: AutomationRegistryConfigV1) -> Self {
        Self::V1(config)
    }
}

/// Configuration to generate supra-nova contracts for genesis
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SupraNovaConfig {
    /// Dora storage addressed utilized by fee operator.
    pub  dora_storage_address: Address,
    /// WETH9 address utilized by token vault and token bridge.
    pub  weth9_address: Address,
    /// Hypernova message index.
    pub  hypernova_msg_id: u64,
    /// USDT pair index in Dora.
    pub  supra_usdt_pair_idx: u64,
    /// Maximum stale oracle price limit.
    pub  max_stale_oracle_price_limit: u64,
}

impl Default for SupraNovaConfig {
    fn default() -> Self {
        Self {
            dora_storage_address: Self::DORA_STORAGE_TESTNET,
            weth9_address: Self::WETH9_TESTNET,
            hypernova_msg_id: 0,
            supra_usdt_pair_idx: Self::SUPRA_USDT_PAIR_INDEX,
            max_stale_oracle_price_limit: Self::MAX_STALE_ORACLE_PRICE_LIMIT,
        }
    }
}


impl SupraNovaConfig {
    pub(crate) const WRAPPED_TOKEN_IMPL_SALT: &'static str = "supranova.WrappedToken.v1";
    pub(crate) const WRAPPED_TOKEN_FACTORY_IMPL_SALT:&'static str = "supranova.WrappedTokenFactory.v1";
    pub(crate) const WRAPPED_TOKEN_FACTORY_PROXY_SALT: &'static str = "supranova.WrappedTokenFactoryProxy.v1";

    pub(crate) const HYPER_NOVA_IMPL_SALT: &'static str = "supranova.Hypernova.v2";
    pub(crate) const HYPER_NOVA_PROXY_SALT: &'static str = "supranova.HypernovaProxy.v2";

    pub(crate) const FEE_OPERATOR_IMPL_SALT: &'static str = "supranova.FeeOperator.v2";
    pub(crate) const FEE_OPERATOR_PROXY_SALT: &'static str = "supranova.FeeOperatorProxy.v2";

    pub(crate) const DORA_STORAGE_TESTNET: Address = address!("0x131918bC49Bb7de74aC7e19d61A01544242dAA80");
    pub(crate) const SUPRA_USDT_PAIR_INDEX: u64 = 500;
    pub(crate) const MAX_STALE_ORACLE_PRICE_LIMIT:u64 = 86400;

    pub(crate) const TOKEN_BRIDGE_IMPL_SALT: &'static str = "supranova.TokenBridge.v2";
    pub(crate) const TOKEN_BRIDGE_PROXY_SALT: &'static str = "supranova.TokenBridgeProxy.v2";

    pub(crate) const WETH9_TESTNET: Address = address!("0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14");


    pub(crate) const TOKEN_VAULT_IMPL_SALT: &'static str = "supranova.TokenVault.v2";
    pub(crate) const TOKEN_VAULT_PROXY_SALT: &'static str = "supranova.TokenVaultProxy.v2";

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
    pub  initial_native_token: u128,
    #[serde(skip_serializing_if = "Option::is_none")]
    /// Indicates whether the genesis transactions are generated for localnet.
    pub  supra_nova_config: Option<SupraNovaConfig>,
}
