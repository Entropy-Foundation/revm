//! Canonical, address-fixed EVM singleton contracts that the wider ecosystem (Foundry,
//! hardhat-deploy, ERC-777, account-abstraction tooling, etc.) expects to find at specific
//! well-known addresses on any EVM chain, alongside the genesis transactions that deploy them.
//!
//! Each contract here is deployed via a plain `CREATE` from its own fixed, independent
//! deployer account at nonce 0, reproducing the exact address the contract already holds
//! on other EVM chains. The init-code is embedded as a static binary asset
//! (`canonical_singletons_bytecode/*.bin`) extracted verbatim from each project's
//! canonical historical deployment transaction — not compiled from vendored Solidity source,
//! since these are third-party contracts we don't own or modify, and any difference in
//! compiler/optimizer/metadata would risk producing bytecode that isn't byte-identical to
//! what's deployed everywhere else.

use crate::contracts::transaction::GenesisTransaction;
use primitives::{address, Address, TxKind};

/// The address that deploys the default CREATE2 deployer contract.
pub const CREATE2_FACTORY_OWNER: Address = address!("0x3fAB184622Dc19b6109349B94811493BF2a45362");

/// The default CREATE2 FACTORY contract address. Assumed deployed by [CREATE2_FACTORY_OWNER] with nonce 0
pub const CREATE2_FACTORY_ADDRESS: Address = address!("0x4e59b44847b379578588920ca78fbf26c0b4956c");

/// The init-code of the default CREATE2 FACTORY widely used in community
/// Retrieved from https://github.com/Arachnid/deterministic-deployment-proxy
pub const CREATE2_FACTORY_CODE: &[u8] =
    include_bytes!("canonical_singletons_bytecode/create2_factory.bin");

/// Deployer of the canonical Multicall3 contract's historical presigned deployment transaction.
/// NOTE: unlike the other three contracts here, this is not a Nick's-method placeholder-signature
/// deployment — it is a real (now publicly known to be compromised, per the project's own README)
/// ECDSA-signed transaction. The compromise is irrelevant to reproducing it here: we never sign
/// with this key, we only replay the sender+nonce+data tuple it produced to derive the same
/// address and bytecode.
/// Retrieved from https://github.com/mds1/multicall3 (README, "New Deployments" section).
pub const MULTICALL3_DEPLOYER: Address = address!("0x05f32B3cC3888453ff71B01135B34FF8e41263F2");
/// Canonical Multicall3 contract address, deployed by [MULTICALL3_DEPLOYER] with nonce 0.
pub const MULTICALL3_ADDRESS: Address = address!("0xcA11bde05977b3631167028862bE2a173976CA11");
/// Multicall3 init-code, extracted from the presigned deployment transaction's data field.
/// Retrieved from https://github.com/mds1/multicall3 (README, "New Deployments" section).
pub const MULTICALL3_CODE: &[u8] = include_bytes!("canonical_singletons_bytecode/multicall3.bin");

/// Deployer of the canonical ERC-2470 SingletonFactory contract (Nick's-method deployment).
/// Retrieved from https://github.com/ethereum/ercs/blob/master/ERCS/erc-2470.md
pub const SINGLETON_FACTORY_DEPLOYER: Address =
    address!("0xBb6e024b9cFFACB947A71991E386681B1Cd1477D");
/// Canonical ERC-2470 SingletonFactory contract address, deployed by
/// [SINGLETON_FACTORY_DEPLOYER] with nonce 0.
pub const SINGLETON_FACTORY_ADDRESS: Address =
    address!("0xce0042B868300000d44A59004Da54A005ffdcf9f");
/// ERC-2470 SingletonFactory init-code, extracted from the presigned deployment transaction's
/// data field. Retrieved from https://github.com/ethereum/ercs/blob/master/ERCS/erc-2470.md
pub const SINGLETON_FACTORY_CODE: &[u8] =
    include_bytes!("canonical_singletons_bytecode/singleton_factory.bin");

/// Deployer of the canonical CreateX contract (Nick's-method-style presigned deployment).
/// Retrieved from https://github.com/pcaversaccio/createx,
/// `scripts/presigned-createx-deployment-transactions/signed_serialised_transaction_gaslimit_3000000_.json`
/// (the 3M-gas variant — the one that produced the address on all of CreateX's existing chain
/// deployments; the 25M/45M variants carry byte-identical init-code, differing only in gas
/// limit/signature for chains needing a higher gas ceiling).
pub const CREATEX_DEPLOYER: Address = address!("0xeD456e05CaAb11d66C4c797dD6c1D6f9A7F352b5");
/// Canonical CreateX contract address, deployed by [CREATEX_DEPLOYER] with nonce 0.
pub const CREATEX_ADDRESS: Address = address!("0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed");
/// CreateX init-code, extracted from the presigned deployment transaction's data field.
/// Retrieved from https://github.com/pcaversaccio/createx,
/// `scripts/presigned-createx-deployment-transactions/signed_serialised_transaction_gaslimit_3000000_.json`
pub const CREATEX_CODE: &[u8] = include_bytes!("canonical_singletons_bytecode/createx.bin");

