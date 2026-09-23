// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {MultiSignatureWallet} from "../src/MultiSignatureWallet.sol";
import {BlockMeta} from "../src/BlockMeta.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";

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
        MultiSignatureWallet wallet = MultiSignatureWallet(multisigWalletAddr);
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

contract InitializeCycleMonitoring is GovSubmitAction {
    address blockMetadata;
    address registry;
    bytes4 selector;
    uint64 selectorGasLimit;

    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("MULTISIG_WALLET_ADDRESS"));
        blockMetadata = vm.envAddress("BLOCK_METADATA_ADDRESS");
        registry = vm.envAddress("REGISTRY");
        selector = bytes4(keccak256("monitorCycleEnd()"));
        // if gas-selectorGasLimit is greater than the block prologue gas cap,
        // the transaction will fail and the cycle monitoring will not be registered
        selectorGasLimit = uint64(vm.envUint("SELECTOR_GAS_LIMIT"));
        timeout = uint64(vm.envUint("TIMEOUT"));
    }

    function run() public {
        vm.startBroadcast();

        // Submit a foundation/gov action to register registry::monitor_cycle_event
        // to be executed for each block
        bytes memory data = abi.encodeCall(BlockMeta.register, (registry, selector, selectorGasLimit));
        submit(blockMetadata, 0, data);

        vm.stopBroadcast();
    }
}

contract AuthorizeAccount is GovSubmitAction {
    address automationRegistry;
    address account;

    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("MULTISIG_WALLET_ADDRESS"));
        automationRegistry = vm.envAddress("REGISTRY");
        account = vm.envAddress("ACCOUNT_TO_AUTHORIZE");
        timeout = uint64(vm.envUint("TIMEOUT"));
    }

    function run() public {
        vm.startBroadcast();

        // Submit a foundation/gov action to grant authorization for gst task registration
        bytes memory data = abi.encodeCall(IConfigFacet.grantAuthorization, (account));
        submit(automationRegistry, 0, data);

        vm.stopBroadcast();
    }
}

contract EnableDisableAutomation is GovSubmitAction {
    address automationRegistry;
    address account;
    bool enable;

    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("MULTISIG_WALLET_ADDRESS"));
        automationRegistry = vm.envAddress("REGISTRY");
        account = vm.envAddress("ACCOUNT_TO_AUTHORIZE");
        timeout = uint64(vm.envUint("TIMEOUT"));
        enable = bool(vm.envBool("ENABLE_AUTOMATION"));
    }

    function run() public {
        vm.startBroadcast();

        console.log("Automation Flag: ", ICoreFacet(automationRegistry).isAutomationEnabled());

        // Submit a foundation/gov action to enable/disable automation
        bytes memory data = hex"";
        if (enable) {
            data = abi.encodeCall(ICoreFacet.enableAutomation, ());
        } else {
            data = abi.encodeCall(ICoreFacet.disableAutomation, ());
        }
        submit(automationRegistry, 0, data);

        vm.stopBroadcast();
    }
}

contract VoteForTxn is Script {
    address payable multisigWalletAddr;
    uint256 txIndex;
    bytes32 contentHash;

    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("MULTISIG_WALLET_ADDRESS"));
        txIndex = uint256(vm.envUint("GOV_TXN_INDEX"));
        contentHash = vm.envBytes32("GOV_TXN_CONTENT_HASH");
    }

    function run() public {
        MultiSignatureWallet wallet = MultiSignatureWallet(multisigWalletAddr);
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
        multisigWalletAddr = payable(vm.envAddress("MULTISIG_WALLET_ADDRESS"));
        txIndex = uint256(vm.envUint("GOV_TXN_INDEX"));
        contentHash = vm.envBytes32("GOV_TXN_CONTENT_HASH");
    }

    function run() public {
        MultiSignatureWallet wallet = MultiSignatureWallet(multisigWalletAddr);

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
