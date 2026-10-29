# Automation Registry Cycle-Transition Gas Guide

This is a downstream-facing reference for sizing the `gas_limit` of the bookkeeping
transactions (`AutomationRegistryRecord`, see `transactions/automation_record.rs`) that
drive an automation-registry cycle transition: the transaction that triggers the
transition (`monitorCycleEnd` or `disableAutomation`) and the `processTasks`
transactions that carry it to completion.

`contracts/configs.rs`'s `MAX_SUPPORTED_AUTOMATION_TASKS` doc comment already covers
`monitorCycleEnd`'s cost in isolation. This guide adds the rest of the picture: what
`processTasks` costs per batch, how that differs across the ways a transition can
happen, and how the node sizes `processTasks` records from it ("How the node sizes a
record"). All figures come from
`solidity/supra_contracts/test/CycleTransitionGas.t.sol` — reproduce with:

```
cd solidity/supra_contracts && forge test --match-contract CycleTransitionGasTest -vv
```

The last section, "Registering a single task", covers the user-facing `register` and
`registerSystemTask` calls, from `solidity/supra_contracts/test/RegistrationGas.t.sol`.

**Assumptions common to the six scenarios below**, matching production defaults
(`LibDiamondUtils.defaultInitParams()`):
- Registry at its production cap: 200 tasks (160 UST + 40 GST), matching
  `MAX_SUPPORTED_AUTOMATION_TASKS`.
- `processTasks` submitted in batches of 25 tasks (8 batches to cover the full
  registry). 25 is the benchmark's measurement size, kept fixed so figures compare
  across runs; the node sizes its records with `CoreFacet.getRecordMaxTaskCount`
  instead (Entropy-Foundation/smr-moonshot#4755), which
  `testCycleTransitionGas_DerivedRecordSize_*` exercise.
- Tasks carry the test fixture's 640-byte payload and 128-byte predicate, except in
  scenario 4, where both are at the data-length caps, scenario 5, where half the USTs
  are, and scenario 6, where the USTs also carry 64 one-byte auxData entries.
- Every call runs as its own transaction, as on a chain: the suite runs in Forge's
  isolation mode (a `forge-config: default.isolate = true` inline config on the test
  contract), so the registrations before a transition are committed state when a
  record runs. Without it a test is one transaction, and a slot registration wrote
  earlier in the same test still has its original value of zero when a record clears
  it, which EIP-2200 prices as a cheap write to a slot dirtied in the same transaction
  rather than as clearing a stored value: removals then measure about half their
  on-chain cost.
- `monitorCycleEnd` and `processTasks` figures are the call's execution gas before
  refunds, measured by a meter contract placed at the VM signer's address
  (`ExecutionGasMeter`). A record's gas limit has to cover the gas spent before refunds,
  which a transaction's gas used does not show: refunds, up to a fifth of the gas
  (EIP-3529), are subtracted from it, and storage clears earn large ones. The figures
  exclude intrinsic gas and calldata, which `_requiredGasLimit` adds where the benchmark
  compares a batch with a gas limit, and charge the registry as a cold call target where
  a record transaction has it warm, 2,500 gas over. The `disableAutomation` figures are
  the owner transaction's gas used: intrinsic gas included, refunds subtracted.
  Reproduce and re-check after any change to the registry's storage layout or
  transition logic.

## Running with a custom task count

The task counts are overridable via environment variables, so this benchmark can be
re-run for a hypothetical registry size without editing the test file. All three env
vars fall back to the production defaults (160 / 40 / 20) when unset, so a plain
`forge test` run is unaffected:

| Env var | Default | Applies to |
| --- | --- | --- |
| `CYCLE_GAS_BENCH_UST_COUNT` | 160 | every test in the contract |
| `CYCLE_GAS_BENCH_GST_COUNT` | 40 | every test in the contract |
| `CYCLE_GAS_BENCH_EXPIRING_UST_COUNT` | 20 | scenario 3 only (must be ≤ the UST count) |

Example — re-run the scenarios at a smaller, non-default size (73 tasks: 60
UST + 13 GST, 5 of them expiring in scenario 3):

```
CYCLE_GAS_BENCH_UST_COUNT=60 \
CYCLE_GAS_BENCH_GST_COUNT=13 \
CYCLE_GAS_BENCH_EXPIRING_UST_COUNT=5 \
forge test --match-contract CycleTransitionGasTest -vv
```

Counts that exceed the production capacity (160 UST / 40 GST) are handled too — the
test widens `taskCapacity`/`sysTaskCapacity` (and their paired gas caps) just enough
to fit, so you can probe beyond the current production cap, e.g. to see where the
finalization premium heads at 310 tasks:

```
CYCLE_GAS_BENCH_UST_COUNT=250 CYCLE_GAS_BENCH_GST_COUNT=60 \
forge test --match-test testCycleTransitionGas_FullFlow_ProductionMix -vv
```

The task count need not be a multiple of the 25-task batch size — the last batch is
simply smaller. The `SANITY_GAS_CEILING` (30M) assertion in each test is a fixed,
generic ceiling, not scaled to the custom count — a large enough custom N can
legitimately trip it; that's expected, not a contract bug, and the logged per-batch
figures are the real data to read in that case.

Each run also checks the measured batches against the benchmark-derived record gas figures
(`LibCommon.RECORD_GAS_*`; `_assertWithinRecordGasFigures`, `_assertPremiumWithinReserve`;
see "How the node sizes a record"). The figures are derived at 400 tasks
(`RECORD_GAS_BENCHMARK_CAPACITY`), and `testCycleTransitionGas_FullFlow_BenchmarkCapacity`
runs scenario 1 at that size in every run. A custom count above 400 can fail the checks,
since the finalization premium per task grows with the registry; the logged premium per
registered task is the figure to compare. At a custom count, a cap in `DERIVED_SIZE_CAPS`
may leave no room for a task; the derived-size tests then log `no task fits at cap` for it
instead of failing. To run every scenario at 400 tasks:

```
CYCLE_GAS_BENCH_UST_COUNT=320 CYCLE_GAS_BENCH_GST_COUNT=80 \
forge test --match-contract CycleTransitionGasTest -vv
```

Each scenario logs, besides the per-batch gas: the initial batch, the middle batches
(average and maximum), the final batch, the gas per task of the non-final batches (average
and maximum), and the finalization premium, the final batch's gas less its tasks at the
non-final average per task. Scenario 1 also logs the premium per registered task.

## How `monitorCycleEnd` relates to `BlockMeta::blockPrologue`

`monitorCycleEnd` doesn't run as a standalone transaction. It runs because it's
**registered as one entry in a separate system contract, `BlockMeta`**
(`solidity/supra_contracts/src/BlockMeta.sol`), which the Supra VM calls once per
block, at block-start, via `blockPrologue()`. `BlockMeta` maintains an ordered list
of `(target contract, selector, gasLimit)` entries — a "cron-within-a-block" for
system hooks that must run every block without a user transaction — and
`blockPrologue()` just loops that list:

```
// BlockMeta.sol
function blockPrologue() external {
    msg.sender.enforceIsVmSigner();
    for (uint256 i = 0; i < executions.length; i++) {
        uint256 entry = executions[i];
        uint64 gasLimit = uint64(entry);                 // this entry's OWN registered gas limit
        (address target, bytes4 selector) = unpackExecution(entry);
        (bool ok, bytes memory data) = target.call{gas: gasLimit}(abi.encodePacked(selector));
        if (ok) { emit CallSucceeded(target, selector); } else { emit CallFailed(target, selector, data); }
    }
}
```

`monitorCycleEnd` was added to that list via a governance/multisig action
(`InitializeCycleMonitoring` in `solidity/supra_contracts/script/GovActions.s.sol`,
submitted through `solidity/supra_contracts/submit_governance_action.sh`), which calls
`BlockMeta.register(registry, monitorCycleEnd.selector, selectorGasLimit)`.
**`selectorGasLimit` is an operator-chosen value, not hardcoded anywhere in this
repo** — whoever submits that governance action sets it via the `SelectorGasLimit`
env var. This is the actual `monitorCycleEnd` gas budget the guidance in this
document is sizing against.

### Two gas ceilings, only one of which is enforced in code

There are two distinct "total gas" concepts here, and only a genesis-time check
connects them:

1. **`BlockMeta.blockPrologueGasCap`** — an on-chain `uint64` state variable, the sum
   that all registered entries' individual gas limits must fit under. Enforced at
   *registration time only*, in `register()`:
   ```
   uint256 upperBound = forwardingRuleCompatibleUpperBoundGasCap(blockPrologueGasCap); // cap * 63/64
   require(uint256(totalGasAllocated) + _gasLimit <= upperBound, GasCapExceeded());
   ```
   The `* 63/64` factor accounts for the EVM's own forwarding rule (a `call` can
   never forward more than 63/64 of the gas available to its caller), so the sum of
   what `blockPrologue()` hands out to entries has to leave that margin. The owner
   can raise this cap later via `setBlockPrologueGasCap`.
2. **`DEFAULT_BLOCK_METADATA_GAS_LIMIT`** (`crates/supra-extension/src/transactions/block_metadata.rs`,
   = `TX_GAS_LIMIT_CAP` = 16,777,216, the EIP-7825 network-wide transaction gas cap)
   — the ceiling on the *outer* `BlockMetadata` system transaction that carries the
   `blockPrologue()` call itself. This is a Rust/consensus-layer constant; Solidity
   has no reference to it at all.

The **only** code-level tie between the two is at genesis:
`GenesisTransactionGeneratorConfig::is_valid()` (`crates/supra-extension/src/contracts/configs.rs`)
rejects a genesis `block_prologue_gas_cap` greater than `DEFAULT_BLOCK_METADATA_GAS_LIMIT`.
**After genesis, nothing stops `blockPrologueGasCap` from being raised (via
`setBlockPrologueGasCap`) past what the outer transaction can actually ever afford.**
If that happens, `register()` will happily accept more/bigger entries than the
transaction can really fund, and at execution time individual `call{gas: gasLimit}`
sub-calls will just silently receive less gas than their registered limit once the
outer call frame runs low — showing up as spurious `CallFailed` events, not a
revert with a clear reason.

### Why a mis-sized `monitorCycleEnd` entry fails quietly, not loudly

`blockPrologue()`'s loop does not `require(ok)` — a failing entry only emits
`CallFailed` and the loop moves on to the next entry. So if `monitorCycleEnd`'s
*actual* cost (driven by `taskCapacity + sysTaskCapacity`, per Scenario 1 above)
exceeds its *registered* `selectorGasLimit`, the symptom is not a reverted block or
a loud error: **the automation cycle simply stops advancing**, silently, block after
block, observable only via `CallFailed` events on `BlockMeta` — every other
registered entry keeps running fine.

### The capacity/gas-limit gap this repo cannot close for you

`ConfigFacet.updateConfigBuffer`'s own NatSpec says it plainly (`ConfigFacet.sol`):

> `_taskCapacity` and `_sysTaskCapacity` bound how many tasks `CoreFacet.monitorCycleEnd()`
> iterates over each cycle, so raising them raises that function's per-call gas cost.
> ... This contract has no on-chain reference to `BlockMeta` and intentionally does
> not cap `_taskCapacity`/`_sysTaskCapacity` against it ... increasing these values is
> NOT automatically safe.

Confirmed by reading `LibCommon.validateConfigParameters` directly: it checks
non-zero values and simple orderings, and never references `BlockMeta`,
`blockPrologueGasCap`, or any gas-limit constant. **There is no code path anywhere
in this repo that checks the automation registry's task capacity against
`monitorCycleEnd`'s registered `BlockMeta` gas limit, in either direction.** The two
are governed independently:

| Who controls it | What | Where |
| --- | --- | --- |
| `BlockMeta`'s owner (foundation multisig) | `monitorCycleEnd`'s registered `selectorGasLimit`, `blockPrologueGasCap` | `BlockMeta.register` / `.setBlockPrologueGasCap`, via `InitializeCycleMonitoring`/governance actions |
| The automation registry's owner/governance | `taskCapacity`, `sysTaskCapacity` | `ConfigFacet.updateConfigBuffer` |

**Guideline: governance must treat these as one joint change, never independently.**
Before raising `taskCapacity`/`sysTaskCapacity` beyond the current production
default (160/40 = 200, `MAX_SUPPORTED_AUTOMATION_TASKS`), re-run this benchmark
(`Running with a custom task count` above) at the target N, and confirm the
resulting `monitorCycleEnd` gas figure still fits under `monitorCycleEnd`'s
currently-registered `BlockMeta` gas limit — re-registering it with a higher
`selectorGasLimit` first if it doesn't, and confirming that fits under
`blockPrologueGasCap` (with headroom left for whatever other entries are also
registered there) and, transitively, under `DEFAULT_BLOCK_METADATA_GAS_LIMIT`.
Doing it in the other order — raising capacity first — will silently stall
automation the moment `monitorCycleEnd`'s real cost outgrows its registered limit.

## Scenario 1 — normal transition, everything survives (`FINISHED -> STARTED`)

The common case: automation stays enabled, no task expires mid-transition.

| Call | Gas |
| --- | --- |
| `monitorCycleEnd` (trigger) | 1,945,671 |
| `processTasks`, non-final batch (average of batches 1–7) | 1,010,029 (40,401 per task) |
| `processTasks`, initial batch (1/8) | 1,088,023 (43,520 per task) |
| `processTasks`, **final batch (8/8)** | **2,647,737** |
| Final-batch finalization premium (final − 25 × non-final average per task) | 1,637,712 |
| Total `processTasks` (8 batches) | 9,717,939 |
| **Grand total** (trigger + all batches) | **11,663,610** |

The registry's task-ID lists (`activeTaskIds`, `orderedTaskIds`, `survivedTaskIds`,
`expectedTasksToBeProcessed`) are `uint64[]` arrays, which pack four task IDs per
storage slot, so each list of 200 tasks occupies 50 slots (#4285).

The final batch of a `FINISHED->STARTED` transition is 2.6x a typical batch. That
premium comes from four things landing on whichever call happens to finalize the
transition (`LibCore.sol`):
1. `updateRegistryState`'s two O(n) array writes — `registryState.activeTaskIds` and
   `registryState.orderedTaskIds` are both freshly assigned the full survivor list,
   one SSTORE per four survivors (fresh nonzero SSTOREs).
2. `moveToStartedState`'s `delete` of the whole transition-state struct (clears
   `expectedTasksToBeProcessed` and `survivedTaskIds`, up to 50 slots each), and the
   reset of the stored-words bound to the caps in force (`resetTaskStoredWordsBound`).