/// Deployer of the canonical ERC-1820 Registry contract (Nick's-method deployment).
/// Retrieved from https://github.com/ethereum/ercs/blob/master/ERCS/erc-1820.md
pub const ERC1820_REGISTRY_DEPLOYER: Address =
    address!("0xa990077c3205cbDf861e17Fa532eeB069cE9fF96");
/// Canonical ERC-1820 Registry contract address, deployed by [ERC1820_REGISTRY_DEPLOYER] with
/// nonce 0.
pub const ERC1820_REGISTRY_ADDRESS: Address =
    address!("0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24");
/// ERC-1820 Registry init-code, extracted from the presigned deployment transaction's data
/// field. Retrieved from https://github.com/ethereum/ercs/blob/master/ERCS/erc-1820.md
pub const ERC1820_REGISTRY_CODE: &[u8] =
    include_bytes!("canonical_singletons_bytecode/erc1820_registry.bin");

/// Generates the Create2Factory (Arachnid deterministic-deployment-proxy) deployment transaction.
pub fn generate_create2_factory_transaction() -> GenesisTransaction {
    GenesisTransaction::new(
        CREATE2_FACTORY_OWNER,
        0,
        0,
        CREATE2_FACTORY_CODE.to_owned(),
        TxKind::Create,
        Some(CREATE2_FACTORY_ADDRESS),
    )
}

/// Generates the Multicall3 deployment transaction.
pub fn generate_multicall3_transaction() -> GenesisTransaction {
    GenesisTransaction::create(
        MULTICALL3_DEPLOYER,
        MULTICALL3_CODE.to_owned(),
        0,
        MULTICALL3_ADDRESS,
    )
}

/// Generates the ERC-2470 SingletonFactory deployment transaction.
pub fn generate_singleton_factory_transaction() -> GenesisTransaction {
    GenesisTransaction::create(
        SINGLETON_FACTORY_DEPLOYER,
        SINGLETON_FACTORY_CODE.to_owned(),
        0,
        SINGLETON_FACTORY_ADDRESS,
    )
}

/// Generates the CreateX deployment transaction.
pub fn generate_createx_transaction() -> GenesisTransaction {
    GenesisTransaction::create(
        CREATEX_DEPLOYER,
        CREATEX_CODE.to_owned(),
        0,
        CREATEX_ADDRESS,
    )
}

