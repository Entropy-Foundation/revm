// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";

contract DeployERC20Supra is Script {
    address owner;

    function setUp() public {
        owner = vm.envAddress("OWNER");
    }

    function run() public {
        vm.startBroadcast();

        // Deploy ERC20Supra 
        ERC20Supra erc20Supra = new ERC20Supra(owner);
        console.log("ERC20Supra deployed at: ", address(erc20Supra));

        vm.stopBroadcast();
    }
}