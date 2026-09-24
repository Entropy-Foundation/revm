// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";

contract DeployWrappedSupra is Script {
    function run() public {
        vm.startBroadcast();

        // Deploy WrappedSupra
        WrappedSupra wsupra = new WrappedSupra();
        console.log("WrappedSupra deployed at: ", address(wsupra));

        vm.stopBroadcast();
    }
}
