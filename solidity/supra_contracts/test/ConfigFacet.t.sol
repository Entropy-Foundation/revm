// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {ConfigFacet} from "../src/facets/ConfigFacet.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {Config} from "../src/libraries/LibAppStorage.sol";

contract ConfigFacetTest is BaseDiamondTest {

    // :::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'grantAuthorization' ::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'grantAuthorization' grants authorization to an address.
    function testGrantAuthorization() public {
        vm.prank(admin);
        ConfigFacet(diamondAddr).grantAuthorization(alice);

        // assertTrue(ConfigFacet(diamondAddr).isAuthorizedSubmitter(alice));
    }

    /// @dev Test to ensure 'grantAuthorization' emits event 'AuthorizationGranted'.
    function testGrantAuthorizationEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ConfigFacet.AuthorizationGranted(alice, block.timestamp);

        vm.prank(admin);
        ConfigFacet(diamondAddr).grantAuthorization(alice);
    }

    /// @dev Test to ensure 'grantAuthorization' reverts if address is already authorized.
    function testGrantAuthorizationRevertsIfAlreadyAuthorised() public {
        // Grant authorization to alice
        testGrantAuthorization();

        vm.expectRevert(IConfigFacet.AddressAlreadyExists.selector);

        vm.prank(admin);
        ConfigFacet(diamondAddr).grantAuthorization(alice);
    }

    /// @dev Test to ensure 'grantAuthorization' reverts if caller is not owner.
    function testGrantAuthorizationRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        ConfigFacet(diamondAddr).grantAuthorization(alice);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'revokeAuthorization' :::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @dev Test to ensure 'revokeAuthorization' revokes authorization from an address.
    function testRevokeAuthorization() public {
        // Grant authorization to alice
        testGrantAuthorization();

        // Revoke authorization
        vm.prank(admin);
        ConfigFacet(diamondAddr).revokeAuthorization(alice);

        // assertFalse(ConfigFacet(diamondAddr).isAuthorizedSubmitter(alice));
    }

    /// @dev Test to ensure 'revokeAuthorization' emits event 'AuthorizationRevoked'.
    function testRevokeAuthorizationEmitsEvent() public {
        // Grant authorization to alice
        testGrantAuthorization();

        vm.expectEmit(true, true, false, false);
        emit ConfigFacet.AuthorizationRevoked(alice, block.timestamp);

        vm.prank(admin);
        ConfigFacet(diamondAddr).revokeAuthorization(alice);
    }

    /// @dev Test to ensure 'revokeAuthorization' reverts if address is not authorised.
    function testRevokeAuthorizationRevertsIfNotAuthorised() public {
        vm.expectRevert(IConfigFacet.AddressDoesNotExist.selector);

        vm.prank(admin);
        ConfigFacet(diamondAddr).revokeAuthorization(alice);
    }

    /// @dev Test to ensure 'revokeAuthorization' reverts if caller is not owner.
    function testRevokeAuthorizationRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        ConfigFacet(diamondAddr).revokeAuthorization(alice);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'disableRegistration' ::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @dev Test to ensure 'disableRegistration' disables the registration.
    function testDisableRegistration() public {
        vm.prank(admin);
        ConfigFacet(diamondAddr).disableRegistration();

        assertFalse(ConfigFacet(diamondAddr).isRegistrationEnabled());
    }
    
    /// @dev Test to ensure 'disableRegistration' emits event 'TaskRegistrationDisabled'. 
    function testDisableRegistrationEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ConfigFacet.TaskRegistrationDisabled(false);

        testDisableRegistration();
    }

    /// @dev Test to ensure 'disableRegistration' reverts if registration is already disabled.
    function testDisableRegistrationRevertsIfAlreadyDisabled() public {
        // Disable registration
        testDisableRegistration();

        // Disable again → revert
        vm.expectRevert(IConfigFacet.AlreadyDisabled.selector);

        vm.prank(admin);
        ConfigFacet(diamondAddr).disableRegistration();
    }

    /// @dev Test to ensure 'disableRegistration' reverts if caller is not owner.
    function testDisableRegistrationRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));
        
        vm.prank(alice);
        ConfigFacet(diamondAddr).disableRegistration();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'enableRegistration' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'enableRegistration' enables the registration.
    function testEnableRegistration() public {
        // Disable registration
        testDisableRegistration();

        // Enable registration
        vm.prank(admin);
        ConfigFacet(diamondAddr).enableRegistration();

        assertTrue(ConfigFacet(diamondAddr).isRegistrationEnabled());
    }

    /// @dev Test to ensure 'enableRegistration' emits event 'TaskRegistrationEnabled'.
    function testEnableRegistrationEmitsEvent() public {
        // Disable registration
        testDisableRegistration();

        vm.expectEmit(true, false, false, false);
        emit ConfigFacet.TaskRegistrationEnabled(true);

        // Enable registration
        vm.prank(admin);
        ConfigFacet(diamondAddr).enableRegistration();
    }

    /// @dev Test to ensure 'enableRegistration' reverts if registration is already enabled.
    function testEnableRegistrationRevertsIfAlreadyEnabled() public {
        // Already enabled in initialize()
        vm.expectRevert(IConfigFacet.AlreadyEnabled.selector);

        vm.prank(admin);
        ConfigFacet(diamondAddr).enableRegistration();
    }

    /// @dev Test to ensure 'enableRegistration' reverts if caller is not owner.
    function testEnableRegistrationRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        ConfigFacet(diamondAddr).enableRegistration();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'setVmSigner' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'setVmSigner' updates the VM Signer address.
    function testSetVmSigner() public {
        address newVmSigner = address(0x100);

        vm.prank(admin);
        ConfigFacet(diamondAddr).setVmSigner(newVmSigner);

        assertEq(ConfigFacet(diamondAddr).getVmSigner(), newVmSigner);
    }

    /// @dev Test to ensure 'setVmSigner' emits event 'VmSignerUpdated'.
    function testSetVmSignerEmitsEvent() public {
        address oldVmSigner = ConfigFacet(diamondAddr).getVmSigner();
        address newVmSigner = address(0x100);

        vm.expectEmit(true, true, false, false);
        emit ConfigFacet.VmSignerUpdated(oldVmSigner, newVmSigner);

        vm.prank(admin);
        ConfigFacet(diamondAddr).setVmSigner(newVmSigner);
    }

    /// @dev Test to ensure 'setVmSigner' reverts if zero address is passed.
    function testSetVmSignerRevertsIfZeroAddress() public {
        vm.expectRevert(IConfigFacet.AddressCannotBeZero.selector);

        vm.prank(admin);
        ConfigFacet(diamondAddr).setVmSigner(address(0));
    }

    /// @dev Test to ensure 'setVmSigner' reverts if caller is not owner.
    function testSetVmSignerRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        ConfigFacet(diamondAddr).setVmSigner(address(0x100));
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'setErc20Supra' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'setErc20Supra' updates the ERC20Supra address. 
    function testSetErc20Supra() public {
        ERC20Supra supraErc20 = new ERC20Supra(msg.sender);

        vm.prank(admin);
        ConfigFacet(diamondAddr).setErc20Supra(address(supraErc20));

        assertEq(ConfigFacet(diamondAddr).erc20Supra(), address(supraErc20));
    }

    /// @dev Test to ensure 'setErc20Supra' emits event 'Erc20SupraUpdated'. 
    function testSetErc20SupraEmitsEvent() public {
        address oldAddr = ConfigFacet(diamondAddr).erc20Supra();
        ERC20Supra supraErc20 = new ERC20Supra(msg.sender);

        vm.expectEmit(true, true, false, false);
        emit ConfigFacet.Erc20SupraUpdated(oldAddr, address(supraErc20));

        vm.prank(admin);
        ConfigFacet(diamondAddr).setErc20Supra(address(supraErc20));
    }

    /// @dev Test to ensure 'setErc20Supra' reverts if zero address is passed. 
    function testSetErc20SupraRevertsIfZeroAddress() public {
        vm.expectRevert(IConfigFacet.AddressCannotBeZero.selector);

        vm.prank(admin);
        ConfigFacet(diamondAddr).setErc20Supra(address(0));
    }

    /// @dev Test to ensure 'setErc20Supra' reverts if EOA is passed. 
    function testSetErc20SupraRevertsIfEoa() public {
        vm.expectRevert(LibUtils.AddressCannotBeEOA.selector);

        vm.prank(admin);
        ConfigFacet(diamondAddr).setErc20Supra(alice);
    }

    /// @dev Test to ensure 'setErc20Supra' reverts if caller is not owner. 
    function testSetErc20SupraRevertsIfNotOwner() public {
        ERC20Supra supraErc20 = new ERC20Supra(msg.sender);

        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        ConfigFacet(diamondAddr).setErc20Supra(address(supraErc20));
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'withdrawFees' ::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'withdrawFees' reverts if amount is zero.
    function testWithdrawFeesRevertsIfAmountZero() public {
        vm.prank(admin);

        vm.expectRevert(IConfigFacet.InvalidAmount.selector);
        ConfigFacet(diamondAddr).withdrawFees(0, admin);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if recipient address is zero.
    function testWithdrawFeesRevertsIfRecipientAddressZero() public {
        vm.prank(admin);

        vm.expectRevert(IConfigFacet.AddressCannotBeZero.selector);
        ConfigFacet(diamondAddr).withdrawFees(1 ether, address(0));
    }

    /// @dev Test to ensure 'withdrawFees' reverts if contract has insufficient balance.
    function testWithdrawFeesRevertsIfInsufficientBalance() public {
        vm.expectRevert(IConfigFacet.InsufficientBalance.selector);

        vm.prank(admin);
        ConfigFacet(diamondAddr).withdrawFees(1 ether, admin);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if request amount exceeds the locked balance.
    function testWithdrawFeesRevertsIfRequestExceedsLockedBalance() public {
        registerUST();

        vm.expectRevert(IConfigFacet.RequestExceedsLockedBalance.selector);

        vm.prank(admin);
        ConfigFacet(diamondAddr).withdrawFees(0.04 ether, admin);
    }

    /// @dev Test to ensure 'withdrawFees' reverts if caller is not owner.
    function testWithdrawFeesRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        ConfigFacet(diamondAddr).withdrawFees(1 ether, admin);
    }

    /// @dev Test to ensure 'withdrawFees' withdraws the requested amount and updates the balance.
    function testWithdrawFees() public {
        registerUST();

        assertEq(erc20Supra.balanceOf(admin), 0);
        assertEq(erc20Supra.balanceOf(diamondAddr), 0.502 ether);

        vm.prank(admin);
        ConfigFacet(diamondAddr).withdrawFees(0.002 ether, admin);

        assertEq(erc20Supra.balanceOf(admin), 0.002 ether);
        assertEq(erc20Supra.balanceOf(diamondAddr), 0.5 ether);
    }
    
    /// @dev Test to ensure 'withdrawFees' emits event 'RegistryFeeWithdrawn'.
    function testWithdrawFeesEmitsEvent() public {
        registerUST();

        vm.expectEmit(true, true, false, false);
        emit ConfigFacet.RegistryFeeWithdrawn(admin, 0.002 ether);

        vm.prank(admin);
        ConfigFacet(diamondAddr).withdrawFees(0.002 ether, admin);
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
        ConfigFacet(diamondAddr).updateConfigBuffer(
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
        Config memory configBuffer = ConfigFacet(diamondAddr).getConfigBuffer();
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
        emit ConfigFacet.ConfigBufferUpdated(cfg);
        
        vm.prank(admin);
        ConfigFacet(diamondAddr).updateConfigBuffer(
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
        ConfigFacet(diamondAddr).updateConfigBuffer(
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