// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";

contract MintErc20Supra is Script {
    uint64 value;
    uint64 allowance;
    address payable erc20supra;
    address authority;

    // Config values loaded from .env file
    function setUp() public {
        value = uint64(vm.envUint("VALUE"));
        allowance = uint64(vm.envUint("ALLOWANCE"));
        erc20supra = payable(vm.envAddress("ERC20SUPRA"));
        authority = vm.envAddress("AUTOMATION_CORE");
    }

    function run() public {
        vm.startBroadcast();

        ERC20Supra erc20supraImpl = ERC20Supra(erc20supra);
        console.log("Sender ", msg.sender);
        console.log("Token balance ", erc20supraImpl.balanceOf(msg.sender));

        //erc20supraImpl.nativeToErc20SupraWithAllowance{value: value}(authority, uint256(allowance));

        console.log("Sender ", msg.sender);
        console.log("Token balance ", erc20supraImpl.balanceOf(msg.sender));

        vm.stopBroadcast();
    }

}
