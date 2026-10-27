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

**Assumptions common to the four scenarios below**, matching production defaults
(`LibDiamondUtils.defaultInitParams()`):
- Registry at its production cap: 200 tasks (160 UST + 40 GST), matching
  `MAX_SUPPORTED_AUTOMATION_TASKS`.
- `processTasks` submitted in batches of 25 tasks (8 batches to cover the full
  registry). 25 is the benchmark's measurement size, kept fixed so figures compare
  across runs; the node sizes its records with `CoreFacet.getRecordMaxTaskCount`
  instead (Entropy-Foundation/smr-moonshot#4755), which
  `testCycleTransitionGas_DerivedRecordSize_*` exercise.
- Tasks carry the test fixture's 640-byte payload and 128-byte predicate, except in
  scenario 4, where both are at the data-length caps.
- Figures are `gasleft()`-bracket measurements around a single external call, the
  same methodology `MonitorCycleEndGas.t.sol` uses (not `forge snapshot`/gas-report
  tooling, which this repo doesn't use). Before each `processTasks` call the registry's
  accounts and storage are marked cold (`vm.cool`), as at the start of the transaction
  a record is: the whole benchmark runs in one test transaction, and without this the
  task slots written at registration would be charged warm. The trigger calls are not
  cooled. The figures do not include a transaction's intrinsic gas or calldata;
  `_requiredGasLimit` adds them where the benchmark compares a batch with a gas limit.
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

Each run also checks the measured batches against the registry's record gas figures
(`_assertWithinRecordGasFigures`, `_assertPremiumWithinReserve`; see "How the node sizes a
record"). A custom count above 400 can fail those checks, since the default finalization
figure covers registries of up to 400 tasks; the logged premium per registered task is the
figure to raise. At a custom count, a cap in `DERIVED_SIZE_CAPS` may leave no room for a
task; the derived-size tests then log `no task fits at cap` for it instead of failing.

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
| `monitorCycleEnd` (trigger) | 1,413,792 |
| `processTasks`, non-final batch (average of batches 1–7) | 909,940 (36,397 per task) |
| `processTasks`, initial batch (1/8) | 997,134 (39,885 per task) |
| `processTasks`, **final batch (8/8)** | **2,276,487** |
| Final-batch finalization premium (final − 25 × non-final average per task) | 1,366,562 |
| Total `processTasks` (8 batches) | 8,646,066 |
| **Grand total** (trigger + all batches) | **10,059,858** |

The registry's task-ID lists (`activeTaskIds`, `orderedTaskIds`, `survivedTaskIds`,
`expectedTasksToBeProcessed`) are `uint64[]` arrays, which pack four task IDs per
storage slot, so each list of 200 tasks occupies 50 slots (#4285).

The final batch of a `FINISHED->STARTED` transition is 2.5x a typical batch. That
premium comes from four things landing on whichever call happens to finalize the
transition (`LibCore.sol`):
1. `updateRegistryState`'s two O(n) array writes — `registryState.activeTaskIds` and
   `registryState.orderedTaskIds` are both freshly assigned the full survivor list,
   one SSTORE per four survivors (fresh nonzero SSTOREs, not cheap storage-clear
   refunds).
2. `moveToStartedState`'s `delete` of the whole transition-state struct (clears
   `expectedTasksToBeProcessed` and `survivedTaskIds`, up to 50 slots each).
3. The batch's own per-task `survivedTaskIds.push()` cost, same as any other batch;
   a push writes a fresh slot for every fourth survivor and rewrites the current slot
   for the other three.
4. The `ActiveTasks` log, whose data holds the ABI-encoded survivor list (32 bytes per
   survivor plus a 64-byte offset and length, at 8 gas per byte). Measured against the
   same transition with the list hashed into a topic, it adds 48,873 gas for 200
   survivors; the log-data charge alone is ~51.7k, less the topic and hash it replaces.

The premium per registered task is 6,832 at 200 tasks. Per surviving task it grows with
the registry: about 5,970 at 100 tasks, 7,139 at 250, 7,251 at 300 and 7,441 at 400, and
7,933 at 310 tasks, where the last batch carries 10 tasks.

This is the largest finalization premium among the scenarios. Scenario 4 has the largest
cost per task.

## Scenario 2 — mid-cycle suspension, everything dropped (`STARTED -> SUSPENDED -> READY`)

Automation is disabled mid-cycle (`disableAutomation`, contract-owner-only), well
before the cycle would otherwise end. Every registered task is refunded and removed;
none survive into a next cycle, and the cycle index does not increment.

| Call | Gas |
| --- | --- |
| `disableAutomation` (trigger) | 1,414,912 |
| `processTasks` (`onCycleSuspend`), non-final batch (average) | 2,564,775 (102,591 per task) |
| `processTasks`, initial batch (1/8) | 2,730,315 (109,212 per task) |
| `processTasks`, **final batch (8/8)** | **2,664,848** |
| Final-batch finalization premium | 100,073 |
| Total `processTasks` (8 batches) | 20,618,310 |
| **Grand total** (trigger + all batches) | **22,033,222** |

Relative to Scenario 1:
- **Removal clears the task's storage**: `onCycleSuspend` removes every task, and
  `LibCommon.removeTask` `delete`s its whole record, payload, predicate and auxData
  included, one cold slot clear per 32 bytes stored. A removed task costs 2.8x a
  surviving one with the fixture's 640-byte payload and 128-byte predicate, and its cost
  grows with its size (Scenario 4). The refunds those clears earn are credited after
  execution, so a record's gas limit has to cover the gas before them.
- **No survivor bookkeeping**: `onCycleSuspend` never pushes to `survivedTaskIds`.
- **Finalization is a clear, not a write**: on the `SUSPENDED` branch,
  `updateRegistryState` resets `activeTaskIds`/`orderedTaskIds` to empty arrays and
  clears `sysTaskIds`, so the final batch's premium is about 0.1M, against 1.37M in
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
| `monitorCycleEnd` (trigger, cycle 2) | 1,660,592 |
| `processTasks`, non-final batch (average) | 1,123,550 (44,942 per task) |
| `processTasks`, initial batch (1/8: 20 drops, 5 survivors) | 2,478,387 (99,135 per task) |
| `processTasks`, **final batch (8/8)** | **1,216,646** |
| Final-batch finalization premium | 93,096 |
| Total `processTasks` (8 batches) | 9,081,586 |
| **Grand total** (trigger + all batches) | **10,742,178** |

The batch containing the 20 expiring tasks costs 2.7x a batch of survivors, since a drop
removes the task and clears its storage, as in Scenario 2; that batch also emits
`RemovedTasks` for the 20 dropped indexes, which adds 4,103 gas. With 180 survivors,
cycle 2's finalizing batch carries the `ActiveTasks` log data for the 180 survivors
(43,872 gas, measured against the list hashed into a topic), yet its premium is 93,096,
against 1,366,562 for cycle 1's finalizing batch with 200 survivors (the Scenario 1
figure). Cycle 1 writes the survivor lists into fresh slots, while cycle 2 rewrites slots
that already hold values. The finalization cost is therefore not proportional to survivor
count, and the record gas figures are derived from the first transition, Scenario 1.

The trigger calls are not cooled before they are measured, so their figures depend on
what the calls before them left warm; cycle 2's trigger follows the cooled cycle-1 batches.

## Scenario 4 — mid-cycle suspension of tasks at the data-length caps

Scenario 2 with every task's payload at 4,096 bytes and predicate at 2,048 bytes, the
default data-length caps (`DiamondInit`), filled with non-zero bytes. Each task stores
192 words of payload and predicate, against 24 for the fixture.

| Call | Gas |
| --- | --- |
| `disableAutomation` (trigger) | 1,414,915 |
| `processTasks` (`onCycleSuspend`), non-final batch (average) | 12,023,300 (480,932 per task) |
| `processTasks`, initial batch (1/8) | 12,188,715 (487,548 per task) |
| `processTasks`, **final batch (8/8)** | **12,123,298** |
| Final-batch finalization premium | 99,998 |
| Total `processTasks` (8 batches) | 96,286,451 |
| **Grand total** (trigger + all batches) | **97,701,366** |

Between Scenario 2 and this scenario a removed task's cost rises by 378,336 gas for 168
more stored words, 2,252 gas per word, on top of 55,051. This is the largest cost a task
adds to a record under the default caps. A batch of 25 such tasks needs 12.2M gas, which
a record at a per-transaction cap below that cannot carry.

## How the node sizes a record

The node builds every `processTasks` `AutomationRegistryRecord` with the per-transaction
cap of the epoch's gas schedule as its gas limit (smr-moonshot#4084), and asks the
registry how many tasks a record of that limit may carry,
`CoreFacet.getRecordMaxTaskCount(cap)` (Entropy-Foundation/smr-moonshot#4755). The view
mirrors the Move registry's `automation_registry::get_record_max_task_count`:

```
budget     = cap × 80 / 100                               (RECORD_TASK_SUPPORT_PERCENTAGE)
taskGas    = recordGasPerTask + recordGasPerStoredWord × storedWords(data-length caps)
reserve    = (taskCapacity + sysTaskCapacity) × recordFinalizationGasPerTask
count      = budget > reserve ? (budget − reserve) / taskGas : 0
```

- `storedWords` (`LibCommon.recordStoredWords`) bounds the words one task can store under
  the current data-length caps: payload and predicate in 32-byte words, auxData's combined
  length in words plus two words per entry. A task that is removed clears all of them.
- Every record reserves the finalization cost, since the node does not know in advance
  which record finalizes the transition. The reserve also covers the fixed cost of a
  `processTasks` call, which the per-task figures do not carry: a record of one cap-size
  task measures 555,152 gas, against 487,548 per task in a batch of 25.
- The remaining 20 % of the cap covers the transaction's intrinsic gas and calldata.
- The view applies the current data-length caps and the active capacity. A buffered
  config applies in `monitorCycleEnd`, before the transition's first `processTasks`, so a
  transition's records are sized with the capacity it runs under.

The three figures are owner-set with `ConfigFacet.updateRecordGasParameters` and read with
`getRecordGasParameters`; they take effect immediately. Their defaults (`DiamondInit`) come
from the scenarios above, rounded up:

| Figure | Default | Derived from |
| --- | --- | --- |
| `recordGasPerTask` | 60,000 | 55,051, the fixed part of a removed task (Scenarios 2 and 4) |
| `recordGasPerStoredWord` | 2,500 | 2,252 per word (Scenarios 2 and 4) |
| `recordFinalizationGasPerTask` | 8,500 | 6,832 per task at 200 tasks, up to 7,933 at 310 (Scenario 1) |

The benchmark asserts the figures against every scenario it measures: each batch of k
tasks costs at most `k × taskGas + reserve`, each non-final batch of 25 at most
`25 × taskGas`, and each finalization premium at most the reserve. A change to the
registry's processing logic that raises a cost above its figure fails `forge test`.

### Derived sizes at the defaults

With 200 tasks and the default data-length caps, `taskGas` is 60,000 + 2,500 × 192 =
540,000 and the reserve 1,700,000:

| Cap | Records carry | Records for 200 tasks | Largest measured record, all survive | Largest measured record, cap-size removals |
| --- | --- | --- | --- | --- |
| 16,777,216 | 21 tasks | 10 | 2,203,675 | 10,277,943 |
| 8,000,000 | 8 tasks | 25 | 1,891,437 | 4,212,706 |
| 4,000,000 | 2 tasks | 100 | 1,735,286 | 1,413,992 |
| 3,000,000 | 1 task | 200 | 1,715,970 | 947,618 |

"Largest measured record" is the gas limit the record needs, intrinsic gas and calldata
included, from `testCycleTransitionGas_DerivedRecordSize_FinalBatchFitsCap` and
`testCycleTransitionGas_DerivedRecordSize_CapSizeRemovalsFitCap`, which run the transition
at each cap with the final record carrying a full batch and assert every record fits.

Below 2,800,000 no task fits at 200 tasks: the view returns 0, and the node pauses
automation instead of building records that cannot complete. The figures are the same
for every task size: the count is sized for a task at the data-length caps, so at the
production cap a transition of fixture-size tasks also takes 10 records where 1 would do.
A record that fails is retried as single-task records (`flatten` in the node's
`evm/records.rs`).

### Pre-checks on parameter changes

Each owner action that moves a term of the formula reverts with
`LibCommon.RecordBudgetTooSmall` if, after it, a record at the per-transaction cap the
gas config precompile serves could not carry one task:

| Action | Checked against |
| --- | --- |
| `updateRecordGasParameters` | the new figures, current data-length caps, the larger of the active and buffered capacity |
| `updateDataLengthCaps` | the new caps, current figures, the larger of the active and buffered capacity |
| `updateConfigBuffer` | the new capacity, current figures and data-length caps |

`updateRecordGasParameters` and `updateDataLengthCaps` also revert with
`LibCommon.RecordSizingChangeDuringTransition` unless the cycle is READY or STARTED. The node
sizes a transition's records when the transition starts and again only at an epoch change, so
the count cannot change under a transition in progress. `updateConfigBuffer` is not guarded: a
buffered capacity applies in `monitorCycleEnd`, before the node sizes the transition's records.

The cap itself is a gas-schedule entry governed outside the registry and can fall after
these checks; the view then returns 0 and the node pauses automation. Before lowering the
cap, check `getRecordMaxTaskCount(newCap)` against the registry. Raising the capacity
above 400 needs Scenario 1 re-run at the new size (`CYCLE_GAS_BENCH_*`) and, if the
premium per task exceeds the figure, `recordFinalizationGasPerTask` raised first.

### Trigger calls

`monitorCycleEnd` and `disableAutomation` are not `processTasks` records. Size the trigger
to at least ~1.5M gas at the 200-task cap, consistent with `configs.rs`'s
`MAX_SUPPORTED_AUTOMATION_TASKS` justification; Scenario 3's cycle-2 trigger, measured
after the cooled cycle-1 batches, is 1.66M. For `monitorCycleEnd`, "size" means the
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
