// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";

contract ERC20SupraTest is Test {
    ERC20Supra token;

    address owner = address(0x123);
    address alice = address(0x456);
    address bob   = address(0x789);

    function setUp() public {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 50 ether);
        vm.deal(owner, 10 ether);

        token = new ERC20Supra(owner);
    }

    function testDeployment() public view {
        assertEq(token.owner(), owner);
        assertEq(token.name(), "ERC20Supra");
        assertEq(token.symbol(), "SUPRA");
        assertEq(token.decimals(), 18);
    }

    function testDepositMintsTokens() public {
        vm.prank(alice);
        token.deposit{value: 5 ether}();

        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(address(token).balance, 5 ether);
        assertEq(address(token).balance, token.totalSupply());
        assertEq(alice.balance, 95 ether);
    }

    function testDepositZeroReverts() public {
        vm.expectRevert(ERC20Supra.InvalidAmount.selector);

        vm.prank(alice);
        token.deposit{value: 0}();
    }

    function testReceiveMintsTokens() public {
        vm.prank(alice);
        (bool success, ) = address(token).call{value: 3 ether}("");
        require(success);

        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(address(token).balance, 3 ether);
        assertEq(alice.balance, 97 ether);
    }

    function testReceiveZeroReverts() public {
        vm.expectRevert(ERC20Supra.InvalidAmount.selector);

        vm.prank(alice);
        address(token).call{value: 0}("");
    }

    function testWithdrawBurnsAndSends() public {
        // Alice deposits 5 SUPRA → gets 5 * 10 ** 18 ERC20Supra tokens
        testDepositMintsTokens();

        // Alice withdraws 3 SUPRA → burns 3 * 10 ** 18 ERC20Supra tokens
        vm.prank(alice);
        token.withdraw(3 ether);

        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(address(alice).balance, 98 ether);
        assertEq(address(token).balance, 2 ether);
        assertEq(address(token).balance, token.totalSupply());
    }

    function testWithdrawRevertsIfInsufficientBalance() public {
        vm.expectRevert(ERC20Supra.InsufficientBalance.selector);

        vm.prank(alice);
        token.withdraw(1 ether);
    }

    function testWithdrawRevertsInvalidAmount() public {
        vm.expectRevert(ERC20Supra.InvalidAmount.selector);

        vm.prank(alice);
        token.withdraw(0);
    }

    function testWithdrawRevertsIfNativeTransferFails() public {
        // Mint tokens
        vm.prank(alice);
        token.deposit{value: 1 ether}();

        RejectReceive rejector = new RejectReceive();

        // Transfer tokens to the rejecting contract
        vm.prank(alice);
        token.transfer(address(rejector), 1 ether);

        // Attempt withdrawal → should revert
        vm.expectRevert(ERC20Supra.TransferFailed.selector);

        vm.prank(address(rejector));
        token.withdraw(1 ether);

        assertEq(token.balanceOf(address(rejector)), 1 ether);
    }

    function testCannotTransferToContract() public {
        vm.prank(alice);
        token.deposit{value: 1 ether}();

        vm.expectRevert(ERC20Supra.InvalidTransfer.selector);

        vm.prank(alice);
        token.transfer(address(token), 1 ether);
    }
    
    function testMintToContractReverts() public {
        vm.deal(address(token), 1 ether);

        vm.expectRevert(ERC20Supra.InvalidTransfer.selector);

        vm.prank(address(token));
        token.deposit{value: 1 ether}();
    }

    // Additional test cases for ERC20Supra
    function testTransferBetweenUsers() public {
        vm.prank(alice);
        token.deposit{value: 5 ether}();
        
        assertEq(token.balanceOf(alice) , 5 ether);

        vm.prank(alice);
        token.transfer(bob, 2 ether);

        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.balanceOf(bob), 2 ether);
    }

    function testTransferFromAllowance() public {
        vm.prank(alice);
        token.deposit{value: 5 ether}();

        vm.prank(alice);
        token.approve(bob, 3 ether);

        vm.prank(bob);
        token.transferFrom(alice, bob, 2 ether);

        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.balanceOf(bob), 2 ether);
        assertEq(token.allowance(alice, bob), 1 ether);
    }

    function testBurnFromReducesBalance() public {
        vm.prank(alice);
        token.deposit{value: 5 ether}();

        vm.prank(alice);
        token.approve(bob, 3 ether);

        vm.prank(bob);
        token.burnFrom(alice, 2 ether);

        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.allowance(alice, bob), 1 ether);
        assertEq(token.totalSupply(), 3 ether);
    }

    function testTotalSupplyEqualsContractBalance() public {
        vm.prank(alice);
        token.deposit{value: 3 ether}();
        vm.prank(bob);
        token.deposit{value: 2 ether}();

        vm.prank(alice);
        token.withdraw(1 ether);
        vm.prank(bob);
        token.withdraw(2 ether);

        assertEq(address(token).balance, token.totalSupply());
        assertEq(token.totalSupply(), 2 ether);
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function testDepositEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ERC20Supra.Deposit(alice, 5 ether);

        vm.prank(alice);
        token.deposit{value: 5 ether}();
    }

    function testReceiveEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ERC20Supra.Deposit(alice, 3 ether);

        vm.prank(alice);
        (bool success, ) = address(token).call{value: 3 ether}("");
        require(success);
    }

    function testWithdrawEmitsEvent() public {
        vm.prank(alice);
        token.deposit{value: 5 ether}();

        vm.expectEmit(true, true, false, false);
        emit ERC20Supra.Withdrawal(alice, 2 ether);

        vm.prank(alice);
        token.withdraw(2 ether);
    }
}

contract RejectReceive {
    fallback() external payable { revert(); }
    receive() external payable { revert(); }
}
