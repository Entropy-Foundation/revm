// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {MultiSignatureWallet} from "../src/MultiSignatureWallet.sol";
import {BlockMeta} from "../src/BlockMeta.sol";

contract InitializeCycleMonitoring is Script {
    address payable multisigWalletAddr;
    address blockMetadata;
    address automationController;
    bytes4 selector;
    uint64 timeout;

    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("MULTISIG_WALLET_ADDRESS"));
        blockMetadata = vm.envAddress("BLOCK_METADATA_ADDRESS");
        automationController = vm.envAddress("AUTOMATION_CONTROLLER");
        selector = bytes4(keccak256("monitorCycleEnd()"));
        timeout = uint64(vm.envUint("TIMEOUT"));
    }

    function run() public {
        vm.startBroadcast();

        // Initialize MultiSignatureWallet and get nextTxnIndex
        MultiSignatureWallet wallet = MultiSignatureWallet(multisigWalletAddr);
        uint256 nextTxnIndex = wallet.getNextTransactionIndex();
        console.log("TxnIndex: ", nextTxnIndex);

        // Submit a foundation/gov action to register automationController::monitor_cycle_event
        // to be executed for each block
        bytes memory data = abi.encodeCall(BlockMeta.register, (automationController, selector));
        wallet.submitTransaction(blockMetadata, 0,  timeout, data);

        vm.stopBroadcast();
    }
}

contract VoteForTxn is Script {
    address payable multisigWalletAddr;
    uint256 txn_index;


    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("MULTISIG_WALLET_ADDRESS"));
        txn_index = uint256(vm.envUint("GOV_TXN_INDEX"));
    }

    function run() public {
        vm.startBroadcast();
        MultiSignatureWallet wallet = MultiSignatureWallet(multisigWalletAddr);
        console.log("Txn count", wallet.txCount());
        wallet.confirmTransaction(txn_index);
        vm.stopBroadcast();
    }
}

contract ExecuteTxn is Script {
    address payable multisigWalletAddr;
    uint256 txn_index;


    function setUp() public {
        multisigWalletAddr = payable(vm.envAddress("MULTISIG_WALLET_ADDRESS"));
        txn_index = uint256(vm.envUint("GOV_TXN_INDEX"));
    }

    function run() public {
        vm.startBroadcast();
        MultiSignatureWallet wallet = MultiSignatureWallet(multisigWalletAddr);
        wallet.executeTransaction(txn_index);
        vm.stopBroadcast();
    }
}
