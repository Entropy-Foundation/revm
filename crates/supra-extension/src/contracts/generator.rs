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

/// Genesis Transaction generator configuration details
#[derive(Debug, Clone)]
pub struct GenesisTransactionGeneratorConfig {
    /// List of EOAs to set up multisig foundation wallet.
    pub foundation_owners: Vec<Address>,
    /// Threshold of the foundation multisig wallet.
    pub foundation_threshold: u64,
    /// Flag indicating whether full set of genesis transaction should be generated or only mandatory once.
    pub full_set: bool,
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
        } = config;
        // First foundation multisig account setup should be done
        let mut genesis_transactions =
            self.setup_multisig_wallet(foundation_owners, foundation_threshold)?;
        if full_set {
            let multisig_address = *genesis_transactions
                .get(&GenesisTransactionTags::FoundationWallet)
                .expect("Foundation Wallet deployment transaction")
                .deploy_address();
            genesis_transactions.insert(
                GenesisTransactionTags::Erc20Supra,
                self.setup_erc20_supra(multisig_address)?,
            );
            genesis_transactions.extend(self.setup_block_metadata(multisig_address)?.into_iter());
            genesis_transactions.extend(self.setup_automation_registry(multisig_address)?.into_iter());
        };

        Ok(genesis_transactions)
    }

    /// Generates genesis transactions which help to set up foundation multisig wallet.
    ///  - MultiSignatureWallet implementation contract deployment, deployed by `VM_SIGNER`,
    ///    address will be derived from `(VM_SIGNER, 0)` aka `IMPL_ADDRESS`
    ///  - MultisigBeacon beacon contract deployment, deployed by `VM_SIGNER`,
    ///    address will be derived from `(VM_SIGNER, 1)` aka `BEACON_ADDRESS`
    ///    - inputs are IMPL_ADDRESS, `FOUNDATION_WALLET_ADDRESS`
    ///  - BeaconProxy proxy contract deployment to set up foundation multi-signature wallet,
    ///    deployed by `VM_SIGNER`, address is derived from `(VM_SIGNER, 2)` aka `FOUNDATION_WALLET_ADDRESS`
    fn setup_multisig_wallet(
        &mut self,
        owners: Vec<Address>,
        threshold: u64,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        let multisig_impl_address = self.address.create(self.nonce);
        let beacon_contract_address = self.address.create(self.nonce + 1);
        let multisig_wallet_address = self.address.create(self.nonce + 2);

        let multisig_impl_create_data = Self::load_contract_bytecode(MULTISIG_WALLET)?;
        let multisig_txn = GenesisTransaction::new(
            self.address.clone(),
            multisig_impl_create_data,
            self.nonce,
            multisig_impl_address,
        );

        self.nonce += 1;
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

        let beacon_proxy_create_data = Self::load_contract_bytecode(BEACON_PROXY)?;
        let multisig_init_data = MultiSignatureWallet::initializeCall {
            _owners: owners,
            _numConfirmationsRequired: U256::from(threshold),
        }
        .abi_encode();
        let beacon_proxy_args = BeaconProxy::constructorCall {
            _beacon: beacon_contract_address,
            _data: Bytes::from(multisig_init_data),
        }
        .abi_encode();
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

    /// Expected to be generated on behalf of multisig account address
    fn setup_erc20_supra(&mut self, initial_owner: Address) -> Result<GenesisTransaction> {
        let contract_address = self.address.create(self.nonce);
        let erc20_contract_create_data = Self::load_contract_bytecode(ERC20_SUPRA)?;
        let erc20_constructor_args = ERC20Supra::constructorCall {
            _initialOwner: initial_owner,
        }
        .abi_encode();
        let erc20_txn_data = [erc20_contract_create_data, erc20_constructor_args].concat();
        let txn =
            GenesisTransaction::new(self.address, erc20_txn_data, self.nonce, contract_address);
        self.nonce += 1;
        Ok(txn)
    }

    /// Expected to be generated on behalf of multisig account address
    fn setup_block_metadata(
        &mut self,
        initial_owner: Address,
    ) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        let block_metadata_impl_address = self.address.create(self.nonce);
        let block_metadata_impl = Self::load_contract_bytecode(BLOCK_META)?;
        let block_metadata_impl_txn = GenesisTransaction::new(
            self.address,
            block_metadata_impl,
            self.nonce,
            block_metadata_impl_address,
        );
        self.nonce += 1;

        let block_metadata_proxy_address = self.address.create(self.nonce + 1);
        let block_metadata_initialize = BlockMeta::initializeCall {
            _initialOwner: initial_owner,
        }
        .abi_encode();
        let proxy_impl_data = Self::load_contract_bytecode(ERC1967PROXY)?;
        let proxy_args = ERC1967Proxy::constructorCall {
            _impl: block_metadata_impl_address,
            _data: block_metadata_initialize.into(),
        }
        .abi_encode();
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

    fn setup_automation_registry(&mut self, _initial_owner:  Address) -> Result<BTreeMap<GenesisTransactionTags, GenesisTransaction>> {
        // TODO add automation registry setup transactions as well, after finalizing the contracts
        // creation order and initialization api
        Ok(BTreeMap::new())

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
        };
        let result = generator.prepare_genesis_transactions(config.clone());
        assert!(result.is_ok());
        assert!(result
            .unwrap()
            .contains_key(&GenesisTransactionTags::FoundationWallet));
        config.full_set = true;
        let result = generator
            .prepare_genesis_transactions(config)
            .expect("Successful txn generation");
        assert!(result.contains_key(&GenesisTransactionTags::FoundationWallet));
        assert!(result.contains_key(&GenesisTransactionTags::BlockMetadata));
        assert!(result.contains_key(&GenesisTransactionTags::Erc20Supra));
        println!("{result:#?}");
    }
}
