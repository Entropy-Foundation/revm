// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Supra EVM chain parameters.
/// @notice The chain's governed EVM gas parameters, exposed to EVM contracts at the Supra-reserved
/// address `0x0000000000000000000000000000000053555005`.
///
/// The two figures are the ones the chain itself enforces on every EVM transaction: the
/// per-transaction gas cap that bounds a transaction's gas limit, and the minimum gas price, which
/// is the block's base fee in wei. They are governed on chain and can change at an epoch boundary,
/// so a contract that has to agree with what the chain will accept reads them here instead of
/// hard-coding a copy that governance can make stale. The automation registry is one such
/// contract: it refuses to register a task the chain could never execute.
///
/// The values are the ones in force for the epoch of the block being executed. They are identical
/// for every transaction in the block, and are served identically in block execution and in RPC
/// simulation (`eth_call` / `eth_estimateGas`), where the simulated block's epoch decides them. In
/// particular they do not follow the gas ceiling an RPC call runs under, which is the RPC's own and
/// may differ from the chain's cap.
///
/// The address is frozen: it is what callers encode into their contracts.
interface ISupraChainParams {
    /// @notice Thrown when the call data does not name a known entry point.
    error UnknownSelector();
    /// @notice Thrown when the call data is anything other than the bare four-byte selector.
    error MalformedInput();

    /// @notice The per-transaction gas cap: the largest gas limit an EVM transaction may carry.
    ///
    /// # Rules
    ///
    /// No caller rule. The figure is public chain configuration, so `STATICCALL`, a nested `CALL`,
    /// `DELEGATECALL`, any transaction sender including one with code, and every kind of
    /// transaction are all served.
    ///
    /// The value is the cap in force for the epoch of the block being executed, the same for every
    /// transaction in the block, and the same in block execution and in RPC simulation.
    ///
    /// The call data must be the bare four-byte selector. The refusals are therefore
    /// {UnknownSelector} and {MalformedInput}. There is no "unavailable" refusal: every execution
    /// has an epoch, and so has a cap.
    ///
    /// # Cost
    ///
    /// A fixed 20 gas in addition to the cost of the call itself.
    ///
    /// @return The per-transaction gas cap, in gas units.
    function txGasLimitCap() external view returns (uint64);

    /// @notice The minimum gas price an EVM transaction must pay: the block's base fee, in wei.
    ///
    /// # Rules
    ///
    /// No caller rule, as for {txGasLimitCap}.
    ///
    /// The value is the minimum in force for the epoch of the block being executed, the same for
    /// every transaction in the block, and the same in block execution and in RPC simulation. It
    /// is the floor that transaction admission requires, not the price any particular block's
    /// transactions paid.
    ///
    /// The call data must be the bare four-byte selector. The refusals are therefore
    /// {UnknownSelector} and {MalformedInput}.
    ///
    /// # Cost
    ///
    /// A fixed 20 gas in addition to the cost of the call itself.
    ///
    /// @return The minimum gas price, in wei per gas unit.
    function minGasPrice() external view returns (uint256);
}
