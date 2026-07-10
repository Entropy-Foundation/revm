// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {BlockMeta} from "../src/BlockMeta.sol";
import {Counter} from "./Counter.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {IBlockMeta} from "../src/interfaces/IBlockMeta.sol";

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
        bytes memory blockMetaInitData = abi.encodeCall(BlockMeta.initialize, admin);
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

    /// @dev Helper function to register a selector.
    /// @param _targetContract The target contract address.
    /// @param _selector Function selector to register.
    function register(address _targetContract, bytes4 _selector) private {
        vm.prank(admin);
        blockMeta.register(_targetContract, _selector);
    }

    /// @dev Test to ensure 'register' registers a selector.
    function testRegister() public {
        address[] memory targets;
        bytes4[] memory selectors;
        (targets, selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 0);
        assertEq(selectors.length, 0);

        register(counterAddress, selector);

        (targets, selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 1);
        assertEq(selectors.length, 1);
        assertEq(targets[0], counterAddress);
        assertEq(selectors[0], selector);
    }

    /// @dev Test to ensure 'register' emits event 'SelectorRegistered'.
    function testRegisterEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IBlockMeta.SelectorRegistered(counterAddress, selector);

        register(counterAddress, selector);
    }

    /// @dev Test to ensure 'register' reverts if caller is not owner.
    function testRegisterRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        blockMeta.register(counterAddress, selector);
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

        vm.prank(admin);
        blockMeta.deregister(counterAddress, selector);

        (targets, selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 1);
        assertEq(selectors.length, 1);
        assertEq(targets[0], counterAddress);
        assertEq(selectors[0], foo);
    }

    /// @dev Test to ensure 'deregister' emits event 'SelectorDeregistered'.
    function testDeregisterEmitsEvent() public {
        testRegister();

        vm.expectEmit(true, true, false, false);
        emit IBlockMeta.SelectorDeregistered(counterAddress, selector);

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

        vm.expectEmit(true, true, false, false);
        emit IBlockMeta.SelectorDeregistered(counterAddress, selector);

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
        executionOrder[0] = packExecution(address(failingContract), failSelector);
        executionOrder[1] = packExecution(counterAddress, selector); 

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

        vm.expectEmit(true, false, false, false);
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
        executionOrder[0] = packExecution(counterAddress, selector); 
        executionOrder[1] = packExecution(address(0), selector);

        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts if EOA is passed as target.
    function testUpdateExecutionOrderRevertsIfTargetAddressEOA() public {
        uint256[] memory executionOrder = new uint256[](2);
        executionOrder[0] = packExecution(counterAddress, selector); 
        executionOrder[1] = packExecution(alice, selector);

        vm.expectRevert(LibUtils.AddressCannotBeEOA.selector);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts if empty selector is passed
    function testUpdateExecutionOrderRevertsIfEmptySelector() public {
        uint256[] memory executionOrder = new uint256[](2);
        executionOrder[0] = packExecution(counterAddress, selector); 
        executionOrder[1] = packExecution(counterAddress, bytes4(0));

        vm.expectRevert(IBlockMeta.InvalidSelector.selector);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);
    }

    /// @dev Test to ensure 'updateExecutionOrder' reverts if duplicate selector is passed.
    function testUpdateExecutionOrderRevertsIfDuplicateSelector() public {
        uint256[] memory executionOrder = new uint256[](2);
        executionOrder[0] = packExecution(counterAddress, selector); 
        executionOrder[1] = packExecution(counterAddress, selector);

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
        executionOrder[0] = packExecution(address(failingContract), failSelector);

        vm.prank(admin);
        blockMeta.updateExecutionOrder(executionOrder);

        (targetsList, selectorsList) = blockMeta.getExecutions();
        assertEq(targetsList.length, 1);
        assertEq(selectorsList.length, 1);
        assertEq(targetsList[0], address(failingContract));
        assertEq(selectorsList[0], failSelector);
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

    /// @dev Helper function to pack a target contract address and function selector into a single uint256 execution entry.
    function packExecution(address _targetContract, bytes4 _selector) private pure returns (uint256) {
        // Layout: [target[160] | selector[32] | 0[64] ]
        return (uint256(uint160(_targetContract)) << 96)  | (uint256(uint32(_selector)) << 64);
    }

    /// @dev Helper function to return an execution order.
    function createExecutionOrder() private returns (uint256[] memory) {
        FailingContract failingContract = new FailingContract();
        bytes4 failSelector = FailingContract.fail.selector;

        uint256[] memory executionOrder = new uint256[](2);
        executionOrder[0] = packExecution(address(failingContract), failSelector);
        executionOrder[1] = packExecution(counterAddress, selector); 
        
        return executionOrder;
    }
}

contract FailingContract {
    error Fail();
    function fail() external pure {
        revert Fail();
    }
}