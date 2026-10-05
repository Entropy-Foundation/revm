// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {ISupraEvmGasConfig} from "../src/interfaces/ISupraEvmGasConfig.sol";
import {LibEvmGasConfig} from "../src/libraries/LibEvmGasConfig.sol";

/// @dev Stands in for the EVM gas config precompile in Foundry tests.
///
/// Forge's EVM has no Supra precompiles, so any test that reaches the registry's registration
/// path has to serve {ISupraEvmGasConfig} itself, the same way the tests serve the tx-hash
/// precompile. The two reads are mocked per selector so a test can move one figure without
/// touching the other, and the defaults are kept in one place so every fixture agrees on them.
library EvmGasConfigMock {
    /// @dev Default per-transaction gas cap: 2^24, comfortably above every task the test helpers
    /// register (100,000 gas) and every larger maxGasAmount a test chooses explicitly, apart from
    /// the tests that set out to exceed it.
    uint64 internal constant DEFAULT_TX_GAS_LIMIT_CAP = 16_777_216;

    /// @dev Default minimum gas price: 1 gwei, below the 4 gwei gasPriceCap the test helpers
    /// register UST tasks with, so those registrations clear the floor.
    uint256 internal constant DEFAULT_MIN_GAS_PRICE = 1 gwei;

    /// @dev Serves both figures at their defaults.
    function mockDefaults(Vm vm) internal {
        mockTxGasLimitCap(vm, DEFAULT_TX_GAS_LIMIT_CAP);
        mockMinGasPrice(vm, DEFAULT_MIN_GAS_PRICE);
    }

    /// @dev Makes {ISupraEvmGasConfig-txGasLimitCap} return `_cap`, replacing any earlier mock of it.
    function mockTxGasLimitCap(Vm vm, uint64 _cap) internal {
        vm.mockCall(
            address(LibEvmGasConfig.EVM_GAS_CONFIG),
            abi.encodeCall(ISupraEvmGasConfig.txGasLimitCap, ()),
            abi.encode(_cap)
        );
    }

    /// @dev Makes {ISupraEvmGasConfig-minGasPrice} return `_minGasPrice`, replacing any earlier mock
    /// of it.
    function mockMinGasPrice(Vm vm, uint256 _minGasPrice) internal {
        vm.mockCall(
            address(LibEvmGasConfig.EVM_GAS_CONFIG),
            abi.encodeCall(ISupraEvmGasConfig.minGasPrice, ()),
            abi.encode(_minGasPrice)
        );
    }
}
