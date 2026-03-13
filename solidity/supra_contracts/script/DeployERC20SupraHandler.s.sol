// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {ERC20SupraHandler} from "../src/ERC20SupraHandler.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployERC20SupraHandler is Script {
    address owner;
    address erc20Supra;

    function setUp() public {
        owner = vm.envAddress("OWNER");
        erc20Supra = vm.envAddress("ERC20SUPRA");
    }

    function run() public {
        vm.startBroadcast();

        // Deploy ERC20SupraHandler implementation
        ERC20SupraHandler impl = new ERC20SupraHandler();
        console.log("ERC20SupraHandler implementation deployed at: ", address(impl));

        // Deploy ERC20SupraHandler proxy
        bytes memory initData = abi.encodeCall(ERC20SupraHandler.initialize, (owner, erc20Supra));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        console.log("ERC20SupraHandler proxy deployed at: ", address(proxy));

        vm.stopBroadcast();
    }
}