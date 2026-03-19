// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {MultiSignatureWallet} from "../src/MultiSignatureWallet.sol";
import {MultisigBeacon} from "../src/MultisigBeacon.sol";
import {BeaconProxy} from "../lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";

contract DeployMultisig is Script {
    address[] owners;
    uint256 numConfirmations;
    address beaconOwner;

    function setUp() public {
        owners = vm.envAddress("OWNERS", ",");
        numConfirmations = vm.envUint("NUM_CONFIRMATIONS");
        beaconOwner = vm.envAddress("BEACON_OWNER");
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
        MultisigBeacon beacon = new MultisigBeacon(address(multisigImpl), beaconOwner);
        console.log("Beacon deployed at: ", address(beacon));
        console.log("Beacon owner: ", beacon.owner());

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

        vm.stopBroadcast();
    }
}