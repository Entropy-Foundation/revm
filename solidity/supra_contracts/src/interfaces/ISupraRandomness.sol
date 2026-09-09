// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Supra native randomness.
/// @notice The per-block randomness seed the Move VM consumes, exposed to EVM contracts.
///
/// Two reads at one Supra-reserved address, `0x0000000000000000000000000000000053555003`:
///
/// - {next} is *synchronous*: it returns fresh randomness inside the transaction that asks for it,
///   protected against test-and-abort by rules the VM enforces. No other EVM chain offers this -
///   Chainlink VRF, Pyth Entropy and Flare are all asynchronous, so a consumer has to commit in
///   one transaction and settle in another.
/// - {seedAt} is the *historical* read, for designs that must settle in a later transaction
///   anyway. It is public data and carries no rules.
///
/// The address is frozen: it is what callers encode into their contracts.
interface ISupraRandomness {
    /// @notice Thrown when the call data does not name a known entry point.
    error UnknownSelector();
    /// @notice Thrown when the call data is not the length the named entry point takes, or a
    /// `uint64` argument has bits set above its 64th.
    error MalformedInput();
    /// @notice Thrown when this chain has no randomness for the block in question. For {next} the
    /// chain has no seed yet at all; for {seedAt} this node has no block at that height.
    error SeedUnavailable();
    /// @notice Thrown when the seed exists but is biasable - the block's proposer knew it while
    /// building the block - so it is refused rather than served weaker.
    error SeedBiasable();
    /// @notice Thrown when the calling contract is not the transaction's root context, so code its
    /// author did not choose sits between the transaction boundary and the read. See rule 2 on
    /// {next}.
    error CallerNotTransactionRoot();
    /// @notice Thrown when the transaction's sender account has code, which would run at the root
    /// context and could revert on the outcome. This refuses EIP-7702 delegated senders.
    error OriginHasCode();
    /// @notice Thrown when a system or genesis transaction attempts to read randomness.
    error ExecutionModeNotPermitted();
    /// @notice Thrown when the requested height is outside the window {seedAt} serves.
    error HeightOutOfWindow();

    /// @notice Fresh randomness for this transaction.
    ///
    /// Returns 32 bytes derived as `keccak256(seed || tx_hash || counter)`, where `seed` is the
    /// block's seed, `tx_hash` is this transaction's hash and `counter` counts the reads this
    /// transaction has already made. Every read on the chain therefore has a distinct value, and
    /// two reads in one transaction differ.
    ///
    /// # Rules
    ///
    /// All of the following must hold, or the call reverts with one of the errors above:
    ///
    /// 1. The block's seed exists and is unbiasable. Early in a chain's life, before the first
    ///    threshold-signed block, it is neither.
    /// 2. **The calling contract is the transaction's root context** - the contract the
    ///    transaction itself invoked, or the contract being deployed if the transaction is a
    ///    deployment. A contract reached by `CALL` from another contract is refused. Code reached
    ///    by `DELEGATECALL` runs *as* its caller, so a proxy's implementation, a Diamond facet and
    ///    an external library are all served: the read happens at the proxy's own context.
    /// 3. The transaction's sender is an account with no code.
    /// 4. The execution mode is not a system or genesis transaction.
    ///
    /// Rule 2 is the analogue of Move's private-entry requirement. It guarantees that the only
    /// code between the transaction boundary and the read is code the reading contract's own
    /// author chose to run, so no wrapper can observe the outcome and revert on it.
    ///
    /// # Cost of failure
    ///
    /// **A transaction that reads a value and then fails is charged its whole gas limit**, not the
    /// gas it used. This is the analogue of the gas deposit Move requires. Reverting after seeing
    /// the outcome cannot be prevented - the reading contract can always revert - so instead it is
    /// made to cost what the sender was willing to spend, which removes the cheap retry that would
    /// otherwise make grinding an outcome free. `eth_estimateGas` estimates the success path and
    /// is unaffected.
    ///
    /// # What the rules do not cover
    ///
    /// Move has no dynamic dispatch, so private entry closes test-and-abort completely. The EVM
    /// does have it, and this is the gap it leaves:
    ///
    /// > **After reading randomness, either make no external call whose failure you do not catch,
    /// > or persist the outcome to storage before making any.** A callee controlled by the
    /// > transaction sender can otherwise revert the transaction after observing the outcome.
    ///
    /// The callee does not have to look dangerous. An ERC-20 transfer hook, a bare `receive()`, an
    /// ERC-721 `onERC721Received` or an ERC-1155 acceptance check are all calls into an address the
    /// sender may control, and any of them can revert. No VM rule can prevent this, because the
    /// callee is code the reading contract chose to call; the full-gas charge above makes each
    /// attempt expensive, which is a tax rather than a prevention.
    ///
    /// `STATICCALL` to this function is permitted.
    ///
    /// @return The 32 random bytes.
    function next() external returns (bytes32);

    /// @notice The seed of a recent committed block, as `keccak256` of its raw seed.
    ///
    /// For commit-then-settle designs: commit in one transaction, then settle in a later one
    /// against the seed of a block the committer could not predict.
    ///
    /// Serves any height in `[block.number - 256, block.number - 1]`. The window matches
    /// `BLOCKHASH`'s. **The block being executed is excluded**: its seed is what {next}'s rules
    /// protect, and it is the same value for every transaction in the block, so serving it here -
    /// where no context rule applies - would be an unprotected route to randomness for the current
    /// block. Use {next} for that.
    ///
    /// No context, sender or gas rule applies, and none is needed. Every height this serves
    /// belongs to a block that is already committed and executed, so the value is public and a
    /// caller reading it has nothing left to bias. The hazard note on {next} still applies to
    /// whatever the settlement does with the value.
    ///
    /// @param height The block height whose seed is wanted.
    /// @return `keccak256` of that block's raw seed.
    function seedAt(uint64 height) external view returns (bytes32);
}
