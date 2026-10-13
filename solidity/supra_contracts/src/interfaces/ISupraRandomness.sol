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
    /// @notice Thrown when a frame between the transaction boundary and the read runs in a context
    /// other than the transaction's root, so code its author did not choose sits between the
    /// transaction boundary and the read. See rule 2 on {next}.
    error CallerNotTransactionRoot();
    /// @notice Thrown when the transaction's sender account has code, which would run at the root
    /// context and could revert on the outcome. Every EIP-7702 delegated sender is refused,
    /// including a self-sponsored one.
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
    /// 2. **Every frame from the transaction's root to the read runs in the root context** - the
    ///    contract the transaction itself invoked, or the contract being deployed if the
    ///    transaction is a deployment. Code reached by `DELEGATECALL` runs *as* its caller, so a
    ///    proxy's implementation, a Diamond facet, an external library and a `Multicall` that
    ///    delegatecalls its own contract are all served: the read happens at the proxy's own
    ///    context. A call the root context makes to itself is served. A contract reached by `CALL`
    ///    from another contract is refused, and so is a read in any frame with such a contract's
    ///    frame beneath it, including a call from that contract back into the root context.
    /// 3. The transaction's sender is an account with no code. Every EIP-7702 delegated account is
    ///    refused as the sender, a self-sponsored one included.
    /// 4. The transaction is one that may read: an ordinary user transaction, an automation
    ///    task's action, an automation task's predicate, or a simulated call (`eth_call`,
    ///    `eth_estimateGas`). The chain's own internal transactions may not read.
    ///
    /// Rule 2 guarantees that the only code between the transaction boundary and the read is code
    /// the reading contract's own author chose to run, so nothing can wrap the reader, observe the
    /// outcome and revert on it.
    ///
    /// Call this function with `CALL` or `STATICCALL`. A `DELEGATECALL` to it is decided on the
    /// calling frame's `msg.sender` instead of its context, so it is served from a self-call frame
    /// and refused from the root frame. Do not send ETH with a call to this address: value sent
    /// there stays at the address, which no key controls, and is not recoverable.
    ///
    /// # Cost of an undone read
    ///
    /// **A transaction is charged its whole gas limit, not the gas it used, whenever a frame in
    /// which a {next} value is served is reverted or halts**, running out of gas included,
    /// whether or not the transaction fails. A read is undone when the call it was made in reverts
    /// or halts, or when any call between that call and the transaction does, wherever the failure
    /// is caught. A batch entry point that tolerates a failing entry (`tryMulticall`, Multicall3
    /// `allowFailure`, `try this.f(data)`) and catches an inner frame that holds a read pays the
    /// full limit. A read stands, and the transaction pays the gas it used, when every call from
    /// the read back to the transaction returns successfully: a reader that catches the failure of
    /// a callee it calls after the read is not charged.
    ///
    /// The reading contract can always revert after seeing the outcome, so the abort costs what
    /// the sender was willing to spend instead. The price is the limit the sender chose. That is
    /// what leaves the second item under "What the rules do not cover" below.
    ///
    /// Simulation (`eth_call`, `eth_estimateGas`, `debug_traceCall`) does not apply the charge. An
    /// estimate is the gas the transaction uses to execute; on chain, a transaction that undoes a
    /// read costs the gas limit the sender set.
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
    /// Recording the outcome and settling in a later transaction closes this only when the
    /// settlement cannot run in the same transaction as the read, after it: a transaction that
    /// calls both the reading function and the settlement runs the settlement after the read.
    ///
    /// The second needs no external call, so a contract that never calls out is exposed to it too:
    /// **the sender chooses the transaction's gas limit**, and running out of gas unwinds the frame
    /// exactly as a revert does.
    ///
    /// > **After a read, the gas you spend must not depend on the value in a way that makes an
    /// > outcome the sender would reject the more expensive one.** Equalise the branches, record
    /// > the outcome and let a later transaction spend the outcome-dependent gas, or check before
    /// > the read that enough gas remains for the most expensive outcome.
    ///
    /// If one outcome costs more than another, a sender can set a limit that completes the outcome
    /// they want and exhausts the one they do not. The full-gas charge applies to the exhausted
    /// attempt, but it charges that same chosen limit - so each attempt costs one favourable run
    /// and an unfavourable outcome is never completed, while each resubmission is served a fresh
    /// value. It selects in one direction only: a limit can favour a cheap outcome over an
    /// expensive one, never the reverse.
    ///
    /// The check before the read is `require(gasleft() >= N)` immediately before calling this
    /// function, in the same function. `N` is the gas at which the most expensive outcome
    /// *succeeds* when it is started at the read, through to the end of the function and including
    /// this call and every call made after it. That is more than the gas the outcome uses: under
    /// EIP-150 each call keeps back 1/64 of the gas available to it, so `N` covers that 1/64 at
    /// every call level on the outcome's path, and gas refunds do not reduce it. Measure `N` as
    /// the lowest gas limit at which the most expensive outcome completes, add a margin, and
    /// measure again after a gas repricing. When the check passes every outcome can complete, so
    /// the gas limit selects nothing; when it fails, nothing has been read.
    ///
    /// `gasleft()` is the reading function's own remaining gas, and the check covers that
    /// function's work only. Behind a batch, a self-call or a `DELEGATECALL` the reading
    /// function's `gasleft()` is a share of the transaction's gas, not the transaction's gas, and
    /// work that runs after it returns can still run out of gas or revert.
    /// {LibRandomness-valueWithGasLeft} performs the check and the read together.
    ///
    /// # Batching
    ///
    /// **A reading function must not be reachable from a batch whose other entries the sender
    /// chooses**, a strict self-delegating `multicall` included. Every frame of such a batch runs
    /// in the transaction's root context, so the read is served, and an entry the sender adds can
    /// revert the whole batch on an outcome the sender does not want, which undoes the read.
    /// Exclude a function that reads from the selectors a `multicall` the contract exposes
    /// forwards. An automation task's gas limit is chosen by whoever registered the task.
    ///
    /// Recording the outcome and settling in a later transaction closes both ways only when the
    /// settlement cannot run in the same transaction as the read, after it.
    ///
    /// # Visibility
    ///
    /// A {next} value cannot be known by anyone before its transaction is ordered. Once the block
    /// commits, anyone can compute it: the seed is published with the block's commit certificate
    /// and the transaction hash is public. Do not use a {next} value as a secret, such as hidden
    /// cards, a sealed draw, a salt or a key.
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
    /// {next} does not have this problem: its value cannot be known before its transaction is
    /// ordered. Once the block commits, anyone can compute it, so it is not a secret either.
    ///
    /// @param height The block height whose seed is wanted.
    /// @return `keccak256` of that block's raw seed.
    function seedAt(uint64 height) external view returns (bytes32);
}
