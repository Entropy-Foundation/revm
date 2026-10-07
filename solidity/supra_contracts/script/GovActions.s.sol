// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {IMultiSignatureWallet} from "../src/interfaces/IMultiSignatureWallet.sol";
import {IBlockMeta} from "../src/interfaces/IBlockMeta.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";

// Governance actions on the genesis-deployed EVM system contracts, each submitted through the
// foundation MultiSignatureWallet that owns them. submit_governance_action.sh drives one action
// end to end: owner 0 submits it with the action's script below, the remaining owners confirm it
// with VoteForTxn, and owner 0 executes it with ExecuteTxn.
//
// Every script reads its addresses from environment variables named after the keys of the
// on-chain `0x1::evm_config::EvmContractsDetails` resource (FoundationWallet, BlockMetadata,
// AutomationRegistry), so the values can be exported straight from that resource.

/// @dev Shared by the governance action scripts below: each one submits a single action to the
/// foundation multisig wallet. Factored out so the three submitters can't drift apart on how
/// they submit, and so the assigned transaction index and content digest are surfaced the same
/// way for every action.
abstract contract GovSubmitAction is Script {
    address payable multisigWalletAddr;
    uint64 timeout;

    /// @dev Submits a governance action and prints the digest that VoteForTxn and ExecuteTxn
    /// must be given to confirm/execute it. The transaction index this submission is assigned
    /// becomes known only from the SubmitTransaction event in this run's own broadcast receipt,
    /// once the submission has landed. Do not read it from getNextTransactionIndex: a
    /// different submission landing first would misattribute the index.
    function submit(address _to, uint256 _value, bytes memory _data) internal {
        IMultiSignatureWallet wallet = IMultiSignatureWallet(multisigWalletAddr);
        bytes32 contentHash = wallet.hashTransactionContent(_to, _value, _data);

        console.log("Submitting governance action:");
        console.log("  to: ", _to);
        console.log("  value: ", _value);
        console.log("  data: ");
        console.logBytes(_data);
        // Printed as a single line so it can be scraped from stdout; the hash is derived from
        // this run's own intended action, not read back from the chain, so scraping it carries
        // no risk of picking up someone else's submission.
        console.log(string.concat("TxnContentHash: ", vm.toString(contentHash)));

        wallet.submitTransaction(_to, _value, timeout, _data);
    }
}

/// @dev Registers the automation registry's monitorCycleEnd() as a BlockMeta block-prologue
/// entry. Until it is registered, the automation cycle never leaves the state genesis put it in
/// and every registered task stays pending: genesis deploys BlockMeta with an empty entry list.
contract InitializeCycleMonitoring is GovSubmitAction {
    address blockMetadata;
    address registry;
    bytes4 selector;
    uint64 selectorGasLimit;

    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("FoundationWallet"));
        blockMetadata = vm.envAddress("BlockMetadata");
        registry = vm.envAddress("AutomationRegistry");
        selector = ICoreFacet.monitorCycleEnd.selector;
        // Gas the block prologue allots to this entry in every block. It has to cover the
        // worst-case cost of monitorCycleEnd at the registry's current task capacities (see
        // crates/supra-extension/src/AUTOMATION_REGISTRY_GAS_GUIDE.md): an entry that runs out of
        // gas fails silently, with only a CallFailed event, and the cycle stops advancing.
        selectorGasLimit = uint64(vm.envUint("SelectorGasLimit"));
        timeout = uint64(vm.envUint("Timeout"));
    }

    function run() public {
        // Every condition BlockMeta.register enforces is checked here first. The multisig only
        // runs register when the owners execute the action, so a registration that BlockMeta
        // would refuse otherwise fails after a quorum of owners has already paid to confirm it.
        checkRegistrable();

        vm.startBroadcast();

        bytes memory data = abi.encodeCall(IBlockMeta.register, (registry, selector, selectorGasLimit));
        submit(blockMetadata, 0, data);

        vm.stopBroadcast();
    }

    /// @dev Reverts, with the reason BlockMeta.register would give, when the registration this
    /// script is about to submit cannot succeed against the chain's current state.
    function checkRegistrable() internal view {
        require(selectorGasLimit > 0, "SelectorGasLimit must be greater than zero");
        require(registry.code.length > 0, "AutomationRegistry has no code at the given address");

        IBlockMeta blockMeta = IBlockMeta(blockMetadata);

        // getExecutionIndex returns for a registered pair and reverts with SelectorNotRegistered
        // for an unregistered one. Any other revert means the address is not a BlockMeta, or the
        // call itself failed, and is passed through rather than read as "not registered".
        try blockMeta.getExecutionIndex(registry, selector) returns (uint256 index) {
            console.log("monitorCycleEnd is already registered at execution index: ", index);
            revert("monitorCycleEnd is already registered in BlockMetadata");
        } catch (bytes memory reason) {
            // Truncating to the first four bytes is the point: they are the custom error's
            // selector, and a shorter reason pads with zeros, which matches no selector.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (bytes4(reason) != IBlockMeta.SelectorNotRegistered.selector) {
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }

        // The same bound BlockMeta.register applies: the sum of every registered entry's gas
        // limit must stay within the share of the block prologue gas cap that the 63/64
        // forwarding rule leaves callable.
        uint64 gasCap = blockMeta.blockPrologueGasCap();
        uint64 allocated = blockMeta.totalGasAllocated();
        uint256 callableCap = (uint256(gasCap) * 63) / 64;
        console.log("Block prologue gas cap: ", gasCap);
        console.log("Gas already allocated to other entries: ", allocated);
        console.log("Selector gas limit: ", selectorGasLimit);
        require(
            uint256(allocated) + selectorGasLimit <= callableCap,
            "SelectorGasLimit exceeds the callable share of the block prologue gas cap"
        );
    }
}

