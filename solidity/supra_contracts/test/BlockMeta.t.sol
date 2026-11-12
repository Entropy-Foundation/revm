// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {BlockMeta} from "../src/BlockMeta.sol";
import {MultiSignatureWallet} from "../src/MultiSignatureWallet.sol";
import {MultisigBeacon} from "../src/MultisigBeacon.sol";
import {Counter} from "./Counter.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {IBlockMeta} from "../src/interfaces/IBlockMeta.sol";
import {IMultiSignatureWallet} from "../src/interfaces/IMultiSignatureWallet.sol";

contract BlockMetaTest is Test {
    BlockMeta blockMeta;                        // BlockMeta instance on proxy address
    Counter counter;                            // Counter instance on proxy address
    address counterAddress;
    bytes4 selector;

    address admin = address(0xA11CE);
    address vmAddress = address(0x99);
    address alice = address(0x123);

    /// @dev Sets up initial state for testing.
    /// @dev Deploys and initializes BlockMeta and AutomationController contracts.
    function setUp() public {
        vm.startPrank(admin);

        // Deploy BlockMeta proxy
        BlockMeta blockMetaImpl = new BlockMeta();
        bytes memory blockMetaInitData = abi.encodeCall(BlockMeta.initialize, (admin, 1_000_000));
        ERC1967Proxy blockMetaProxy = new ERC1967Proxy(address(blockMetaImpl), blockMetaInitData);
        blockMeta = BlockMeta(address(blockMetaProxy));

	    Counter counterImpl = new Counter();
        bytes memory counterInitData = abi.encodeCall(Counter.initialize, (address(blockMeta)));
        ERC1967Proxy counterProxy = new ERC1967Proxy(address(counterImpl), counterInitData);
        counter = Counter(address(counterProxy));

	    counterAddress = address(counter);
	    selector = Counter.increment.selector;

        vm.stopPrank();
    }

    uint64 constant DEFAULT_GAS = 50_000;

    /// @dev Helper function to register a selector with a default gas limit.
    /// @param _targetContract The target contract address.
    /// @param _selector Function selector to register.
    function register(address _targetContract, bytes4 _selector) private {
        register(_targetContract, _selector, DEFAULT_GAS);
    }

    function register(address _targetContract, bytes4 _selector, uint64 _gasLimit) private {
        vm.prank(admin);
        blockMeta.register(_targetContract, _selector, _gasLimit);
    }

    /// @dev Test to ensure 'register' registers a selector.
    function testRegister() public {
        address[] memory targets;
        bytes4[] memory selectors;
        (targets, selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 0);
        assertEq(selectors.length, 0);
        assertEq(blockMeta.totalGasAllocated(), 0);

        register(counterAddress, selector);

        (targets, selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 1);
        assertEq(selectors.length, 1);
        assertEq(targets[0], counterAddress);
        assertEq(selectors[0], selector);
        assertEq(blockMeta.totalGasAllocated(), DEFAULT_GAS);
    }

    /// @dev Test to ensure 'register' emits event 'SelectorRegistered'.
    function testRegisterEmitsEvent() public {
        vm.expectEmit(true, true, true, false);
        emit IBlockMeta.SelectorRegistered(counterAddress, selector, DEFAULT_GAS);

        register(counterAddress, selector);
    }

    /// @dev Test to ensure 'register' reverts if caller is not owner.
    function testRegisterRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        blockMeta.register(counterAddress, selector, DEFAULT_GAS);
    }

    /// @dev Test to ensure 'register' reverts if address(0) is passed.
    function testRegisterRevertsIfAddressZero() public {
        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);

        register(address(0), selector);
    }

    /// @dev Test to ensure 'register' reverts if EOA is passed.
    function testRegisterRevertsIfEOA() public {
        vm.expectRevert(LibUtils.AddressCannotBeEOA.selector);

        register(alice, selector);
    }

    /// @dev Test to ensure 'register' reverts if empty selector is passed.
    function testRegisterRevertsIfEmptySelector() public {
        vm.expectRevert(IBlockMeta.InvalidSelector.selector);

        register(counterAddress, bytes4(0));
    }

    /// @dev Test to ensure 'register' reverts if gas limit is zero.
    function testRegisterRevertsIfGasLimitZero() public {
        vm.expectRevert(IBlockMeta.InvalidGasLimit.selector);
        register(counterAddress, selector, 0);
    }

    /// @dev Test to ensure 'register' reverts if total allocated gas exceeds the cap.
    function testRegisterRevertsIfGasCapExceeded() public {
        register(counterAddress, selector, 800_000);

        vm.expectRevert(IBlockMeta.GasCapExceeded.selector);
        register(counterAddress, bytes4(keccak256("foo()")), 200_001);
    }

    /// @dev Test to ensure 'register' accepts a total exactly at the 63/64 forwarding-rule
    /// bound of 'blockPrologueGasCap' (1_000_000 set in setUp -> bound is exactly 984_375).
    function testRegisterAtExact63_64BoundarySucceeds() public {
        register(counterAddress, selector, 984_375);
        assertEq(blockMeta.totalGasAllocated(), 984_375);
    }

    /// @dev Test to ensure 'register' reverts one gas unit above the 63/64 forwarding-rule
    /// bound, even though it is still within the raw 'blockPrologueGasCap' of 1_000_000.
    function testRegisterOneGasAbove63_64BoundaryReverts() public {
        vm.expectRevert(IBlockMeta.GasCapExceeded.selector);
        register(counterAddress, selector, 984_376);
    }

    /// @dev Test to ensure 'register' reverts if selector already exists.
    function testRegisterRevertsIfSelectorAlreadyExists() public {
        testRegister();

        vm.expectRevert(IBlockMeta.SelectorAlreadyRegistered.selector);
        register(counterAddress, selector);
    }

    /// @dev Test to ensure 'deregister' deregisters a selector.
    function testDeregister() public {
        bytes4 foo = bytes4(keccak256("foo()"));
        register(counterAddress, selector);
        register(counterAddress, foo);

        address[] memory targets;
        bytes4[] memory selectors;
        (targets, selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 2);
        assertEq(selectors.length, 2);
        assertEq(targets[0], counterAddress);
        assertEq(targets[1], counterAddress);
        assertEq(selectors[0], selector);
        assertEq(selectors[1], foo);
        assertEq(blockMeta.totalGasAllocated(), DEFAULT_GAS * 2);

        vm.prank(admin);
        blockMeta.deregister(counterAddress, selector);

        (targets, selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 1);
        assertEq(selectors.length, 1);
        assertEq(targets[0], counterAddress);
        assertEq(selectors[0], foo);
        assertEq(blockMeta.totalGasAllocated(), DEFAULT_GAS);
    }

    /// @dev Test to ensure 'deregister' emits event 'SelectorDeregistered'.
    function testDeregisterEmitsEvent() public {
        testRegister();

        vm.expectEmit(true, true, true, false);
        emit IBlockMeta.SelectorDeregistered(counterAddress, selector, DEFAULT_GAS);

        vm.prank(admin);
        blockMeta.deregister(counterAddress, selector);
    }

    /// @dev Test to ensure 'deregister' reverts if caller is not owner.
    function testDeregisterRevertsIfNotOwner() public {
        testRegister();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        blockMeta.deregister(counterAddress, selector);
    }

    /// @dev Test to ensure 'deregister' reverts if selector does not exist.
    function testDeregisterRevertsIfSelectorDoesNotExist() public {
        testRegister();

        bytes4 invalidSelector = bytes4(keccak256("foo()"));

        vm.expectRevert(IBlockMeta.SelectorNotRegistered.selector);
        
        vm.prank(admin);
        blockMeta.deregister(counterAddress, invalidSelector);
    }

    /// @dev Test to ensure 'deregisterAt' deregisters a selector at an index.
    function testDeregisterAt() public {
        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;
        register(counterAddress, selector);
        register(address(failingContract), failSelector);
        
        address[] memory targets;
        bytes4[] memory selectors;
        (targets, selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 2);
        assertEq(selectors.length, 2);
        assertEq(targets[0], counterAddress);
        assertEq(targets[1], address(failingContract));
        assertEq(selectors[0], selector);
        assertEq(selectors[1], failSelector);

        vm.prank(admin);
        blockMeta.deregisterAt(0);

        (targets, selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 1);
        assertEq(selectors.length, 1);
        assertEq(targets[0], address(failingContract));
        assertEq(selectors[0], failSelector);
    }

    /// @dev Test to ensure 'deregisterAt' emits event 'SelectorDeregistered'.
    function testDeregisterAtEmitsEvent() public {
        testRegister();

        vm.expectEmit(true, true, true, false);
        emit IBlockMeta.SelectorDeregistered(counterAddress, selector, DEFAULT_GAS);

        vm.prank(admin);
        blockMeta.deregisterAt(0);
    }
    
    /// @dev Test to ensure 'deregisterAt' reverts if caller is not owner.
    function testDeregisterAtRevertsIfNotOwner() public {
        testRegister();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        blockMeta.deregisterAt(0);
    }

    /// @dev Test to ensure 'deregisterAt' reverts if invalid index is passed.
    function testDeregisterAtRevertsIfInvalidIndex() public {
        testRegister();

        vm.expectRevert(IBlockMeta.InvalidIndex.selector);

        vm.prank(admin);
        blockMeta.deregisterAt(1);
    }

    /// @dev Test to ensure 'updateExecutionOrder' updates the execution order.
    function testUpdateExecutionOrder() public {
        testRegister();

        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;

        uint256[] memory executionOrder = new uint256[](2);
        executionOrder[0] = packExecution(address(failingContract), failSelector, DEFAULT_GAS);
        executionOrder[1] = packExecution(counterAddress, selector, DEFAULT_GAS);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);

        (address[] memory targets, bytes4[] memory selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 2);
        assertEq(selectors.length, 2);
        assertEq(targets[0], address(failingContract));
        assertEq(targets[1], counterAddress);
        assertEq(selectors[0], failSelector);
        assertEq(selectors[1], selector);
    }

    /// @dev Test to ensure 'updateExecutionOrder' emits event 'ExecutionOrderUpdated'.
    function testUpdateExecutionOrderEmitsEvent() public {
        testRegister();

        uint256[] memory executionOrder = createExecutionOrder();

        vm.expectEmit(address(blockMeta));
        emit IBlockMeta.ExecutionOrderUpdated(executionOrder);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts if caller is not owner.
    function testUpdateExecutionOrderRevertsIfNotOwner() public {
        uint256[] memory executionOrder = createExecutionOrder();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        blockMeta.updateExecutionOrder(executionOrder);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts if address(0) is passed as target.
    function testUpdateExecutionOrderRevertsIfTargetAddressZero() public {
        uint256[] memory executionOrder = new uint256[](2);
        executionOrder[0] = packExecution(counterAddress, selector, DEFAULT_GAS);
        executionOrder[1] = packExecution(address(0), selector, DEFAULT_GAS);

        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts if EOA is passed as target.
    function testUpdateExecutionOrderRevertsIfTargetAddressEOA() public {
        uint256[] memory executionOrder = new uint256[](2);
        executionOrder[0] = packExecution(counterAddress, selector, DEFAULT_GAS);
        executionOrder[1] = packExecution(alice, selector, DEFAULT_GAS);

        vm.expectRevert(LibUtils.AddressCannotBeEOA.selector);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts if empty selector is passed
    function testUpdateExecutionOrderRevertsIfEmptySelector() public {
        uint256[] memory executionOrder = new uint256[](2);
        executionOrder[0] = packExecution(counterAddress, selector, DEFAULT_GAS);
        executionOrder[1] = packExecution(counterAddress, bytes4(0), DEFAULT_GAS);

        vm.expectRevert(IBlockMeta.InvalidSelector.selector);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts if zero gas limit is passed.
    function testUpdateExecutionOrderRevertsIfGasLimitZero() public {
        uint256[] memory executionOrder = new uint256[](1);
        executionOrder[0] = packExecution(counterAddress, selector, 0);

        vm.prank(admin);
        vm.expectRevert(IBlockMeta.InvalidGasLimit.selector);
        blockMeta.updateExecutionOrder(executionOrder);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts if duplicate selector is passed.
    function testUpdateExecutionOrderRevertsIfDuplicateSelector() public {
        uint256[] memory executionOrder = new uint256[](2);
        executionOrder[0] = packExecution(counterAddress, selector, DEFAULT_GAS);
        executionOrder[1] = packExecution(counterAddress, selector, DEFAULT_GAS);

        vm.expectRevert(IBlockMeta.SelectorAlreadyRegistered.selector);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);
    }
    
    /// @dev Test to ensure 'updateExecutionOrder' decreases execution order length.
    function testUpdateExecutionOrderDecreasesExecutionOrder() public {
        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;

        register(counterAddress, selector);
        register(address(failingContract), failSelector);

        address[] memory targetsList;
        bytes4[] memory selectorsList;
        (targetsList, selectorsList) = blockMeta.getExecutions();
        assertEq(targetsList.length, 2);
        assertEq(selectorsList.length, 2);
        assertEq(targetsList[0], counterAddress);
        assertEq(targetsList[1], address(failingContract));
        assertEq(selectorsList[0], selector);
        assertEq(selectorsList[1], failSelector);

        uint256[] memory executionOrder = new uint256[](1);
        executionOrder[0] = packExecution(address(failingContract), failSelector, DEFAULT_GAS);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);

        (targetsList, selectorsList) = blockMeta.getExecutions();
        assertEq(targetsList.length, 1);
        assertEq(selectorsList.length, 1);
        assertEq(targetsList[0], address(failingContract));
        assertEq(selectorsList[0], failSelector);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts if total gas exceeds the block prologue gas cap.
    function testUpdateExecutionOrderRevertsIfGasCapExceeded() public {
        uint256[] memory executionOrder = new uint256[](2);
        executionOrder[0] = packExecution(counterAddress, selector, 600_000);
        executionOrder[1] = packExecution(counterAddress, bytes4(keccak256("foo()")), 600_000);

        vm.prank(admin);
        vm.expectRevert(IBlockMeta.GasCapExceeded.selector);
        blockMeta.updateExecutionOrder(executionOrder);
    }

    /// @dev Test to ensure 'updateExecutionOrder' accepts a total exactly at the 63/64
    /// forwarding-rule bound of 'blockPrologueGasCap' (1_000_000 set in setUp -> bound is
    /// exactly 984_375).
    function testUpdateExecutionOrderAtExact63_64BoundarySucceeds() public {
        uint256[] memory executionOrder = new uint256[](1);
        executionOrder[0] = packExecution(counterAddress, selector, 984_375);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);

        assertEq(blockMeta.totalGasAllocated(), 984_375);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts one gas unit above the 63/64
    /// forwarding-rule bound, even though it is still within the raw 'blockPrologueGasCap'.
    function testUpdateExecutionOrderOneGasAbove63_64BoundaryReverts() public {
        uint256[] memory executionOrder = new uint256[](1);
        executionOrder[0] = packExecution(counterAddress, selector, 984_376);

        vm.prank(admin);
        vm.expectRevert(IBlockMeta.GasCapExceeded.selector);
        blockMeta.updateExecutionOrder(executionOrder);
    }

    /// @dev Test to ensure 'updateExecutionOrder' replaces (rather than accumulates on top of)
    /// the previously tracked 'totalGasAllocated', even when entries already existed.
    function testUpdateExecutionOrderReplacesTotalGasAllocated() public {
        register(counterAddress, selector, DEFAULT_GAS);
        register(counterAddress, bytes4(keccak256("foo()")), DEFAULT_GAS);
        assertEq(blockMeta.totalGasAllocated(), DEFAULT_GAS * 2);

        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;

        uint256[] memory executionOrder = new uint256[](1);
        executionOrder[0] = packExecution(address(failingContract), failSelector, DEFAULT_GAS);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);

        // If the running total carried over the pre-existing allocation instead of being
        // reset, this would read DEFAULT_GAS * 3 instead of DEFAULT_GAS.
        assertEq(blockMeta.totalGasAllocated(), DEFAULT_GAS);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts if passed an empty array.
    function testUpdateExecutionOrderRevertsIfEmptyArray() public {
        vm.prank(admin);
        vm.expectRevert(IBlockMeta.InvalidExecutionsLength.selector);
        blockMeta.updateExecutionOrder(new uint256[](0));
    }

    /// @dev Test to ensure 'blockPrologue' executes.
    function testBlockPrologue() public {
        assertEq(counter.counter(), 0);
        testRegister();

        vm.prank(LibUtils.VM_SIGNER);
        blockMeta.blockPrologue();
        assertEq(counter.counter(), 1);
    }

    /// @dev Test to ensure 'blockPrologue' reverts if caller is not VM Signer.
    function testBlockPrologueRevertsIfNotVmSigner() public {
        vm.expectRevert(IBlockMeta.CallerNotVmSigner.selector);

        vm.prank(alice);
        blockMeta.blockPrologue();
    }

    /// @dev Test to ensure 'blockPrologue' emits 'CallFailed' when a registered function reverts.
    function testBlockPrologueEmitsCallFailed() public {
        // Deploy a contract with a failing function
        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;

        register(address(failingContract), failSelector);

        vm.expectEmit(true, true, false, true);
        emit IBlockMeta.CallFailed(address(failingContract), failSelector, abi.encodeWithSignature("Fail()"));

        vm.prank(LibUtils.VM_SIGNER);
        blockMeta.blockPrologue();
    }

    /// @dev Test to ensure 'blockPrologue' emits 'CallSucceeded' for a successful call.
    function testBlockPrologueEmitsCallSucceeded() public {
        register(counterAddress, selector);

        vm.expectEmit(true, true, false, false);
        emit IBlockMeta.CallSucceeded(counterAddress, selector);

        vm.prank(LibUtils.VM_SIGNER);
        blockMeta.blockPrologue();
    }

    /// @dev Test to ensure 'blockPrologue' continues execution even if a call fails.
    function testBlockPrologueContinuesAfterACallFails() public {
        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;

        register(address(failingContract), failSelector);
        register(counterAddress, selector);

        assertEq(counter.counter(), 0);

        // Expect the failing call event
        vm.expectEmit(true, true, false, true);
        emit IBlockMeta.CallFailed(address(failingContract), failSelector, abi.encodeWithSignature("Fail()"));

        // Expect the successful call event
        vm.expectEmit(true, true, false, false);
        emit IBlockMeta.CallSucceeded(counterAddress, selector);

        vm.prank(LibUtils.VM_SIGNER);
        blockMeta.blockPrologue();

        // Counter must still be incremented even though the first call failed
        assertEq(counter.counter(), 1);
    }

    /// @dev Verifies the per-call gas cap is enforced in blockPrologue.
    /// Registers three entries: one with sufficient gas (succeeds),
    /// one with starved gas (fails, OOG), and another with sufficient gas (succeeds).
    /// Asserts that a gas-starved call does not halt execution of subsequent entries.
    function testBlockPrologueEnforcesGasLimit() public {
        bytes4 updateSelector = Counter.update.selector;
        bytes4 viewSelector = Counter.isNotDivisibleBy3.selector;

        // 1. Sufficient gas
        register(counterAddress, selector, 100_000);
        // 2. Starved gas — call fails
        register(counterAddress, updateSelector, 200);
        // 3. Sufficient gas — proves loop continues
        register(counterAddress, viewSelector, 100_000);

        vm.expectEmit(true, true, false, false);
        emit IBlockMeta.CallSucceeded(counterAddress, selector);

        vm.expectEmit(true, true, false, true);
        emit IBlockMeta.CallFailed(counterAddress, updateSelector, "");

        vm.expectEmit(true, true, false, false);
        emit IBlockMeta.CallSucceeded(counterAddress, viewSelector);

        vm.prank(LibUtils.VM_SIGNER);
        blockMeta.blockPrologue();

        assertEq(counter.counter(), 1);
    }

    /// @dev Test to ensure 'setBlockPrologueGasCap' reverts if caller is not the owner.
    function testSetBlockPrologueGasCapRevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        blockMeta.setBlockPrologueGasCap(500_000);
    }

    /// @dev Test to ensure 'setBlockPrologueGasCap' reverts if cap is zero.
    function testSetBlockPrologueGasCapRevertsIfZero() public {
        vm.prank(admin);
        vm.expectRevert(IBlockMeta.InvalidGasCap.selector);
        blockMeta.setBlockPrologueGasCap(0);
    }

    /// @dev Test to ensure 'setBlockPrologueGasCap' reverts if new cap is below current total allocated gas.
    function testSetBlockPrologueGasCapRevertsIfBelowAllocated() public {
        register(counterAddress, selector, 50_000);

        vm.prank(admin);
        vm.expectRevert(IBlockMeta.InvalidGasCap.selector);
        blockMeta.setBlockPrologueGasCap(40_000);
    }

    /// @dev Test to ensure 'setBlockPrologueGasCap' accepts a cap whose 63/64 forwarding-rule
    /// bound exactly covers the already-allocated budget (50_794 -> floor(50_794*63/64) ==
    /// 50_000 == DEFAULT_GAS).
    function testSetBlockPrologueGasCapAtExact63_64BoundarySucceeds() public {
        register(counterAddress, selector, DEFAULT_GAS);

        vm.prank(admin);
        blockMeta.setBlockPrologueGasCap(50_794);

        assertEq(blockMeta.blockPrologueGasCap(), 50_794);
    }

    /// @dev Test to ensure 'setBlockPrologueGasCap' reverts one gas unit below the 63/64
    /// boundary (50_793 -> floor(50_793*63/64) == 49_999 < DEFAULT_GAS == 50_000).
    function testSetBlockPrologueGasCapJustBelow63_64BoundaryReverts() public {
        register(counterAddress, selector, DEFAULT_GAS);

        vm.prank(admin);
        vm.expectRevert(IBlockMeta.InvalidGasCap.selector);
        blockMeta.setBlockPrologueGasCap(50_793);
    }

    /// @dev Test to ensure 'setBlockPrologueGasCap' updates the cap.
    function testSetBlockPrologueGasCap() public {
        vm.prank(admin);
        blockMeta.setBlockPrologueGasCap(500_000);
        assertEq(blockMeta.blockPrologueGasCap(), 500_000);
    }

    /// @dev Test to ensure 'setBlockPrologueGasCap' emits 'BlockPrologueGasCapUpdated'.
    function testSetBlockPrologueGasCapEmitsEvent() public {
        uint64 newCap = 500_000;

        vm.expectEmit(true, false, false, false);
        emit IBlockMeta.BlockPrologueGasCapUpdated(newCap);
        
        vm.prank(admin);
        blockMeta.setBlockPrologueGasCap(newCap);
    }

    /// @dev Test to ensure 'blockPrologueGasCap' returns the gas cap set.
    function testBlockPrologueGasCap() public {
        assertEq(blockMeta.blockPrologueGasCap(), 1_000_000);
    }

    /// @dev Test to ensure 'totalGasAllocated' returns the sum of all registered gas limits.
    function testTotalGasAllocated() public {
        assertEq(blockMeta.totalGasAllocated(), 0);

        register(counterAddress, selector, 50_000);
        assertEq(blockMeta.totalGasAllocated(), 50_000);

        vm.prank(admin);
        blockMeta.deregister(counterAddress, selector);
        assertEq(blockMeta.totalGasAllocated(), 0);
    }

    /// @dev Test to ensure 'register' succeeds again once 'deregister' frees enough budget
    /// under a gas cap that was fully consumed.
    function testRegisterSucceedsAfterDeregisterFreesBudget() public {
        // 50_794 is the smallest cap whose 63/64-forwarding-rule bound
        // (floor(50_794 * 63 / 64) == 50_000) exactly covers a single DEFAULT_GAS entry,
        // so it fits one but not two.
        uint64 cap = 50_794;
        vm.prank(admin);
        blockMeta.setBlockPrologueGasCap(cap);

        register(counterAddress, selector, DEFAULT_GAS);

        bytes4 foo = bytes4(keccak256("foo()"));
        vm.expectRevert(IBlockMeta.GasCapExceeded.selector);
        register(counterAddress, foo, DEFAULT_GAS);

        vm.prank(admin);
        blockMeta.deregister(counterAddress, selector);

        register(counterAddress, foo, DEFAULT_GAS);

        assertEq(blockMeta.totalGasAllocated(), DEFAULT_GAS);
        (address[] memory targets, bytes4[] memory selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 1);
        assertEq(targets[0], counterAddress);
        assertEq(selectors[0], foo);
    }

    /// @dev Test to ensure 'getExecutions' returns the execution order.
    function testGetExecutions() public {
        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;
        bytes4 foo = bytes4(keccak256("foo()"));

        register(counterAddress, selector);
        register(address(failingContract), failSelector);
        register(counterAddress, foo);

        (address[] memory targets, bytes4[] memory selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 3);
        assertEq(targets[0], counterAddress);
        assertEq(targets[1], address(failingContract));
        assertEq(targets[2], counterAddress);

        assertEq(selectors.length, 3);
        assertEq(selectors[0], selector);
        assertEq(selectors[1], failSelector);
        assertEq(selectors[2], foo);
    }

    /// @dev Test to ensure 'getTargetContracts' works correctly.
    function testGetTargetContracts() public {
        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;

        register(counterAddress, selector);
        register(address(failingContract), failSelector);
        register(counterAddress, bytes4(keccak256("foo()")));

        address[] memory targets = blockMeta.getTargetContracts();
        assertEq(targets.length, 2);
        assertEq(targets[0], counterAddress);
        assertEq(targets[1], address(failingContract));
    }

    /// @dev Test to ensure 'getSelectors' works correctly.
    function testGetSelectors() public {
        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;
        bytes4 foo = bytes4(keccak256("foo()"));

        register(counterAddress, selector);
        register(address(failingContract), failSelector);
        register(counterAddress, foo);

        bytes4[] memory selectors = blockMeta.getSelectors(counterAddress);
        assertEq(selectors.length, 2);
        assertEq(selectors[0], selector);
        assertEq(selectors[1], foo);
    }

    /// @dev Test to ensure 'getExecutionAt' returns an execution entry.
    function testGetExecutionAt() public {
        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;

        register(counterAddress, selector);
        register(address(failingContract), failSelector);

        (address target, bytes4 sel) = blockMeta.getExecutionAt(1);
        assertEq(target, address(failingContract));
        assertEq(sel, failSelector);
    }

    /// @dev Test to ensure 'getExecutionAt' reverts if invalid index is passed.
    function testGetExecutionAtRevertsIfInvalidIndex() public {
        testRegister();

        vm.expectRevert(IBlockMeta.InvalidIndex.selector);
        blockMeta.getExecutionAt(1);
    }

    /// @dev Test to ensure 'getExecutionIndex' returns the index for a target address and selector.
    function testGetExecutionIndex() public {
        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;

        register(counterAddress, selector);
        register(address(failingContract), failSelector);

        assertEq(blockMeta.getExecutionIndex(address(failingContract), failSelector), 1);
    }

    /// @dev Test to ensure 'getExecutionIndex' reverts if selector does not exist.
    function testGetExecutionIndexRevertsIfSelectorDoesNotExist() public {
        vm.expectRevert(IBlockMeta.SelectorNotRegistered.selector);
        
        blockMeta.getExecutionIndex(counterAddress, selector);
    }

    /// @dev Test to ensure 'getExecutionGasLimit' returns the correct gas limit.
    function testGetExecutionGasLimit() public {
        register(counterAddress, selector, 80_000);
        assertEq(blockMeta.getExecutionGasLimit(counterAddress, selector), 80_000);
    }

    /// @dev Test to ensure 'getExecutionGasLimit' reverts if the pair is not registered.
    function testGetExecutionGasLimitRevertsIfNotRegistered() public {
        vm.expectRevert(IBlockMeta.SelectorNotRegistered.selector);
        blockMeta.getExecutionGasLimit(counterAddress, selector);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'upgradeToAndCall' :::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'upgradeToAndCall' upgrades the proxy to a new implementation.
    function testUpgradeToAndCall() public {
        register(counterAddress, selector);

        vm.startPrank(admin);
        BlockMeta newImpl = new BlockMeta();
        blockMeta.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();

        assertEq(address(uint160(uint256(vm.load(address(blockMeta), ERC1967Utils.IMPLEMENTATION_SLOT)))), address(newImpl));
        
        register(counterAddress, bytes4(keccak256("foo()")));
        (address[] memory targets, bytes4[] memory selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 2);
        assertEq(selectors.length, 2);
    }

    /// @dev Test to ensure 'upgradeToAndCall' reverts if caller is not the owner.
    function testUpgradeToAndCallRevertsIfNotOwner() public {
        vm.prank(admin);
        BlockMeta newImpl = new BlockMeta();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        blockMeta.upgradeToAndCall(address(newImpl), "");
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to ownership (Entropy-Foundation/smr-moonshot#4936) :::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev A second BlockMeta implementation for the ownership helpers' upgrade checks, deployed on first use and
    ///      reused, so a test that checks owner powers several times pays for one deployment. Upgrading a proxy to
    ///      the implementation it already runs is allowed, so reuse does not weaken the check.
    BlockMeta private spareImpl;

    function spareImplementation() private returns (BlockMeta) {
        if (address(spareImpl) == address(0)) {
            spareImpl = new BlockMeta();
        }
        return spareImpl;
    }

    /// @dev Asserts that `_account` can use every owner-only BlockMeta entry point: register, the gas cap
    ///      setter and the UUPS upgrade authorisation. Each call leaves the contract usable for the next.
    function assertHasOwnerPowers(address _account) private {
        BlockMeta newImpl = spareImplementation();

        vm.startPrank(_account);
        blockMeta.register(counterAddress, selector, DEFAULT_GAS);
        blockMeta.deregister(counterAddress, selector);
        blockMeta.setBlockPrologueGasCap(2_000_000);
        blockMeta.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();

        assertEq(blockMeta.blockPrologueGasCap(), 2_000_000);
        assertEq(address(uint160(uint256(vm.load(address(blockMeta), ERC1967Utils.IMPLEMENTATION_SLOT)))), address(newImpl));
    }

    /// @dev Asserts that `_account` is refused by every owner-only BlockMeta entry point.
    function assertHasNoOwnerPowers(address _account) private {
        bytes memory unauthorized = abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, _account);
        BlockMeta newImpl = spareImplementation();

        vm.expectRevert(unauthorized);
        vm.prank(_account);
        blockMeta.register(counterAddress, selector, DEFAULT_GAS);

        vm.expectRevert(unauthorized);
        vm.prank(_account);
        blockMeta.setBlockPrologueGasCap(2_000_000);

        vm.expectRevert(unauthorized);
        vm.prank(_account);
        blockMeta.upgradeToAndCall(address(newImpl), "");
    }

    /// @dev 'renounceOwnership' is always refused for the owner, and the owner keeps every owner-only power.
    function testRenounceOwnershipReverts() public {
        vm.expectRevert(IBlockMeta.OwnershipRenunciationDisabled.selector);
        vm.prank(admin);
        blockMeta.renounceOwnership();

        assertEq(blockMeta.owner(), admin);
        assertEq(blockMeta.pendingOwner(), address(0));
        assertHasOwnerPowers(admin);
    }

    /// @dev A non-owner calling 'renounceOwnership' gets the ordinary access error, not the renunciation one.
    function testRenounceOwnershipRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        blockMeta.renounceOwnership();

        assertEq(blockMeta.owner(), admin);
    }

    /// @dev 'transferOwnership' only nominates: the owner is unchanged and keeps its powers, the nominee has none yet.
    function testTransferOwnershipSetsPendingOwner() public {
        vm.expectEmit(true, true, false, false, address(blockMeta));
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(admin, alice);
        vm.prank(admin);
        blockMeta.transferOwnership(alice);

        assertEq(blockMeta.owner(), admin);
        assertEq(blockMeta.pendingOwner(), alice);
        assertHasNoOwnerPowers(alice);
        assertHasOwnerPowers(admin);
    }

    /// @dev 'transferOwnership' is owner-only.
    function testTransferOwnershipRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        blockMeta.transferOwnership(alice);

        assertEq(blockMeta.pendingOwner(), address(0));
    }

    /// @dev The nominee completes the transfer with 'acceptOwnership': ownership and every owner-only power move,
    ///      and the pending slot is cleared.
    function testAcceptOwnership() public {
        vm.prank(admin);
        blockMeta.transferOwnership(alice);

        vm.expectEmit(true, true, false, false, address(blockMeta));
        emit OwnableUpgradeable.OwnershipTransferred(admin, alice);
        vm.prank(alice);
        blockMeta.acceptOwnership();

        assertEq(blockMeta.owner(), alice);
        assertEq(blockMeta.pendingOwner(), address(0));
        assertHasNoOwnerPowers(admin);
        assertHasOwnerPowers(alice);
    }

    /// @dev Only the nominee can accept, including the current owner and when nobody is nominated.
    function testAcceptOwnershipRevertsIfNotPendingOwner() public {
        // Nobody nominated: pendingOwner is zero, so no caller matches.
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        blockMeta.acceptOwnership();

        vm.prank(admin);
        blockMeta.transferOwnership(alice);

        address bob = address(0xB0B);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        blockMeta.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, admin));
        vm.prank(admin);
        blockMeta.acceptOwnership();

        assertEq(blockMeta.owner(), admin);
        assertEq(blockMeta.pendingOwner(), alice);
    }

    /// @dev A nomination of the wrong address is corrected by the owner: a new nomination replaces it (and the
    ///      replaced nominee can no longer accept), and nominating zero cancels it.
    function testOwnershipTransferMistakeIsRecoverable() public {
        address wrongAddress = address(0xBAD);

        vm.prank(admin);
        blockMeta.transferOwnership(wrongAddress);
        assertEq(blockMeta.owner(), admin);

        // Cancel by nominating zero; the wrong nominee cannot accept any more.
        vm.prank(admin);
        blockMeta.transferOwnership(address(0));
        assertEq(blockMeta.pendingOwner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, wrongAddress));
        vm.prank(wrongAddress);
        blockMeta.acceptOwnership();

        // Nominate the wrong address again, then replace it with the intended one.
        vm.prank(admin);
        blockMeta.transferOwnership(wrongAddress);
        vm.prank(admin);
        blockMeta.transferOwnership(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, wrongAddress));
        vm.prank(wrongAddress);
        blockMeta.acceptOwnership();

        vm.prank(alice);
        blockMeta.acceptOwnership();
        assertEq(blockMeta.owner(), alice);
        assertEq(blockMeta.pendingOwner(), address(0));
    }

    /// @dev Helper function to pack a target contract address, function selector, and gas limit into a single uint256 execution entry.
    function packExecution(address _targetContract, bytes4 _selector, uint64 _gasLimit) private pure returns (uint256) {
        // Layout: [target[160] | selector[32] | gasLimit[64]]
        return (uint256(uint160(_targetContract)) << 96)  | (uint256(uint32(_selector)) << 64) | _gasLimit;
    }

    /// @dev Helper function to return an execution order.
    function createExecutionOrder() private returns (uint256[] memory) {
        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;

        uint256[] memory executionOrder = new uint256[](2);
        executionOrder[0] = packExecution(address(failingContract), failSelector, DEFAULT_GAS);
        executionOrder[1] = packExecution(counterAddress, selector, DEFAULT_GAS);
        
        return executionOrder;
    }
}

