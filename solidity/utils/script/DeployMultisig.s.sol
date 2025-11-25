// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MultiSignatureWallet} from "../src/MultiSignatureWallet.sol";
import {MultisigBeacon} from "../src/MultisigBeacon.sol";
import {BeaconProxy} from "../lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";

contract DeployMultisig is Script {
    address[] owners;
    uint256 numConfirmations;

    function setUp() public {
        owners = vm.envAddress("OWNERS", ",");
        numConfirmations = vm.envUint("NUM_CONFIRMATIONS");
    }

    function run() public {
        vm.startBroadcast();

        // ---------------------------------
        // Deploy multisig implementation
        // ---------------------------------
        MultiSignatureWallet multisigImpl = new MultiSignatureWallet();
        console.log("Multisig implementation deployed at: ", address(multisigImpl));

        // -------------------------------------------
        // Deploy beacon pointing to implementation
        // -------------------------------------------
        MultisigBeacon beacon = new MultisigBeacon(address(multisigImpl));
        console.log("Beacon deployed at: ", address(beacon));

        // ----------------------
        // Deploy multisig proxy
        // ----------------------
        console.log("Number of confirmations: ", numConfirmations);
        console.log("Adding following owners: ");
        for (uint i = 0; i < owners.length; i++) {
            console.logAddress(owners[i]);
        }

        bytes memory initData = abi.encodeCall(MultiSignatureWallet.initialize, (owners, numConfirmations));
        BeaconProxy multisigProxy = new BeaconProxy(address(beacon), initData);
        console.log("Multisig Proxy deployed at: ", address(multisigProxy));

        // ------------------------------------------
        // Transfer beacon's ownership to multisig
        // ------------------------------------------
        beacon.transferOwnership(address(multisigProxy));
        console.log("Beacon ownership transferred to multisig proxy at: ", address(multisigProxy));

        vm.stopBroadcast();
    }
}