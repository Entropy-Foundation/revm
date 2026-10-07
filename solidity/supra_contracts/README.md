## Supra EVM system contracts

The contracts the Supra EVM deploys at genesis (`crates/supra-extension/src/contracts/generator.rs`):

- `MultiSignatureWallet`, behind a `BeaconProxy` whose beacon is `MultisigBeacon`. Genesis deploys
  one instance, the foundation wallet (`FoundationWallet`), which owns the other system contracts.
- `WrappedSupra`.
- `BlockMeta`, behind an `ERC1967Proxy`. Runs its registered `(target, selector, gasLimit)` entries
  once per block from the `BlockMetadata` system transaction (`blockPrologue`).
- The automation registry, an EIP-2535 `Diamond` (`AutomationRegistry`) with `DiamondCutFacet`,
  `DiamondLoupeFacet`, `OwnershipFacet`, `ConfigFacet`, `RegistryFacet`, `RegistryViewFacet` and
  `CoreFacet`.

The tooling is [Foundry](https://book.getfoundry.sh/).

## Usage

### Install dependencies

The dependencies are git submodules under `lib/`:

```shell
git submodule update --init --recursive
```

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Deploying the automation registry on a chain without it

`deploy_automation_registry.sh` deploys `WrappedSupra` and the automation registry `Diamond` with
`script/DeployWrappedSupra.s.sol` and `script/DeployDiamond.s.sol`, reading `RPC_URL`,
`PRIVATE_KEY` and the registry's initial parameters from `.env`. `script/DeployBlockMeta.s.sol`
and `script/DeployMultisig.s.sol` deploy the other two system contracts the same way. A Supra
chain does not need any of these: genesis deploys all of them.

## Post-genesis governance actions

Genesis deploys `BlockMeta` and the automation registry with the foundation wallet as their owner,
and leaves `BlockMeta` with no registered entries. Until the registry's `monitorCycleEnd()` is
registered there, the automation cycle never ends and every registered task stays pending. The
registration is a governance action of the foundation wallet, as are the other owner-only calls
below.

`submit_governance_action.sh <action>` runs one action through the wallet: the first owner submits
it, the next owners confirm it until the wallet's `numConfirmationsRequired` is met, and the first
owner executes it. Each step is a `forge script` from `script/GovActions.s.sol`, signed with an
owner's keystore.

| Action | Effect |
|---|---|
| `InitializeCycleMonitoring` | `BlockMeta.register(AutomationRegistry, monitorCycleEnd.selector, SelectorGasLimit)` |
| `EnableDisableAutomation` | `CoreFacet.enableAutomation()` or `disableAutomation()`, per `EnableAutomation` |
| `AuthorizeAccount` | `ConfigFacet.grantAuthorization(AccountToAuthorize)`, which allows an account to register system tasks |

Each action script checks, before submitting, that the action can succeed against the chain's
current state, and stops with the reason when it cannot. A refused submission costs nothing; an
action that fails only at execution has already cost every confirming owner a transaction.

### Prerequisites

- `forge` and `cast`, and `forge build` run once in this directory.
- Keystores (Web3 Secret Storage JSON, as written by `cast wallet new` or `cast wallet import`) of
  at least `numConfirmationsRequired` owners of the foundation wallet, all with one password.
- An EVM balance on each signing owner. Genesis credits no EVM balance, so on a new chain the
  owners have to be funded first, by crossing SUPRA from the Move side
  (`supra move account transfer-to-evm`). 100 SUPRA per owner covers many actions.

The full sequence for bringing a newly genesised Supra chain to running automation, including the
funding, is in smr-moonshot `docs/operations/evm-automation-bring-up-runbook.md`.

### Environment

Exported, or written to a `.env` file in this directory (git ignores it):

| Variable | Used by | Value |
|---|---|---|
| `EVM_RPC_URL` | all | EVM JSON-RPC endpoint, e.g. `https://rpc-devnet.supra.com/rpc/v1/eth` |
| `EVM_FOUNDATION_OWNERS` | all | Signing owners' keystore paths, space separated; the first submits and executes |
| `CLI_PROFILE_PASSWORD` | all | The keystores' password; handed to Foundry as a private temporary file, never on the command line |
| `FoundationWallet` | all | Foundation wallet address |
| `Timeout` | all | Seconds the submitted action stays executable, at most the wallet's maximum (30 days unless changed) |
| `BlockMetadata` | `InitializeCycleMonitoring` | `BlockMeta` proxy address |
| `AutomationRegistry` | all three actions | Automation registry `Diamond` address |
| `SelectorGasLimit` | `InitializeCycleMonitoring` | Gas `blockPrologue` gives `monitorCycleEnd` in every block |
| `EnableAutomation` | `EnableDisableAutomation` | `true` or `false` |
| `AccountToAuthorize` | `AuthorizeAccount` | Account to authorize |

`FoundationWallet`, `BlockMetadata` and `AutomationRegistry` are the keys of the on-chain
`0x1::evm_config::EvmContractsDetails` resource, which holds the addresses genesis deployed:

```shell
curl -s <rest-url>/rpc/v3/accounts/0x1/resources/0x1%3A%3Aevm_config%3A%3AEvmContractsDetails
```

The resource drops leading zero bytes from an address, so a value shorter than 40 hex digits is
left-padded with zeros.

### Sizing `SelectorGasLimit`

- **Upper bound.** The gas limits of all registered entries together must stay within 63/64 of
  `BlockMeta.blockPrologueGasCap()`, the share the EVM's forwarding rule leaves callable.
  `BlockMeta.register` refuses a registration over it, and `InitializeCycleMonitoring` refuses to
  submit one. With the default cap of 16,777,216 and no other entries, the bound is 16,515,072.
- **Lower bound.** The worst-case cost of `monitorCycleEnd` at the registry's current
  `taskCapacity + sysTaskCapacity`, from `crates/supra-extension/src/AUTOMATION_REGISTRY_GAS_GUIDE.md`
  (about 1.5M gas at the 200-task cap). An entry that runs out of gas emits `CallFailed` and
  nothing else: the cycle stops advancing without any error.
- The smr-moonshot localnet end-to-end tests register 9,000,000.

Nothing checks the registered limit when the task capacities change later. Re-check it whenever
either capacity is raised.

### Running an action

```shell
export EVM_RPC_URL=https://rpc-devnet.supra.com/rpc/v1/eth
export EVM_FOUNDATION_OWNERS="owner0.json owner1.json owner2.json"
export CLI_PROFILE_PASSWORD=...
export FoundationWallet=0x... BlockMetadata=0x... AutomationRegistry=0x...
export Timeout=1800 SelectorGasLimit=9000000

./submit_governance_action.sh InitializeCycleMonitoring
```

### Verifying

```shell
# The registered entries, in execution order.
cast call ${BlockMetadata} "getExecutions()(address[],bytes4[])" --rpc-url ${EVM_RPC_URL}

# The gas registered for monitorCycleEnd. Reverts with SelectorNotRegistered when it is not registered.
cast call ${BlockMetadata} "getExecutionGasLimit(address,bytes4)(uint64)" \
  ${AutomationRegistry} "$(cast sig 'monitorCycleEnd()')" --rpc-url ${EVM_RPC_URL}

# The automation feature's state, and the cycle (index, start time, duration, state).
cast call ${AutomationRegistry} "isAutomationEnabled()(bool)" --rpc-url ${EVM_RPC_URL}
cast call ${AutomationRegistry} "getCycleInfo()(uint64,uint64,uint64,uint8)" --rpc-url ${EVM_RPC_URL}
```
