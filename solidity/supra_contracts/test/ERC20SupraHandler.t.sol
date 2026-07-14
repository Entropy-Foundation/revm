// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {ERC20SupraHandler} from "../src/ERC20SupraHandler.sol";
import {IERC20SupraHandler} from "../src/interfaces/IERC20SupraHandler.sol";

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
        address[] memory authorizedAddresses = new address[](2);
        authorizedAddresses[0] = bridge;
        authorizedAddresses[1] = erc20SupraHandlerAddr;

        vm.startPrank(owner);
        ERC20Supra erc20SupraImpl = new ERC20Supra();
        bytes memory erc20SupraInitData = abi.encodeCall(ERC20Supra.initialize, (owner, authorizedAddresses));
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
    
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'deposit' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'deposit' deposits native tokens and mints ERC20Supra tokens 1:1.
    function testDeposit() public {
        vm.prank(alice);
        erc20SupraHandler.deposit{value: 5 ether}();

        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(address(erc20SupraHandler).balance, 5 ether);
        assertEq(address(erc20SupraHandler).balance, token.totalSupply());
        assertEq(alice.balance, 95 ether);
    }

    /// @dev Test to ensure 'deposit' emits event.
    function testDepositEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IERC20SupraHandler.Deposit(alice, 5 ether);

        vm.prank(alice);
        erc20SupraHandler.deposit{value: 5 ether}();
    }

    /// @dev Test to ensure 'deposit' reverts if amount sent is zero.
    function testDepositRevertsIfAmountZero() public {
        vm.expectRevert(IERC20SupraHandler.InvalidAmount.selector);

        vm.prank(alice);
        erc20SupraHandler.deposit{value: 0}();
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
        emit IERC20SupraHandler.Deposit(alice, 3 ether);

        vm.prank(alice);
        (bool success, ) = address(erc20SupraHandler).call{value: 3 ether}("");
        require(success);
    }

    /// @dev Test to ensure 'receive' reverts if amount sent is zero.
    function testReceiveRevertsIfAmountZero() public {
        vm.prank(alice);
        (bool success, bytes memory data) = address(erc20SupraHandler).call{value: 0}("");

        assertFalse(success);
        assertEq(bytes4(data), IERC20SupraHandler.InvalidAmount.selector);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'withdraw' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'withdraw' withdraws native tokens and burns ERC20Supra 1:1.
    function testWithdraw() public {
        // Alice deposits 5 SUPRA → gets 5 * 10 ** 18 ERC20Supra tokens
        testDeposit();

        // Alice withdraws 3 SUPRA → burns 3 * 10 ** 18 ERC20Supra tokens
        vm.prank(alice);
        erc20SupraHandler.withdraw(3 ether);

        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(address(alice).balance, 98 ether);
        assertEq(address(erc20SupraHandler).balance, 2 ether);
        assertEq(address(erc20SupraHandler).balance, token.totalSupply());
    }

    /// @dev Test to ensure 'withdraw' emits event.
    function testWithdrawEmitsEvent() public {
        vm.prank(alice);
        erc20SupraHandler.deposit{value: 5 ether}();

        vm.expectEmit(true, true, false, false);
        emit IERC20SupraHandler.Withdrawal(alice, 2 ether);

        vm.prank(alice);
        erc20SupraHandler.withdraw(2 ether);
    }

    /// @dev Test to ensure 'withdraw' reverts if balance is less than requested amount.
    function testWithdrawRevertsIfInsufficientBalance() public {
        vm.expectRevert(IERC20SupraHandler.InsufficientBalance.selector);

        vm.prank(alice);
        erc20SupraHandler.withdraw(1 ether);
    }

    /// @dev Test to ensure 'withdraw' reverts if contract balance is less than requested amount.
    function testWithdrawRevertsIfInsufficientContractBalance() public {
        vm.prank(bridge);
        token.mint(alice, 1 ether);

        vm.expectRevert(IERC20SupraHandler.InsufficientContractBalance.selector);
        
        vm.prank(alice);
        erc20SupraHandler.withdraw(1 ether);
    }

    /// @dev Test to ensure 'withdraw' reverts if requested amount is zero.
    function testWithdrawRevertsIfAmountZero() public {
        vm.expectRevert(IERC20SupraHandler.InvalidAmount.selector);

        vm.prank(alice);
        erc20SupraHandler.withdraw(0);
    }

    /// @notice Test to ensure that `withdraw` reverts if the native token transfer fails.
    /// @dev This test uses a contract that always reverts on receiving native token to simulate a failing low-level call. 
    function testWithdrawRevertsIfNativeTransferFails() public {
        // Mint tokens
        vm.prank(alice);
        erc20SupraHandler.deposit{value: 1 ether}();

        RejectReceive rejector = new RejectReceive();

        // Transfer tokens to the rejecting contract
        vm.prank(alice);
        bool success = token.transfer(address(rejector), 1 ether);
        assertTrue(success);

        // Attempt withdrawal → should revert
        vm.expectRevert(IERC20SupraHandler.TransferFailed.selector);

        vm.prank(address(rejector));
        erc20SupraHandler.withdraw(1 ether);

        assertEq(token.balanceOf(address(rejector)), 1 ether);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Additional test cases for ERC20Supra ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure transfer of tokens between users works correctly.
    function testTransferBetweenUsers() public {
        vm.prank(alice);
        erc20SupraHandler.deposit{value: 5 ether}();
        
        assertEq(token.balanceOf(alice) , 5 ether);

        vm.prank(alice);
        bool success = token.transfer(bob, 2 ether);
        assertTrue(success);

        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.balanceOf(bob), 2 ether);
    }

    /// @dev Test to ensure 'transferFrom' works correctly after allowance is granted.
    function testTransferFromAllowance() public {
        vm.prank(alice);
        erc20SupraHandler.deposit{value: 5 ether}();

        vm.prank(alice);
        token.approve(bob, 3 ether);

        vm.prank(bob);
        bool success = token.transferFrom(alice, bob, 2 ether);
        assertTrue(success);

        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.balanceOf(bob), 2 ether);
        assertEq(token.allowance(alice, bob), 1 ether);
    }

    /// @dev Test to ensure 'totalSupply' is equal to the balance of ERC20Supra contract. 
    function testTotalSupplyEqualsContractBalance() public {
        vm.prank(alice);
        erc20SupraHandler.deposit{value: 3 ether}();
        vm.prank(bob);
        erc20SupraHandler.deposit{value: 2 ether}();

        vm.prank(alice);
        erc20SupraHandler.withdraw(1 ether);
        vm.prank(bob);
        erc20SupraHandler.withdraw(2 ether);

        assertEq(address(erc20SupraHandler).balance, token.totalSupply());
        assertEq(token.totalSupply(), 2 ether);
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'upgradeToAndCall' :::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'upgradeToAndCall' upgrades the proxy to a new implementation.
    function testUpgradeToAndCall() public {
        vm.prank(alice);
        erc20SupraHandler.deposit{value: 1 ether}();
        assertEq(token.balanceOf(alice), 1 ether);

        vm.startPrank(owner);
        ERC20SupraHandler newImpl = new ERC20SupraHandler();
        erc20SupraHandler.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();

        assertEq(address(uint160(uint256(vm.load(address(erc20SupraHandler), ERC1967Utils.IMPLEMENTATION_SLOT)))), address(newImpl));

        vm.prank(alice);
        erc20SupraHandler.deposit{value: 1 ether}();
        assertEq(token.balanceOf(alice), 2 ether);
    }

    /// @dev Test to ensure 'upgradeToAndCall' reverts if caller is not the owner.
    function testUpgradeToAndCallRevertsIfNotOwner() public {
        vm.prank(owner);
        ERC20SupraHandler newImpl = new ERC20SupraHandler();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        erc20SupraHandler.upgradeToAndCall(address(newImpl), "");
    }
}

/// @notice Helper contract that rejects all incoming native token transfers.
contract RejectReceive {
    fallback() external payable { revert(); }
    receive() external payable { revert(); }
}
