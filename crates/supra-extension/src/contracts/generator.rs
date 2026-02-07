//! Encloses transaction data generation logic based on the genesis contracts

use crate::contracts::transaction::{GenesisTransaction, GenesisTransactionTags};
use alloy::primitives::Address;
use alloy_sol_types::{sol, SolCall, SolConstructor};
use anyhow::{anyhow, Result};
use foundry_compilers::artifacts::ContractBytecode;
use primitives::supra_constants::VM_SIGNER;
use primitives::{Bytes, U256};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::BufReader;
use std::path::Path;

/// Output path of the compiled smart contracts, exported by build script.
const OUTPUT_PATH: &str = env!("COMPILED_CONTRACTS_DIR");

/////////////// Multi-Signature-Wallet related contracts and init APIs /////////////////////////////
const MULTISIG_WALLET: &str = "MultiSignatureWallet";
const MULTISIG_BEACON: &str = "MultisigBeacon";
const BEACON_PROXY: &str = "BeaconProxy";

sol! {
    contract MultiSignatureWallet {
        function initialize(address[] memory _owners, uint256 _numConfirmationsRequired);
    }
}

sol! {
    contract MultisigBeacon {
         constructor(address _implementation, address _owner);
    }
}

sol! {
    contract BeaconProxy {
         constructor(address _beacon, bytes _data);
    }
}

///////////////////// ERC20Supra related contracts and init APIs /////////////////////////////
const ERC20_SUPRA: &str = "ERC20Supra";
sol! {
    contract ERC20Supra {
         constructor(address _initialOwner);
    }
}

///////////////////// Block Meta related contracts and init APIs /////////////////////////////
const BLOCK_META: &str = "BlockMeta";
sol! {
    contract BlockMeta {
         function initialize(address _initialOwner);
    }
}

const ERC1967PROXY: &str = "ERC1967Proxy";

sol! {
    contract ERC1967Proxy {
         constructor(address _impl, bytes _data);
    }
}

///////////////////// Automation related contracts and init APIs /////////////////////////////

const AUTOMATION_CORE: &str = "AutomationCore";
const AUTOMATION_REGISTRY: &str = "AutomationRegistry";
const AUTOMATION_CONTROLLER: &str = "AutomationController";

sol! {
    /// Initialization parameters for AutomationCore contract.
    struct InitializeParams {
        uint64 taskDurationCapSecs;
        uint128 registryMaxGasCap;
        uint128 automationBaseFeeWeiPerSec;
        uint128 flatRegistrationFeeWei;
        uint8 congestionThresholdPercentage;
        uint128 congestionBaseFeeWeiPerSec;
        uint8 congestionExponent;
        uint16 taskCapacity;
        uint64 cycleDurationSecs;
        uint64 sysTaskDurationCapSecs;
        uint128 sysRegistryMaxGasCap;
        uint16 sysTaskCapacity;
        address vmSigner;
        address erc20Supra;
        address controller;
        address registry;
        address owner;
    }

    /// AutomationCore is a UUPS upgradeable contract - constructor has no parameters.
    /// Deployed behind ERC1967Proxy.
    contract AutomationCore {
        constructor();
        function initialize(InitializeParams calldata params);
    }

    /// AutomationRegistry is a UUPS upgradeable contract - constructor has no parameters.
    /// Deployed behind ERC1967Proxy.
    contract AutomationRegistry {
        constructor();
        function initialize(address _automationCore, address _automationController, address _owner);
    }

    /// AutomationController is a UUPS upgradeable contract - constructor has no parameters.
    /// Deployed behind ERC1967Proxy.
    contract AutomationController {
        constructor();
        function initialize(address _automationCore, address _registry, address _owner, bool _automationEnabled, uint64 _cycleDurationSecs);
    }
}

/// Configuration parameters for Automation Registry contracts initialization
#[derive(Debug, Clone)]
pub struct AutomationRegistryConfig {
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
}