3. The batch's own per-task `survivedTaskIds.push()` cost, same as any other batch;
   a push writes a fresh slot for every fourth survivor and rewrites the current slot
   for the other three.
4. The `ActiveTasks` log, whose data holds the ABI-encoded survivor list (32 bytes per
   survivor plus a 64-byte offset and length, at 8 gas per byte). Measured against the
   same transition with the list hashed into a topic, it adds 48,873 gas for 200
   survivors; the log-data charge alone is ~51.7k, less the topic and hash it replaces.

The premium per registered task is 8,188 at 200 tasks and grows with the registry: at 400
tasks (`testCycleTransitionGas_FullFlow_BenchmarkCapacity`) the final batch costs 4,515,857
and the premium is 3,528,632, 8,821 per task. The record finalization figure is derived from
the 400-task figure.

This is the largest finalization premium among the scenarios. Scenario 5 has the largest
cost per task.

## Scenario 2 — mid-cycle suspension, everything dropped (`STARTED -> SUSPENDED -> READY`)

Automation is disabled mid-cycle (`disableAutomation`, contract-owner-only), well
before the cycle would otherwise end. Every registered task is refunded and removed;
none survive into a next cycle, and the cycle index does not increment.

| Call | Gas |
| --- | --- |
| `disableAutomation` (trigger, transaction gas used) | 1,968,544 |
| `processTasks` (`onCycleSuspend`), non-final batch (average) | 4,970,432 (198,817 per task) |
| `processTasks`, initial batch (1/8) | 5,264,767 (210,590 per task) |
| `processTasks`, **final batch (8/8)** | **5,260,020** |
| Final-batch finalization premium | 289,595 |
| Total `processTasks` (8 batches) | 40,053,046 |
| **Grand total** (trigger + all batches) | **42,021,590** |

