//! Encloses transaction data generation logic based on the genesis contracts

use crate::contracts::configs::{
    AutomationRegistryConfig, GenesisTransactionGeneratorConfig, SupraNovaConfig,
};
use crate::contracts::supra_nova_contracts::{
    FeeOperator, FeeOperatorProxy, Hypernova, HypernovaProxy, TokenBridge, TokenBridgeProxy,
    TokenVault, TokenVaultProxy, WrappedTokenFactory, WrappedTokenFactoryProxy, FEE_OPERATOR,
    FEE_OPERATOR_PROXY, HYPERNOVA, HYPERNOVA_PROXY, TOKEN_BRIDGE, TOKEN_BRIDGE_PROXY, TOKEN_VAULT,
    TOKEN_VAULT_PROXY, WRAPPED_TOKEN, WRAPPED_TOKEN_FACTORY, WRAPPED_TOKEN_FACTORY_PROXY,
};
use crate::contracts::transaction::{
    GenesisTransaction, GenesisTransactionTags, CREATE2_FACTORY_ADDRESS, CREATE2_FACTORY_CODE,
    CREATE2_FACTORY_OWNER,
};
use alloy::primitives::Address;
use alloy_sol_types::{sol, SolCall, SolConstructor};
use anyhow::{anyhow, Result};
use bincode::config;
use once_cell::sync::Lazy;
use primitives::supra_constants::VM_SIGNER;
use primitives::{Bytes, TxKind, U256};
use std::collections::BTreeMap;

/// Load precompiled combined bytecode of contracts.
const CONTRACT_BYTECODES_RAW: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/supra_contracts_bytecode.bin"));

const CONTRACT_BYTECODES: Lazy<BTreeMap<String, Vec<u8>>> = Lazy::new(|| {
    // Deserialize the bytecodes from the raw bytes
    let (bytecodes, _) =
        bincode::serde::decode_from_slice(CONTRACT_BYTECODES_RAW, config::standard())
            .expect("Failed to deserialize contract bytecodes");
    bytecodes
});

/////////////// Multi-Signature-Wallet related contracts and init APIs /////////////////////////////
const MULTISIG_WALLET: &str = "MultiSignatureWallet";
const MULTISIG_BEACON: &str = "MultisigBeacon";
const BEACON_PROXY: &str = "BeaconProxy";

sol! {
    contract MultiSignatureWallet {
        function initialize(address[] memory _owners, uint256 _numConfirmationsRequired);
    }

    contract MultisigBeacon {
         constructor(address _implementation, address _owner);
    }

    contract BeaconProxy {
         constructor(address _beacon, bytes _data);
    }
}

