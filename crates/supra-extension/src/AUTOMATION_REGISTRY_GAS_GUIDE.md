# Automation Registry Cycle-Transition Gas Guide

This is a downstream-facing reference for sizing the `gas_limit` of the bookkeeping
transactions (`AutomationRegistryRecord`, see `transactions/automation_record.rs`) that
drive an automation-registry cycle transition: the transaction that triggers the
transition (`monitorCycleEnd` or `disableAutomation`) and the `processTasks`
transactions that carry it to completion.

`contracts/configs.rs`'s `MAX_SUPPORTED_AUTOMATION_TASKS` doc comment already covers
`monitorCycleEnd`'s cost in isolation. This guide adds the rest of the picture: what
`processTasks` costs per batch, and how that differs across the three ways a
transition can happen. All figures come from
`solidity/supra_contracts/test/CycleTransitionGas.t.sol` — reproduce with:

```
cd solidity/supra_contracts && forge test --match-contract CycleTransitionGasTest -vv
```

The last section, "Registering a single task", covers the user-facing `register` and
`registerSystemTask` calls, from `solidity/supra_contracts/test/RegistrationGas.t.sol`.

**Assumptions common to all three scenarios below**, matching production defaults
(`LibDiamondUtils.defaultInitParams()`):
- Registry at its production cap: 200 tasks (160 UST + 40 GST), matching
  `MAX_SUPPORTED_AUTOMATION_TASKS`.
- `processTasks` submitted in batches of 25 tasks (8 batches to cover the full
  registry). This is the *submitter's* convention, not an on-chain constant — no
  batch-size cap exists in the contract or in this crate.
- Figures are `gasleft()`-bracket measurements around a single external call, the
  same methodology `MonitorCycleEndGas.t.sol` uses (not `forge snapshot`/gas-report
  tooling, which this repo doesn't use). They reflect gas charged at each call site
  and are best read as *relative* figures for sizing purposes, not a promise of the
  exact number a live network will report — reproduce and re-check after any change
  to the registry's storage layout or transition logic.

## Running with a custom task count

The task counts are overridable via environment variables, so this benchmark can be
re-run for a hypothetical registry size without editing the test file. All three env
vars fall back to the production defaults (160 / 40 / 20) when unset, so a plain
`forge test` run is unaffected:

| Env var | Default | Applies to |
| --- | --- | --- |
| `CYCLE_GAS_BENCH_UST_COUNT` | 160 | all three scenarios |
| `CYCLE_GAS_BENCH_GST_COUNT` | 40 | all three scenarios |
| `CYCLE_GAS_BENCH_EXPIRING_UST_COUNT` | 20 | scenario 3 only (must be ≤ the UST count) |

Example — re-run all three scenarios at a smaller, non-default size (73 tasks: 60
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
submitted through `run_steps.sh`), which calls
`BlockMeta.register(registry, monitorCycleEnd.selector, selectorGasLimit)`.
**`selectorGasLimit` is an operator-chosen value, not hardcoded anywhere in this
repo** — whoever submits that governance action sets it via the `SELECTOR_GAS_LIMIT`
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
| `monitorCycleEnd` (trigger) | 4,683,163 |
| `processTasks`, non-final batch (average of batches 1–7) | ~973,546 |
| `processTasks`, **final batch (8/8)** | **5,442,144** |
| Final-batch finalization premium (final − average) | ~4,468,598 |
| Total `processTasks` (8 batches) | 12,256,967 |
| **Grand total** (trigger + all batches) | **16,940,130** |

The final batch of a `FINISHED->STARTED` transition is ~5.6x a typical batch. That
premium comes from four things landing on whichever call happens to finalize the
transition (`LibCore.sol`):
1. `updateRegistryState`'s two O(n) array writes — `registryState.activeTaskIds` and
   `registryState.orderedTaskIds` are both freshly assigned the full survivor list
   (fresh nonzero SSTOREs, not cheap storage-clear refunds).
2. `moveToStartedState`'s `delete` of the whole transition-state struct (clears
   `expectedTasksToBeProcessed` and `survivedTaskIds`, up to 200 elements each).
