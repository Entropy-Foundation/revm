// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WSUPRA} from "../src/WSUPRA.sol";
import {IWSUPRA} from "../src/interfaces/IWSUPRA.sol";

contract WSUPRATest is Test {
    WSUPRA wsupra;

    address deployer = address(0x123);
    address alice = address(0x456);
    address bob   = address(0x789);

    function setUp() public {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 50 ether);

        vm.startPrank(deployer);
        wsupra = new WSUPRA();
        vm.stopPrank();
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testDeployment() public view {
        assertEq(wsupra.name(), "Wrapped Supra");
        assertEq(wsupra.symbol(), "WSUPRA");
        assertEq(wsupra.decimals(), 18);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'deposit' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'deposit' deposits native tokens and mints WSUPRA tokens 1:1.
    function testDeposit() public {
        vm.prank(alice);
        wsupra.deposit{value: 5 ether}();

        assertEq(wsupra.balanceOf(alice), 5 ether);
        assertEq(address(wsupra).balance, 5 ether);
        assertEq(address(wsupra).balance, wsupra.totalSupply());
        assertEq(alice.balance, 95 ether);
    }

    /// @dev Test to ensure 'deposit' emits event.
    function testDepositEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IWSUPRA.Deposit(alice, 5 ether);

        vm.prank(alice);
        wsupra.deposit{value: 5 ether}();
    }

    /// @dev Test to ensure 'deposit' reverts if amount sent is zero.
    function testDepositRevertsIfAmountZero() public {
        vm.expectRevert(IWSUPRA.InvalidAmount.selector);

        vm.prank(alice);
        wsupra.deposit{value: 0}();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'receive' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure sending native tokens directly mints WSUPRA tokens 1:1.
    function testReceiveMintsWsupra() public {
        vm.prank(alice);
        (bool success, ) = address(wsupra).call{value: 3 ether}("");
        require(success);

        assertEq(wsupra.balanceOf(alice), 3 ether);
        assertEq(address(wsupra).balance, 3 ether);
        assertEq(alice.balance, 97 ether);
    }

    /// @dev Test to ensure 'receive' emits event.
    function testReceiveEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IWSUPRA.Deposit(alice, 3 ether);

        vm.prank(alice);
        (bool success, ) = address(wsupra).call{value: 3 ether}("");
        require(success);
    }

    /// @dev Test to ensure 'receive' reverts if amount sent is zero.
    function testReceiveRevertsIfAmountZero() public {
        vm.prank(alice);
        (bool success, bytes memory data) = address(wsupra).call{value: 0}("");

        assertFalse(success);
        assertEq(bytes4(data), IWSUPRA.InvalidAmount.selector);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'withdraw' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'withdraw' withdraws native tokens and burns WSUPRA 1:1.
    function testWithdraw() public {
        // Alice deposits 5 SUPRA → gets 5 * 10 ** 18 WSUPRA tokens
        testDeposit();

        // Alice withdraws 3 SUPRA → burns 3 * 10 ** 18 WSUPRA tokens
        vm.prank(alice);
        wsupra.withdraw(3 ether);

        assertEq(wsupra.balanceOf(alice), 2 ether);
        assertEq(address(alice).balance, 98 ether);
        assertEq(address(wsupra).balance, 2 ether);
        assertEq(address(wsupra).balance, wsupra.totalSupply());
    }

    /// @dev Test to ensure 'withdraw' emits event.
    function testWithdrawEmitsEvent() public {
        vm.prank(alice);
        wsupra.deposit{value: 5 ether}();

        vm.expectEmit(true, true, false, false);
        emit IWSUPRA.Withdrawal(alice, 2 ether);

        vm.prank(alice);
        wsupra.withdraw(2 ether);
    }

    /// @dev Test to ensure 'withdraw' reverts if balance is less than requested amount.
    function testWithdrawRevertsIfInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0 ether, 1 ether));

        vm.prank(alice);
        wsupra.withdraw(1 ether);
    }

    /// @dev Test to ensure 'withdraw' reverts if contract balance is less than requested amount.
    function testWithdrawRevertsIfInsufficientContractBalance() public {
        vm.prank(alice);
        wsupra.deposit{value: 5 ether}();

        // Reduce contract balance by transferring some SUPRA to bob
        vm.prank(address(wsupra));
        (bool success, ) = bob.call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(wsupra).balance, 4 ether);
        
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 4 ether, 5 ether));
        
        vm.prank(alice);
        wsupra.withdraw(5 ether);
    }

    /// @dev Test to ensure 'withdraw' reverts if requested amount is zero.
    function testWithdrawRevertsIfAmountZero() public {
        vm.expectRevert(IWSUPRA.InvalidAmount.selector);

        vm.prank(alice);
        wsupra.withdraw(0);
    }

    /// @notice Test to ensure that `withdraw` reverts if the native token transfer fails.
    /// @dev This test uses a contract that always reverts on receiving native token to simulate a failing low-level call. 
    function testWithdrawRevertsIfNativeTransferFails() public {
        // Mint tokens
        vm.prank(alice);
        wsupra.deposit{value: 1 ether}();

        RejectReceive rejector = new RejectReceive();

        // Transfer tokens to the rejecting contract
        vm.prank(alice);
        bool success = wsupra.transfer(address(rejector), 1 ether);
        assertTrue(success);

        // Attempt withdrawal → should revert
        vm.expectRevert(Errors.FailedCall.selector);

        vm.prank(address(rejector));
        wsupra.withdraw(1 ether);

        assertEq(wsupra.balanceOf(address(rejector)), 1 ether);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Additional test cases for WSUPRA ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure transfer of tokens between users works correctly.
    function testTransferBetweenUsers() public {
        vm.prank(alice);
        wsupra.deposit{value: 5 ether}();
        
        assertEq(wsupra.balanceOf(alice) , 5 ether);

        vm.prank(alice);
        bool success = wsupra.transfer(bob, 2 ether);
        assertTrue(success);

        assertEq(wsupra.balanceOf(alice), 3 ether);
        assertEq(wsupra.balanceOf(bob), 2 ether);
    }

    /// @dev Test to ensure 'transferFrom' works correctly after allowance is granted.
    function testTransferFromAllowance() public {
        vm.prank(alice);
        wsupra.deposit{value: 5 ether}();

        vm.prank(alice);
        wsupra.approve(bob, 3 ether);

        vm.prank(bob);
        bool success = wsupra.transferFrom(alice, bob, 2 ether);
        assertTrue(success);

        assertEq(wsupra.balanceOf(alice), 3 ether);
        assertEq(wsupra.balanceOf(bob), 2 ether);
        assertEq(wsupra.allowance(alice, bob), 1 ether);
    }

    /// @dev Test to ensure 'totalSupply' is equal to the balance of WSUPRA contract. 
    function testTotalSupplyEqualsContractBalance() public {
        vm.prank(alice);
        wsupra.deposit{value: 3 ether}();
        vm.prank(bob);
        wsupra.deposit{value: 2 ether}();

        vm.prank(alice);
        wsupra.withdraw(1 ether);
        vm.prank(bob);
        wsupra.withdraw(2 ether);

        assertEq(address(wsupra).balance, wsupra.totalSupply());
        assertEq(wsupra.totalSupply(), 2 ether);
        assertEq(wsupra.balanceOf(alice), 2 ether);
        assertEq(wsupra.balanceOf(bob), 0);
    }
}

/// @notice Helper contract that rejects all incoming native token transfers.
contract RejectReceive {
    fallback() external payable { revert(); }
    receive() external payable { revert(); }
}
