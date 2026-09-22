// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Supra native crossing, SEVM to Move.
/// @notice Sends native SUPRA out of the Supra EVM to a Move address, through the Supra-reserved
/// address `0x0000000000000000000000000000000053555002`.
///
/// Native SUPRA on the Supra EVM mirrors value escrowed on the Move side. {crossToMove} takes the
/// value sent with the call out of the EVM's circulation and records a crossing that the Move side
/// credits to the named Move address in a later block. The credit is not part of this call: the
/// call returns once the crossing is recorded, and the recipient's Move balance changes afterwards.
///
/// Amounts cross in **quants**, the Move side's unit. One quant is `10 ** 10` wei, so a call must
/// send a whole multiple of `10 ** 10` wei; a sub-quant remainder is refused rather than rounded
/// away.
///
/// The address is frozen: it is what callers encode into their contracts, and it is the address
/// that authenticates a {NativeCrossingToMove} log.
interface ISupraNativeCrossing {
    /// @notice Emitted for each recorded crossing, at this precompile's own address.
    ///
    /// The data word is `amountQuants`, the amount in **quants** - not the wei the caller sent.
    /// One quant is `10 ** 10` wei, so the wei value of a crossing is `amountQuants * 10 ** 10`.
    /// A consumer that reads the word as wei is off by that factor.
    ///
    /// The log is the record the Move side settles against, so it is emitted by the EVM at this
    /// address and unwinds with the frame that produced it: a crossing recorded inside a call
    /// frame that later reverts disappears along with the debit.
    ///
    /// @param sender The Supra EVM address that was debited, and the address a Move-side refund
    /// returns the value to.
    /// @param recipient The 32 bytes of the Move address the value is owed to.
    /// @param amountQuants The amount crossing, in quants.
    event NativeCrossingToMove(address indexed sender, bytes32 indexed recipient, uint256 amountQuants);

    /// @notice Thrown when the call data does not name a known entry point. Permanent: the call
    /// has to be corrected.
    error UnknownSelector();
    /// @notice Thrown when the call data is not the four-byte selector followed by exactly one
    /// 32-byte word. A mis-sized recipient is neither padded nor truncated. Permanent: the call
    /// has to be corrected.
    error MalformedInput();
    /// @notice Thrown when the precompile was not entered as a plain `CALL` to its own address, so
    /// the value the frame reports was never transferred to it. `DELEGATECALL` and `CALLCODE` both
    /// look like this. Permanent: the call has to be corrected.
    error NotACall();
    /// @notice Thrown when the call is made from a static frame. A crossing changes state, so
    /// `STATICCALL` cannot carry one. Permanent: the call has to be corrected.
    error StaticCall();
    /// @notice Thrown when the value sent is zero, or carries a sub-quant remainder. The value must
    /// be a non-zero whole multiple of `10 ** 10` wei. Permanent: the call has to be corrected.
    error NotWholeQuants();
    /// @notice Thrown when the value sent is more quants than a Move fungible-asset amount can
    /// express. Permanent: the call has to be corrected, by crossing less at a time.
    error AmountTooLarge();
    /// @notice Thrown when the recipient is the zero address, which cannot hold a balance.
    /// Permanent: the call has to be corrected.
    error BadRecipient();
    /// @notice Thrown when the chain has cross-VM settlement disabled, so no new crossing may
    /// start. Transient: the same call succeeds once the chain enables settlement again.
    error SettlementDisabled();
    /// @notice Thrown when the chain's settlement backlog is at its bound, so a crossing started
    /// now could not be given a bounded wait. Transient: the backlog drains as the Move side
    /// settles what is already recorded, and the same call succeeds on a later retry.
    error BacklogFull();

    /// @notice Sends the value of this call to `recipient` on the Move side.
    ///
    /// The value sent with the call is the amount that crosses. It is taken out of the Supra EVM's
    /// circulation here, and credited to `recipient` by the Move side in a later block. A crossing
    /// the Move side cannot apply is refunded there to {NativeCrossingToMove}'s `sender`, so it
    /// costs a round trip rather than reverting this call.
    ///
    /// Emits {NativeCrossingToMove}.
    ///
    /// # Rules
    ///
    /// All of the following must hold, or the call reverts with one of the errors above:
    ///
    /// 1. The call data is this selector followed by exactly one 32-byte word.
    /// 2. The call is a plain `CALL` to this address from a non-static frame.
    /// 3. The value sent is a non-zero whole number of quants - a multiple of `10 ** 10` wei -
    ///    and no more quants than a `uint64` can express.
    /// 4. `recipient` is not the zero address.
    /// 5. The chain has cross-VM settlement enabled and backlog room for one more crossing.
    ///
    /// Rules 1 to 4 are properties of the call, and their refusals are permanent. Rule 5 is a
    /// property of the chain, and its two refusals - {SettlementDisabled} and {BacklogFull} - are
    /// transient: a caller that retries later can succeed unchanged.
    ///
    /// **The rules are decided in that order**, so a call that breaks one of rules 1 to 4 is
    /// refused for that and never told that a retry would serve it. A caller that receives a
    /// transient error can therefore act on it, because the call itself has already been found
    /// sound.
    ///
    /// A refusal reverts, which returns the value sent with the call. Nothing crosses and nothing
    /// is debited.
    ///
    /// @dev A call whose `value` exceeds the caller's balance carries none of these errors. The EVM
    /// refuses it as it builds the frame, returning `OutOfFunds` to the parent frame, so the `CALL`
    /// returns 0 with empty return data - a high-level call reverts with empty revert data, a
    /// low-level `.call` returns `false` - and this precompile does not run. An externally owned
    /// account sending a crossing directly is refused at admission, with `insufficient funds for
    /// gas * price + value`.
    ///
    /// # Cost
    ///
    /// A fixed 100,000 gas in addition to the cost of the call itself. It prices the Move-side
    /// settlement the crossing causes - a durable queue row, a row in the next block's settlement
    /// transaction, and the escrow withdrawal and deposit that transaction performs - none of
    /// which the Move side charges for.
    ///
    /// It is charged after every rule above has passed and before anything is debited, so **a
    /// refused crossing is charged nothing** and only a recorded crossing pays for one. A frame
    /// whose gas does not cover the charge runs out of gas, which carries no revert data.
    ///
    /// @param recipient The 32 bytes of the Move address to credit.
    /// @return amountQuants The amount recorded as crossing, in quants: the value sent divided by
    /// `10 ** 10`.
    function crossToMove(bytes32 recipient) external payable returns (uint64 amountQuants);
}
