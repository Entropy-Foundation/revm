// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from"../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {AutomationRegistry} from "../src/AutomationRegistry.sol";
import {AutomationController} from "../src/AutomationController.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {BlockMeta} from "../src/BlockMeta.sol";

contract BlockMetaTest is Test {
    address controller;                         // AutomationController address
    BlockMeta blockMeta;                        // BlockMeta instance on proxy address

    address admin = address(0xA11CE);
    address vmAddress = address(0x99);
    address alice = address(0x123);

    /// @dev Sets up initial state for testing.
    /// @dev Deploys and initializes BlockMeta and AutomationController contracts. 
    function setUp() public {
        vm.startPrank(admin);

        // Deploy BlockMeta proxy
        BlockMeta blockMetaImpl = new BlockMeta();
        bytes memory blockMetaInitData = abi.encodeCall(BlockMeta.initialize, ());
        ERC1967Proxy blockMetaProxy = new ERC1967Proxy(address(blockMetaImpl), blockMetaInitData);
        blockMeta = BlockMeta(address(blockMetaProxy));

        // Deploy AutomationRegistry proxy
        address supraERC20 = address(new ERC20Supra(msg.sender));
        AutomationRegistry registryImpl = new AutomationRegistry();
        bytes memory registryInitData = abi.encodeCall(
            AutomationRegistry.initialize,
            (
                3600,                       // taskDurationCapSecs
                10_000_000,                 // registryMaxGasCap
                0.001 ether,                // automationBaseFeeWeiPerSec
                0.002 ether,                // flatRegistrationFeeWei
                50,                         // congestionThresholdPercentage
                0.002 ether,                // congestionBaseFeeWeiPerSec
                2,                          // congestionExponent
                500,                        // taskCapacity
                2000,                       // cycleDurationSecs
                3600,                       // sysTaskDurationCapSecs
                5_000_000,                  // sysRegistryMaxGasCap
                500,                        // sysTaskCapacity
                vmAddress,                  // vm address
                supraERC20                  // supraERC20 address
            )
        );
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);

        // Deploy AutomationController proxy 
        AutomationController controllerImpl = new AutomationController();
        bytes memory controllerInitData = abi.encodeCall(AutomationController.initialize,(address(registryProxy), address(blockMeta)));
        ERC1967Proxy controllerProxy = new ERC1967Proxy(address(controllerImpl), controllerInitData);
        controller = address(controllerProxy);
        
        vm.stopPrank();
    }

    /// @dev Test to ensure 'setAutomationController' sets the AutomationController address. 
    function testSetAutomationController() public {
        assertEq(blockMeta.automationController(), address(0));

        vm.prank(admin);
        blockMeta.setAutomationController(controller);
        assertEq(blockMeta.automationController(), controller);
    }

    /// @dev Test to ensure 'setAutomationController' emits event 'AutomationControllerUpdated'. 
    function testSetAutomationControllerEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit BlockMeta.AutomationControllerUpdated(address(0), controller);

        vm.prank(admin);
        blockMeta.setAutomationController(controller);
    }

    /// @dev Test to ensure 'setAutomationController' reverts if caller is not owner. 
    function testSetAutomationControllerRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        blockMeta.setAutomationController(controller);
    }

    /// @dev Test to ensure 'setAutomationController' reverts if address(0) is passed. 
    function testSetAutomationControllerRevertsIfAddressZero() public {
        vm.expectRevert(BlockMeta.AddressCannotBeZero.selector);

        vm.prank(admin);
        blockMeta.setAutomationController(address(0));
    }

    /// @dev Test to ensure 'setAutomationController' reverts if EOA is passed. 
    function testSetAutomationControllerRevertsIfEOA() public {
        vm.expectRevert(BlockMeta.AddressCannotBeEOA.selector);

        vm.prank(admin);
        blockMeta.setAutomationController(alice);
    }

    /// @dev Test to ensure 'blockPrologue' executes. 
    function testBlockPrologue() public {
        testSetAutomationController();

        vm.prank(address(0x5355500000000000000000000000000000000000));
        blockMeta.blockPrologue();
    }

    /// @dev Test to ensure 'blockPrologue' reverts if caller is not SUP0. 
    function testBlockPrologueRevertsIfNotSUP0() public {
        vm.expectRevert(BlockMeta.InvalidCaller.selector);

        vm.prank(alice);
        blockMeta.blockPrologue();
    }

    /// @dev Test to ensure 'blockPrologue' reverts if AutomationController address is not set. 
    function testBlockPrologueRevertsIfControllerNotSet() public {
        vm.expectRevert(BlockMeta.AutomationControllerNotSet.selector);

        vm.prank(address(0x5355500000000000000000000000000000000000));
        blockMeta.blockPrologue();
    }
}