// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";
import {IWrappedSupra} from "../src/interfaces/IWrappedSupra.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";

contract WrappedSupraTest is Test {
    WrappedSupra wsupra;

    address deployer = address(0x123);
    address alice = address(0x456);
    address bob   = address(0x789);

    function setUp() public {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 50 ether);

        vm.startPrank(deployer);
        WrappedSupra impl = new WrappedSupra();
        bytes memory initData = abi.encodeCall(WrappedSupra.initialize, (deployer));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        wsupra = WrappedSupra(payable(address(proxy)));
        vm.stopPrank();
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testDeployment() public view {
        assertEq(wsupra.owner(), deployer);
        assertEq(wsupra.name(), "Wrapped Supra");
        assertEq(wsupra.symbol(), "WSUPRA");
        assertEq(wsupra.decimals(), 18);
    }

    /// @dev Test to ensure initialization reverts with invalid owner address.
    function testInitializeRevertsWithInvalidOwner() public {
        vm.startPrank(deployer);
        WrappedSupra impl = new WrappedSupra();
        bytes memory initData = abi.encodeCall(WrappedSupra.initialize, (address(0)));

        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(impl), initData);
        vm.stopPrank();
    }

    /// @dev Test to ensure 'initialize' cannot be called a second time on the proxy.
    function testCannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wsupra.initialize(alice);
    }

    /// @dev Test to ensure the implementation contract itself can never be initialized
    /// directly, since its constructor disables initializers on deployment.
    function testImplementationCannotBeInitializedDirectly() public {
        WrappedSupra impl = new WrappedSupra();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(alice);
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
        emit IWrappedSupra.Deposit(alice, 5 ether);

        vm.prank(alice);
        wsupra.deposit{value: 5 ether}();
    }

    /// @dev Test to ensure 'deposit' reverts if amount sent is zero.
    function testDepositRevertsIfAmountZero() public {
        vm.expectRevert(IWrappedSupra.InvalidAmount.selector);

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
        emit IWrappedSupra.Deposit(alice, 3 ether);

        vm.prank(alice);
        (bool success, ) = address(wsupra).call{value: 3 ether}("");
        require(success);
    }

    /// @dev Test to ensure 'receive' reverts if amount sent is zero.
    function testReceiveRevertsIfAmountZero() public {
        vm.prank(alice);
        (bool success, bytes memory data) = address(wsupra).call{value: 0}("");

        assertFalse(success);
        assertEq(bytes4(data), IWrappedSupra.InvalidAmount.selector);
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
        emit IWrappedSupra.Withdrawal(alice, 2 ether);

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
        vm.expectRevert(IWrappedSupra.InvalidAmount.selector);

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

    /// @notice Test to ensure 'withdraw' cannot be reentered to double-spend the same balance.
    /// @dev The token balance is burned before the native transfer (checks-effects-interactions),
    /// so a reentrant 'withdraw' call sees a zero balance and reverts with
    /// 'ERC20InsufficientBalance', which bubbles up and fails the whole outer transaction.
    function testWithdrawReentrancyCannotDoubleSpend() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(wsupra);

        vm.deal(address(attacker), 1 ether);
        vm.prank(address(attacker));
        wsupra.deposit{value: 1 ether}();
        assertEq(wsupra.balanceOf(address(attacker)), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(attacker), 0, 1 ether)
        );
        attacker.attack(1 ether);

        // State is unchanged since the whole transaction reverted.
        assertEq(wsupra.balanceOf(address(attacker)), 1 ether);
        assertEq(address(wsupra).balance, 1 ether);
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

    /// @dev Test to ensure 'transfer' reverts when sent to the zero address.
    function testTransferRevertsToZeroAddress() public {
        vm.prank(alice);
        wsupra.deposit{value: 1 ether}();

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        wsupra.transfer(address(0), 1 ether);
    }

    /// @dev Test to ensure 'transferFrom' reverts if the allowance is insufficient.
    function testTransferFromRevertsIfInsufficientAllowance() public {
        vm.prank(alice);
        wsupra.deposit{value: 1 ether}();

        vm.prank(alice);
        wsupra.approve(bob, 0.5 ether);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0.5 ether, 1 ether));
        vm.prank(bob);
        wsupra.transferFrom(alice, bob, 1 ether);
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

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'upgradeToAndCall' :::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'upgradeToAndCall' upgrades the proxy to a new implementation while preserving state.
    function testUpgradeToAndCall() public {
        vm.prank(alice);
        wsupra.deposit{value: 5 ether}();
        assertEq(wsupra.balanceOf(alice), 5 ether);

        vm.prank(deployer);
        WrappedSupra newImpl = new WrappedSupra();

        vm.prank(deployer);
        wsupra.upgradeToAndCall(address(newImpl), "");

        assertEq(address(uint160(uint256(vm.load(address(wsupra), ERC1967Utils.IMPLEMENTATION_SLOT)))), address(newImpl));

        // Existing balance and behavior are preserved after the upgrade.
        assertEq(wsupra.balanceOf(alice), 5 ether);

        vm.prank(alice);
        wsupra.deposit{value: 2 ether}();
        assertEq(wsupra.balanceOf(alice), 7 ether);
    }

    /// @dev Test to ensure 'upgradeToAndCall' reverts if caller is not the owner.
    function testUpgradeToAndCallRevertsIfNotOwner() public {
        vm.prank(deployer);
        WrappedSupra newImpl = new WrappedSupra();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        wsupra.upgradeToAndCall(address(newImpl), "");
    }

    /// @dev Test to ensure 'upgradeToAndCall' reverts when the new implementation doesn't
    /// implement the UUPS 'proxiableUUID' contract, since ERC1967Utils can't safely verify it.
    function testUpgradeRevertsIfNewImplementationNotUUPS() public {
        NotUUPSCompliant badImpl = new NotUUPSCompliant();

        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(badImpl)));
        vm.prank(deployer);
        wsupra.upgradeToAndCall(address(badImpl), "");
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to ownership :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'transferOwnership' moves upgrade authority to the new owner.
    function testTransferOwnership() public {
        vm.prank(deployer);
        wsupra.transferOwnership(alice);
        assertEq(wsupra.owner(), alice);

        WrappedSupra newImpl = new WrappedSupra();

        // The former owner can no longer upgrade.
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, deployer));
        vm.prank(deployer);
        wsupra.upgradeToAndCall(address(newImpl), "");

        // The new owner can.
        vm.prank(alice);
        wsupra.upgradeToAndCall(address(newImpl), "");
        assertEq(address(uint160(uint256(vm.load(address(wsupra), ERC1967Utils.IMPLEMENTATION_SLOT)))), address(newImpl));
    }

    /// @notice Test to ensure 'renounceOwnership' permanently blocks future upgrades.
    /// @dev This is an irreversible foot-gun specific to an upgradeable contract: once
    /// ownership is renounced, 'upgradeToAndCall' can never be called by anyone again.
    function testRenounceOwnershipBlocksFutureUpgrades() public {
        vm.prank(deployer);
        wsupra.renounceOwnership();
        assertEq(wsupra.owner(), address(0));

        WrappedSupra newImpl = new WrappedSupra();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, deployer));
        vm.prank(deployer);
        wsupra.upgradeToAndCall(address(newImpl), "");
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'permit' :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    uint256 constant PERMIT_SIGNER_KEY = 0xA11CE5;
    address permitSigner = vm.addr(PERMIT_SIGNER_KEY);

    /// @dev Signs an EIP-2612 permit for `permitSigner` using the given key over the current domain separator.
    function _signPermit(uint256 signerKey, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                permitSigner,
                spender,
                value,
                wsupra.nonces(permitSigner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", wsupra.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(signerKey, digest);
    }

    /// @dev Test to ensure 'permit' approves a spender via signature, usable immediately with 'transferFrom'.
    function testPermitApprovesSpenderViaSignature() public {
        vm.deal(permitSigner, 5 ether);
        vm.prank(permitSigner);
        wsupra.deposit{value: 5 ether}();

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_SIGNER_KEY, bob, 3 ether, deadline);

        wsupra.permit(permitSigner, bob, 3 ether, deadline, v, r, s);
        assertEq(wsupra.allowance(permitSigner, bob), 3 ether);
        assertEq(wsupra.nonces(permitSigner), 1);

        vm.prank(bob);
        wsupra.transferFrom(permitSigner, bob, 3 ether);
        assertEq(wsupra.balanceOf(bob), 3 ether);
    }

    /// @dev Test to ensure 'permit' reverts once its deadline has passed.
    function testPermitRevertsIfDeadlineExpired() public {
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_SIGNER_KEY, bob, 1 ether, deadline);

        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        wsupra.permit(permitSigner, bob, 1 ether, deadline, v, r, s);
    }

    /// @dev Test to ensure 'permit' reverts if the signature was not produced by the claimed owner.
    function testPermitRevertsIfSignerMismatched() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 wrongKey = 0xBADD1e;
        address wrongSigner = vm.addr(wrongKey);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                permitSigner,
                bob,
                1 ether,
                wsupra.nonces(permitSigner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", wsupra.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, wrongSigner, permitSigner));
        wsupra.permit(permitSigner, bob, 1 ether, deadline, v, r, s);
    }
}

/// @notice Helper contract that rejects all incoming native token transfers.
contract RejectReceive {
    fallback() external payable { revert(); }
    receive() external payable { revert(); }
}

/// @notice Helper contract that attempts to reenter 'withdraw' from within its 'receive' hook.
contract ReentrantWithdrawer {
    WrappedSupra public wsupra;
    uint256 public reentryAmount;
    bool public reentered;

    constructor(WrappedSupra _wsupra) {
        wsupra = _wsupra;
    }

    function attack(uint256 amount) external {
        reentryAmount = amount;
        wsupra.withdraw(amount);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            wsupra.withdraw(reentryAmount);
        }
    }
}

/// @notice Helper contract used to test that upgrading to a non-UUPS-compliant
/// implementation reverts, since it exposes no 'proxiableUUID' function.
contract NotUUPSCompliant {}
