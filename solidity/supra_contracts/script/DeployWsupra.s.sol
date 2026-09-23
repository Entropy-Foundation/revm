// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {WSUPRA} from "../src/WSUPRA.sol";

contract DeployWsupra is Script {
    function run() public {
        vm.startBroadcast();

        // Deploy WSUPRA
        WSUPRA wsupra = new WSUPRA();
        console.log("WSUPRA deployed at: ", address(wsupra));

        vm.stopBroadcast();
    }
}