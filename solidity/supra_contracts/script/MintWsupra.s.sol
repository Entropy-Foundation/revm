// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";

contract MintWsupra is Script {
    uint256 value;
    uint256 allowance;
    address wsupraAddr;
    address authority;

    // Config values loaded from .env file
    function setUp() public {
        value = vm.envUint("VALUE");
        allowance = vm.envUint("ALLOWANCE");
        wsupraAddr = vm.envAddress("WSUPRA");
        authority = vm.envAddress("REGISTRY");
    }

    function run() public {
        vm.startBroadcast();

        WrappedSupra wsupra = WrappedSupra(payable(wsupraAddr));
        console.log("Sender: ", msg.sender);
        console.log("Token balance before: ", wsupra.balanceOf(msg.sender));

        // First approve the authority to spend tokens
        wsupra.approve(authority, allowance);
        console.log("Approved authority for allowance: ", allowance);

        // Then do the conversion
        wsupra.deposit{value: value}();
        uint256 confAll  = wsupra.allowance(msg.sender, authority);

        console.log("Sender: ", msg.sender, confAll, authority);
        console.log("Token balance after: ", wsupra.balanceOf(msg.sender));

        vm.stopBroadcast();
    }

}