3. The batch's own per-task `survivedTaskIds.push()` cost, same as any other batch.
4. The `ActiveTasks` log, whose data holds the ABI-encoded survivor list (32 bytes per
   survivor plus a 64-byte offset and length, at 8 gas per byte). Measured against the
   same transition with the list hashed into a topic, it adds 48,873 gas for 200
   survivors; the log-data charge alone is ~51.7k, less the topic and hash it replaces.

**This is the worst case among the three scenarios** — see Scenario 2 below, where
the equivalent finalization is actually free.

## Scenario 2 — mid-cycle suspension, everything dropped (`STARTED -> SUSPENDED -> READY`)

Automation is disabled mid-cycle (`disableAutomation`, contract-owner-only), well
before the cycle would otherwise end. Every registered task is refunded and removed;
none survive into a next cycle, and the cycle index does not increment.

| Call | Gas |
| --- | --- |
| `disableAutomation` (trigger) | 4,684,239 |
| `processTasks` (`onCycleSuspend`), non-final batch (average) | ~557,651 |
| `processTasks`, **final batch (8/8)** | **445,690** |
| Final-batch finalization premium | **0** (final batch is *cheaper* than typical) |
| Total `processTasks` (8 batches) | 4,349,250 |
| **Grand total** (trigger + all batches) | **9,033,489** |

Two things stand out relative to Scenario 1:
- **No survivor bookkeeping**: `onCycleSuspend` never pushes to `survivedTaskIds` —
  every task is unconditionally removed and refunded, so there's no per-survivor
  push cost building up across batches.
- **Finalization is a clear, not a write**: on the `SUSPENDED` branch,
  `updateRegistryState` resets `activeTaskIds`/`orderedTaskIds` to empty arrays and
  clears `sysTaskIds` — storage-clearing operations (partially refunded gas under
  EIP-3529), not fresh nonzero writes. The finalizing batch here is *cheaper* than a
  typical batch, the opposite of Scenario 1. **Do not size a suspension-path
  `processTasks` record off Scenario 1's final-batch premium** — it doesn't apply
  here.
- **Every batch logs its removals**: each `onCycleSuspend` batch emits `RemovedTasks`
  with the batch's task indexes ABI-encoded in the log data; measured against the same
  batch with the indexes hashed into a topic, this adds ~6.2k gas for 25 indexes.

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
| `monitorCycleEnd` (trigger, cycle 2) | 4,250,963 |
| `processTasks`, non-final batch (average) | ~896,024 |
| `processTasks`, **final batch (8/8)** | **989,941** |
| Final-batch finalization premium | ~93,917 |
| Total `processTasks` (8 batches) | 7,262,111 |
| **Grand total** (trigger + all batches) | **11,513,074** |

With 180 survivors, cycle 2's finalization premium is ~94k gas, of which 43,872 is
the `ActiveTasks` log data for the 180 survivors (measured against the list hashed
into a topic). The premium is not proportional to survivor count: in the same
benchmark, cycle 1's finalizing batch, with 200 survivors, measures 5,442,144 gas,
the Scenario 1 figure, while cycle 2's measures 989,941. Size a final batch from the
Scenario 1 figure, not by scaling it down with the survivor count. The batches
containing the 20 expiring tasks (batch 1, dominated by expired-task drops) are
cheaper than a normal batch, since a refund-and-drop is less work than a full
fee-charge-and-survive path; that batch also emits `RemovedTasks` for the 20 dropped
indexes, which adds 4,103 gas.

## Guidance for downstream `gas_limit` sizing

### Where things stand today: a flat cap, not per-record sizing

Every `processTasks` `AutomationRegistryRecord` is currently assigned the same flat
`gas_limit` — `TX_GAS_LIMIT_CAP` (16,777,216, `crates/primitives/src/eip7825.rs`),
per the node's transaction-construction code (`evm/records.rs`, outside this repo).
There is no per-batch variable budget today, and no use of
`ICoreFacet.getCycleStateDetails()` to detect and specially size a transition's
final batch.