Relative to Scenario 1:
- **Removal clears the task's storage**: `onCycleSuspend` removes every task, and
  `LibCommon.removeTask` `delete`s its whole record, payload, predicate and auxData
  included, one cold slot clear per 32 bytes stored. A removed task costs 4.8x a
  surviving one with the fixture's 640-byte payload and 128-byte predicate, and its cost
  grows with its size (Scenario 4). The refunds those clears earn are credited after
  execution, so a record's gas limit has to cover the gas before them.
- **No survivor bookkeeping**: `onCycleSuspend` never pushes to `survivedTaskIds`.
- **Finalization is a clear, not a write**: on the `SUSPENDED` branch,
  `updateRegistryState` resets `activeTaskIds`/`orderedTaskIds` to empty arrays and
  clears `sysTaskIds`, so the final batch's premium is about 0.3M, against 1.64M in
  Scenario 1.
- **Every batch logs its removals**: each `onCycleSuspend` batch emits `RemovedTasks`
  with the batch's task indexes ABI-encoded in the log data; measured against the same
  batch with the indexes hashed into a topic, this adds ~6.2k gas for 25 indexes. The log
  also carries the processing state (`SUSPENDED`) as a topic, ~375 gas, so a reader tells
  these removals from a transition's drops, which carry `FINISHED`.

