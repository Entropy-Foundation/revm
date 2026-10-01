// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ISupraChainParams} from "../src/interfaces/ISupraChainParams.sol";

/// @dev Stand-in for the chain parameters precompile, etched at its address by the registration
/// scripts so that their local execution of `register` / `registerSystemTask` can read the
/// figures, as {TxHashPrecompile} does for the tx-hash precompile.
///
/// The figures served here only affect that local run. The broadcast transaction is executed by
/// the chain, against the chain's own governed figures, so a task this stub accepts can still be
/// refused on chain if it is over the chain's cap or under its minimum gas price.
contract ChainParamsPrecompile is ISupraChainParams {
    /// @dev 2^24 gas, the per-transaction gas cap EIP-7825 sets, used as a representative value.
    uint64 internal constant TX_GAS_LIMIT_CAP = 16_777_216;

    /// @dev 1 gwei, a minimum gas price low enough not to stand in the way of a local run.
    uint256 internal constant MIN_GAS_PRICE = 1 gwei;

    function txGasLimitCap() external pure returns (uint64) {
        return TX_GAS_LIMIT_CAP;
    }

    function minGasPrice() external pure returns (uint256) {
        return MIN_GAS_PRICE;
    }
}
