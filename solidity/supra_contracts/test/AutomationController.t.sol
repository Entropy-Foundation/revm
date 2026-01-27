// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from"../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {AutomationRegistry} from "../src/AutomationRegistry.sol";
import {AutomationCore} from "../src/AutomationCore.sol";
import {AutomationController} from "../src/AutomationController.sol";
import {IAutomationController} from "../src/IAutomationController.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {CommonUtils} from "../src/CommonUtils.sol";
import {LibConfig} from "../src/LibConfig.sol";

contract AutomationControllerTest is Test {
    ERC20Supra erc20Supra;                      // ERC20Supra contract
    AutomationCore automationCore;              // AutomationCore instance on proxy address
    AutomationRegistry registry;                // AutomationRegistry instance on proxy address
    AutomationController controller;            // AutomationController instance on proxy address

    address admin = address(0xA11CE);
    address vmSigner = address(0x53555000);
    address alice = address(0x123);
    address bob = address(0x456);

    /// @dev Sets up initial state for testing.
    /// @dev Sets balance of 'alice' to 100 ether.
    /// @dev Deploys and initializes all contracts with required parameters. 
    function setUp() public {
        vm.deal(alice, 100 ether);

        vm.startPrank(admin);
        erc20Supra = new ERC20Supra(msg.sender);

        AutomationCore automationCoreImpl = new AutomationCore();
        bytes memory automationCoreInitData = abi.encodeCall(
            AutomationCore.initialize,
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
                address(erc20Supra)         // ERC20Supra address
            )
        );
        ERC1967Proxy automationCoreProxy = new ERC1967Proxy(address(automationCoreImpl), automationCoreInitData);
        automationCore = AutomationCore(address(automationCoreProxy));
        
        AutomationRegistry registryImpl = new AutomationRegistry();
        bytes memory registryInitData = abi.encodeCall(AutomationRegistry.initialize, (address(automationCore)));
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), registryInitData);
        registry = AutomationRegistry(address(registryProxy));

        AutomationController controllerImpl = new AutomationController();
        bytes memory controllerInitData = abi.encodeCall(AutomationController.initialize,(address(automationCore), address(registry)));
        ERC1967Proxy controllerProxy = new ERC1967Proxy(address(controllerImpl), controllerInitData);
        controller = AutomationController(address(controllerProxy));

        automationCore.setAutomationRegistry(address(registry));
        automationCore.setAutomationController(address(controller));
        registry.setAutomationController(address(controller));

        vm.stopPrank();
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testInitialize() public view {
        assertEq(controller.owner(), admin);
        assertEq(address(controller.automationCore()), address(automationCore));
        assertEq(address(controller.registry()), address(registry));

        (uint64 index, uint64 startTime, uint64 durationSecs, CommonUtils.CycleState state) = controller.getCycleInfo();
        assertEq(index, 1);
        assertEq(startTime, block.timestamp);
        assertEq(durationSecs, automationCore.cycleDurationSecs());
        assertEq(uint8(state), uint8(CommonUtils.CycleState.STARTED));
    }

    /// @dev Test to ensure initialize reverts if reinitialized.
    function testInitializeRevertsIfReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        
        vm.prank(admin);
        controller.initialize(address(automationCore), address(registry));
    }

    /// @dev Test to ensure initialize reverts if AutomationCore address is zero.
    function testInitializeRevertsIfAutomationCoreAddressZero() public {
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize, (address(0), address(registry)));

        vm.expectRevert(CommonUtils.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Test to ensure initialize reverts if AutomationCore address is EOA.
    function testInitializeRevertsIfAutomationCoreEoa() public {
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize, (alice, address(registry)));

        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Test to ensure initialize reverts if AutomationRegistry address is zero.
    function testInitializeRevertsIfRegistryZero() public {
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize, (address(automationCore), address(0)));

        vm.expectRevert(CommonUtils.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Test to ensure initialize reverts if AutomationRegistry address is EOA.
    function testInitializeRevertsIfRegistryEoa() public {
        AutomationController impl = new AutomationController();
        bytes memory initData = abi.encodeCall(AutomationController.initialize, (address(automationCore), alice));

        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);
        new ERC1967Proxy(address(impl), initData);
    }
    
    /// @dev Test to ensure 'setAutomationRegistry' reverts if caller is not owner.
    function testSetAutomationRegistryRevertsIfNotOwner() public {
        AutomationRegistry registryImplementation = new AutomationRegistry();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        controller.setAutomationRegistry(address(registryImplementation));
    }
    
    /// @dev Test to ensure 'setAutomationRegistry' reverts if address is zero.
    function testSetAutomationRegistryRevertsIfAddressZero() public {
        vm.expectRevert(CommonUtils.AddressCannotBeZero.selector);

        vm.prank(admin);
        controller.setAutomationRegistry(address(0));
    }

    /// @dev Test to ensure 'setAutomationRegistry' reverts if address is EOA.
    function testSetAutomationRegistryRevertsIfAddressEoa() public {
        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);

        vm.prank(admin);
        controller.setAutomationRegistry(alice);
    }

    /// @dev Test to ensure 'setAutomationRegistry' updates the registry address.
    function testSetAutomationRegistry() public {
        AutomationRegistry registryImplementation = new AutomationRegistry();

        vm.prank(admin);
        controller.setAutomationRegistry(address(registryImplementation));

        assertEq(address(controller.registry()), address(registryImplementation));
    }

    /// @dev Test to ensure 'setAutomationRegistry' emits event 'AutomationRegistryUpdated'.
    function testSetAutomationRegistryEmitsEvent() public {
        AutomationRegistry registryImplementation = new AutomationRegistry();

        vm.expectEmit(true, true, false, false);
        emit AutomationController.AutomationRegistryUpdated(address(controller.registry()), address(registryImplementation));

        vm.prank(admin);
        controller.setAutomationRegistry(address(registryImplementation));
    }

    /// @dev Test to ensure 'setAutomationCore' reverts if caller is not owner.
    function testSetAutomationCoreRevertsIfNotOwner() public {
        AutomationCore automationCoreImpl = new AutomationCore();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        controller.setAutomationCore(address(automationCoreImpl));
    }
    
    /// @dev Test to ensure 'setAutomationCore' reverts if address is zero.
    function testSetAutomationCoreRevertsIfAddressZero() public {
        vm.expectRevert(CommonUtils.AddressCannotBeZero.selector);

        vm.prank(admin);
        controller.setAutomationCore(address(0));
    }

    /// @dev Test to ensure 'setAutomationCore' reverts if address is EOA.
    function testSetAutomationCoreRevertsIfAddressEoa() public {
        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);

        vm.prank(admin);
        controller.setAutomationCore(alice);
    }

    /// @dev Test to ensure 'setAutomationCore' updates the AutomationCore address.
    function testSetAutomationCore() public {
        AutomationCore automationCoreImpl = new AutomationCore();

        vm.prank(admin);
        controller.setAutomationCore(address(automationCoreImpl));

        assertEq(address(controller.automationCore()), address(automationCoreImpl));
    }

    /// @dev Test to ensure 'setAutomationCore' emits event 'AutomationCoreUpdated'.
    function testSetAutomationCoreEmitsEvent() public {
        AutomationCore automationCoreImpl = new AutomationCore();

        vm.expectEmit(true, true, false, false);
        emit AutomationController.AutomationCoreUpdated(address(controller.automationCore()), address(automationCoreImpl));

        vm.prank(admin);
        controller.setAutomationCore(address(automationCoreImpl));
    }

    /// @dev Test to ensure 'monitorCycleEnd' reverts if tx.origin is not VM Signer.
    function testMonitorCycleEndRevertsIfTxOriginNotVm() public {
        vm.expectRevert(IAutomationController.CallerNotVmSigner.selector);

        vm.prank(vmSigner);
        controller.monitorCycleEnd();
    }

    /// @dev Test to ensure 'monitorCycleEnd' does nothing before cycle expiry.
    function testMonitorCycleEndDoesNothingBeforeCycleExpiry() public {
        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, CommonUtils.CycleState stateBefore) = controller.getCycleInfo();

        vm.prank(vmSigner, vmSigner);
        controller.monitorCycleEnd();

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, CommonUtils.CycleState stateAfter) = controller.getCycleInfo();

        assertEq(indexAfter, indexBefore);
        assertEq(startAfter, startBefore);
        assertEq(durationAfter, durationBefore);
        assertEq(uint8(stateAfter), uint8(stateBefore));
    }

    /// @dev Test to ensure 'monitorCycleEnd' does nothing if state is not STARTED.
    function testMonitorCycleEndDoesNothingIfNotStarted() public {
        // Move state to READY state
        vm.prank(address(automationCore));
        controller.tryMoveToSuspendedState();

        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, CommonUtils.CycleState stateBefore) = controller.getCycleInfo();
        assertEq(uint8(stateBefore), uint8(CommonUtils.CycleState.READY));

        vm.warp(startBefore + durationBefore);

        vm.prank(vmSigner, vmSigner);
        controller.monitorCycleEnd();

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, CommonUtils.CycleState stateAfter) = controller.getCycleInfo();

        assertEq(indexAfter, indexBefore);
        assertEq(startAfter, startBefore);
        assertEq(durationAfter, durationBefore);
        assertEq(uint8(stateAfter), uint8(stateBefore));
    }

    /// @dev Test to ensure 'monitorCycleEnd' moves cycle state to READY if automation is disabled and no tasks exist.
    function testMonitorCycleEndWhenAutomationDisabledNoTasks() public {
        // Disable automation
        vm.prank(admin);
        automationCore.disableAutomation();

        assertFalse(automationCore.isAutomationEnabled());

        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, CommonUtils.CycleState stateBefore) = controller.getCycleInfo();
        vm.warp(startBefore + durationBefore);
        
        vm.expectEmit(true, true, false, true);
        emit AutomationController.AutomationCycleEvent(
            indexBefore, 
            CommonUtils.CycleState.READY,
            startBefore,
            durationBefore,
            stateBefore
        );

        vm.prank(vmSigner, vmSigner);
        controller.monitorCycleEnd();

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, CommonUtils.CycleState stateAfter) = controller.getCycleInfo();

        assertEq(indexAfter, indexBefore);
        assertEq(startAfter, startBefore);
        assertEq(durationAfter, durationBefore);
        assertEq(uint8(stateAfter), uint8(CommonUtils.CycleState.READY));
    }

    /// @dev Test to ensure 'monitorCycleEnd' moves cycle state to STARTED if automation is enabled and no tasks exist.
    function testMonitorCycleEndWhenAutomationEnabledNoTasks() public {
        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, CommonUtils.CycleState stateBefore) = controller.getCycleInfo();

        vm.warp(startBefore + durationBefore);

        vm.expectEmit(true, true, false, true);
        emit AutomationController.AutomationCycleEvent(
            indexBefore + 1,
            CommonUtils.CycleState.STARTED, 
            uint64(block.timestamp), 
            durationBefore, 
            stateBefore
        );

        vm.prank(vmSigner, vmSigner);
        controller.monitorCycleEnd();

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, CommonUtils.CycleState stateAfter) = controller.getCycleInfo();

        assertEq(indexAfter, indexBefore + 1);
        assertEq(startAfter, block.timestamp);
        assertEq(durationAfter, durationBefore);
        assertEq(uint8(stateAfter), uint8(CommonUtils.CycleState.STARTED));
    }

    /// @dev Test to ensure 'monitorCycleEnd' moves cycle state to FINISHED if automation is enabled and tasks exist.
    function testMonitorCycleEndWhenAutomationEnabledAndTasksExist() public {
        registerTask();

        (uint64 indexBefore, uint64 startBefore, uint64 durationBefore, CommonUtils.CycleState stateBefore) = controller.getCycleInfo();
        vm.warp(startBefore + durationBefore);

        vm.expectEmit(true, true, false, true);
        emit AutomationController.AutomationCycleEvent(
            indexBefore,
            CommonUtils.CycleState.FINISHED,
            startBefore,
            durationBefore,
            stateBefore
        );

        vm.prank(vmSigner, vmSigner);
        controller.monitorCycleEnd();

        (uint64 indexAfter, uint64 startAfter, uint64 durationAfter, CommonUtils.CycleState stateAfter) = controller.getCycleInfo();

        assertEq(indexAfter, indexBefore);
        assertEq(startAfter, startBefore);
        assertEq(durationAfter, durationBefore);
        assertEq(uint8(stateAfter), uint8(CommonUtils.CycleState.FINISHED));

        (uint64 refundDuration, uint128 automationFeePerSec) = controller.getTransitionInfo();
        assertEq(refundDuration, 0);
        assertEq(automationFeePerSec, 1000000000000000);
    }

    /// @dev Test to ensure 'processTasks' reverts if caller is not VM Signer.
    function testProcessTasksRevertsIfNotVm() public {
        uint64[] memory tasks = new uint64[](1);
        tasks[0] = 0;

        vm.expectRevert(IAutomationController.CallerNotVmSigner.selector);

        vm.prank(admin);
        controller.processTasks(1, tasks);
    }

    /// @dev Test to ensure 'processTasks' reverts if state is not FINISHED or SUSPENDED.
    function testProcessTasksRevertsIfInvalidState() public {
        uint64[] memory tasks = new uint64[](1);
        tasks[0] = 0;
        
        vm.expectRevert(IAutomationController.InvalidRegistryState.selector);

        vm.prank(vmSigner, vmSigner);
        controller.processTasks(1, tasks);
    }

    /// @dev Test to ensure 'processTasks' works correctly when cycle state is FINISHED.
    function testProcessTasksWhenCycleStateFinished() public {
        registerTask();

        ( , uint64 startTime, uint64 duration, ) = controller.getCycleInfo();
        vm.warp(startTime + duration);

        vm.prank(vmSigner, vmSigner);
        controller.monitorCycleEnd();

        (uint64 index, , , CommonUtils.CycleState state) = controller.getCycleInfo();
        assertEq(uint8(state), uint8(CommonUtils.CycleState.FINISHED));

        uint64[] memory tasks = new uint64[](1);
        tasks[0] = 0;

        uint256[] memory activeTasks = new uint256[](1);
        tasks[0] = 0;

        vm.expectEmit(true, false, false, false);
        emit AutomationController.ActiveTasks(activeTasks);

        vm.prank(vmSigner, vmSigner);
        controller.processTasks(index + 1, tasks);

        (uint64 newIndex, uint64 newStart, uint64 newDuration, CommonUtils.CycleState newState) = controller.getCycleInfo();
        assertEq(newIndex, index + 1);
        assertEq(newStart, uint64(block.timestamp));
        assertEq(newDuration, 2000);
        assertEq(uint8(newState), uint8(CommonUtils.CycleState.STARTED));

        assertEq(registry.getAllActiveTaskIds(), activeTasks);
        assertEq(registry.getSystemGasCommittedForNextCycle(), 0);
        assertEq(registry.getSystemGasCommittedForCurrentCycle(), 0);
        assertEq(registry.getGasCommittedForNextCycle(), 0);
        assertEq(registry.getGasCommittedForCurrentCycle(), 1000000);
        assertEq(registry.getCycleLockedFees(), 200000000000000000);
    }

    /// @dev Test to ensure 'processTasks' reverts if invalid cycle index is passed when cycle state is FINISHED.
    function testProcessTasksRevertsIfInvalidCycleIndexWhenCycleStateFinished() public {
        registerTask();

        ( , uint64 startTime, uint64 duration, ) = controller.getCycleInfo();
        vm.warp(startTime + duration);
        
        vm.prank(vmSigner, vmSigner);
        controller.monitorCycleEnd();

        (uint64 index, , , CommonUtils.CycleState state) = controller.getCycleInfo();
        assertEq(uint8(state), uint8(CommonUtils.CycleState.FINISHED));
        
        uint64[] memory tasks = new uint64[](1);
        tasks[0] = 0;

        vm.expectRevert(IAutomationController.InvalidInputCycleIndex.selector);

        vm.prank(vmSigner, vmSigner);
        controller.processTasks(index, tasks);
    }

    /// @dev Test to ensure 'processTasks' works correctly when cycle state is SUSPENDED and automation is disabled.
    function testProcessTasksWhenCycleStateSuspendedAutomationDisabled() public {
        registerTask();

        ( , uint64 start, uint64 duration, ) = controller.getCycleInfo();
        vm.warp(start + duration);
        
        // Moves state to FINISHED
        vm.prank(vmSigner, vmSigner);
        controller.monitorCycleEnd();

        ( , , , CommonUtils.CycleState stateBefore) = controller.getCycleInfo();
        assertEq(uint8(stateBefore), uint8(CommonUtils.CycleState.FINISHED));

        // Disable automation → moves state to SUSPENDED
        vm.prank(admin);
        automationCore.disableAutomation();

        (uint64 indexAfter, , , CommonUtils.CycleState stateAfter) = controller.getCycleInfo();
        assertEq(uint8(stateAfter), uint8(CommonUtils.CycleState.SUSPENDED));

        uint64[] memory tasks = new uint64[](1);
        tasks[0] = 0;

        vm.expectEmit(true, false, false, false);
        emit AutomationController.RemovedTasks(tasks);

        vm.prank(vmSigner, vmSigner);
        controller.processTasks(indexAfter, tasks);

        ( , , , CommonUtils.CycleState newState) = controller.getCycleInfo();
        assertEq(uint8(newState), uint8(CommonUtils.CycleState.READY));
        assertFalse(registry.ifTaskExists(tasks[0]));
    }   

    /// @dev Test to ensure 'processTasks' works correctly when cycle state is SUSPENDED and automation is enabled.
    function testProcessTasksWhenCycleStateSuspendedAutomationEnabled() public {
        registerTask();

        ( , uint64 start, uint64 duration, ) = controller.getCycleInfo();
        vm.warp(start + duration);
        
        // Moves state to FINISHED
        vm.prank(vmSigner, vmSigner);
        controller.monitorCycleEnd();

        ( , , , CommonUtils.CycleState stateBefore) = controller.getCycleInfo();
        assertEq(uint8(stateBefore), uint8(CommonUtils.CycleState.FINISHED));

        // Disable automation → moves state to SUSPENDED
        vm.prank(admin);
        automationCore.disableAutomation();

        (uint64 indexAfter, , , CommonUtils.CycleState stateAfter) = controller.getCycleInfo();
        assertEq(uint8(stateAfter), uint8(CommonUtils.CycleState.SUSPENDED));

        // Enable automation
        vm.prank(admin);
        automationCore.enableAutomation();

        uint64[] memory tasks = new uint64[](1);
        tasks[0] = 0;

        vm.expectEmit(true, false, false, false);
        emit AutomationController.RemovedTasks(tasks);

        vm.prank(vmSigner, vmSigner);
        controller.processTasks(indexAfter, tasks);

        (uint64 newIndex, uint64 newStart, uint64 newDuration, CommonUtils.CycleState newState) = controller.getCycleInfo();
        assertEq(newIndex, indexAfter + 1);
        assertEq(newStart, uint64(block.timestamp));
        assertEq(newDuration, 2000);
        assertEq(uint8(newState), uint8(CommonUtils.CycleState.STARTED));
        assertFalse(registry.ifTaskExists(tasks[0]));
    }

    /// @dev Test to ensure 'processTasks' reverts if invalid cycle index is passed when cycle state is SUSPENDED.
    function testProcessTasksRevertsIfInvalidCycleIndexWhenCycleStateSuspended() public {
        registerTask();

        ( , uint64 start, uint64 duration, ) = controller.getCycleInfo();
        vm.warp(start + duration);

        // Moves state to FINISHED
        vm.prank(vmSigner, vmSigner);
        controller.monitorCycleEnd();

        ( , , , CommonUtils.CycleState stateBefore) = controller.getCycleInfo();
        assertEq(uint8(stateBefore), uint8(CommonUtils.CycleState.FINISHED));

        // Disable automation → moves state to SUSPENDED
        vm.prank(admin);
        automationCore.disableAutomation();

        (uint64 indexAfter, , , CommonUtils.CycleState stateAfter) = controller.getCycleInfo();
        assertEq(uint8(stateAfter), uint8(CommonUtils.CycleState.SUSPENDED));

        uint64[] memory tasks = new uint64[](1);
        tasks[0] = 0;

        vm.expectRevert(IAutomationController.InvalidInputCycleIndex.selector);
        
        vm.prank(vmSigner, vmSigner);
        controller.processTasks(indexAfter + 1, tasks);
    }

    /// @dev Test to ensure 'tryMoveToSuspendedState' reverts if caller is not AutomationCore.
    function testTryMoveToSuspendedStateRevertsIfNotAutomationCore() public {
        vm.expectRevert(IAutomationController.CallerNotAutomationCore.selector);

        vm.prank(address(registry));
        controller.tryMoveToSuspendedState();
    }

    /// @dev Test to ensure 'moveToStartedState' reverts if caller is not AutomationCore.
    function testMoveToStartedStateRevertsIfNotAutomationCore() public {
        vm.expectRevert(IAutomationController.CallerNotAutomationCore.selector);

        vm.prank(address(registry));
        controller.moveToStartedState();
    }

    /// @dev Test to ensure 'updateCyleDuration' reverts if caller is not AutomationCore.
    function testUpdateCyleDurationRevertsIfNotAutomationCore() public {
        vm.expectRevert(IAutomationController.CallerNotAutomationCore.selector);

        vm.prank(address(registry));
        controller.updateCyleDuration(3800);
    }

    /// @dev Helper function to register a UST.
    function registerTask() private {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 
        
        vm.startPrank(alice);
        erc20Supra.nativeToErc20Supra{value: 5 ether}();
        erc20Supra.approve(address(automationCore), type(uint256).max);

        registry.register(
            payload,
            uint64(block.timestamp + 2250),
            keccak256("txHash"),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            2,
            0,
            auxData
        );
        vm.stopPrank();
    }

    /// @dev Helper function to return payload.
    /// @param _value Value to be sent along with transaction.
    /// @param _target Address of destination smart contract.
    function createPayload(uint128 _value, address _target) private pure returns (bytes memory) {
        LibConfig.AccessListEntry[] memory accessList = new LibConfig.AccessListEntry[](2);
        
        bytes32[] memory keys = new bytes32[](2); 
        keys[0] = bytes32(uint256(0));
        keys[1] = bytes32(uint256(1));

        accessList[0] = LibConfig.AccessListEntry({
            addr: address(0x1111),
            storageKeys: keys
        });

        accessList[1] = LibConfig.AccessListEntry({
            addr: address(0x2222),
            storageKeys: keys
        });

        bytes memory callData = abi.encodeCall(ERC20Supra.erc20SupraToNative, 100);
        bytes memory payload = abi.encode(_value, _target, callData, accessList);

        return payload;   
    }
}