// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ISupraEvmGasConfig} from "../interfaces/ISupraEvmGasConfig.sol";

/// @title Convenience helper over {ISupraEvmGasConfig}.
/// @notice Holds the precompile's frozen address so a contract does not have to spell it out, and
/// wraps the two reads.
///
/// @dev The helper adds no semantics of its own. The values are the per-transaction gas cap and
/// the minimum gas price (the base fee, in wei) in force for the epoch of the block being
/// executed, identical for every transaction in the block and served identically in block
/// execution and RPC simulation. No caller rule applies to either read. See {ISupraEvmGasConfig}
/// for the errors they can revert with.
library LibEvmGasConfig {
    /// @notice The EVM gas config precompile. Frozen.
    ISupraEvmGasConfig internal constant EVM_GAS_CONFIG =
        ISupraEvmGasConfig(0x0000000000000000000000000000000053555005);

    /// @notice The per-transaction gas cap, in gas units.
    function txGasLimitCap() internal view returns (uint64) {
        return EVM_GAS_CONFIG.txGasLimitCap();
    }

    /// @notice The minimum gas price (the base fee), in wei per gas unit.
    function minGasPrice() internal view returns (uint256) {
        return EVM_GAS_CONFIG.minGasPrice();
    }
}
