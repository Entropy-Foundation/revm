// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {ISupraEvmGasConfig} from "../src/interfaces/ISupraEvmGasConfig.sol";
import {LibEvmGasConfig} from "../src/libraries/LibEvmGasConfig.sol";

/// @dev Stand-in for the EVM gas config precompile, etched at its address by the registration
/// scripts so that their local execution of `register` / `registerSystemTask` can read the
/// figures, as {TxHashPrecompile} does for the tx-hash precompile.
///
/// The figures served here only affect that local run. The broadcast transaction is executed by
/// the chain against the chain's own governed figures, so the two can disagree in either
/// direction: a task this stand-in accepts can be refused on chain, and a task it refuses would
/// be accepted on chain but is never broadcast. Set the figures to the target chain's with the
/// optional `CHAIN_TX_GAS_LIMIT_CAP` and `CHAIN_MIN_GAS_PRICE` environment variables; read the
/// chain's own with `eth_call` to {ISupraEvmGasConfig-txGasLimitCap} and
/// {ISupraEvmGasConfig-minGasPrice}.
///
/// The figures are immutables, so they are part of the runtime code that `vm.etch` copies.
contract EvmGasConfigPrecompile is ISupraEvmGasConfig {
    uint64 internal immutable TX_GAS_LIMIT_CAP;
    uint256 internal immutable MIN_GAS_PRICE;

    constructor(uint64 _txGasLimitCap, uint256 _minGasPrice) {
        TX_GAS_LIMIT_CAP = _txGasLimitCap;
        MIN_GAS_PRICE = _minGasPrice;
    }

    function txGasLimitCap() external view returns (uint64) {
        return TX_GAS_LIMIT_CAP;
    }

    function minGasPrice() external view returns (uint256) {
        return MIN_GAS_PRICE;
    }
}

/// @dev Installs {EvmGasConfigPrecompile} at the precompile's address for a script's local run.
library EvmGasConfigStandIn {
    /// @dev 2^24 gas, the per-transaction gas cap EIP-7825 sets, served when
    /// `CHAIN_TX_GAS_LIMIT_CAP` is not set.
    uint64 internal constant DEFAULT_TX_GAS_LIMIT_CAP = 16_777_216;

    /// @dev 1 gwei, served when `CHAIN_MIN_GAS_PRICE` is not set.
    uint256 internal constant DEFAULT_MIN_GAS_PRICE = 1 gwei;

    /// @dev Etches a stand-in serving `CHAIN_TX_GAS_LIMIT_CAP` and `CHAIN_MIN_GAS_PRICE`, or the
    /// defaults when they are not set. A cap that does not fit a `uint64` reverts, as it could not
    /// be the chain's.
    function etch(Vm vm) internal {
        uint256 cap = vm.envOr("CHAIN_TX_GAS_LIMIT_CAP", uint256(DEFAULT_TX_GAS_LIMIT_CAP));
        require(cap <= type(uint64).max, "CHAIN_TX_GAS_LIMIT_CAP does not fit a uint64");
        uint256 minGasPrice = vm.envOr("CHAIN_MIN_GAS_PRICE", DEFAULT_MIN_GAS_PRICE);
        // casting to 'uint64' is safe because the require above bounds `cap` by type(uint64).max
        // forge-lint: disable-next-line(unsafe-typecast)
        EvmGasConfigPrecompile standIn = new EvmGasConfigPrecompile(uint64(cap), minGasPrice);
        vm.etch(address(LibEvmGasConfig.EVM_GAS_CONFIG), address(standIn).code);
    }
}
