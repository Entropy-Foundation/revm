// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {Config} from "../src/libraries/LibAppStorage.sol";

contract ConfigFacetTest is BaseDiamondTest {

    // :::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'grantAuthorization' ::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'grantAuthorization' grants authorization to an address.
    function testGrantAuthorization() public {
        vm.prank(admin);
        IConfigFacet(diamondAddr).grantAuthorization(alice);

        assertTrue(IRegistryFacet(diamondAddr).isAuthorizedSubmitter(alice));
    }

    /// @dev Test to ensure 'grantAuthorization' emits event 'AuthorizationGranted'.
    function testGrantAuthorizationEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IConfigFacet.AuthorizationGranted(alice, block.timestamp);

        vm.prank(admin);
        IConfigFacet(diamondAddr).grantAuthorization(alice);
    }

    /// @dev Test to ensure 'grantAuthorization' reverts if address is already authorized.
    function testGrantAuthorizationRevertsIfAlreadyAuthorised() public {
        // Grant authorization to alice
        testGrantAuthorization();

        vm.expectRevert(IConfigFacet.AddressAlreadyExists.selector);

        vm.prank(admin);
        IConfigFacet(diamondAddr).grantAuthorization(alice);
    }

    /// @dev Test to ensure 'grantAuthorization' reverts if caller is not owner.
    function testGrantAuthorizationRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        IConfigFacet(diamondAddr).grantAuthorization(alice);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'revokeAuthorization' :::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @dev Test to ensure 'revokeAuthorization' revokes authorization from an address.
    function testRevokeAuthorization() public {
        // Grant authorization to alice
        testGrantAuthorization();

        // Revoke authorization
        vm.prank(admin);
        IConfigFacet(diamondAddr).revokeAuthorization(alice);

        assertFalse(IRegistryFacet(diamondAddr).isAuthorizedSubmitter(alice));
    }

    /// @dev Test to ensure 'revokeAuthorization' emits event 'AuthorizationRevoked'.
    function testRevokeAuthorizationEmitsEvent() public {
        // Grant authorization to alice
        testGrantAuthorization();

        vm.expectEmit(true, true, false, false);
        emit IConfigFacet.AuthorizationRevoked(alice, block.timestamp);

        vm.prank(admin);
        IConfigFacet(diamondAddr).revokeAuthorization(alice);
    }

    /// @dev Test to ensure 'revokeAuthorization' reverts if address is not authorised.
    function testRevokeAuthorizationRevertsIfNotAuthorised() public {
        vm.expectRevert(IConfigFacet.AddressDoesNotExist.selector);

        vm.prank(admin);
        IConfigFacet(diamondAddr).revokeAuthorization(alice);
    }

    /// @dev Test to ensure 'revokeAuthorization' reverts if caller is not owner.
    function testRevokeAuthorizationRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        IConfigFacet(diamondAddr).revokeAuthorization(alice);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'disableRegistration' ::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @dev Test to ensure 'disableRegistration' disables the registration.
    function testDisableRegistration() public {
        vm.prank(admin);
        IConfigFacet(diamondAddr).disableRegistration();

        assertFalse(IConfigFacet(diamondAddr).isRegistrationEnabled());
    }
    
    /// @dev Test to ensure 'disableRegistration' emits event 'TaskRegistrationDisabled'. 
    function testDisableRegistrationEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit IConfigFacet.TaskRegistrationDisabled(false);

        testDisableRegistration();
    }

    /// @dev Test to ensure 'disableRegistration' reverts if registration is already disabled.
    function testDisableRegistrationRevertsIfAlreadyDisabled() public {
        // Disable registration
        testDisableRegistration();

        // Disable again → revert
        vm.expectRevert(IConfigFacet.AlreadyDisabled.selector);

        vm.prank(admin);
        IConfigFacet(diamondAddr).disableRegistration();
    }

    /// @dev Test to ensure 'disableRegistration' reverts if caller is not owner.
    function testDisableRegistrationRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));
        
        vm.prank(alice);
        IConfigFacet(diamondAddr).disableRegistration();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'enableRegistration' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'enableRegistration' enables the registration.
    function testEnableRegistration() public {
        // Disable registration
        testDisableRegistration();

        // Enable registration
        vm.prank(admin);
        IConfigFacet(diamondAddr).enableRegistration();

        assertTrue(IConfigFacet(diamondAddr).isRegistrationEnabled());
    }

    /// @dev Test to ensure 'enableRegistration' emits event 'TaskRegistrationEnabled'.
    function testEnableRegistrationEmitsEvent() public {
        // Disable registration
        testDisableRegistration();

        vm.expectEmit(true, false, false, false);
        emit IConfigFacet.TaskRegistrationEnabled(true);

        // Enable registration
        vm.prank(admin);
        IConfigFacet(diamondAddr).enableRegistration();
    }

    /// @dev Test to ensure 'enableRegistration' reverts if registration is already enabled.
    function testEnableRegistrationRevertsIfAlreadyEnabled() public {
        vm.expectRevert(IConfigFacet.AlreadyEnabled.selector);

        vm.prank(admin);
        IConfigFacet(diamondAddr).enableRegistration();
    }

    /// @dev Test to ensure 'enableRegistration' reverts if caller is not owner.
    function testEnableRegistrationRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        IConfigFacet(diamondAddr).enableRegistration();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'withdrawFees' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'withdrawFees' reverts if amount is zero.
    function testWithdrawFeesRevertsIfAmountZero() public {
        vm.prank(admin);

        vm.expectRevert(IConfigFacet.InvalidAmount.selector);
        IConfigFacet(diamondAddr).withdrawFees(0, admin);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if recipient address is zero.
    function testWithdrawFeesRevertsIfRecipientAddressZero() public {
        vm.prank(admin);

        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);
        IConfigFacet(diamondAddr).withdrawFees(1 ether, address(0));
    }

    /// @dev Test to ensure 'withdrawFees' reverts if contract has insufficient balance.
    function testWithdrawFeesRevertsIfInsufficientBalance() public {
        vm.expectRevert(IConfigFacet.InsufficientBalance.selector);

        vm.prank(admin);
        IConfigFacet(diamondAddr).withdrawFees(1 ether, admin);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if request amount exceeds the locked balance.
    function testWithdrawFeesRevertsIfRequestExceedsLockedBalance() public {
        registerUst();

        vm.expectRevert(IConfigFacet.RequestExceedsLockedBalance.selector);

        vm.prank(admin);
        IConfigFacet(diamondAddr).withdrawFees(2 ether, admin);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if caller is not owner.
    function testWithdrawFeesRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        IConfigFacet(diamondAddr).withdrawFees(1 ether, admin);
    }

    /// @dev Test to ensure 'withdrawFees' withdraws the requested amount and updates the balance.
    function testWithdrawFees() public {
        registerUst();

        assertEq(erc20Supra.balanceOf(admin), 0);
        assertEq(erc20Supra.balanceOf(diamondAddr), 61.1 ether);

        vm.prank(admin);
        IConfigFacet(diamondAddr).withdrawFees(1 ether, admin);

        assertEq(erc20Supra.balanceOf(admin), 1 ether);
        assertEq(erc20Supra.balanceOf(diamondAddr), 60.1 ether);
    }
    
    /// @dev Test to ensure 'withdrawFees' emits event 'RegistryFeeWithdrawn'.
    function testWithdrawFeesEmitsEvent() public {
        registerUst();

        vm.expectEmit(true, true, false, false);
        emit IConfigFacet.RegistryFeeWithdrawn(admin, 0.002 ether);

        vm.prank(admin);
        IConfigFacet(diamondAddr).withdrawFees(0.002 ether, admin);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'updateConfigBuffer' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Helper function that returns a valid config.
    function validConfig() private pure returns (Config memory cfg) {
        cfg = Config({ 
            registryMaxGasCap: 10_000_000, 
            sysRegistryMaxGasCap: 5_000_000, 
            automationBaseFeeWeiPerSec: 0.001 ether, 
            flatRegistrationFeeWei: 0.002 ether, 
            congestionBaseFeeWeiPerSec: 0.002 ether, 
            taskDurationCapSecs: 3600, 
            sysTaskDurationCapSecs: 3600, 
            cycleDurationSecs: 2000, 
            taskCapacity: 500, 
            sysTaskCapacity: 500, 
            congestionThresholdPercentage: 55, 
            congestionExponent: 3
        }); 
    }

    /// @dev Test to ensure 'updateConfigBuffer' updates the config buffer.
    function testUpdateConfigBuffer() public {
        Config memory cfg = validConfig();

        vm.prank(admin);
        IConfigFacet(diamondAddr).updateConfigBuffer(
            cfg.taskDurationCapSecs,
            cfg.registryMaxGasCap,
            cfg.automationBaseFeeWeiPerSec,
            cfg.flatRegistrationFeeWei,
            cfg.congestionThresholdPercentage,
            cfg.congestionBaseFeeWeiPerSec,
            cfg.congestionExponent,
            cfg.taskCapacity,
            cfg.cycleDurationSecs,
            cfg.sysTaskDurationCapSecs,
            cfg.sysRegistryMaxGasCap,
            cfg.sysTaskCapacity
        );
    
        // Pending config should be updated
        Config memory configBuffer = IConfigFacet(diamondAddr).getConfigBuffer();
        assertEq(configBuffer.taskDurationCapSecs, cfg.taskDurationCapSecs);
        assertEq(configBuffer.registryMaxGasCap, cfg.registryMaxGasCap);
        assertEq(configBuffer.automationBaseFeeWeiPerSec, cfg.automationBaseFeeWeiPerSec);
        assertEq(configBuffer.flatRegistrationFeeWei, cfg.flatRegistrationFeeWei);
        assertEq(configBuffer.congestionThresholdPercentage, cfg.congestionThresholdPercentage);
        assertEq(configBuffer.congestionBaseFeeWeiPerSec, cfg.congestionBaseFeeWeiPerSec);
        assertEq(configBuffer.congestionExponent, cfg.congestionExponent);
        assertEq(configBuffer.taskCapacity, cfg.taskCapacity);
        assertEq(configBuffer.cycleDurationSecs, cfg.cycleDurationSecs);
        assertEq(configBuffer.sysTaskDurationCapSecs, cfg.sysTaskDurationCapSecs);
        assertEq(configBuffer.sysRegistryMaxGasCap, cfg.sysRegistryMaxGasCap);
        assertEq(configBuffer.sysTaskCapacity, cfg.sysTaskCapacity);
    }

    /// @dev Test to ensure 'updateConfigBuffer' emits event 'ConfigBufferUpdated'.
    function testUpdateConfigBufferEmitsEvent() public {
        Config memory cfg = validConfig();

        vm.expectEmit(true, false, false, false);
        emit IConfigFacet.ConfigBufferUpdated(cfg);
        
        vm.prank(admin);
        IConfigFacet(diamondAddr).updateConfigBuffer(
            cfg.taskDurationCapSecs,
            cfg.registryMaxGasCap,
            cfg.automationBaseFeeWeiPerSec,
            cfg.flatRegistrationFeeWei,
            cfg.congestionThresholdPercentage,
            cfg.congestionBaseFeeWeiPerSec,
            cfg.congestionExponent,
            cfg.taskCapacity,
            cfg.cycleDurationSecs,
            cfg.sysTaskDurationCapSecs,
            cfg.sysRegistryMaxGasCap,
            cfg.sysTaskCapacity
        );
    }

    /// @dev Test to ensure 'updateConfigBuffer' reverts if caller is not owner.
    function testUpdateConfigBufferRevertsIfNotOwner() public {
        Config memory cfg = validConfig();

        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        IConfigFacet(diamondAddr).updateConfigBuffer(
            cfg.taskDurationCapSecs,
            cfg.registryMaxGasCap,
            cfg.automationBaseFeeWeiPerSec,
            cfg.flatRegistrationFeeWei,
            cfg.congestionThresholdPercentage,
            cfg.congestionBaseFeeWeiPerSec,
            cfg.congestionExponent,
            cfg.taskCapacity,
            cfg.cycleDurationSecs,
            cfg.sysTaskDurationCapSecs,
            cfg.sysRegistryMaxGasCap,
            cfg.sysTaskCapacity
        );
    }
}