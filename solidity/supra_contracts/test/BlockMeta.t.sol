// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from"../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {BlockMeta} from "../src/BlockMeta.sol";
import {Counter} from "./Counter.sol";
import {CommonUtils} from "../src/CommonUtils.sol";

contract BlockMetaTest is Test {
    BlockMeta blockMeta;                        // BlockMeta instance on proxy address
    Counter counter;                            // Counter instance on proxy address
    address counterAddress;
    bytes4 selector;

    address admin = address(0xA11CE);
    address vmAddress = address(0x99);
    address alice = address(0x123);

    // Address of the VM Signer: SUP0
    address constant VM_SIGNER = address(0x53555000);

    /// @dev Sets up initial state for testing.
    /// @dev Deploys and initializes BlockMeta and AutomationController contracts.
    function setUp() public {
        vm.startPrank(admin);

        // Deploy BlockMeta proxy
        BlockMeta blockMetaImpl = new BlockMeta();
        bytes memory blockMetaInitData = abi.encodeCall(BlockMeta.initialize, ());
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
        assertEq(blockMeta.getTargetContracts().length, 0);

        register(counterAddress, selector);

        address[] memory targetContracts = blockMeta.getTargetContracts();
        assertEq(targetContracts.length, 1);
        assertEq(targetContracts[0], counterAddress);

        bytes4[] memory selectors = blockMeta.getSelectors(counterAddress);
        assertEq(selectors.length, 1);
        assertEq(selectors[0], selector);
    }

    /// @dev Test to ensure 'register' emits event 'SelectorRegistered'.
    function testRegisterEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit BlockMeta.SelectorRegistered(counterAddress, selector);

        register(counterAddress, selector);
    }

    /// @dev Test to ensure 'register' reverts if caller is not owner.
    function testRegisterRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        blockMeta.register(counterAddress, selector);
    }

    /// @dev Test to ensure 'register' reverts if address(0) is passed.
    function testRegisterRevertsIfAddressZero() public {
        vm.expectRevert(CommonUtils.AddressCannotBeZero.selector);

        register(address(0), selector);
    }

    /// @dev Test to ensure 'register' reverts if EOA is passed.
    function testRegisterRevertsIfEOA() public {
        vm.expectRevert(CommonUtils.AddressCannotBeEOA.selector);

        register(alice, selector);
    }

    /// @dev Test to ensure 'register' reverts if selector already exists.
    function testRegisterRevertsIfSelectorAlreadyExists() public {
        testRegister();

        vm.expectRevert(BlockMeta.SelectorAlreadyRegistered.selector);
        register(counterAddress, selector);
    }

    /// @dev Test to ensure 'deregister' deregisters a single selector.
    function testDeregisterSingleSelector() public {
        register(counterAddress, selector);
        register(counterAddress, bytes4(keccak256("foo()")));

        assertEq(blockMeta.getTargetContracts().length, 1);
        assertEq(blockMeta.getSelectors(counterAddress).length, 2);

        vm.prank(admin);
        blockMeta.deregister(counterAddress, selector);

        assertEq(blockMeta.getTargetContracts().length, 1);
        assertEq(blockMeta.getSelectors(counterAddress).length, 1);
    }

    /// @dev Test to ensure 'deregister' removes target contract if no selector is left.
    function testDeregisterLastSelectorRemovesTarget() public {
        testRegister();

        vm.prank(admin);
        blockMeta.deregister(counterAddress, selector);

        // Target contract should be removed.        
        assertEq(blockMeta.getTargetContracts().length, 0);

        // Selector should be removed
        assertEq(blockMeta.getSelectors(counterAddress).length, 0);
    }

    /// @dev Test to ensure 'deregister' emits event 'SelectorDeregistered'.
    function testDeregisterEmitsEvent() public {
        testRegister();

        vm.expectEmit(true, true, false, false);
        emit BlockMeta.SelectorDeregistered(counterAddress, selector);

        vm.prank(admin);
        blockMeta.deregister(counterAddress, selector);
    }

    /// @dev Test to ensure 'deregister' reverts if caller is not owner.
    function testDeregisterRevertsIfNotOwner() public {
        testRegister();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        blockMeta.deregister(counterAddress, selector);
    }

    /// @dev Test to ensure 'deregister' reverts if selector does not exist.
    function testDeregisterRevertsIfSelectorDoesNotExist() public {
        testRegister();

        bytes4 invalidSelector = bytes4(keccak256("foo()"));

        vm.expectRevert(BlockMeta.SelectorNotRegistered.selector);
        
        vm.prank(admin);
        blockMeta.deregister(counterAddress, invalidSelector);
    }

    /// @dev Test to ensure 'deregister' reverts if target contract is not registered.
    function testDeregisterRevertsIfTargetNotRegistered() public {
        assertEq(blockMeta.getTargetContracts().length, 0);

        vm.expectRevert(BlockMeta.SelectorNotRegistered.selector);

        vm.prank(admin);
        blockMeta.deregister(counterAddress, selector);
    }

    /// @dev Test to ensure 'blockPrologue' executes.
    function testBlockPrologue() public {
	    assertEq(counter.counter(), 0);
        testRegister();

        vm.prank(VM_SIGNER);
        blockMeta.blockPrologue();
	    assertEq(counter.counter(), 1);
    }

    /// @dev Test to ensure 'blockPrologue' reverts if caller is not VM Signer.
    function testBlockPrologueRevertsIfNotVmSigner() public {
        vm.expectRevert(BlockMeta.CallerNotVmSigner.selector);

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
        emit BlockMeta.CallFailed(address(failingContract), failSelector, abi.encodeWithSignature("Fail()"));

        vm.prank(VM_SIGNER);
        blockMeta.blockPrologue();
    }

    /// @dev Test to ensure 'blockPrologue' emits 'CallSucceeded' for a successful call.
    function testBlockPrologueEmitsCallSucceeded() public {
        register(counterAddress, selector);

        vm.expectEmit(true, true, false, false);
        emit BlockMeta.CallSucceeded(counterAddress, selector);

        vm.prank(VM_SIGNER);
        blockMeta.blockPrologue();
    }
}

contract FailingContract {
    error Fail();
    function fail() external pure {
        revert Fail();
    }
}