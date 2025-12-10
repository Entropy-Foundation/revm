// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from"../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {AutomationRegistry} from "../src/AutomationRegistry.sol";
import {AutomationController} from "../src/AutomationController.sol";
import {IAutomationController} from "../src/IAutomationController.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {BlockMeta} from "../src/BlockMeta.sol";
import {CommonUtils} from "../src/CommonUtils.sol";

contract AutomationControllerTest is Test {
    AutomationRegistry registry;                // AutomationRegistry instance on proxy address
    AutomationController controller;            // AutomationController instance on proxy address
    BlockMeta blockMeta;                        // BlockMeta instance on proxy address
    ERC20Supra supraERC20;                      // ERC20Supra contract

    address admin = address(0xA11CE);
    address vmAddress = address(0x99);
    address alice = address(0x123);
    address bob = address(0x456);

    /// @dev Sets up initial state for testing.
    /// @dev Sets balance of 'alice' to 100 ether.
    /// @dev Deploys and initializes ERC20Supra, BlockMeta, AutomationRegistry and AutomationController contracts. 
    function setUp() public {
        vm.deal(alice, 100 ether);

        // Deploy ERC20Supra
        vm.prank(admin);
        supraERC20 = new ERC20Supra(msg.sender);

        // Deploy AutomationRegistry proxy
        registry = AutomationRegistry(deployRegistry(address(supraERC20)));

        // Deploy BlockMeta proxy
        blockMeta = BlockMeta(deployBlockMeta());

        // Deploy AutomationController proxy
        controller = AutomationController(deployController(address(registry), address(blockMeta)));
    }
    
    /// @dev Helper function to deploy AutomationRegistry proxy 
    function deployRegistry(address _supraERC20) private returns (address) {
        vm.startPrank(admin);
        AutomationRegistry impl = new AutomationRegistry();

        bytes memory initData = abi.encodeCall(
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
                address(_supraERC20)        // supraERC20 address
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vm.stopPrank();
        
        return address(proxy);
    }

    /// @dev Helper function to deploy BlockMeta proxy
    function deployBlockMeta() private returns (address) {
        vm.startPrank(admin);
        BlockMeta impl = new BlockMeta();
        bytes memory initData = abi.encodeCall(BlockMeta.initialize, ());
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vm.stopPrank();

        return address(proxy);
    }

    /// @dev Helper function to deploy AutomationController proxy 
    function deployController(address _registry, address _blockMeta) private returns (address) {
        vm.startPrank(admin);
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize,(_registry, _blockMeta));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vm.stopPrank();
        
        return address(proxy);
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testInitialize() public view {
        assertEq(controller.owner(), admin);
        assertEq(address(controller.registry()), address(registry));
        assertEq(controller.blockMeta(), address(blockMeta));

        (uint64 index, uint64 startTime, uint64 durationSecs, CommonUtils.CycleState state) = controller.getCycleInfo();
        assertEq(index, 1);
        assertEq(startTime, block.timestamp);
        assertEq(durationSecs, registry.cycleDurationSecs());
        assertEq(uint8(state), uint8(CommonUtils.CycleState.STARTED));
    }

    /// @dev Test to ensure initialize reverts if reinitialized.
    function testInitializeRevertsIfReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        
        vm.prank(admin);
        controller.initialize(address(registry), address(blockMeta));
    }

    /// @dev Test to ensure initialize reverts if registry address is zero.
    function testInitializeRevertsIfRegistryZero() public {
        // Deploy BlockMeta proxy
        address blockMetaProxy = deployBlockMeta();

        // Deploy AutomationController proxy
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize,(address(0), blockMetaProxy));

        vm.expectRevert(IAutomationController.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Test to ensure initialize reverts if registry address is EOA.
    function testInitializeRevertsIfRegistryEoa() public {
        // Deploy BlockMeta proxy
        address blockMetaProxy = deployBlockMeta();

        // Deploy AutomationController proxy
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize,(alice, blockMetaProxy));

        vm.expectRevert(IAutomationController.AddressCannotBeEOA.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Test to ensure initialize reverts if blockMeta address is zero.
    function testInitializeRevertsIfBlockMetaZero() public {
        // Deploy AutomationRegistry proxy
        address registryProxy = deployRegistry(address(supraERC20));

        // Deploy AutomationController proxy
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize,(registryProxy, address(0)));

        vm.expectRevert(IAutomationController.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Test to ensure initialize reverts if blockMeta address is EOA.
    function testInitializeRevertsIfBlockMetaEoa() public {
        // Deploy AutomationRegistry proxy
        address registryProxy = deployRegistry(address(supraERC20));

        // Deploy AutomationController proxy
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize,(registryProxy, alice));

        vm.expectRevert(IAutomationController.AddressCannotBeEOA.selector);
        new ERC1967Proxy(address(impl), initData);
    }
    
    /// @dev Test to ensure 'setRegistry' reverts if caller is not owner.
    function testSetRegistryRevertsIfNotOwner() public {
        address newRegistry = deployRegistry(address(supraERC20));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        controller.setRegistry(newRegistry);
    }
    
    /// @dev Test to ensure 'setRegistry' reverts if address is zero.
    function testSetRegistryRevertsIfAddressZero() public {
        vm.expectRevert(IAutomationController.AddressCannotBeZero.selector);

        vm.prank(admin);
        controller.setRegistry(address(0));
    }

    /// @dev Test to ensure 'setRegistry' reverts if address is EOA.
    function testSetRegistryRevertsIfAddressEoa() public {
        vm.expectRevert(IAutomationController.AddressCannotBeEOA.selector);

        vm.prank(admin);
        controller.setRegistry(alice);
    }

    /// @dev Test to ensure 'setRegistry' updates the registry address.
    function testSetRegistry() public {
        address newRegistry = deployRegistry(address(supraERC20));
        
        vm.prank(admin);
        controller.setRegistry(newRegistry);

        assertEq(address(controller.registry()), newRegistry);
    }

    /// @dev Test to ensure 'setRegistry' emits event 'RegistryUpdated'.
    function testSetRegistryEmitsEvent() public {
        address newRegistry = deployRegistry(address(supraERC20));

        vm.expectEmit(true, true, false, false);
        emit AutomationController.RegistryUpdated(address(controller.registry()), newRegistry);

        vm.prank(admin);
        controller.setRegistry(newRegistry);
    }

    /// @dev Test to ensure 'setBlockMeta' reverts if caller is not owner.
    function testSetBlockMetaRevertsIfNotOwner() public {
        address newBlockMeta = deployBlockMeta();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        controller.setBlockMeta(newBlockMeta);
    }

    /// @dev Test to ensure 'setBlockMeta' reverts if address is zero.
    function testSetBlockMetaRevertsIfAddressZero() public {
        vm.expectRevert(IAutomationController.AddressCannotBeZero.selector);

        vm.prank(admin);
        controller.setBlockMeta(address(0));
    }

    /// @dev Test to ensure 'setBlockMeta' reverts if address is EOA.
    function testSetBlockMetaRevertsIfAddressEoa() public {
        vm.expectRevert(IAutomationController.AddressCannotBeEOA.selector);

        vm.prank(admin);
        controller.setBlockMeta(alice);
    }

    /// @dev Test to ensure 'setBlockMeta' updates the blockMeta address.
    function testSetBlockMeta() public {
        address newBlockMeta = deployBlockMeta();

        vm.prank(admin);
        controller.setBlockMeta(newBlockMeta);

        assertEq(controller.blockMeta(), newBlockMeta);
    }

    /// @dev Test to ensure 'setBlockMeta' emits event 'BlockMetaAddressUpdated'.
    function testSetBlockMetaEmitsEvent() public {
        address newBlockMeta = deployBlockMeta();

        vm.expectEmit(true, true, false, false); 
        emit AutomationController.BlockMetaAddressUpdated(controller.blockMeta() , newBlockMeta);

        vm.prank(admin);
        controller.setBlockMeta(newBlockMeta);
    }

    /// @dev Test to ensure 'processTasks' reverts if caller is not VM address.
    function testProcessTasksRevertsIfNotVm() public {
        uint64[] memory tasks = new uint64[](1);
        tasks[0] = 0;

        vm.expectRevert(IAutomationController.CallerNotVM.selector);

        vm.prank(admin);
        controller.processTasks(1, tasks);
    }
}