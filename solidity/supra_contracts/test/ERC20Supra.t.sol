// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";

contract ERC20SupraTest is Test {
    ERC20Supra token;

    address owner = address(0x123);
    address alice = address(0x456);
    address bob   = address(0x789);
    address bridge = address(0xabc);
    address erc20SupraHandlerAddr;

    function setUp() public {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 50 ether);
        vm.deal(owner, 10 ether);

        erc20SupraHandlerAddr = vm.computeCreateAddress(owner, 3);

        vm.startPrank(owner);
        ERC20Supra impl = new ERC20Supra();
        bytes memory initData = abi.encodeCall(ERC20Supra.initialize, (owner, bridge, erc20SupraHandlerAddr));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = ERC20Supra(address(proxy));
        vm.stopPrank();
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testDeployment() public view {
        assertEq(token.owner(), owner);
        assertEq(token.name(), "ERC20Supra");
        assertEq(token.symbol(), "SUPRA");
        assertEq(token.decimals(), 18);

        assertEq(token.bridge(), bridge);
        assertEq(token.erc20SupraHandler(), erc20SupraHandlerAddr);
    }
    
    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'mint' :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'mint' works correctly when called by the bridge.
    function testMintByBridge() public {
        vm.prank(bridge);
        token.mint(alice, 100);

        assertEq(token.balanceOf(alice), 100);
    }

    /// @dev Test to ensure 'mint' works correctly when called by the ERC20SupraHandler.
    function testMintByHandler() public {
        vm.prank(erc20SupraHandlerAddr);
        token.mint(alice, 200);

        assertEq(token.balanceOf(alice), 200);
    }

    /// @dev Test to ensure 'mint' reverts if called by an unauthorized caller.
    function testMintRevertsIfUnauthorizedCaller() public {
        vm.expectRevert(ERC20Supra.UnauthorizedCaller.selector);

        vm.prank(alice);
        token.mint(alice, 100);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'burn' :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'burn' works correctly when called by the bridge.
    function testBurnByBridge() public {
        vm.prank(bridge);
        token.mint(alice, 100);
        assertEq(token.balanceOf(alice), 100);

        vm.prank(bridge);
        token.burn(alice, 50);

        assertEq(token.balanceOf(alice), 50);
    }

    /// @dev Test to ensure 'burn' works correctly when called by the ERC20SupraHandler.
    function testBurnByHandler() public {
        vm.prank(bridge);
        token.mint(alice, 100);
        assertEq(token.balanceOf(alice), 100);

        vm.prank(erc20SupraHandlerAddr);
        token.burn(alice, 30);

        assertEq(token.balanceOf(alice), 70);
    }

    /// @dev Test to ensure 'burn' reverts if called by an unauthorized caller.
    function testBurnRevertsIfUnauthorizedCaller() public {
        vm.expectRevert(ERC20Supra.UnauthorizedCaller.selector);

        vm.prank(alice);
        token.burn(alice, 10);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'approveFor' ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'approveFor' works correctly when called by the ERC20SupraHandler.
    function testApproveForByHandler() public {
        vm.prank(erc20SupraHandlerAddr);
        token.approveFor(alice, bob, 50);

        assertEq(token.allowance(alice, bob), 50);
    }

    /// @dev Test to ensure 'approveFor' reverts if called by an unauthorized caller.
    function testApproveForRevertsIfUnauthorizedCaller() public {
        vm.expectRevert(ERC20Supra.UnauthorizedCaller.selector);

        vm.prank(alice);
        token.approveFor(alice, bob, 50);
    }
}