/// @dev Authorizes an account to register system automation tasks.
contract AuthorizeAccount is GovSubmitAction {
    address automationRegistry;
    address account;

    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("FoundationWallet"));
        automationRegistry = vm.envAddress("AutomationRegistry");
        account = vm.envAddress("AccountToAuthorize");
        timeout = uint64(vm.envUint("Timeout"));
    }

    function run() public {
        vm.startBroadcast();

        bytes memory data = abi.encodeCall(IConfigFacet.grantAuthorization, (account));
        submit(automationRegistry, 0, data);

        vm.stopBroadcast();
    }
}

/// @dev Turns the automation feature on (EnableAutomation=true) or off (EnableAutomation=false).
contract EnableDisableAutomation is GovSubmitAction {
    address automationRegistry;
    bool enable;

    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("FoundationWallet"));
        automationRegistry = vm.envAddress("AutomationRegistry");
        timeout = uint64(vm.envUint("Timeout"));
        enable = vm.envBool("EnableAutomation");
    }

    function run() public {
        // enableAutomation and disableAutomation each revert when the feature is already in the
        // requested state, which would only surface when the owners execute the action.
        bool enabled = ICoreFacet(automationRegistry).isAutomationEnabled();
        console.log("Automation enabled: ", enabled);
        require(enabled != enable, "Automation is already in the requested state");

        vm.startBroadcast();

        bytes memory data =
            enable ? abi.encodeCall(ICoreFacet.enableAutomation, ()) : abi.encodeCall(ICoreFacet.disableAutomation, ());
        submit(automationRegistry, 0, data);

        vm.stopBroadcast();
    }
}

contract VoteForTxn is Script {
    address payable multisigWalletAddr;
    uint256 txIndex;
    bytes32 contentHash;

    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("FoundationWallet"));
        txIndex = uint256(vm.envUint("GOV_TXN_INDEX"));
        contentHash = vm.envBytes32("GOV_TXN_CONTENT_HASH");
    }

    function run() public {
        IMultiSignatureWallet wallet = IMultiSignatureWallet(multisigWalletAddr);
        console.log("Txn count", wallet.txCount());

        // getTransaction reverts if txIndex does not exist or has expired, the same conditions
        // confirmTransaction itself checks. Caught here only so the operator sees that
        // diagnosis in the log; the catch block itself aborts the run, so a missing or expired
        // transaction is never confirmed.
        try wallet.getTransaction(txIndex) returns (address to, uint256 value, uint24, uint64, bytes memory data) {
            console.log("Confirming txIndex: ", txIndex);
            console.log("  to: ", to);
            console.log("  value: ", value);
            console.log("  data: ");
            console.logBytes(data);
            console.log(string.concat("  expected content hash: ", vm.toString(contentHash)));
            console.log(
                string.concat("  on-chain content hash: ", vm.toString(wallet.getTransactionContentHash(txIndex)))
            );
        } catch {
            revert("No live transaction at this index (does not exist, or expired); refusing to confirm.");
        }

        vm.startBroadcast();
        wallet.confirmTransaction(txIndex, contentHash);
        vm.stopBroadcast();
    }
}

contract ExecuteTxn is Script {
    address payable multisigWalletAddr;
    uint256 txIndex;
    bytes32 contentHash;

    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("FoundationWallet"));
        txIndex = uint256(vm.envUint("GOV_TXN_INDEX"));
        contentHash = vm.envBytes32("GOV_TXN_CONTENT_HASH");
    }

    function run() public {
        IMultiSignatureWallet wallet = IMultiSignatureWallet(multisigWalletAddr);

        // getTransaction reverts if txIndex does not exist or has expired, the same conditions
        // executeTransaction itself checks. Caught here only so the operator sees that
        // diagnosis in the log; the catch block itself aborts the run, so a missing or expired
        // transaction is never executed.
        try wallet.getTransaction(txIndex) returns (address to, uint256 value, uint24, uint64, bytes memory data) {
            console.log("Executing txIndex: ", txIndex);
            console.log("  to: ", to);
            console.log("  value: ", value);
            console.log("  data: ");
            console.logBytes(data);
            console.log(string.concat("  expected content hash: ", vm.toString(contentHash)));
            console.log(
                string.concat("  on-chain content hash: ", vm.toString(wallet.getTransactionContentHash(txIndex)))
            );
        } catch {
            revert("No live transaction at this index (does not exist, or expired); refusing to execute.");
        }

        vm.startBroadcast();
        wallet.executeTransaction(txIndex, contentHash);
        vm.stopBroadcast();
    }
}