///////////////////// ERC20Supra related contracts and init APIs /////////////////////////////
const ERC20_SUPRA: &str = "ERC20Supra";
const ERC20_SUPRA_HANDLER: &str = "ERC20SupraHandler";
sol! {
    contract ERC20Supra {
         function initialize(address _initialOwner, address[] memory _authorizedAddresses);
    }

    contract ERC20SupraHandler {
         function initialize(address _initialOwner, address _erc20Supra);
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

const DIAMOND_CUT_FACET: &str = "DiamondCutFacet";
const DIAMOND: &str = "Diamond";
const DIAMOND_LOUPE_FACET: &str = "DiamondLoupeFacet";
const OWNERSHIP_FACET: &str = "OwnershipFacet";
const CONFIG_FACET: &str = "ConfigFacet";
const REGISTRY_FACET: &str = "RegistryFacet";
const CORE_FACET: &str = "CoreFacet";
const DIAMOND_INIT: &str = "DiamondInit";

sol! {

    /// Initialization parameters for Automation Registry State.
    struct InitParams {
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
        bool registrationEnabled;
        bool automationEnabled;
    }

    /// Addresses of the facets for diamond cut and diamond initializer contract
    struct FacetsDeployment {
        address diamondCutFacet;
        address loupeFacet;
        address ownershipFacet;
        address configFacet;
        address registryFacet;
        address coreFacet;
        address diamondInit;
    }

    contract Diamond {
        constructor(
            address _contractOwner,
            FacetsDeployment memory _facets,
            address _erc20Supra,
            InitParams memory _params
        );
    }

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

    /// Generates Create2Factory contract deployment transaction.
    fn generate_create2_factory_transaction() -> GenesisTransaction {
        GenesisTransaction::new(
            CREATE2_FACTORY_OWNER,
            0,
            0,
            CREATE2_FACTORY_CODE.to_owned(),
            TxKind::Create,
            CREATE2_FACTORY_ADDRESS,
        )
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
            initial_native_token,
            supra_nova_config,
        } = config;
        // First Create2 Factory contract deployment, which will allow later to utilize create2 API
        // if required during genesis
        let mut genesis_transactions = BTreeMap::from([(
            GenesisTransactionTags::Create2Factory,
            Self::generate_create2_factory_transaction(),
        )]);
        // Second multisig contract and foundation multisig account setup should be done
        genesis_transactions
            .extend(self.setup_multisig_wallet(foundation_owners, foundation_threshold)?);
        if full_set {
            let multisig_address = *genesis_transactions
                .get(&GenesisTransactionTags::FoundationWallet)
                .expect("Foundation Wallet deployment transaction")
                .deploy_address();

            // Erc20 Supra contracts
            let erc20_contracts =
                self.setup_erc20_contracts(multisig_address, initial_native_token)?;
            let erc20supra_address = *erc20_contracts
                .get(&GenesisTransactionTags::Erc20Supra)
                .expect("Erc20Supra deployment transaction exists")
                .deploy_address();
            genesis_transactions.extend(erc20_contracts);

            // BlockMetadata contract
            genesis_transactions.extend(self.setup_block_metadata(multisig_address)?.into_iter());

            // Automation registry contracts
            if let Some(config) = automation_config {
                genesis_transactions.extend(
                    self.setup_automation_registry(multisig_address, erc20supra_address, config)?
                        .into_iter(),
                );
            }

            // Supra Nova/Bridge contracts
            if let Some(nova_conig) = supra_nova_config {
                genesis_transactions
                    .extend(self.setup_supra_nova_contracts(nova_conig, multisig_address)?);
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
        let multisig_txn = GenesisTransaction::create(
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
        let multisig_beacon_txn = GenesisTransaction::create(
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
        let beacon_proxy_txn = GenesisTransaction::create(
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

    /// Generates Erc20Supra and Erc20SupraHandler contracts deployment transactions.
    /// Both are ERC1967Proxy upgradeable contracts, and are deployed in the same transaction
    /// batch to ensure correct initial authorization setup.
    fn setup_erc20_contracts(
        &mut self,
        owner: Address,
        initial_native_tokens: u128,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        // Precomputed addresses
        // nonce + 0: ERC20Supra Impl
        // nonce + 1: ERC20Supra (Proxy)
        // nonce + 2: ERC20SupraHandler Impl
        // nonce + 3: ERC20SupraHandler (Proxy)
        let erc20_supra_address = self.address.create(self.nonce + 1);
        let erc20_handler_address = self.address.create(self.nonce + 3);

        // For now only erc20supra handler address is specified as authorized, the bridge one will be specified past deployment
        let mut erc20_supra_txn = self.setup_erc20_supra(owner, vec![erc20_handler_address])?;
        let gen_erc20_supra_address = *erc20_supra_txn
            .get(&GenesisTransactionTags::Erc20Supra)
            .expect("Erc20Supra should be deployed")
            .deploy_address();
        assert_eq!(
            erc20_supra_address, gen_erc20_supra_address,
            "Address computed by tag and nonce should be the same"
        );

        let erc20_handler_txn =
            self.setup_erc20_supra_handler(owner, gen_erc20_supra_address, initial_native_tokens)?;
        let gen_erc20_handler_address = *erc20_handler_txn
            .get(&GenesisTransactionTags::Erc20SupraHandler)
            .expect("Erc20Supra should be deployed")
            .deploy_address();
        assert_eq!(
            erc20_handler_address, gen_erc20_handler_address,
            "Address computed by tag and nonce should be the same"
        );

        erc20_supra_txn.extend(erc20_handler_txn);
        Ok(erc20_supra_txn)
    }

    /// Generates genesis transaction for ERC20Supra token contract deployment.
    /// Deployment order follows GenesisTransactionTags:
    ///  1. ERC20SupraImpl (nonce+0) - ERC20Supra implementation contract (UUPS upgradeable)
    ///  2. ERC20Supra (nonce+1) - ERC1967Proxy with initialize(initialOwner, authorizedAddresses[])
    ///
    /// The initial owner (typically the foundation multisig wallet) receives
    /// administrative privileges over the token contract.
    fn setup_erc20_supra(
        &mut self,
        initial_owner: Address,
        authorized_addresses: Vec<Address>,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        // -------------------------------------------------------------------------
        // Pre-compute deployment address
        // -------------------------------------------------------------------------
        let erc20_supra_address_impl = self.address.create(self.nonce);
        let erc20_supra_address = self.address.create(self.nonce + 1);

        // -------------------------------------------------------------------------
        // 1. Deploy ERC20Supra
        // -------------------------------------------------------------------------
        let erc20_contract_create_data = Self::load_contract_bytecode(ERC20_SUPRA)?;
        let erc20supra_impl = GenesisTransaction::create(
            self.address,
            erc20_contract_create_data,
            self.nonce,
            erc20_supra_address_impl,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 2. Deploy ERC1967Proxy (ERC20Supra)
        // Constructor args: implementation address, initialization data
        // Initialization data: initialize(initialOwner, authorizedAddresses[])
        // -------------------------------------------------------------------------
        let proxy_impl_data = Self::load_contract_bytecode(ERC1967PROXY)?;
        // Encode Erc20Supra initialize call
        let erc20_init_args = ERC20Supra::initializeCall {
            _initialOwner: initial_owner,
            _authorizedAddresses: authorized_addresses,
        }
        .abi_encode();
        // Encode the ERC1967Proxy constructor args
        let proxy_args = ERC1967Proxy::constructorCall {
            _impl: erc20_supra_address_impl,
            _data: erc20_init_args.into(),
        }
        .abi_encode();
        // Concatenate bytecode + constructor args for deployment
        let proxy_txn_data = [proxy_impl_data, proxy_args].concat();
        let erc20supra = GenesisTransaction::create(
            self.address,
            proxy_txn_data,
            self.nonce,
            erc20_supra_address,
        );
        self.nonce += 1;

        Ok(BTreeMap::from([
            (GenesisTransactionTags::Erc20SupraImpl, erc20supra_impl),
            (GenesisTransactionTags::Erc20Supra, erc20supra),
        ]))
    }

    /// Generates genesis transaction for ERC20SupraHandler token conversion contract deployment.
    /// Deployment order follows GenesisTransactionTags:
    ///  1. ERC20SupraHandlerImpl (nonce+0) - ERC20SupraHandler implementation contract (UUPS upgradeable)
    ///  2. ERC20SupraHandler (nonce+1) - ERC1967Proxy with initialize(initialOwner, erc20supra)
    ///
    /// The initial owner (typically the foundation multisig wallet) receives
    /// administrative privileges over the token contract.
    fn setup_erc20_supra_handler(
        &mut self,
        initial_owner: Address,
        erc20supra: Address,
        initial_native_tokens: u128,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        // -------------------------------------------------------------------------
        // Pre-compute deployment address
        // -------------------------------------------------------------------------
        let erc20_handler_address_impl = self.address.create(self.nonce);
        let erc20_handler_address = self.address.create(self.nonce + 1);

        // -------------------------------------------------------------------------
        // 1. Deploy ERC20SupraHandler
        // -------------------------------------------------------------------------
        let erc20_contract_create_data = Self::load_contract_bytecode(ERC20_SUPRA_HANDLER)?;
        let erc20supra_handler_impl = GenesisTransaction::create(
            self.address,
            erc20_contract_create_data,
            self.nonce,
            erc20_handler_address_impl,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 2. Deploy ERC1967Proxy (ERC20SupraHandler)
        // Constructor args: implementation address, initialization data
        // Initialization data: initialize(initialOwner, erc20supra)
        // -------------------------------------------------------------------------
        let proxy_impl_data = Self::load_contract_bytecode(ERC1967PROXY)?;
        // Encode Erc20Supra initialize call
        let erc20_handler_init_args = ERC20SupraHandler::initializeCall {
            _initialOwner: initial_owner,
            _erc20Supra: erc20supra,
        }
        .abi_encode();
        // Encode the ERC1967Proxy constructor args
        let proxy_args = ERC1967Proxy::constructorCall {
            _impl: erc20_handler_address_impl,
            _data: erc20_handler_init_args.into(),
        }
        .abi_encode();
        // Concatenate bytecode + constructor args for deployment
        let proxy_txn_data = [proxy_impl_data, proxy_args].concat();
        let erc20supra_handler = GenesisTransaction::new(
            self.address,
            self.nonce,
            initial_native_tokens,
            proxy_txn_data,
            TxKind::Create,
            erc20_handler_address,
        );
        self.nonce += 1;

        Ok(BTreeMap::from([
            (
                GenesisTransactionTags::Erc20SupraHandlerImpl,
                erc20supra_handler_impl,
            ),
            (
                GenesisTransactionTags::Erc20SupraHandler,
                erc20supra_handler,
            ),
        ]))
    }

    /// Generates genesis transactions for BlockMeta contract deployment.
    /// Deployment order follows GenesisTransactionTags:
    ///  1. BlockMetadataImpl - BlockMeta implementation contract (UUPS upgradeable)
    ///  2. BlockMetadata  - ERC1967Proxy with initialize(initialOwner)
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
        let block_metadata_impl_txn = GenesisTransaction::create(
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
        let block_metadata_proxy_txn = GenesisTransaction::create(
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
    ///
    ///  1. DiamondCutFacet, // Facet contract enabling APIs to extend facets and executed registered facet
    ///  2. DiamondLoupeFacet, // Facet providing API to query registered facets
    ///  3. OwnershipFacet, // Facet to manage ownership credential updates and checks
    ///  4. ConfigFacet, // Facet to manage automation registry configuration
    ///  5. RegistryFacet, // Facet providing API for task registration, cancellation and registry state query
    ///  6. CoreFacet, // Facet providing API to monitor cycle and initiate bookkeeping on cycle transition
    ///  7. DiamondInit,
    ///  8. Diamond, // The wrapper contract of all the facets, main entry point of automation registry API
    /// All contracts addresses are pre-computed before deployment to handle circular dependencies if any.
    fn setup_automation_registry(
        &mut self,
        owner: Address,
        erc20_supra_address: Address,
        registry_config: AutomationRegistryConfig,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        let config = registry_config
            .v1()
            .ok_or_else(|| anyhow!("Unhandled configuration version"))?;
        // Pre-compute all deployment addresses
        // nonce+0: DiamondCutFacet (implementation for Diamond proxy)
        // nonce+1: DiamondLoupeFacet
        // nonce+2: OwnershipFacet
        // nonce+3: ConfigFacet
        // nonce+4: RegistryFacet
        // nonce+5: CoreFacet
        // nonce+6: DiamondInit
        // nonce+7: Diamond (proxy to all facets APIs)

        let diamond_cut_facet_addr = self.address.create(self.nonce);
        let diamond_loupe_facet_addr = self.address.create(self.nonce + 1);
        let ownership_facet_addr = self.address.create(self.nonce + 2);
        let config_facet_addr = self.address.create(self.nonce + 3);
        let registry_facet_addr = self.address.create(self.nonce + 4);
        let core_facet_addr = self.address.create(self.nonce + 5);
        let diamond_init_addr = self.address.create(self.nonce + 6);
        let diamond_addr = self.address.create(self.nonce + 7);

        // -------------------------------------------------------------------------
        // 1. Deploy DiamondCutFacet (no constructor args)
        // -------------------------------------------------------------------------
        let diamond_cut = Self::load_contract_bytecode(DIAMOND_CUT_FACET)?;
        let diamond_cut_txn = GenesisTransaction::create(
            self.address,
            diamond_cut,
            self.nonce,
            diamond_cut_facet_addr,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 2. Deploy DiamondLoupeFacet
        // -------------------------------------------------------------------------
        let diamond_loupe_data = Self::load_contract_bytecode(DIAMOND_LOUPE_FACET)?;
        let diamond_loupe_txn = GenesisTransaction::create(
            self.address,
            diamond_loupe_data,
            self.nonce,
            diamond_loupe_facet_addr,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 3. Deploy Ownership facet
        // -------------------------------------------------------------------------
        let ownership_data = Self::load_contract_bytecode(OWNERSHIP_FACET)?;
        let ownership_txn = GenesisTransaction::create(
            self.address,
            ownership_data,
            self.nonce,
            ownership_facet_addr,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 4. Deploy Config Facet
        // -------------------------------------------------------------------------
        let config_data = Self::load_contract_bytecode(CONFIG_FACET)?;
        let config_txn =
            GenesisTransaction::create(self.address, config_data, self.nonce, config_facet_addr);
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 5. Deploy Register facet
        // -------------------------------------------------------------------------
        let register_data = Self::load_contract_bytecode(REGISTRY_FACET)?;
        let register_txn = GenesisTransaction::create(
            self.address,
            register_data,
            self.nonce,
            registry_facet_addr,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 6. Deploy Core facet
        // -------------------------------------------------------------------------
        let core_data = Self::load_contract_bytecode(CORE_FACET)?;
        let core_txn =
            GenesisTransaction::create(self.address, core_data, self.nonce, core_facet_addr);
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 7. Deploy Core facet
        // -------------------------------------------------------------------------
        let diamond_init_data = Self::load_contract_bytecode(DIAMOND_INIT)?;
        let diamond_init_txn = GenesisTransaction::create(
            self.address,
            diamond_init_data,
            self.nonce,
            diamond_init_addr,
        );
        self.nonce += 1;

        // -------------------------------------------------------------------------
        // 7. Deploy Diamond
        // -------------------------------------------------------------------------
        let diamond_init_data = Self::load_contract_bytecode(DIAMOND)?;
        let facets = FacetsDeployment {
            diamondCutFacet: diamond_cut_facet_addr,
            loupeFacet: diamond_loupe_facet_addr,
            ownershipFacet: ownership_facet_addr,
            configFacet: config_facet_addr,
            registryFacet: registry_facet_addr,
            coreFacet: core_facet_addr,
            diamondInit: diamond_init_addr,
        };

        let init_params = InitParams {
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
            registrationEnabled: true,
            automationEnabled: config.enable_automation_feature,
        };

        let diamond_constructor_data = Diamond::constructorCall {
            _contractOwner: owner,
            _facets: facets,
            _erc20Supra: erc20_supra_address,
            _params: init_params,
        }
        .abi_encode();
        let diamond_data = [diamond_init_data, diamond_constructor_data].concat();
        let diamond_txn =
            GenesisTransaction::create(self.address, diamond_data, self.nonce, diamond_addr);
        self.nonce += 1;

        Ok(BTreeMap::from([
            (GenesisTransactionTags::DiamondCutFacet, diamond_cut_txn),
            (GenesisTransactionTags::Diamond, diamond_txn),
            (GenesisTransactionTags::DiamondLoupeFacet, diamond_loupe_txn),
            (GenesisTransactionTags::OwnershipFacet, ownership_txn),
            (GenesisTransactionTags::ConfigFacet, config_txn),
            (GenesisTransactionTags::RegistryFacet, register_txn),
            (GenesisTransactionTags::CoreFacet, core_txn),
            (GenesisTransactionTags::DiamondInit, diamond_init_txn),
        ]))
    }

    fn setup_supra_nova_contracts(
        &mut self,
        config: SupraNovaConfig,
        owner: Address,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        // First setup all independent contracts
        // 1. Wrapped token contracts
        // 2. Hypernova contracts
        // 3. Token Vault contracts
        let wrapped_token_contracts = self.setup_wrapped_token_contracts(owner)?;
        let hyper_nova_contracts = self.setup_hyper_nova_contracts(owner, &config)?;
        let token_vault_contracts = self.setup_token_vault_contracts(owner, &config)?;

        // 4. Setup FeeOperator contracts which depends on hypernova deployment
        let hyper_nova = *hyper_nova_contracts
            .get(&GenesisTransactionTags::HypernovaProxy)
            .expect("Hypernova contract should be deployed")
            .deploy_address();

        let fee_operator_contracts =
            self.setup_fee_operator_contracts(owner, hyper_nova, &config)?;

        // 5. Setup Token Bridge contracts which depends on all above
        let token_vault = *token_vault_contracts
            .get(&GenesisTransactionTags::TokenVaultProxy)
            .expect("TokenVault contract should be deployed")
            .deploy_address();

        let fee_operator = *fee_operator_contracts
            .get(&GenesisTransactionTags::FeeOperatorProxy)
            .expect("FeeOperator contract should be deployed")
            .deploy_address();

        let wrapped_token = *wrapped_token_contracts
            .get(&GenesisTransactionTags::WrappedTokenFactoryProxy)
            .expect("WrappedToken contract should be deployed")
            .deploy_address();

        let token_bridge_contracts = self.setup_token_bridge_contracts(
            owner,
            hyper_nova,
            token_vault,
            fee_operator,
            wrapped_token,
            &config,
        )?;

        let mut contract_txns = wrapped_token_contracts;
        contract_txns.extend(hyper_nova_contracts);
        contract_txns.extend(token_vault_contracts);
        contract_txns.extend(fee_operator_contracts);
        contract_txns.extend(token_bridge_contracts);

        Ok(contract_txns)
    }

    fn setup_wrapped_token_contracts(
        &mut self,
        owner: Address,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        let wrapped_token_init_data = Self::load_contract_bytecode(WRAPPED_TOKEN)?;
        let wrapped_token_txn = GenesisTransaction::create2(
            self.address,
            SupraNovaConfig::WRAPPED_TOKEN_IMPL_SALT,
            wrapped_token_init_data,
            self.nonce,
        );
        self.nonce += 1;

        let wrapped_token_fct_init_data = Self::load_contract_bytecode(WRAPPED_TOKEN_FACTORY)?;
        let wrapped_token_fct_txn = GenesisTransaction::create2(
            self.address,
            SupraNovaConfig::WRAPPED_TOKEN_FACTORY_IMPL_SALT,
            wrapped_token_fct_init_data,
            self.nonce,
        );
        self.nonce += 1;

        let wrapped_token_fct_init_call = WrappedTokenFactory::initializeCall {
            owner,
            token_impl: *wrapped_token_txn.deploy_address(),
        }
        .abi_encode();

        let wrapped_token_proxy_init_data =
            Self::load_contract_bytecode(WRAPPED_TOKEN_FACTORY_PROXY)?;
        let wrapped_token_proxy_cnstr_data = WrappedTokenFactoryProxy::constructorCall {
            factory_impl: *wrapped_token_fct_txn.deploy_address(),
            init_data: wrapped_token_fct_init_call.into(),
        }
        .abi_encode();
        let wrapped_token_proxy_txn_data = [
            wrapped_token_proxy_init_data,
            wrapped_token_proxy_cnstr_data,
        ]
        .concat();
        let wrapped_token_proxy_txn = GenesisTransaction::create2(
            self.address,
            SupraNovaConfig::WRAPPED_TOKEN_FACTORY_PROXY_SALT,
            wrapped_token_proxy_txn_data,
            self.nonce,
        );
        self.nonce += 1;

        Ok(BTreeMap::from([
            (GenesisTransactionTags::WrappedToken, wrapped_token_txn),
            (
                GenesisTransactionTags::WrappedTokenFactory,
                wrapped_token_fct_txn,
            ),
            (
                GenesisTransactionTags::WrappedTokenFactoryProxy,
                wrapped_token_proxy_txn,
            ),
        ]))
    }

    fn setup_hyper_nova_contracts(
        &mut self,
        owner: Address,
        config: &SupraNovaConfig,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        let hyper_nova_init_data = Self::load_contract_bytecode(HYPERNOVA)?;
        let hyper_nova_txn = GenesisTransaction::create2(
            self.address,
            SupraNovaConfig::HYPER_NOVA_IMPL_SALT,
            hyper_nova_init_data,
            self.nonce,
        );
        self.nonce += 1;

        let hyper_nova_init_call_data = Hypernova::initializeCall {
            owner,
            msgId: U256::from(config.hypernova_msg_id),
        }
        .abi_encode();

        let hyper_nova_proxy_init_data = Self::load_contract_bytecode(HYPERNOVA_PROXY)?;
        let hyper_nova_proxy_cnstr_data = HypernovaProxy::constructorCall {
            hypernova_impl: *hyper_nova_txn.deploy_address(),
            init_data: hyper_nova_init_call_data.into(),
        }
        .abi_encode();
        let hyper_nova_proxy_txn_data =
            [hyper_nova_proxy_init_data, hyper_nova_proxy_cnstr_data].concat();
        let hyper_nova_proxy_txn = GenesisTransaction::create2(
            self.address,
            SupraNovaConfig::HYPER_NOVA_PROXY_SALT,
            hyper_nova_proxy_txn_data,
            self.nonce,
        );
        self.nonce += 1;

        Ok(BTreeMap::from([
            (GenesisTransactionTags::Hypernova, hyper_nova_txn),
            (GenesisTransactionTags::HypernovaProxy, hyper_nova_proxy_txn),
        ]))
    }

    fn setup_token_vault_contracts(
        &mut self,
        owner: Address,
        config: &SupraNovaConfig,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        let token_vault_init_data = Self::load_contract_bytecode(TOKEN_VAULT)?;
        let token_vault_txn = GenesisTransaction::create2(
            self.address,
            SupraNovaConfig::TOKEN_VAULT_IMPL_SALT,
            token_vault_init_data,
            self.nonce,
        );
        self.nonce += 1;

        let token_vault_init_call_data = TokenVault::initializeCall {
            owner,
            nativeToken: config.weth9_address,
            brigde: owner,
        }
        .abi_encode();

        let token_vault_proxy_init_data = Self::load_contract_bytecode(TOKEN_VAULT_PROXY)?;
        let token_vault_proxy_cnstr_data = TokenVaultProxy::constructorCall {
            token_vault_impl: *token_vault_txn.deploy_address(),
            init_data: token_vault_init_call_data.into(),
        }
        .abi_encode();
        let token_vault_proxy_txn_data =
            [token_vault_proxy_init_data, token_vault_proxy_cnstr_data].concat();
        let token_vault_proxy_txn = GenesisTransaction::create2(
            self.address,
            SupraNovaConfig::TOKEN_VAULT_PROXY_SALT,
            token_vault_proxy_txn_data,
            self.nonce,
        );
        self.nonce += 1;

        Ok(BTreeMap::from([
            (GenesisTransactionTags::TokenVault, token_vault_txn),
            (
                GenesisTransactionTags::TokenVaultProxy,
                token_vault_proxy_txn,
            ),
        ]))
    }

    fn setup_fee_operator_contracts(
        &mut self,
        owner: Address,
        hyper_nova: Address,
        config: &SupraNovaConfig,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        let fee_operator_init_data = Self::load_contract_bytecode(FEE_OPERATOR)?;
        let fee_operator_txn = GenesisTransaction::create2(
            self.address,
            SupraNovaConfig::FEE_OPERATOR_IMPL_SALT,
            fee_operator_init_data,
            self.nonce,
        );
        self.nonce += 1;

        let fee_operator_init_call_data = FeeOperator::initializeCall {
            owner,
            hypernova: hyper_nova,
            sValueFeed: config.dora_storage_address,
            supraUsdtPairIndex: U256::from(config.supra_usdt_pair_idx),
            maxStaleOraclePriceLimit: U256::from(config.max_stale_oracle_price_limit),
        }
        .abi_encode();

        let fee_operator_proxy_init_data = Self::load_contract_bytecode(FEE_OPERATOR_PROXY)?;
        let fee_operator_proxy_cnstr_data = FeeOperatorProxy::constructorCall {
            fee_operator_impl: *fee_operator_txn.deploy_address(),
            init_data: fee_operator_init_call_data.into(),
        }
        .abi_encode();
        let fee_operator_proxy_txn_data =
            [fee_operator_proxy_init_data, fee_operator_proxy_cnstr_data].concat();
        let fee_operator_proxy_txn = GenesisTransaction::create2(
            self.address,
            SupraNovaConfig::FEE_OPERATOR_PROXY_SALT,
            fee_operator_proxy_txn_data,
            self.nonce,
        );
        self.nonce += 1;

        Ok(BTreeMap::from([
            (GenesisTransactionTags::FeeOperator, fee_operator_txn),
            (
                GenesisTransactionTags::FeeOperatorProxy,
                fee_operator_proxy_txn,
            ),
        ]))
    }

    fn setup_token_bridge_contracts(
        &mut self,
        owner: Address,
        hyper_nova: Address,
        fee_operator_address: Address,
        token_vault_address: Address,
        wrapped_token_proxy_address: Address,
        config: &SupraNovaConfig,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        let token_bridge_init_data = Self::load_contract_bytecode(TOKEN_BRIDGE)?;
        let token_bridge_txn = GenesisTransaction::create2(
            self.address,
            SupraNovaConfig::TOKEN_BRIDGE_IMPL_SALT,
            token_bridge_init_data,
            self.nonce,
        );
        self.nonce += 1;

        let token_bridge_init_call_data = TokenBridge::initializeCall {
            owner,
            nativeToken: config.weth9_address,
            hypernova: hyper_nova,
            feeOperator: fee_operator_address,
            vault: token_vault_address,
            wrappedTokenFactory: wrapped_token_proxy_address,
        }
        .abi_encode();

        let token_bridge_proxy_init_data = Self::load_contract_bytecode(TOKEN_BRIDGE_PROXY)?;
        let token_bridge_proxy_cnstr_data = TokenBridgeProxy::constructorCall {
            token_bridge_impl: *token_bridge_txn.deploy_address(),
            init_data: token_bridge_init_call_data.into(),
        }
        .abi_encode();
        let token_bridge_proxy_txn_data =
            [token_bridge_proxy_init_data, token_bridge_proxy_cnstr_data].concat();
        let token_bridge_proxy_txn = GenesisTransaction::create2(
            self.address,
            SupraNovaConfig::TOKEN_BRIDGE_PROXY_SALT,
            token_bridge_proxy_txn_data,
            self.nonce,
        );
        self.nonce += 1;

        Ok(BTreeMap::from([
            (GenesisTransactionTags::TokenBridge, token_bridge_txn),
            (
                GenesisTransactionTags::TokenBridgeProxy,
                token_bridge_proxy_txn,
            ),
        ]))
    }

    fn load_contract_bytecode(name: &str) -> Result<Vec<u8>> {
        // Bytecodes are embedded at compile time via include_bytes! macros
        CONTRACT_BYTECODES
            .get(name)
            .map(|v| v.clone())
            .ok_or_else(|| anyhow!("Failed to get bytecode for contract: {name}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contracts::configs::AutomationRegistryConfigV1;
    use primitives::supra_constants::u64_to_address;

    #[test]
    fn check_multisig_setup() {
        let mut generator = GenesisTransactionGenerator::default();
        let owners = vec![u64_to_address(1), u64_to_address(2), u64_to_address(3)];
        let initial_native_token = 1000;
        let mut config = GenesisTransactionGeneratorConfig {
            foundation_owners: owners,
            foundation_threshold: 2,
            full_set: false,
            automation_config: None,
            initial_native_token,
            supra_nova_config: None,
        };
        let result = generator
            .prepare_genesis_transactions(config.clone())
            .unwrap();
        assert_eq!(result.len(), 4);
        assert!(result.contains_key(&GenesisTransactionTags::Create2Factory));
        assert!(result.contains_key(&GenesisTransactionTags::MultisigWalletImpl));
        assert!(result.contains_key(&GenesisTransactionTags::MultisigBeacon));
        assert!(result.contains_key(&GenesisTransactionTags::FoundationWallet));

        // Enable full set of contract generation without automation config
        config.full_set = true;
        let result = generator
            .prepare_genesis_transactions(config)
            .expect("Successful txn generation");
        assert!(result.contains_key(&GenesisTransactionTags::Create2Factory));
        assert!(result.contains_key(&GenesisTransactionTags::FoundationWallet));
        assert!(result.contains_key(&GenesisTransactionTags::BlockMetadata));
        assert!(result.contains_key(&GenesisTransactionTags::Erc20SupraImpl));
        assert!(result.contains_key(&GenesisTransactionTags::Erc20Supra));
        assert!(result.contains_key(&GenesisTransactionTags::Erc20SupraHandlerImpl));
        assert!(result.contains_key(&GenesisTransactionTags::Erc20SupraHandler));
        let erc20_supra_handler = result
            .get(&GenesisTransactionTags::Erc20SupraHandler)
            .unwrap();
        assert_eq!(erc20_supra_handler.value(), &initial_native_token);

        // Verify automation contracts are not deployed
        assert!(!result.contains_key(&GenesisTransactionTags::DiamondCutFacet));
        assert!(!result.contains_key(&GenesisTransactionTags::Diamond));
        assert!(!result.contains_key(&GenesisTransactionTags::DiamondLoupeFacet));
        assert!(!result.contains_key(&GenesisTransactionTags::OwnershipFacet));
        assert!(!result.contains_key(&GenesisTransactionTags::ConfigFacet));
        assert!(!result.contains_key(&GenesisTransactionTags::RegistryFacet));
        assert!(!result.contains_key(&GenesisTransactionTags::CoreFacet));
        assert!(!result.contains_key(&GenesisTransactionTags::DiamondInit));
        println!("{result:#?}");
    }

    #[test]
    fn check_automation_with_custom_config() {
        let mut generator = GenesisTransactionGenerator::default();
        let owners = vec![u64_to_address(1), u64_to_address(2), u64_to_address(3)];
        let custom_config = AutomationRegistryConfigV1 {
            task_duration_cap_secs: 7200,
            registry_max_gas_cap: 20_000_000,
            task_capacity: 1000,
            ..Default::default()
        };
        let config = GenesisTransactionGeneratorConfig {
            foundation_owners: owners,
            foundation_threshold: 2,
            full_set: true,
            automation_config: Some(custom_config.into()),
            initial_native_token: 1000,
            supra_nova_config: None,
        };
        let result = generator
            .prepare_genesis_transactions(config)
            .expect("Successful txn generation");

        // Verify all automation contracts are deployed
        assert!(result.contains_key(&GenesisTransactionTags::DiamondCutFacet));
        assert!(result.contains_key(&GenesisTransactionTags::Diamond));
        assert!(result.contains_key(&GenesisTransactionTags::DiamondLoupeFacet));
        assert!(result.contains_key(&GenesisTransactionTags::OwnershipFacet));
        assert!(result.contains_key(&GenesisTransactionTags::ConfigFacet));
        assert!(result.contains_key(&GenesisTransactionTags::RegistryFacet));
        assert!(result.contains_key(&GenesisTransactionTags::CoreFacet));
        assert!(result.contains_key(&GenesisTransactionTags::DiamondInit));
        println!("{result:#?}");
    }

    #[test]
    fn check_supra_nova_with_custom_config() {
        let mut generator = GenesisTransactionGenerator::default();
        let owners = vec![u64_to_address(1), u64_to_address(2), u64_to_address(3)];
        let custom_config = AutomationRegistryConfigV1 {
            task_duration_cap_secs: 7200,
            registry_max_gas_cap: 20_000_000,
            task_capacity: 1000,
            ..Default::default()
        };
        let config = GenesisTransactionGeneratorConfig {
            foundation_owners: owners,
            foundation_threshold: 2,
            full_set: true,
            automation_config: Some(custom_config.into()),
            initial_native_token: 1000,
            supra_nova_config: Some(SupraNovaConfig::default()),
        };
        let result = generator
            .prepare_genesis_transactions(config)
            .expect("Successful txn generation");

        // Verify all automation contracts are deployed
        assert!(result.contains_key(&GenesisTransactionTags::WrappedToken));
        assert!(result.contains_key(&GenesisTransactionTags::WrappedTokenFactory));
        assert!(result.contains_key(&GenesisTransactionTags::WrappedTokenFactoryProxy));
        assert!(result.contains_key(&GenesisTransactionTags::Hypernova));
        assert!(result.contains_key(&GenesisTransactionTags::HypernovaProxy));
        assert!(result.contains_key(&GenesisTransactionTags::FeeOperator));
        assert!(result.contains_key(&GenesisTransactionTags::FeeOperatorProxy));
        assert!(result.contains_key(&GenesisTransactionTags::TokenVault));
        assert!(result.contains_key(&GenesisTransactionTags::TokenVaultProxy));
        assert!(result.contains_key(&GenesisTransactionTags::TokenBridge));
        assert!(result.contains_key(&GenesisTransactionTags::TokenBridgeProxy));
        println!("{result:#?}");
    }
}
