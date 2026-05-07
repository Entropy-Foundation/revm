// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {ERC20SupraHandler} from "../src/ERC20SupraHandler.sol";

contract MintErc20Supra is Script {
    uint64 value;
    uint64 allowance;
    address erc20SupraAddr;
    address payable erc20SupraHandlerAddr;
    address authority;

    // Config values loaded from .env file
    function setUp() public {
        value = uint64(vm.envUint("VALUE"));
        allowance = uint64(vm.envUint("ALLOWANCE"));
        erc20SupraAddr = vm.envAddress("ERC20SUPRA");
        erc20SupraHandlerAddr = payable(vm.envAddress("ERC20SUPRA_HANDLER"));
        authority = vm.envAddress("REGISTRY");
    }

    function run() public {
        vm.startBroadcast();

        ERC20Supra erc20Supra = ERC20Supra(erc20SupraAddr);
        ERC20SupraHandler erc20SupraHandler = ERC20SupraHandler(erc20SupraHandlerAddr);
        console.log("Sender: ", msg.sender);
        console.log("Token balance before: ", erc20Supra.balanceOf(msg.sender));

        // First approve the authority to spend tokens
        erc20Supra.approve(authority, uint256(allowance));
        console.log("Approved authority for allowance: ", allowance);

        // Then do the conversion
        erc20SupraHandler.deposit{value: value}();
        uint256 conf_all  = erc20Supra.allowance(msg.sender, authority);

        console.log("Sender: ", msg.sender, conf_all, authority);
        console.log("Token balance after: ", erc20Supra.balanceOf(msg.sender));

        vm.stopBroadcast();
    }

}