impl Default for AutomationRegistryConfig {
    fn default() -> Self {
        Self {
            task_duration_cap_secs: 604800,
            registry_max_gas_cap: 8_000_000,
            automation_base_fee_wei_per_sec: 1_714_530_600_000,
            flat_registration_fee_wei: 21_431_633_000_000,
            congestion_threshold_percentage: 50,
            congestion_base_fee_wei_per_sec: 1_714_530_600_000,
            congestion_exponent: 6,
            task_capacity: 400,
            cycle_duration_secs: 600,
            sys_task_duration_cap_secs: 2626560,
            sys_registry_max_gas_cap: 2_000_000,
            sys_task_capacity: 100,
        }
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

/// Genesis Transaction generator using configured address as transaction owner.
/// It provides means to generate minimal mandatory set of genesis transactions to set up evm state,
/// and conditionally generates non-mandatory set of transactions.
#[derive(Debug)]
pub struct GenesisTransactionGenerator {
    nonce: u64,
    address: Address,
}

impl Default for GenesisTransactionGenerator {
    fn default() -> Self {
        Self::new(VM_SIGNER)
    }
}

impl GenesisTransactionGenerator {
    fn new(address: Address) -> Self {
        Self::new_with_nonce(address, 0)
    }

    fn new_with_nonce(address: Address, nonce: u64) -> Self {
        Self { nonce, address }
    }

    /// Prepares genesis transactions based on the input configuration.
    pub fn prepare_genesis_transactions(
        &mut self,
        config: GenesisTransactionGeneratorConfig,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        let GenesisTransactionGeneratorConfig {
            foundation_owners,
            foundation_threshold,
            full_set,
            automation_config,
        } = config;
        // First foundation multisig account setup should be done
        let mut genesis_transactions =
            self.setup_multisig_wallet(foundation_owners, foundation_threshold)?;
        if full_set {
            let multisig_address = *genesis_transactions
                .get(&GenesisTransactionTags::FoundationWallet)
                .expect("Foundation Wallet deployment transaction")
                .deploy_address();
            let erc20_supra_txn = self.setup_erc20_supra(multisig_address)?;
            let erc20_supra_address = *erc20_supra_txn.deploy_address();
            genesis_transactions.insert(GenesisTransactionTags::Erc20Supra, erc20_supra_txn);
            genesis_transactions.extend(self.setup_block_metadata(multisig_address)?.into_iter());
            if let Some(config) = automation_config {
                genesis_transactions.extend(
                    self.setup_automation_registry(multisig_address, erc20_supra_address, config)?
                        .into_iter(),
                );
            }
        };

        Ok(genesis_transactions)
    }

    /// Generates genesis transactions for foundation multisig wallet deployment.
    /// Deployment order follows GenesisTransactionTags:
    ///  1. MultisigWalletImpl (0) - MultiSignatureWallet implementation contract
    ///  2. MultisigBeacon (1) - Beacon contract pointing to implementation
    ///  3. FoundationWallet (2) - BeaconProxy with initialize(owners, threshold)
    ///
    /// The beacon pattern allows future upgrades by changing the implementation
    /// address in the beacon contract. The foundation wallet (BeaconProxy) will
    /// automatically use the new implementation.
    fn setup_multisig_wallet(
        &mut self,
        owners: Vec<Address>,
        threshold: u64,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        // -------------------------------------------------------------------------
        // Pre-compute all deployment addresses
        // nonce+0: MultiSignatureWallet implementation
        // nonce+1: MultisigBeacon
        // nonce+2: BeaconProxy (Foundation Wallet)
        // -------------------------------------------------------------------------
        let multisig_impl_address = self.address.create(self.nonce);
        let beacon_contract_address = self.address.create(self.nonce + 1);
        let multisig_wallet_address = self.address.create(self.nonce + 2);

        // -------------------------------------------------------------------------
        // 1. Deploy MultiSignatureWallet implementation (no constructor args)
        // -------------------------------------------------------------------------
        let multisig_impl_create_data = Self::load_contract_bytecode(MULTISIG_WALLET)?;
        let multisig_txn = GenesisTransaction::new(
            self.address.clone(),
            multisig_impl_create_data,
            self.nonce,
            multisig_impl_address,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 2. Deploy MultisigBeacon
        // Constructor args: implementation address, owner (the wallet itself)
        // The beacon owner is set to the wallet address for self-governance
        // -------------------------------------------------------------------------
        let multisig_beacon_create_data = Self::load_contract_bytecode(MULTISIG_BEACON)?;
        let beacon_args = MultisigBeacon::constructorCall {
            _implementation: multisig_impl_address,
            _owner: multisig_wallet_address,
        }
        .abi_encode();
        let beacon_txn_data = [multisig_beacon_create_data, beacon_args].concat();
        let multisig_beacon_txn = GenesisTransaction::new(
            self.address.clone(),
            beacon_txn_data,
            self.nonce,
            beacon_contract_address,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 3. Deploy BeaconProxy (Foundation Wallet)
        // Constructor args: beacon address, initialization data
        // Initialization data: initialize(owners[], threshold)
        // -------------------------------------------------------------------------
        let beacon_proxy_create_data = Self::load_contract_bytecode(BEACON_PROXY)?;
        // Encode the initialize call data for MultiSignatureWallet
        let multisig_init_data = MultiSignatureWallet::initializeCall {
            _owners: owners,
            _numConfirmationsRequired: U256::from(threshold),
        }
        .abi_encode();
        // Encode the BeaconProxy constructor args
        let beacon_proxy_args = BeaconProxy::constructorCall {
            _beacon: beacon_contract_address,
            _data: Bytes::from(multisig_init_data),
        }
        .abi_encode();
        // Concatenate bytecode + constructor args for deployment
        let beacon_proxy_txn_data = [beacon_proxy_create_data, beacon_proxy_args].concat();
        let beacon_proxy_txn = GenesisTransaction::new(
            self.address.clone(),
            beacon_proxy_txn_data,
            self.nonce,
            multisig_wallet_address,
        );
        self.nonce += 1;

        Ok(BTreeMap::from([
            (GenesisTransactionTags::MultisigWalletImpl, multisig_txn),
            (GenesisTransactionTags::MultisigBeacon, multisig_beacon_txn),
            (GenesisTransactionTags::FoundationWallet, beacon_proxy_txn),
        ]))
    }

    /// Generates genesis transaction for ERC20Supra token contract deployment.
    /// Deployment order follows GenesisTransactionTags:
    ///  1. Erc20Supra (3) - ERC20 token contract with constructor(initialOwner)
    ///
    /// This is a non-upgradeable contract deployed directly (not behind a proxy).
    /// The initial owner (typically the foundation multisig wallet) receives
    /// administrative privileges over the token contract.
    fn setup_erc20_supra(&mut self, initial_owner: Address) -> Result<GenesisTransaction> {
        // -------------------------------------------------------------------------
        // Pre-compute deployment address
        // -------------------------------------------------------------------------
        let contract_address = self.address.create(self.nonce);

        // -------------------------------------------------------------------------
        // Deploy ERC20Supra
        // Constructor args: initial owner address
        // -------------------------------------------------------------------------
        let erc20_contract_create_data = Self::load_contract_bytecode(ERC20_SUPRA)?;
        // Encode the constructor args
        let erc20_constructor_args = ERC20Supra::constructorCall {
            _initialOwner: initial_owner,
        }
        .abi_encode();
        // Concatenate bytecode + constructor args for deployment
        let erc20_txn_data = [erc20_contract_create_data, erc20_constructor_args].concat();
        let txn =
            GenesisTransaction::new(self.address, erc20_txn_data, self.nonce, contract_address);
        self.nonce += 1;

        Ok(txn)
    }

    /// Generates genesis transactions for BlockMeta contract deployment.
    /// Deployment order follows GenesisTransactionTags:
    ///  1. BlockMetadataImpl (4) - BlockMeta implementation contract (UUPS upgradeable)
    ///  2. BlockMetadata (5) - ERC1967Proxy with initialize(initialOwner)
    ///
    /// BlockMeta is a UUPS upgradeable contract deployed behind an ERC1967Proxy.
    /// The proxy pattern allows future upgrades while maintaining the same address.
    fn setup_block_metadata(
        &mut self,
        initial_owner: Address,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        // -------------------------------------------------------------------------
        // Pre-compute all deployment addresses
        // nonce+0: BlockMeta implementation
        // nonce+1: ERC1967Proxy (BlockMetadata)
        // -------------------------------------------------------------------------
        let block_metadata_impl_address = self.address.create(self.nonce);
        let block_metadata_proxy_address = self.address.create(self.nonce + 1);

        // -------------------------------------------------------------------------
        // 1. Deploy BlockMeta implementation (UUPS - no constructor args)
        // -------------------------------------------------------------------------
        let block_metadata_impl = Self::load_contract_bytecode(BLOCK_META)?;
        let block_metadata_impl_txn = GenesisTransaction::new(
            self.address,
            block_metadata_impl,
            self.nonce,
            block_metadata_impl_address,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 2. Deploy ERC1967Proxy (BlockMetadata)
        // Constructor args: implementation address, initialization data
        // Initialization data: initialize(initialOwner)
        // -------------------------------------------------------------------------
        let proxy_impl_data = Self::load_contract_bytecode(ERC1967PROXY)?;
        // Encode the initialize call data for BlockMeta
        let block_metadata_initialize = BlockMeta::initializeCall {
            _initialOwner: initial_owner,
        }
        .abi_encode();
        // Encode the ERC1967Proxy constructor args
        let proxy_args = ERC1967Proxy::constructorCall {
            _impl: block_metadata_impl_address,
            _data: block_metadata_initialize.into(),
        }
        .abi_encode();
        // Concatenate bytecode + constructor args for deployment
        let proxy_txn_data = [proxy_impl_data, proxy_args].concat();
        let block_metadata_proxy_txn = GenesisTransaction::new(
            self.address,
            proxy_txn_data,
            self.nonce,
            block_metadata_proxy_address,
        );
        self.nonce += 1;

        Ok(BTreeMap::from([
            (
                GenesisTransactionTags::BlockMetadataImpl,
                block_metadata_impl_txn,
            ),
            (
                GenesisTransactionTags::BlockMetadata,
                block_metadata_proxy_txn,
            ),
        ]))
    }

    /// Generates genesis transactions for automation contracts deployment.
    /// Deployment order follows GenesisTransactionTags:
    ///  1. AutomationControllerImpl - implementation contract
    ///  2. AutomationController - ERC1967Proxy with initialize(automationCore, registry)
    ///  3. AutomationCoreImpl - implementation contract
    ///  4. AutomationCore - ERC1967Proxy with initialize(InitializeParams)
    ///  5. AutomationRegistryImpl - implementation contract
    ///  6. AutomationRegistry - ERC1967Proxy with initialize(automationCore, automationController)
    ///
    /// All proxy addresses are pre-computed before deployment to handle circular dependencies.
    fn setup_automation_registry(
        &mut self,
        owner: Address,
        erc20_supra_address: Address,
        config: AutomationRegistryConfig,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        // Pre-compute all deployment addresses
        // nonce+0: AutomationControllerImpl
        // nonce+1: AutomationController (proxy)
        // nonce+2: AutomationCoreImpl
        // nonce+3: AutomationCore (proxy)
        // nonce+4: AutomationRegistryImpl
        // nonce+5: AutomationRegistry (proxy)
        let controller_impl_address = self.address.create(self.nonce);
        let controller_proxy_address = self.address.create(self.nonce + 1);
        let core_impl_address = self.address.create(self.nonce + 2);
        let core_proxy_address = self.address.create(self.nonce + 3);
        let registry_impl_address = self.address.create(self.nonce + 4);
        let registry_proxy_address = self.address.create(self.nonce + 5);

        let proxy_bytecode = Self::load_contract_bytecode(ERC1967PROXY)?;

        // -------------------------------------------------------------------------
        // 1. Deploy AutomationControllerImpl (UUPS - no constructor args)
        // -------------------------------------------------------------------------
        let controller_impl_bytecode = Self::load_contract_bytecode(AUTOMATION_CONTROLLER)?;
        let controller_impl_txn = GenesisTransaction::new(
            self.address,
            controller_impl_bytecode,
            self.nonce,
            controller_impl_address,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 2. Deploy AutomationController proxy
        // -------------------------------------------------------------------------
        let controller_init_data = AutomationController::initializeCall {
            _automationCore: core_proxy_address,
            _registry: registry_proxy_address,
            _owner: owner,
            _automationEnabled: true,
            _cycleDurationSecs: config.cycle_duration_secs,
        }
        .abi_encode();
        let controller_proxy_args = ERC1967Proxy::constructorCall {
            _impl: controller_impl_address,
            _data: Bytes::from(controller_init_data),
        }
        .abi_encode();
        let controller_proxy_txn_data = [proxy_bytecode.clone(), controller_proxy_args].concat();
        let controller_proxy_txn = GenesisTransaction::new(
            self.address,
            controller_proxy_txn_data,
            self.nonce,
            controller_proxy_address,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 3. Deploy AutomationCoreImpl (UUPS - no constructor args)
        // -------------------------------------------------------------------------
        let core_impl_bytecode = Self::load_contract_bytecode(AUTOMATION_CORE)?;
        let core_impl_txn = GenesisTransaction::new(
            self.address,
            core_impl_bytecode,
            self.nonce,
            core_impl_address,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 4. Deploy AutomationCore proxy
        // -------------------------------------------------------------------------
        let core_init_params = InitializeParams {
            taskDurationCapSecs: config.task_duration_cap_secs,
            registryMaxGasCap: config.registry_max_gas_cap,
            automationBaseFeeWeiPerSec: config.automation_base_fee_wei_per_sec,
            flatRegistrationFeeWei: config.flat_registration_fee_wei,
            congestionThresholdPercentage: config.congestion_threshold_percentage,
            congestionBaseFeeWeiPerSec: config.congestion_base_fee_wei_per_sec,
            congestionExponent: config.congestion_exponent,
            taskCapacity: config.task_capacity,
            cycleDurationSecs: config.cycle_duration_secs,
            sysTaskDurationCapSecs: config.sys_task_duration_cap_secs,
            sysRegistryMaxGasCap: config.sys_registry_max_gas_cap,
            sysTaskCapacity: config.sys_task_capacity,
            vmSigner: VM_SIGNER,
            erc20Supra: erc20_supra_address,
            controller: controller_proxy_address,
            registry: registry_proxy_address,
            owner,
        };
        let core_init_data = AutomationCore::initializeCall {
            params: core_init_params,
        }
        .abi_encode();
        let core_proxy_args = ERC1967Proxy::constructorCall {
            _impl: core_impl_address,
            _data: Bytes::from(core_init_data),
        }
        .abi_encode();
        let core_proxy_txn_data = [proxy_bytecode.clone(), core_proxy_args].concat();
        let core_proxy_txn = GenesisTransaction::new(
            self.address,
            core_proxy_txn_data,
            self.nonce,
            core_proxy_address,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 5. Deploy AutomationRegistryImpl (UUPS - no constructor args)
        // -------------------------------------------------------------------------
        let registry_impl_bytecode = Self::load_contract_bytecode(AUTOMATION_REGISTRY)?;
        let registry_impl_txn = GenesisTransaction::new(
            self.address,
            registry_impl_bytecode,
            self.nonce,
            registry_impl_address,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 6. Deploy AutomationRegistry proxy
        // -------------------------------------------------------------------------
        let registry_init_data = AutomationRegistry::initializeCall {
            _automationCore: core_proxy_address,
            _automationController: controller_proxy_address,
            _owner: owner,
        }
        .abi_encode();
        let registry_proxy_args = ERC1967Proxy::constructorCall {
            _impl: registry_impl_address,
            _data: Bytes::from(registry_init_data),
        }
        .abi_encode();
        let registry_proxy_txn_data = [proxy_bytecode, registry_proxy_args].concat();
        let registry_proxy_txn = GenesisTransaction::new(
            self.address,
            registry_proxy_txn_data,
            self.nonce,
            registry_proxy_address,
        );
        self.nonce += 1;

        Ok(BTreeMap::from([
            (
                GenesisTransactionTags::AutomationControllerImpl,
                controller_impl_txn,
            ),
            (
                GenesisTransactionTags::AutomationController,
                controller_proxy_txn,
            ),
            (GenesisTransactionTags::AutomationCoreImpl, core_impl_txn),
            (GenesisTransactionTags::AutomationCore, core_proxy_txn),
            (
                GenesisTransactionTags::AutomationRegistryImpl,
                registry_impl_txn,
            ),
            (
                GenesisTransactionTags::AutomationRegistry,
                registry_proxy_txn,
            ),
        ]))
    }

    fn load_contract_bytecode(name: &str) -> Result<Vec<u8>> {
        let path = Path::new(OUTPUT_PATH)
            .join(format!("{name}.sol"))
            .join(format!("{name}.json"));
        let file = File::open(&path)?;
        let buf_reader = BufReader::new(file);
        let contract: ContractBytecode = serde_json::from_reader(buf_reader)?;
        contract
            .bytecode
            .and_then(|b| b.bytes().cloned())
            .map(|b| b.to_vec())
            .filter(|b| !b.is_empty())
            .ok_or_else(|| anyhow!("Failed to load bytecode for contract: {name}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use primitives::supra_constants::u64_to_address;

    #[test]
    fn check_multisig_setup() {
        let mut generator = GenesisTransactionGenerator::default();
        let owners = vec![u64_to_address(1), u64_to_address(2), u64_to_address(3)];
        let mut config = GenesisTransactionGeneratorConfig {
            foundation_owners: owners,
            foundation_threshold: 2,
            full_set: false,
            automation_config: None,
        };
        let result = generator.prepare_genesis_transactions(config.clone()).unwrap();
        assert_eq!(result.len(), 3) ;
        assert!(result.contains_key(&GenesisTransactionTags::MultisigWalletImpl));
        assert!(result.contains_key(&GenesisTransactionTags::MultisigBeacon));
        assert!(result.contains_key(&GenesisTransactionTags::FoundationWallet));

        // Enable full set of contract generation without automation config
        config.full_set = true;
        let result = generator
            .prepare_genesis_transactions(config)
            .expect("Successful txn generation");
        assert!(result.contains_key(&GenesisTransactionTags::FoundationWallet));
        assert!(result.contains_key(&GenesisTransactionTags::BlockMetadata));
        assert!(result.contains_key(&GenesisTransactionTags::Erc20Supra));
        // Verify automation contracts are not deployed
        assert!(!result.contains_key(&GenesisTransactionTags::AutomationControllerImpl));
        assert!(!result.contains_key(&GenesisTransactionTags::AutomationController));
        assert!(!result.contains_key(&GenesisTransactionTags::AutomationCoreImpl));
        assert!(!result.contains_key(&GenesisTransactionTags::AutomationCore));
        assert!(!result.contains_key(&GenesisTransactionTags::AutomationRegistryImpl));
        assert!(!result.contains_key(&GenesisTransactionTags::AutomationRegistry));
        println!("{result:#?}");
    }

    #[test]
    fn check_automation_with_custom_config() {
        let mut generator = GenesisTransactionGenerator::default();
        let owners = vec![u64_to_address(1), u64_to_address(2), u64_to_address(3)];
        let custom_config = AutomationRegistryConfig {
            task_duration_cap_secs: 7200,
            registry_max_gas_cap: 20_000_000,
            task_capacity: 1000,
            ..Default::default()
        };
        let config = GenesisTransactionGeneratorConfig {
            foundation_owners: owners,
            foundation_threshold: 2,
            full_set: true,
            automation_config: Some(custom_config),
        };
        let result = generator
            .prepare_genesis_transactions(config)
            .expect("Successful txn generation");

        // Verify all automation contracts are deployed
        assert!(result.contains_key(&GenesisTransactionTags::AutomationControllerImpl));
        assert!(result.contains_key(&GenesisTransactionTags::AutomationController));
        assert!(result.contains_key(&GenesisTransactionTags::AutomationCoreImpl));
        assert!(result.contains_key(&GenesisTransactionTags::AutomationCore));
        assert!(result.contains_key(&GenesisTransactionTags::AutomationRegistryImpl));
        assert!(result.contains_key(&GenesisTransactionTags::AutomationRegistry));
        println!("{result:#?}");
    }
}
