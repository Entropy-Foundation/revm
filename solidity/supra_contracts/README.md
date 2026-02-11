## Supra EVM Automation Registry

**This repository includes following smart contracts:**
- MultiSignatureWallet and MultisigBeacon
- ERC20Supra
- BlockMeta
- Automation Registry smart contracts
    - AutomationCore: manages configuration, refunds, fee accounting and other helper functions 
    - AutomationRegistry: user facing contract to register/cancel/stop a task
    - AutomationController: manages cycle transition and processing of tasks

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Install dependencies

```
forge install OpenZeppelin/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable
```

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Deploying Automation Registry smart contracts

```shell
$ forge script script/DeployAutomationRegistry.s.sol:DeployAutomationRegistry --rpc-url <your_rpc_url> --private-key <your_private_key>
```