## Scenario 3 — normal transition with some tasks expiring (`FINISHED -> STARTED`, cycle 2)

Same as Scenario 1, but 20 of the 160 UST tasks are past their expiry by the time
this transition processes them, so they get refunded and dropped
(`refundDepositAndDrop`) instead of renewed (`survivedTaskIds.push`). Because
registration always requires `expiry > current cycle's end time`
(`LibRegistry.validateTaskDuration`), a task can never already be expired at the
very first transition it survives into — this scenario necessarily spans two
cycles: the 20 tasks are registered with an expiry inside cycle 2, survive cycle
1's transition, and are dropped at cycle 2's.

| Call | Gas |
| --- | --- |
| `monitorCycleEnd` (trigger, cycle 2) | 1,945,671 |
| `processTasks`, non-final batch (average) | 1,441,245 (57,649 per task) |
| `processTasks`, initial batch (1/8: 20 drops, 5 survivors) | 4,513,843 (180,553 per task) |
| `processTasks`, **final batch (8/8)** | **1,789,390** |
| Final-batch finalization premium | 348,165 |
| Total `processTasks` (8 batches) | 11,878,102 |
| **Grand total** (trigger + all batches) | **13,823,773** |

The batch containing the 20 expiring tasks costs 4.5x a batch of survivors, since a drop
removes the task and clears its storage, as in Scenario 2; that batch also emits
`RemovedTasks` for the 20 dropped indexes, which adds 4,103 gas. With 180 survivors,
cycle 2's finalizing batch carries the `ActiveTasks` log data for the 180 survivors
(43,872 gas, measured against the list hashed into a topic), yet its premium is 348,165,
against 1,637,712 for cycle 1's finalizing batch with 200 survivors (the Scenario 1
figure). Cycle 1 writes the survivor lists into fresh slots, while cycle 2 rewrites slots
that already hold values. The finalization cost is therefore not proportional to survivor
count, and the record gas figures are derived from the first transition, Scenario 1.

Each trigger runs as its own transaction, so cycle 2's trigger starts as cold as cycle 1's,
and with the same number of tasks it costs the same.

## Scenario 4 — mid-cycle suspension of tasks at the data-length caps

Scenario 2 with every task's payload at 4,096 bytes and predicate at 2,048 bytes, the
default data-length caps (`DiamondInit`), filled with non-zero bytes. Each task stores
192 words of payload and predicate, against 24 for the fixture.

| Call | Gas |
| --- | --- |
| `disableAutomation` (trigger, transaction gas used) | 1,968,550 |
| `processTasks` (`onCycleSuspend`), non-final batch (average) | 26,258,832 (1,050,353 per task) |
| `processTasks`, initial batch (1/8) | 26,553,167 (1,062,126 per task) |
| `processTasks`, **final batch (8/8)** | **26,548,420** |
| Final-batch finalization premium | 289,595 |
| Total `processTasks` (8 batches) | 210,360,246 |
| **Grand total** (trigger + all batches) | **212,328,796** |

Between Scenario 2 and this scenario a removed task's cost rises by 851,536 gas for 168
more stored words, 5,069 gas per word, about the cost of clearing a stored slot, on top of
about 89,000. A batch of 25 such tasks needs 26.6M gas, above the production
per-transaction cap; the node's records carry 9 (see "Derived sizes at the defaults").

## Scenario 5 — normal transition after the data-length caps were lowered

The owner lowers the caps to 1,024 / 512 bytes (`updateDataLengthCaps`) while 80 USTs
stored at the previous 4,096 / 2,048-byte caps are registered, alongside 80 fixture USTs
and the 40 fixture GSTs. The lower caps apply in `monitorCycleEnd`, and the transition
drops every task above them, refunding its whole deposit and emitting
`TaskRemovedByDataLengthCaps`, and checks the stored lengths of every other task (see
"Data-length caps and the stored-words bound"). Tasks are processed in index order, so the
oversized USTs fill the first batches.

| Call | Gas |
| --- | --- |
| `monitorCycleEnd` (trigger) | 1,961,388 |
| `processTasks`, batches 1–3 (25 cap-size drops each) | 26,645,088 – 26,679,288 (1,067,171 per task) |
| `processTasks`, batch 4 (5 drops, 20 survivors) | 6,365,449 |
| `processTasks`, batches 5–6 (25 checked UST survivors each) | 1,210,048 – 1,227,148 |
| `processTasks`, batch 7 (25 checked GST survivors) | 1,057,389 |
| `processTasks`, **final batch (8/8)** | **2,380,944** |
| Total `processTasks` (8 batches) | 92,210,442 |
| **Grand total** (trigger + all batches) | **94,171,830** |