/// Generates the ERC-1820 Registry deployment transaction.
pub fn generate_erc1820_registry_transaction() -> GenesisTransaction {
    GenesisTransaction::create(
        ERC1820_REGISTRY_DEPLOYER,
        ERC1820_REGISTRY_CODE.to_owned(),
        0,
        ERC1820_REGISTRY_ADDRESS,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use primitives::{b256, keccak256};

    /// For a plain-CREATE deployment, the resulting contract address depends only on the
    /// sender and nonce, not on the init-code. This asserts each fixed (deployer, address)
    /// pair is self-consistent under standard CREATE address derivation, matching the
    /// canonical address recovered from each contract's real historical deployment.
    macro_rules! create_address_derivation_test {
        ($name:ident, $deployer:expr, $address:expr) => {
            #[test]
            fn $name() {
                assert_eq!($deployer.create(0), $address);
            }
        };
    }

    create_address_derivation_test!(
        create2_factory_deployer_nonce_zero_produces_canonical_address,
        CREATE2_FACTORY_OWNER,
        CREATE2_FACTORY_ADDRESS
    );
    create_address_derivation_test!(
        multicall3_deployer_nonce_zero_produces_canonical_address,
        MULTICALL3_DEPLOYER,
        MULTICALL3_ADDRESS
    );
    create_address_derivation_test!(
        singleton_factory_deployer_nonce_zero_produces_canonical_address,
        SINGLETON_FACTORY_DEPLOYER,
        SINGLETON_FACTORY_ADDRESS
    );
    create_address_derivation_test!(
        createx_deployer_nonce_zero_produces_canonical_address,
        CREATEX_DEPLOYER,
        CREATEX_ADDRESS
    );
    create_address_derivation_test!(
        erc1820_registry_deployer_nonce_zero_produces_canonical_address,
        ERC1820_REGISTRY_DEPLOYER,
        ERC1820_REGISTRY_ADDRESS
    );

    // keccak256 hash checks: a tripwire against accidental truncation/corruption of the
    // embedded init-code assets, strictly stronger than a byte-length check alone.
    //
    // For CreateX, the expected hash is not just self-verification: pcaversaccio/createx's
    // README itself publishes it as the value the community is told to check before trusting
    // a CreateX deployment on any chain ("we recommend verifying prior to interacting with
    // CreateX on any chain, that the keccak256 hash of the broadcasted contract creation
    // bytecode is 0x12ec8615..."), so this test also confirms our embedded asset matches that
    // publicly-published value, not just that it hasn't changed since we extracted it.
    //
    // Arachnid's proxy, Multicall3, ERC-2470, and ERC-1820 don't publish an init-code hash in
    // their own docs/spec the way CreateX does, so those four hashes below are self-computed
    // (via this codebase's own `keccak256`) at the time each asset was extracted and pinned as
    // a regression guard, not independently-published community values.
    #[test]
    fn create2_factory_code_matches_expected_hash() {
        assert_eq!(
            keccak256(CREATE2_FACTORY_CODE),
            b256!("50ea9137a35a9ad33b0ed4a431e9b6996ea9ed1f14781126cec78f168c0e64e5")
        );
    }

    #[test]
    fn multicall3_code_matches_expected_hash() {
        assert_eq!(
            keccak256(MULTICALL3_CODE),
            b256!("0b2046aa018109118d518235014ac2c679dcbdff32c64705fdf50d048cd32d22")
        );
    }

    #[test]
    fn singleton_factory_code_matches_expected_hash() {
        assert_eq!(
            keccak256(SINGLETON_FACTORY_CODE),
            b256!("122b6b28aeddfd05fa3ce4348e93d357b3ce50d9ab7dda4e8ee524a5b9a6ab3b")
        );
    }

    #[test]
    fn createx_code_matches_published_hash() {
        // Retrieved from https://github.com/pcaversaccio/createx README: "the keccak256 hash
        // of the broadcasted contract creation bytecode is
        // 0x12ec861579b63a3ab9db3b5a23c57d56402ad3061475b088f17054e2f2daf22f".
        assert_eq!(
            keccak256(CREATEX_CODE),
            b256!("12ec861579b63a3ab9db3b5a23c57d56402ad3061475b088f17054e2f2daf22f")
        );
    }

    #[test]
    fn erc1820_registry_code_matches_expected_hash() {
        assert_eq!(
            keccak256(ERC1820_REGISTRY_CODE),
            b256!("141438dfbe77ba1a065eadf0ec62a4c90afa1c6355bc528d0f995015db252993")
        );
    }

    #[test]
    fn generate_create2_factory_transaction_matches_constants() {
        let txn = generate_create2_factory_transaction();
        assert_eq!(*txn.sender(), CREATE2_FACTORY_OWNER);
        assert_eq!(*txn.nonce(), 0);
        assert_eq!(*txn.kind(), TxKind::Create);
        assert_eq!(*txn.deploy_address(), Some(CREATE2_FACTORY_ADDRESS));
        assert_eq!(txn.data().as_slice(), CREATE2_FACTORY_CODE);
    }

    #[test]
    fn generate_multicall3_transaction_matches_constants() {
        let txn = generate_multicall3_transaction();
        assert_eq!(*txn.sender(), MULTICALL3_DEPLOYER);
        assert_eq!(*txn.nonce(), 0);
        assert_eq!(*txn.kind(), TxKind::Create);
        assert_eq!(*txn.deploy_address(), Some(MULTICALL3_ADDRESS));
        assert_eq!(txn.data().as_slice(), MULTICALL3_CODE);
    }

    #[test]
    fn generate_singleton_factory_transaction_matches_constants() {
        let txn = generate_singleton_factory_transaction();
        assert_eq!(*txn.sender(), SINGLETON_FACTORY_DEPLOYER);
        assert_eq!(*txn.nonce(), 0);
        assert_eq!(*txn.kind(), TxKind::Create);
        assert_eq!(*txn.deploy_address(), Some(SINGLETON_FACTORY_ADDRESS));
        assert_eq!(txn.data().as_slice(), SINGLETON_FACTORY_CODE);
    }

    #[test]
    fn generate_createx_transaction_matches_constants() {
        let txn = generate_createx_transaction();
        assert_eq!(*txn.sender(), CREATEX_DEPLOYER);
        assert_eq!(*txn.nonce(), 0);
        assert_eq!(*txn.kind(), TxKind::Create);
        assert_eq!(*txn.deploy_address(), Some(CREATEX_ADDRESS));
        assert_eq!(txn.data().as_slice(), CREATEX_CODE);
    }

    #[test]
    fn generate_erc1820_registry_transaction_matches_constants() {
        let txn = generate_erc1820_registry_transaction();
        assert_eq!(*txn.sender(), ERC1820_REGISTRY_DEPLOYER);
        assert_eq!(*txn.nonce(), 0);
        assert_eq!(*txn.kind(), TxKind::Create);
        assert_eq!(*txn.deploy_address(), Some(ERC1820_REGISTRY_ADDRESS));
        assert_eq!(txn.data().as_slice(), ERC1820_REGISTRY_CODE);
    }
}
