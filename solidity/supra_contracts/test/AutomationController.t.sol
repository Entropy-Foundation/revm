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
import {LibCommonUtils} from "../src/LibCommonUtils.sol";

contract AutomationControllerTest is Test {
    AutomationRegistry registry;                // AutomationRegistry instance on proxy address
    AutomationController controller;            // AutomationController instance on proxy address
    ERC20Supra erc20Supra;                      // ERC20Supra contract

    address admin = address(0xA11CE);
    address vmSigner = address(0x5355500000000000000000000000000000000000);
    address alice = address(0x123);
    address bob = address(0x456);

    /// @dev Sets up initial state for testing.
    /// @dev Sets balance of 'alice' to 100 ether.
    /// @dev Deploys and initializes ERC20Supra, AutomationRegistry and AutomationController contracts. 
    function setUp() public {
        vm.deal(alice, 100 ether);

        // Deploy ERC20Supra
        vm.prank(admin);
        erc20Supra = new ERC20Supra(msg.sender);

        // Deploy AutomationRegistry proxy
        registry = AutomationRegistry(deployRegistry(address(erc20Supra)));

        // Deploy AutomationController proxy
        controller = AutomationController(deployController(address(registry)));
    }
    
    /// @dev Helper function to deploy AutomationRegistry proxy 
    function deployRegistry(address _erc20Supra) private returns (address) {
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
                vmSigner,                   // VM Signer address
                address(_erc20Supra)        // ERC20Supra address
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vm.stopPrank();
        
        return address(proxy);
    }

    /// @dev Helper function to deploy AutomationController proxy 
    function deployController(address _registry) private returns (address) {
        vm.startPrank(admin);
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize,(_registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vm.stopPrank();
        
        return address(proxy);
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testInitialize() public view {
        assertEq(controller.owner(), admin);
        assertEq(address(controller.registry()), address(registry));

        (uint64 index, uint64 startTime, uint64 durationSecs, LibCommonUtils.CycleState state) = controller.getCycleInfo();
        assertEq(index, 1);
        assertEq(startTime, block.timestamp);
        assertEq(durationSecs, registry.cycleDurationSecs());
        assertEq(uint8(state), uint8(LibCommonUtils.CycleState.STARTED));
    }

    /// @dev Test to ensure initialize reverts if reinitialized.
    function testInitializeRevertsIfReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        
        vm.prank(admin);
        controller.initialize(address(registry));
    }

    /// @dev Test to ensure initialize reverts if registry address is zero.
    function testInitializeRevertsIfRegistryZero() public {
        // Deploy AutomationController proxy
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize,(address(0)));

        vm.expectRevert(IAutomationController.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Test to ensure initialize reverts if registry address is EOA.
    function testInitializeRevertsIfRegistryEoa() public {
        // Deploy AutomationController proxy
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize,(alice));

        vm.expectRevert(IAutomationController.AddressCannotBeEOA.selector);
        new ERC1967Proxy(address(impl), initData);
    }
    
    /// @dev Test to ensure 'setRegistry' reverts if caller is not owner.
    function testSetRegistryRevertsIfNotOwner() public {
        address newRegistry = deployRegistry(address(erc20Supra));

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
        address newRegistry = deployRegistry(address(erc20Supra));
        
        vm.prank(admin);
        controller.setRegistry(newRegistry);

        assertEq(address(controller.registry()), newRegistry);
    }

    /// @dev Test to ensure 'setRegistry' emits event 'RegistryUpdated'.
    function testSetRegistryEmitsEvent() public {
        address newRegistry = deployRegistry(address(erc20Supra));

        vm.expectEmit(true, true, false, false);
        emit AutomationController.RegistryUpdated(address(controller.registry()), newRegistry);

        vm.prank(admin);
        controller.setRegistry(newRegistry);
    }

    /// @dev Test to ensure 'processTasks' reverts if caller is not VM Signer.
    function testProcessTasksRevertsIfNotVm() public {
        uint64[] memory tasks = new uint64[](1);
        tasks[0] = 0;

        vm.expectRevert(IAutomationController.CallerNotVmSigner.selector);

        vm.prank(admin);
        controller.processTasks(1, tasks);
    }
}