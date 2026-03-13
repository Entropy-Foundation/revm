// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {ERC20SupraHandler} from "../src/ERC20SupraHandler.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";

contract ERC20SupraHandlerTest is Test {
    ERC20Supra token;
    ERC20SupraHandler erc20SupraHandler;

    address owner = address(0x123);
    address alice = address(0x456);
    address bob   = address(0x789);
    address bridge = address(0xabc);

    function setUp() public {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 50 ether);
        vm.deal(owner, 10 ether);

        address erc20SupraHandlerAddr = vm.computeCreateAddress(owner, 3);

        vm.startPrank(owner);
        ERC20Supra erc20SupraImpl = new ERC20Supra();
        bytes memory erc20SupraInitData = abi.encodeCall(ERC20Supra.initialize, (owner, bridge, erc20SupraHandlerAddr));
        ERC1967Proxy erc20SupraProxy = new ERC1967Proxy(address(erc20SupraImpl), erc20SupraInitData);
        token = ERC20Supra(address(erc20SupraProxy));

        ERC20SupraHandler handlerImpl = new ERC20SupraHandler();
        bytes memory handlerInitData = abi.encodeCall(ERC20SupraHandler.initialize, (owner, address(token)));
        ERC1967Proxy handlerProxy = new ERC1967Proxy(address(handlerImpl), handlerInitData);
        erc20SupraHandler = ERC20SupraHandler(payable(address(handlerProxy)));
        vm.stopPrank();
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testDeployment() public view {
        assertEq(erc20SupraHandler.owner(), owner);
        assertEq(erc20SupraHandler.erc20Supra(), address(token));
    }
    
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'nativeToErc20Supra' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'nativeToErc20Supra' deposits native tokens and mints ERC20Supra tokens 1:1.
    function testNativeToErc20Supra() public {
        vm.prank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 5 ether}();

        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(address(erc20SupraHandler).balance, 5 ether);
        assertEq(address(erc20SupraHandler).balance, token.totalSupply());
        assertEq(alice.balance, 95 ether);
    }

    /// @dev Test to ensure 'nativeToErc20Supra' emits event.
    function testNativeToErc20SupraEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ERC20SupraHandler.NativeToERC20Supra(alice, 5 ether);

        vm.prank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 5 ether}();
    }

    /// @dev Test to ensure 'nativeToErc20Supra' reverts if amount sent is zero.
    function testNativeToErc20SupraRevertsIfAmountZero() public {
        vm.expectRevert(ERC20SupraHandler.InvalidAmount.selector);

        vm.prank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 0}();
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'nativeToErc20SupraWithAllowance' :::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'nativeToErc20SupraWithAllowance' deposits native tokens, mint ERC20Supra 1:1 and sets the allowance.
    function testNativeToErc20SupraWithAllowance() public {
        vm.prank(alice);
        token.approve(bob, 2 ether);

        assertEq(token.allowance(alice, bob), 2 ether);
        
        
        vm.prank(alice);
        erc20SupraHandler.nativeToErc20SupraWithAllowance{value: 5 ether}(bob, 5 ether);

        assertEq(alice.balance, 95 ether);
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.allowance(alice, bob), 5 ether);
        assertEq(address(erc20SupraHandler).balance, 5 ether);
        assertEq(token.totalSupply(), 5 ether);
    }

    /// @dev Test to ensure 'nativeToErc20SupraWithAllowance' emits event.
    function testNativeToErc20SupraWithAllowanceEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ERC20SupraHandler.NativeToERC20SupraWithAllowance(alice, 2 ether, bob, 2 ether);

        vm.prank(alice);
        erc20SupraHandler.nativeToErc20SupraWithAllowance{value: 2 ether}(bob, 2 ether);
    }

    /// @dev Test to ensure 'nativeToErc20SupraWithAllowance' reverts if amount sent is zero.
    function testNativeToErc20SupraWithAllowanceRevertsIfAmountZero() public {
        vm.expectRevert(ERC20SupraHandler.InvalidAmount.selector);

        vm.prank(alice);
        erc20SupraHandler.nativeToErc20SupraWithAllowance{value: 0}(bob, 2 ether);
    }

    /// @dev Test to ensure 'nativeToErc20SupraWithAllowance' reverts if spender address is zero.
    function testNativeToErc20SupraWithAllowanceRevertsIfSpenderZero() public {
        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);

        vm.prank(alice);
        erc20SupraHandler.nativeToErc20SupraWithAllowance{value: 1 ether}(address(0), 1 ether);
    }

    /// @dev Test to ensure 'nativeToErc20SupraWithAllowance' reverts if allowance amount is zero.
    function testNativeToErc20SupraWithAllowanceRevertsIfAllowanceAmountZero() public {
        vm.expectRevert(ERC20SupraHandler.InvalidAllowance.selector);

        vm.prank(alice);
        erc20SupraHandler.nativeToErc20SupraWithAllowance{value: 2 ether}(bob, 0);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'receive' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure sending native tokens direcly mints ERC20Supra tokens 1:1.
    function testReceiveMintsERC20Supra() public {
        vm.prank(alice);
        (bool success, ) = address(erc20SupraHandler).call{value: 3 ether}("");
        require(success);

        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(address(erc20SupraHandler).balance, 3 ether);
        assertEq(alice.balance, 97 ether);
    }

    /// @dev Test to ensure 'receive' emits event.
    function testReceiveEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ERC20SupraHandler.NativeToERC20Supra(alice, 3 ether);

        vm.prank(alice);
        (bool success, ) = address(erc20SupraHandler).call{value: 3 ether}("");
        require(success);
    }

    /// @dev Test to ensure 'receive' reverts if amount sent is zero.
    function testReceiveRevertsIfAmountZero() public {
        vm.expectRevert(ERC20SupraHandler.InvalidAmount.selector);

        vm.prank(alice);
        address(token).call{value: 0}("");
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'erc20SupraToNative' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'erc20SupraToNative' withdraws native tokens and burns ERC20Supra 1:1.
    function testErc20SupraToNative() public {
        // Alice deposits 5 SUPRA → gets 5 * 10 ** 18 ERC20Supra tokens
        testNativeToErc20Supra();

        // Alice withdraws 3 SUPRA → burns 3 * 10 ** 18 ERC20Supra tokens
        vm.prank(alice);
        erc20SupraHandler.erc20SupraToNative(3 ether);

        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(address(alice).balance, 98 ether);
        assertEq(address(erc20SupraHandler).balance, 2 ether);
        assertEq(address(erc20SupraHandler).balance, token.totalSupply());
    }

    /// @dev Test to ensure 'erc20SupraToNative' emits event.
    function testErc20SupraToNativeEmitsEvent() public {
        vm.prank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 5 ether}();

        vm.expectEmit(true, true, false, false);
        emit ERC20SupraHandler.ERC20SupraToNative(alice, 2 ether);

        vm.prank(alice);
        erc20SupraHandler.erc20SupraToNative(2 ether);
    }

    /// @dev Test to ensure 'erc20SupraToNative' reverts if balance is less than requested amount.
    function testErc20SupraToNativeRevertsIfInsufficientBalance() public {
        vm.expectRevert(ERC20SupraHandler.InsufficientBalance.selector);

        vm.prank(alice);
        erc20SupraHandler.erc20SupraToNative(1 ether);
    }

    /// @dev Test to ensure 'erc20SupraToNative' reverts if requested amount is zero.
    function testErc20SupraToNativeRevertsIfAmountZero() public {
        vm.expectRevert(ERC20SupraHandler.InvalidAmount.selector);

        vm.prank(alice);
        erc20SupraHandler.erc20SupraToNative(0);
    }

    /// @notice Test to ensure that `erc20SupraToNative` reverts if the native token transfer fails.
    /// @dev This test uses a contract that always reverts on receiving native token to simulate a failing low-level call. 
    function testErc20SupraToNativeRevertsIfNativeTransferFails() public {
        // Mint tokens
        vm.prank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 1 ether}();

        RejectReceive rejector = new RejectReceive();

        // Transfer tokens to the rejecting contract
        vm.prank(alice);
        token.transfer(address(rejector), 1 ether);

        // Attempt withdrawal → should revert
        vm.expectRevert(ERC20SupraHandler.TransferFailed.selector);

        vm.prank(address(rejector));
        erc20SupraHandler.erc20SupraToNative(1 ether);

        assertEq(token.balanceOf(address(rejector)), 1 ether);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Additional test cases for ERC20Supra ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure transfer of tokens between users works correctly.
    function testTransferBetweenUsers() public {
        vm.prank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 5 ether}();
        
        assertEq(token.balanceOf(alice) , 5 ether);

        vm.prank(alice);
        token.transfer(bob, 2 ether);

        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.balanceOf(bob), 2 ether);
    }

    /// @dev Test to ensure 'transferFrom' works correctly after allowance is granted.
    function testTransferFromAllowance() public {
        vm.prank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 5 ether}();

        vm.prank(alice);
        token.approve(bob, 3 ether);

        vm.prank(bob);
        token.transferFrom(alice, bob, 2 ether);

        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.balanceOf(bob), 2 ether);
        assertEq(token.allowance(alice, bob), 1 ether);
    }

    /// @dev Test to ensure 'totalSupply' is equal to the balance of ERC20Supra contract. 
    function testTotalSupplyEqualsContractBalance() public {
        vm.prank(alice);
        erc20SupraHandler.nativeToErc20Supra{value: 3 ether}();
        vm.prank(bob);
        erc20SupraHandler.nativeToErc20Supra{value: 2 ether}();

        vm.prank(alice);
        erc20SupraHandler.erc20SupraToNative(1 ether);
        vm.prank(bob);
        erc20SupraHandler.erc20SupraToNative(2 ether);

        assertEq(address(erc20SupraHandler).balance, token.totalSupply());
        assertEq(token.totalSupply(), 2 ether);
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.balanceOf(bob), 0);
    }
}

/// @notice Helper contract that rejects all incoming native token transfers.
contract RejectReceive {
    fallback() external payable { revert(); }
    receive() external payable { revert(); }
}
