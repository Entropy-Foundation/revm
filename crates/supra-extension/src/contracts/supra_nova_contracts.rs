use alloy_sol_types::sol;

pub(crate) const WRAPPED_TOKEN: &str = "WrappedToken";
pub(crate) const WRAPPED_TOKEN_FACTORY: &str = "WrappedTokenFactory";
pub(crate) const WRAPPED_TOKEN_FACTORY_PROXY: &str = "WrappedTokenFactoryProxy";
pub(crate) const HYPERNOVA: &str = "Hypernova";
pub(crate) const HYPERNOVA_PROXY: &str = "HypernovaProxy";
pub(crate) const TOKEN_VAULT: &str = "TokenVault";
pub(crate) const TOKEN_VAULT_PROXY: &str = "TokenVaultProxy";
pub(crate) const FEE_OPERATOR: &str = "FeeOperator";
pub(crate) const FEE_OPERATOR_PROXY: &str = "FeeOperatorProxy";
pub(crate) const TOKEN_BRIDGE: &str = "TokenBridge";
pub(crate) const TOKEN_BRIDGE_PROXY: &str = "TokenBridgeProxy";

sol! {
    contract WrappedTokenFactory {
        function initialize(address owner, address token_impl);
    }
    contract WrappedTokenFactoryProxy {
        constructor(address factory_impl, bytes init_data);
    }

    contract Hypernova {
        function initialize(address owner, uint256 msgId);
    }

    contract HypernovaProxy {
        constructor(address hypernova_impl, bytes init_data);
    }

    contract TokenVault {
        function initialize(address owner, address nativeToken, address brigde);
    }

    contract TokenVaultProxy {
        constructor(address token_vault_impl, bytes init_data);
    }

    contract FeeOperator {
        function initialize(
            address owner,
            address hypernova,
            address sValueFeed,
            uint256 supraUsdtPairIndex,
            uint256 maxStaleOraclePriceLimit);
    }

    contract FeeOperatorProxy {
        constructor(address fee_operator_impl, bytes init_data);
    }

    contract TokenBridge {
        function initialize(
            address owner,
            address nativeToken,
            address hypernova,
            address feeOperator,
            address vault,
            address wrappedTokenFactory
        );
    }

    contract TokenBridgeProxy {
        constructor(address token_bridge_impl, bytes init_data);
    }

}