Dropping a cap-size task at a transition costs 1,067,171 gas, 5,045 more than removing it
in a suspension (Scenario 4): the length check and the deposit refund. Reading a
survivor's stored lengths adds about 8k gas per task against Scenario 1's batches. Both
costs arise only in the transition that applies lower caps. This is the largest cost a task
adds to a record under the default caps.

## Scenario 6 — normal transition after the auxData caps were lowered

Scenario 5 for auxData. The caps are first set to the fixture's payload and predicate sizes
(640 / 128 bytes) with room for exactly 64 auxData entries of 64 bytes combined, and every
UST registers with 64 one-byte entries; the 40 GSTs carry none. The combined-length cap is
then lowered by one byte, keeping the entry cap, so the check of each UST reads every
entry's length before it finds the task above the caps, and the transition then clears
every entry. A byte array of up to 31 bytes is stored in one slot with its length, so each
entry is one slot to read and clear, while `LibCommon.recordStoredWords` charges two words
per entry plus the words of the combined length: 154 words per UST, 947,000 gas under the
record gas figures.

| Call | Gas |
| --- | --- |
| `monitorCycleEnd` (trigger) | 1,961,506 |
| `processTasks`, batches 1–6 (25 auxData drops each) | 14,199,488 – 14,767,188 (590,687 per task at most) |
| `processTasks`, batch 7 (10 drops, 15 checked GST survivors) | 6,300,972 |
| `processTasks`, **final batch (8/8)** | **1,757,351** |
| Total `processTasks` (8 batches) | 95,162,051 |
| **Grand total** (trigger + all batches) | **97,123,557** |

A dropped task with 64 entries costs 590,687 gas against the 947,000 its stored-words
count allows, so charging two words per entry covers the slot each entry takes and its
length read, about 5,700 gas per entry.

## How the node sizes a record

