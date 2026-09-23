// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {WSUPRA} from "../src/WSUPRA.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployWsupra is Script {
    address owner;

    function setUp() public {
        owner = vm.envAddress("OWNER");
    }

    function run() public {
        vm.startBroadcast();

        // Deploy WSUPRA implementation
        WSUPRA impl = new WSUPRA();
        console.log("WSUPRA implementation deployed at: ", address(impl));

        // Deploy WSUPRA proxy
        bytes memory initData = abi.encodeCall(WSUPRA.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        console.log("WSUPRA proxy deployed at: ", address(proxy));

        vm.stopBroadcast();
    }
}