// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployERC20Supra is Script {
    address owner;
    address bridge;
    address erc20SupraHandler;

    function setUp() public {
        owner = vm.envAddress("OWNER");
        bridge = vm.envAddress("BRIDGE");
        erc20SupraHandler = vm.envAddress("ERC20SUPRA_HANDLER");
    }

    function run() public {
        vm.startBroadcast();

        // Deploy ERC20Supra implementation
        ERC20Supra impl = new ERC20Supra();
        console.log("ERC20Supra implementation deployed at: ", address(impl));

        // Deploy ERC20Supra proxy
        bytes memory initData = abi.encodeCall(ERC20Supra.initialize, (owner, bridge, erc20SupraHandler));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        console.log("ERC20Supra proxy deployed at: ", address(proxy));

        vm.stopBroadcast();
    }
}