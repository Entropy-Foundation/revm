// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Supra native randomness.
/// @notice The per-block randomness seed the Move VM consumes, exposed to EVM contracts.
///
/// Two reads at one Supra-reserved address, `0x0000000000000000000000000000000053555003`:
///
/// - {next} is *synchronous*: it returns fresh randomness inside the transaction that asks for it,
///   protected against test-and-abort by rules the VM enforces.
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
    /// @notice Thrown when the transaction is of a kind that may not read randomness. Ordinary
    /// user transactions, automation task actions and automation task predicates all may;
    /// the chain's own internal transactions may not.
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
    /// 4. The transaction is one that may read: an ordinary user transaction, an automation
    ///    task's action, an automation task's predicate, or a simulated call (`eth_call`,
    ///    `eth_estimateGas`). The chain's own internal transactions may not read.
    ///
    /// Rule 2 guarantees that the only code between the transaction boundary and the read is code
    /// the reading contract's own author chose to run, so nothing can wrap the reader, observe the
    /// outcome and revert on it.
    ///
    /// # Cost of failure
    ///
    /// **A transaction that reads a value and then fails is charged its whole gas limit**, not the
    /// gas it used. Reverting after seeing the outcome cannot be prevented - the reading contract
    /// can always revert - so instead it is made to cost what the sender was willing to spend,
    /// which removes the cheap retry that would otherwise make grinding an outcome free.
    /// `eth_estimateGas` estimates the success path and is unaffected.
    ///
    /// The charge raises the price of an abort without preventing it, and the price is the limit
    /// the sender chose. That is what leaves the second item under "What the rules do not cover"
    /// below.
    ///
    /// **This charge does not reach an automation task's predicate**, which is executed free of
    /// charge. A predicate that reads and then *reverts* pays no gas, but its task is removed from
    /// the registry, so it cannot be repeated. A predicate that reads and returns `false` pays
    /// nothing and keeps its task - and is prevented from gaming its own action by a different
    /// mechanism: reads are counted per transaction and the count carries across a predicate and
    /// the action it gates, so the action reads the *next* value and the predicate cannot compute
    /// it. A predicate therefore learns nothing about what its action will be given.
    ///
    /// That protection is specific to {next}. See the warning on {seedAt} about automation tasks.
    ///
    /// # What the rules do not cover
    ///
    /// Two ways to undo a read remain, and a consumer must close both. The first comes from
    /// dynamic dispatch: any address you call is code that may revert you.
    ///
    /// > **After reading randomness, no external call you make may be able to revert your
    /// > frame.** Either catch the failure of every such call, or finalise the outcome in a
    /// > different transaction from the one that makes the call. A callee controlled by the
    /// > transaction sender can otherwise revert the transaction after observing the outcome.
    ///
    /// An ERC-20 transfer hook, a bare `receive()`, an ERC-721 `onERC721Received` and an ERC-1155
    /// acceptance check are all calls into an address the sender may control, and any of them can
    /// revert. No VM rule can prevent this, because the callee is code the reading contract chose
    /// to call. The full-gas charge above applies to each attempt.
    ///
    /// Persisting the outcome to storage before the call does **not** protect it: a revert unwinds
    /// the entire frame, storage writes included, so the persisted outcome is undone with
    /// everything else. A low-level call whose boolean result you handle, or `try`/`catch` around a
    /// high-level one, keeps the frame alive.
    ///
    /// The second needs no external call, so a contract that never calls out is exposed to it too:
    /// **the sender chooses the transaction's gas limit**, and running out of gas unwinds the frame
    /// exactly as a revert does.
    ///
    /// > **After a read, the gas you spend must not depend on the value in a way that makes an
    /// > outcome the sender would reject the more expensive one.** Equalise the branches, or record
    /// > the outcome and let a later transaction spend the outcome-dependent gas.
    ///
    /// If one outcome costs more than another, a sender can set a limit that completes the outcome
    /// they want and exhausts the one they do not. The full-gas charge applies to the exhausted
    /// attempt, but it charges that same chosen limit - so each attempt costs one favourable run
    /// and an unfavourable outcome is never completed, while each resubmission is served a fresh
    /// value. It selects in one direction only: a limit can favour a cheap outcome over an
    /// expensive one, never the reverse.
    ///
    /// Recording the outcome and settling in a later transaction closes both.
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
    /// # This value is public
    ///
    /// Anyone can read any served height with `eth_call`, at any time, for free, without sending a
    /// transaction. From the moment block `height` is committed, **everybody** can compute whatever
    /// your contract would derive from its seed. None of {next}'s rules apply here and none would
    /// help: there is no secret to protect.
    ///
    /// Two consequences, neither specific to any kind of transaction:
    ///
    /// 1. **Commit before the seed exists.** A design that settles against a height that already
    ///    existed when the commitment was made is broken outright - the committer knew the outcome
    ///    as they committed.
    /// 2. **Settlement must not be withholdable.** If the only party who can settle is a party that
    ///    a particular outcome is bad for, they settle when they win and never when they lose. This
    ///    needs no revert, no gas and no contract: the simplest form is reading the seed off-chain
    ///    and not sending the losing transaction. So *anyone* must be able to settle, and the
    ///    design must not need the loser's cooperation.
    ///
    /// {next} does not have this problem. Its value is not public, and not predictable by anyone.
    ///
    /// @param height The block height whose seed is wanted.
    /// @return `keccak256` of that block's raw seed.
    function seedAt(uint64 height) external view returns (bytes32);
}