Measured against that flat cap, the worst case across all three scenarios is
**Scenario 1's final batch at 5,442,144 gas** — about **3.1x headroom**
(16,777,216 / 5,442,144) under the current 16,777,216 flat limit. **Given that
margin, the "an under-budget final batch cannot be fixed by splitting it further
after the fact" hazard is not live today.** This section exists so that headroom
has a documented, reproducible baseline: if `TX_GAS_LIMIT_CAP` is ever lowered, or
`processTasks` sizing ever moves to a variable per-record budget (using
`getCycleStateDetails()`'s `nextTaskIndexPosition` vs
`expectedTasksToBeProcessed.length` to detect the final batch, as one could
imagine doing), re-run this benchmark and re-check the margin against whatever the
new scheme assigns non-final vs. final batches.

- **Trigger call** (`monitorCycleEnd` / `disableAutomation`): size to at least
  ~4.7M gas at the 200-task cap, consistent with `configs.rs`'s existing
  `MAX_SUPPORTED_AUTOMATION_TASKS` justification. For `monitorCycleEnd`, "size"
  means the `selectorGasLimit` it was registered with in `BlockMeta` (see "How
  `monitorCycleEnd` relates to `BlockMeta::blockPrologue`" above) — this is **not**
  automatically kept in sync with `taskCapacity`/`sysTaskCapacity`, so re-check it
  specifically whenever either capacity changes. `disableAutomation` is a regular
  transaction and needs its own explicit budget of similar size.
- **`processTasks`**: comfortably covered by the current flat 16,777,216 cap at
  every batch size measured here (non-final batches average ~974k/~558k/~896k gas;
  the worst-case final batch at 5,442,144 gas) — see the margin above. If a future
  change introduces a smaller or variable per-record budget instead of the flat
  cap, use **~5.5M gas** (Scenario 1's measured worst case, 5,442,144) as the floor for
  whichever batch will finalize a `FINISHED->STARTED` transition, and ~1M gas for
  every other batch, including suspension-path finalization (Scenario 2's final
  batch is cheaper than typical, not more expensive — see Scenario 2 above for why
  that doesn't generalize to the `FINISHED->STARTED` case).

## Registering a single task

`register` (a UST, paid by the owner) and `registerSystemTask` (a GST, submitted by an
authorized account) are ordinary user transactions, not `AutomationRegistryRecord`s:
the registrant sets their gas limit. Their cost grows with the size of the task's
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
| 640 / 128 (suite fixture) | 938,333 | 848,733 | 13,020 |
| 1,024 / 512 (1/4 of caps) | 1,515,559 | 1,428,459 | 19,164 |
| 2,048 / 1,024 (1/2 of caps) | 2,627,545 | 2,540,445 | 31,452 |
| **4,096 / 2,048 (at caps)** | **4,851,793** | **4,764,693** | 56,028 |

### GST (`registerSystemTask`)

| Payload / predicate (bytes) | First task, tx total | Next task, tx total | Event LOG gas |
| --- | --- | --- | --- |
| 640 / 128 (suite fixture) | 910,478 | 858,178 | 12,764 |
| **4,096 / 2,048 (at caps)** | **4,823,931** | **4,774,131** | 55,772 |

### Reading the figures

- **Storage dominates.** Each additional 32 bytes of payload or predicate adds about
  22k gas, the cost of writing a fresh non-zero storage slot. The UST rows grow by
  ~3.9M gas from the fixture to the caps.
- **The first task costs more.** It is ~90k gas above the next task for a UST and ~52k
  for a GST, from initialising the registry's and the owner's records.
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

- **Every size fits the per-transaction cap.** The largest registration, a UST at the
  caps, is ~4.85M gas, about 3.5x below `TX_GAS_LIMIT_CAP` (16,777,216). The benchmark
  asserts that every measured registration stays under it.
- **Size a registrant's gas limit from the table, not from a fixed figure.** A client
  that estimated gas for a small task and reuses that limit for a larger one runs out
  of gas. Estimate per task, or use the at-caps row as the upper bound for the default
  `DataLengthCaps`. Raising the caps, or allowing `auxData`, moves that bound and needs
  a re-run.