The node builds every `processTasks` `AutomationRegistryRecord` with the per-transaction
cap of the epoch's gas schedule as its gas limit (smr-moonshot#4084), and asks the
registry how many tasks a record of that limit may carry,
`CoreFacet.getRecordMaxTaskCount(cap)` (Entropy-Foundation/smr-moonshot#4755). The view
mirrors the Move registry's `automation_registry::get_record_max_task_count`:

```
budget     = cap × taskSupportPercentage / 100                (owner-set, default 80)
taskGas    = RECORD_GAS_PER_TASK + RECORD_GAS_PER_STORED_WORD × taskStoredWordsBound
reserve    = (taskCapacity + sysTaskCapacity) × RECORD_FINALIZATION_GAS_PER_TASK
count      = budget > reserve ? (budget − reserve) / taskGas : 0
```

- `taskStoredWordsBound` bounds the storage words any task in the registry holds: payload
  and predicate in 32-byte words, auxData's combined length in words plus two words per
  entry (`LibCommon.recordStoredWords`). A task that is removed clears all of them. It is
  the bound of the data-length caps in force, except during a transition that applies
  lower caps (see "Data-length caps and the stored-words bound"); `getTaskStoredWordsBound`
  reads it.
- Every record reserves the finalization cost, since the node does not know in advance
  which record finalizes the transition. The reserve also covers the fixed cost of a
  `processTasks` call, which the per-task figures do not carry: a record of one cap-size
  task measures 1,145,042 gas, against 1,062,126 per task in a batch of 25.
- The rest of the cap, 20 % at the default percentage of 80, covers the transaction's
  intrinsic gas and calldata. The Move registry applies a fixed 80 % (`TASK_SUPPORT_FACTOR`).
- The view applies the active capacity and parameters. Buffered config, caps and
  parameters apply together in `monitorCycleEnd`, before the transition's first
  `processTasks`, so a transition's records are sized with the values it runs under, and a
  node restarting mid-transition computes the size its peers built the records with.

### Gas figures and record sizing parameters

The three gas figures are constants in `LibCommon`, derived from this benchmark at 400
tasks. They measure the transition code itself, so they change only with that code: a
contract change that moves a cost fails the benchmark's assertions, and the upgrade that
carries it re-derives the figures. The constants are inlined into CoreFacet (the view) and
ConfigFacet (the pre-checks), so such an upgrade replaces both facets in one cut.

| Figure | Value | Derived from |
| --- | --- | --- |
| `RECORD_GAS_PER_TASK` | 100,000 | about 89,000, the fixed part of a removed task at 5,069 per word (Scenarios 2 and 4), and about 94,000 for a task dropped above lowered caps (Scenario 5) |
| `RECORD_GAS_PER_STORED_WORD` | 5,500 | 5,069 per word (Scenarios 2 and 4). With `RECORD_GAS_PER_TASK`, 1,156,000 at the default caps' 192 words, against 1,067,171 for the costliest measured task, a cap-size drop when lower caps apply (Scenario 5). A task with 64 auxData entries is dropped for 590,687 against the 947,000 its 154 words allow (Scenario 6) |
| `RECORD_FINALIZATION_GAS_PER_TASK` | 10,000 | 8,821 per task at 400 tasks, 8,188 at 200 (Scenario 1) |

The owner's levers are two `RecordSizingParameters`, buffered with
`ConfigFacet.updateRecordSizingParameters` like a config change and applied at the next
cycle boundary together with the config and caps buffers (`getRecordSizingParameters`,
`getRecordSizingParametersBuffer`):

| Parameter | Range and default | Purpose |
| --- | --- | --- |
| `taskSupportPercentage` | 1 to 80, default 80 | Share of the cap budgeted for tasks and the reserve. 80 is the Move registry's `TASK_SUPPORT_FACTOR`, and the derived-size tests confirm the other 20 % covers intrinsic gas and calldata. Lowering it shrinks every record uniformly, the lever if records run short of gas before an upgrade can re-derive the figures, for instance after a node release reprices storage. |
| `maxCapacity` | default 400 | Largest capacity the figures cover (`RECORD_GAS_BENCHMARK_CAPACITY`). |

The finalization premium per task grows with the registry, so `updateConfigBuffer` refuses
a capacity above the `maxCapacity` in force after the next boundary, with
`LibCommon.CapacityAboveRecordGasLimit`. Raising `maxCapacity` is the owner's declaration
that this benchmark was re-run at the new size (`CYCLE_GAS_BENCH_*`) and that
`RECORD_FINALIZATION_GAS_PER_TASK` covers the premium it measured; if it does not, raising
the capacity needs an upgrade. To raise the capacity above the current `maxCapacity`,
buffer the parameters first and then the config: both apply at the same boundary.
`DiamondInit` sets `maxCapacity` to 400, or to the genesis capacity if that is larger,
which declares the same; genesis uses `MAX_SUPPORTED_AUTOMATION_TASKS`, 200.

### Data-length caps and the stored-words bound

`updateDataLengthCaps` buffers new caps (`getDataLengthCapsBuffer`), and they apply at the
next cycle boundary with the config and parameter buffers, like a config change; registrations until then
are checked against the caps in force. The caps are only checked when a task registers, so
a task registered under higher caps keeps its data after the caps are lowered. The
registry handles that as follows:
- When lower caps apply, the stored-words bound stays at the previous caps' until the
  transition that applies them finalizes. That transition's records are therefore sized
  for the tasks still in the registry.
- That transition drops every task stored above the lower caps, in payload, predicate,
  auxData entry count or combined auxData length, with its whole deposit refunded and
  `TaskRemovedByDataLengthCaps` emitted, as a gas config change drops tasks the chain can
  no longer execute. It reads every other task's stored lengths to check them (Scenario 5).
- When it finalizes, every remaining task is within the caps in force, and the bound
  becomes theirs.
- When higher caps apply, the bound rises at once, in `monitorCycleEnd`, before the
  transition's records are sized; nothing is dropped.
- With no task registered, the bound is the new caps' at once.

### Derived sizes at the defaults

With 200 tasks and the default data-length caps, `taskGas` is 100,000 + 5,500 × 192 =
1,156,000 and the reserve 2,000,000:

| Cap | Records carry | Records for 200 tasks | Largest measured record, all survive | Largest measured record, cap-size removals |
| --- | --- | --- | --- | --- |
| 16,777,216 | 9 tasks | 23 | 2,246,451 | 10,145,283 |
| 8,000,000 | 3 tasks | 67 | 2,078,435 | 3,987,059 |
| 6,000,000 | 2 tasks | 100 | 2,056,117 | 2,960,669 |
| 4,000,000 | 1 task | 200 | 2,033,803 | 1,934,286 |

"Largest measured record" is the gas limit the record needs, intrinsic gas and calldata
included, from `testCycleTransitionGas_DerivedRecordSize_FinalBatchFitsCap` and
`testCycleTransitionGas_DerivedRecordSize_CapSizeRemovalsFitCap`, which run the transition
at each cap with the final record carrying a full batch and assert every record fits.

At 400 tasks the reserve is 4,000,000: records carry 8 tasks at the production cap
(largest measured records 4,091,462 all surviving, 9,921,665 with cap-size removals) and 2
at 8,000,000 (3,922,967 and 3,763,293).

Below 3,945,000 no task fits at 200 tasks, and below 6,445,000 none at 400: the view
returns 0, and the node pauses automation instead of building records that cannot complete.
The count is sized for a task at the stored-words bound, so at the production cap a
transition of fixture-size tasks also takes 23 records where 1 would do. A record that fails
is retried as single-task records (`flatten` in the node's `evm/records.rs`).

### Update flow

Four inputs determine the record size. Three are owner-set registry state, each
double-buffered (an active and a buffer entry plus a buffer-exists flag) and applied at a
cycle boundary; the fourth is outside the registry.

| Input | Changed with | Read with | Accepted in | Takes effect |
| --- | --- | --- | --- | --- |
| Capacity (`taskCapacity + sysTaskCapacity`, part of the config) | `ConfigFacet.updateConfigBuffer` | `getConfig`, `getConfigBuffer` | any cycle state | next cycle boundary |
| Data-length caps | `ConfigFacet.updateDataLengthCaps` | `getDataLengthCaps`, `getDataLengthCapsBuffer`, `getTaskStoredWordsBound` | any cycle state | next cycle boundary |
| Record sizing parameters (`taskSupportPercentage`, `maxCapacity`) | `ConfigFacet.updateRecordSizingParameters` | `getRecordSizingParameters`, `getRecordSizingParametersBuffer` | any cycle state | next cycle boundary |
| Gas figures (`LibCommon.RECORD_GAS_*`) | contract upgrade replacing CoreFacet and ConfigFacet together | the guide's "Gas figures and record sizing parameters" | — | when the upgrade executes |
| Per-transaction gas cap | gas-schedule governance, outside the registry | `ISupraEvmGasConfig.txGasLimitCap` | — | at an epoch change |

Each setter fully replaces its own buffer: a second call before the boundary overwrites the
first, and the other two buffers are untouched. A setter's pre-check (see "Pre-checks on
parameter changes") runs against its new value and the other two inputs as they will be
after the boundary.

**At the cycle boundary.** `LibCore.updateConfigFromBuffer` applies the caps buffer, then
the parameter buffer, then the config buffer, each only if it exists, copying the buffer
entry to the active one and clearing it. It runs in `monitorCycleEnd` (after the transition
state is created, or directly when the registry is empty), at the end of a suspension while
automation is enabled, and in `enableAutomation` from READY. All three therefore apply in
the same call, before the transition's first `processTasks`, and the node sizes the
transition's records with the values in force from then on. Applying the caps also moves the
stored-words bound (see "Data-length caps and the stored-words bound"): lower caps keep the
bound and make the transition drop tasks above them; higher caps raise it at once; with no
task registered it becomes the new caps' bound.

**During a transition.** Values buffered while a transition is in progress (FINISHED or
SUSPENDED) do not apply when that transition finalizes; they wait for the next boundary.
The record size the node built the transition's records with therefore holds until it
finalizes, including for a node that restarts mid-transition and re-reads the view.

**Common sequences.**
- *Raise the capacity above `maxCapacity`:* re-run this benchmark at the new size. If
  `RECORD_FINALIZATION_GAS_PER_TASK` covers the measured premium, call
  `updateRecordSizingParameters` with the higher `maxCapacity`, then `updateConfigBuffer`
  with the capacity; both apply at the same boundary. The reverse order reverts with
  `CapacityAboveRecordGasLimit`. If the premium exceeds the figure, the figures are
  re-derived in a contract upgrade first.
- *Lower the capacity and `maxCapacity` together:* buffer the config first, then the
  parameters; `maxCapacity` may be below the active capacity because it is checked against
  the buffered one.
- *Raise the data-length caps:* `updateDataLengthCaps`; it reverts with
  `RecordBudgetTooSmall` if a cap-size task would not fit one record at the current cap.
  Buffering a lower capacity or a higher percentage first, for the same boundary, can make
  room, since the check reads the buffered values.
- *Lower the data-length caps:* `updateDataLengthCaps`; tasks above the new caps are dropped,
  with their whole deposit refunded, by the transition the boundary starts.
- *Shrink records because they run short of gas:* `updateRecordSizingParameters` with a
  lower `taskSupportPercentage`. It applies at the next boundary; a transition already in
  progress keeps its record size, and a record that fails is retried as single-task records
  by the node.
- *Change the gas figures:* contract upgrade that re-runs this benchmark, replaces CoreFacet
  and ConfigFacet in one cut, and updates the pinned bytecode hashes for genesis.
- *Lower the per-transaction cap:* nothing in the registry re-checks it. Check
  `getRecordMaxTaskCount(newCap)` beforehand; a result of 0 means the node will pause
  automation once the cap applies.
- *Recover after the cap fell below what records need:* the registry's own levers are all
  buffered to the next cycle boundary, so which one helps depends on where the cycle is.
  - In STARTED or READY, buffer a lower capacity: it shrinks the finalization reserve at the
    boundary. Lower data-length caps do not help here and are refused with
    `RecordBudgetTooSmall`: the transition that applies them still sizes its records for the
    tasks registered under the current caps (see "Data-length caps and the stored-words
    bound"), so the check reads the current bound.
  - In FINISHED or SUSPENDED, the transition in progress is already sized for the values in
    force, and buffered changes wait for a boundary it has to finish first. The only remedy
    is raising the per-transaction cap again in the gas schedule.

### Pre-checks on parameter changes

The config, the data-length caps and the record sizing parameters are each double-buffered,
and the three buffers apply together at the next cycle boundary. Each setter reverts with
`LibCommon.RecordBudgetTooSmall` if, with its new value and the values the other two will
hold after that boundary, a record at the per-transaction cap the gas config precompile
serves could not carry one task, and with `LibCommon.CapacityAboveRecordGasLimit` if the
capacity after the boundary would exceed `maxCapacity` after the boundary
(`LibCommon.requireRecordSizingFits`). A buffer only changes what is in force when it
applies, so the combination in force after the boundary has been checked whatever order the
setters were called in, and none of them is refused during a transition.

| Action | Checked against |
| --- | --- |
| `updateRecordSizingParameters` | the new parameters; the capacity after the boundary (buffered, else active); the larger of the stored-words bound and the buffered caps' bound |
| `updateDataLengthCaps` | the larger of the new caps' bound and the current bound; the parameters and capacity after the boundary |
| `updateConfigBuffer` | the new capacity; the parameters after the boundary; the larger of the stored-words bound and the buffered caps' bound |

The stored-words bound is checked at its largest because it can stay above the caps in
force until a transition that applies lower caps finalizes.

The cap itself is a gas-schedule entry governed outside the registry and can fall after
these checks; the view then returns 0 and the node pauses automation. Before lowering the
cap, check `getRecordMaxTaskCount(newCap)` against the registry.

### Trigger calls

`monitorCycleEnd` and `disableAutomation` are not `processTasks` records. At the 200-task
cap `monitorCycleEnd` spends 1,945,671 gas before refunds when it starts a transition, and
3,776,612 at 400 tasks; `disableAutomation` costs about 1.97M as a transaction.
`MonitorCycleEndGas.t.sol`, measured the same way, gives the same 200-task figure and the
table in `configs.rs`'s `MAX_SUPPORTED_AUTOMATION_TASKS` documentation (50 to 800 tasks); its
boundary scan puts the most tasks that fit `BLOCK_METADATA_GAS_LIMIT` at 1,819. Register
`monitorCycleEnd` with headroom over the figure for the registry's capacity, for instance
2,500,000 at 200 tasks. For `monitorCycleEnd`, "size" means the
`selectorGasLimit` it was registered with in `BlockMeta` (see "How `monitorCycleEnd`
relates to `BlockMeta::blockPrologue`" above) — this is **not** automatically kept in sync
with `taskCapacity`/`sysTaskCapacity`, so re-check it specifically whenever either capacity
changes. `disableAutomation` is a regular transaction and needs its own explicit budget of
similar size.

## Registering a single task

`register` (a UST, paid by the owner) and `registerSystemTask` (a GST, submitted by an
authorized account) are ordinary calls made in a user transaction, either directly or from a
contract, which then owns the task (Entropy-Foundation/smr-moonshot#4469). A contract caller,
other than an EIP-7702 delegated account, is first queried through ERC-165 for
`IAutomationTaskOwner`, which adds up to three `staticcall`s of at most 30,000 gas each to the
registration. They are not `AutomationRegistryRecord`s: the user transaction's sender sets their
gas limit. Their cost grows with the size of the task's
`payloadTx` and `predicate`, which the registry stores and which the registration event
carries in its log data (Entropy-Foundation/smr-moonshot#4285). Reproduce with:

```
cd solidity/supra_contracts && forge test --match-contract RegistrationGasTest -vv
```

How the figures are produced:
- Each scenario registers one task into a fresh registry ("first task") and then a
  second task of the same size and owner ("next task"). The first task also writes the
  registry's and the owner's bookkeeping for the first time.
- Before each measured call the Diamond, every facet and `WrappedSupra` are marked cold
  (`vm.cool`), so storage and account access is charged as in a transaction that
  touches the registry for the first time.
- "Tx total" is the measured call frame plus what the transaction pays around it under
  the Prague rules `foundry.toml` selects: 21,000 intrinsic gas, 4 gas per calldata
  token, the refund capped at a fifth of the gas used (EIP-3529), and the EIP-7623
  calldata floor.
- Payload and predicate are filled with non-zero bytes. Zero-filled input would store
  into fresh slots almost for free and cost a quarter as much in calldata, so it would
  understate both.
- The cap rows use the `DataLengthCaps` that `DiamondInit` sets: payload 4,096 bytes,
  predicate 2,048 bytes, no `auxData`. The benchmark reads the caps from the registry.
- "Event LOG gas" is the LOG opcode's charge for `TaskRegistered` or
  `SystemTaskRegistered`: 375, plus 375 per topic, plus 8 per byte of data. Memory
  expansion for the encoding is not included.

### UST (`register`)

| Payload / predicate (bytes) | First task, tx total | Next task, tx total | Event LOG gas |
| --- | --- | --- | --- |
| 640 / 128 (suite fixture) | 938,424 | 848,824 | 13,020 |
| 1,024 / 512 (1/4 of caps) | 1,515,650 | 1,428,550 | 19,164 |
| 2,048 / 1,024 (1/2 of caps) | 2,627,636 | 2,540,536 | 31,452 |
| **4,096 / 2,048 (at caps)** | **4,851,884** | **4,764,784** | 56,028 |

### GST (`registerSystemTask`)

| Payload / predicate (bytes) | First task, tx total | Next task, tx total | Event LOG gas |
| --- | --- | --- | --- |
| 640 / 128 (suite fixture) | 910,569 | 858,269 | 12,764 |
| **4,096 / 2,048 (at caps)** | **4,824,022** | **4,774,222** | 55,772 |

### Reading the figures

- **Storage dominates.** Each additional 32 bytes of payload or predicate adds about
  22k gas, the cost of writing a fresh non-zero storage slot. The UST rows grow by
  ~3.9M gas from the fixture to the caps.
- **The first task costs more.** It is ~90k gas above the next task for a UST and ~52k
  for a GST, from initialising the registry's and the owner's records.
- **Registration appends to `orderedTaskIds`, a packed `uint64[]`.** An append writes a
  fresh storage slot when the task ID starts a new slot (one in four) and rewrites a
  non-zero slot otherwise. The benchmark registers tasks 0 and 1, which share one slot.
  Task 0's ID is 0, so its append leaves the slot zero, and task 1's append pays the
  fresh-slot price, as a `uint256[]` append of task 1 did; the tables therefore do not
  show the cheaper rewrite.
- **Carrying `taskMetadata` in the log data adds about 1.2% to a UST registration.**
  `TaskRegistered` carries the task record in its log data (#4285). The same benchmark
  run on the parent commit (a0c93ab6), where the event logged only the hash of
  `taskMetadata` as a topic, measures the difference below; it is the same for the
  first and the next task. `SystemTaskRegistered` already carried `taskMetadata` in its
  log data, and its figures are unchanged.

  | Payload / predicate (bytes) | Tx total, hash in topic | Tx total, record in data | Difference |
  | --- | --- | --- | --- |
  | 640 / 128 | 927,328 | 938,333 | +11,005 |
  | 1,024 / 512 | 1,498,119 | 1,515,559 | +17,440 |
  | 2,048 / 1,024 | 2,597,236 | 2,627,545 | +30,309 |
  | 4,096 / 2,048 | 4,795,747 | 4,851,793 | +56,046 |

  These two columns were measured before the task-ID lists became `uint64[]`; the
  tables above are 91 gas higher in every row: 41 from the packed lists and 50 from the
  word-alignment checks on `payloadTx` and `predicate`.

- **Every size fits the per-transaction cap.** The largest registration, a UST at the
  caps, is ~4.85M gas, about 3.5x below `TX_GAS_LIMIT_CAP` (16,777,216). The benchmark
  asserts that every measured registration stays under it.
- **Size a registrant's gas limit from the table, not from a fixed figure.** A client
  that estimated gas for a small task and reuses that limit for a larger one runs out
  of gas. Estimate per task, or use the at-caps row as the upper bound for the default
  `DataLengthCaps`. Raising the caps, or allowing `auxData`, moves that bound and needs
  a re-run.
