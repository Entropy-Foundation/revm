// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Supra microsecond block timestamp.
/// @notice The certified block's timestamp in microseconds, exposed to EVM contracts at the
/// Supra-reserved address `0x0000000000000000000000000000000053555004`.
///
/// `block.timestamp` is the same instant truncated to whole seconds, as it is on every EVM chain.
/// This precompile serves the untruncated value, so a contract that needs sub-second resolution
/// does not have to give up `block.timestamp`'s meaning to get it.
///
/// The value is taken from the block's certified header, so it is identical for every transaction
/// in the block and is the same number Move's `block_prologue` receives and
/// `supra_framework::timestamp::now_microseconds()` returns. `microseconds() / 1_000_000` equals
/// `block.timestamp`.
///
/// The address is frozen: it is what callers encode into their contracts.
interface ISupraBlockTimestamp {
    /// @notice Thrown when the call data does not name a known entry point.
    error UnknownSelector();
    /// @notice Thrown when the call data is anything other than the bare four-byte selector.
    error MalformedInput();
    /// @notice Thrown when the execution has no block timestamp. This happens only on node-internal
    /// paths that execute no real block; it is not reachable from a transaction in a block or from
    /// `eth_call`.
    error TimestampUnavailable();
    /// @notice Thrown when the call carries value. The precompile takes none: a call with value
    /// reverts, which returns the value to the caller rather than leaving it at an address
    /// nothing can spend from.
    error ValueNotAccepted();

    /// @notice The block's timestamp in microseconds since the Unix epoch.
    ///
    /// The same value for every transaction in the block, and for every read within a transaction.
    ///
    /// # Rules
    ///
    /// No caller rule. Header data is public, so none applies and none would help: `STATICCALL`, a
    /// nested `CALL`, `DELEGATECALL`, any transaction sender including one with code, and every
    /// kind of transaction are all served. This is unlike {ISupraRandomness-next}, whose rules
    /// exist to protect a value that is not public; do not carry them over to this read.
    ///
    /// The call must carry no value and no call data beyond the four-byte selector. The refusals
    /// are therefore {UnknownSelector}, {MalformedInput}, {ValueNotAccepted} and, on node-internal
    /// paths only, {TimestampUnavailable}.
    ///
    /// # Cost
    ///
    /// A fixed 20 gas in addition to the cost of the call itself.
    ///
    /// @return The microseconds since the Unix epoch of the block being executed.
    function microseconds() external view returns (uint64);
}
