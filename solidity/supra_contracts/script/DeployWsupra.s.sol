// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployWsupra is Script {
    address owner;

    function setUp() public {
        owner = vm.envAddress("OWNER");
    }

    function run() public {
        vm.startBroadcast();

        // Deploy WrappedSupra implementation
        WrappedSupra impl = new WrappedSupra();
        console.log("WrappedSupra implementation deployed at: ", address(impl));

        // Deploy WrappedSupra proxy
        bytes memory initData = abi.encodeCall(WrappedSupra.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        console.log("WrappedSupra proxy deployed at: ", address(proxy));

        vm.stopBroadcast();
    }
}