contract FailingContract {
    error Fail();
    function fail() external pure {
        revert Fail();
    }
}

/// @dev BlockMeta owned by the Foundation multisig, as genesis deploys it: ownership actions reach BlockMeta only
///      as wallet transactions that gather the required confirmations.
contract BlockMetaWalletOwnershipTest is Test {
    MultiSignatureWallet wallet;
    BlockMeta blockMeta;
    Counter counter;

    address ownerA = address(0xA11CE);
    address ownerB = address(0xB0B);
    address nominee = address(0xC0FFEE);

    uint64 constant GAS_CAP = 1_000_000;
    uint64 constant TIMEOUT = 1 hours;

    function setUp() public {
        address[] memory owners = new address[](2);
        owners[0] = ownerA;
        owners[1] = ownerB;

        MultisigBeacon beacon = new MultisigBeacon(address(new MultiSignatureWallet()), address(this));
        BeaconProxy walletProxy =
            new BeaconProxy(address(beacon), abi.encodeCall(MultiSignatureWallet.initialize, (owners, 2)));
        wallet = MultiSignatureWallet(payable(walletProxy));

        ERC1967Proxy blockMetaProxy = new ERC1967Proxy(
            address(new BlockMeta()), abi.encodeCall(BlockMeta.initialize, (address(wallet), GAS_CAP))
        );
        blockMeta = BlockMeta(address(blockMetaProxy));

        Counter counterImpl = new Counter();
        ERC1967Proxy counterProxy =
            new ERC1967Proxy(address(counterImpl), abi.encodeCall(Counter.initialize, (address(blockMeta))));
        counter = Counter(address(counterProxy));
    }

    /// @dev Submits `_data` to BlockMeta as ownerA (which counts as its confirmation) and confirms it as ownerB,
    ///      so the transaction meets the 2-of-2 threshold. Returns its index and content hash for execution.
    function submitAndConfirm(bytes memory _data) private returns (uint256 txIndex, bytes32 contentHash) {
        txIndex = wallet.getNextTransactionIndex();
        vm.prank(ownerA);
        wallet.submitTransaction(address(blockMeta), 0, TIMEOUT, _data);
        contentHash = wallet.getTransactionContentHash(txIndex);
        vm.prank(ownerB);
        wallet.confirmTransaction(txIndex, contentHash);
    }

    /// @dev Submits, confirms and executes `_data` through the wallet; the execution must succeed.
    function executeThroughWallet(bytes memory _data) private {
        (uint256 txIndex, bytes32 contentHash) = submitAndConfirm(_data);
        vm.prank(ownerA);
        wallet.executeTransaction(txIndex, contentHash);
    }

    /// @dev A fully confirmed wallet transaction calling 'renounceOwnership' fails with BlockMeta's renunciation
    ///      error, and the wallet keeps governing BlockMeta afterwards.
    function testWalletRenounceOwnershipIsRefused() public {
        (uint256 txIndex, bytes32 contentHash) = submitAndConfirm(abi.encodeCall(BlockMeta.renounceOwnership, ()));

        vm.expectRevert(
            abi.encodeWithSelector(
                IMultiSignatureWallet.ExecutionFailed.selector,
                abi.encodeWithSelector(IBlockMeta.OwnershipRenunciationDisabled.selector)
            )
        );
        vm.prank(ownerA);
        wallet.executeTransaction(txIndex, contentHash);

        assertEq(blockMeta.owner(), address(wallet));

        executeThroughWallet(abi.encodeCall(IBlockMeta.register, (address(counter), Counter.increment.selector, 50_000)));
        assertEq(blockMeta.getExecutionGasLimit(address(counter), Counter.increment.selector), 50_000);
    }

    /// @dev The wallet hands BlockMeta over in two steps: its transaction only nominates, the wallet stays owner
    ///      until the nominee accepts, and the nominee then holds the owner-only powers.
    function testWalletTransfersOwnershipInTwoSteps() public {
        executeThroughWallet(abi.encodeCall(IBlockMeta.transferOwnership, (nominee)));

        assertEq(blockMeta.owner(), address(wallet));
        assertEq(blockMeta.pendingOwner(), nominee);

        // Still the wallet's to govern while the nomination is pending.
        executeThroughWallet(abi.encodeCall(IBlockMeta.setBlockPrologueGasCap, (2_000_000)));
        assertEq(blockMeta.blockPrologueGasCap(), 2_000_000);

        vm.prank(nominee);
        blockMeta.acceptOwnership();

        assertEq(blockMeta.owner(), nominee);
        assertEq(blockMeta.pendingOwner(), address(0));
        vm.prank(nominee);
        blockMeta.register(address(counter), Counter.increment.selector, 50_000);
    }
}
