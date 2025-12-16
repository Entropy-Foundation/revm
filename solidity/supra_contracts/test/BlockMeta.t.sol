// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from"../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {BlockMeta} from "../src/BlockMeta.sol";
import {BlockBasedCounter} from "./BlockBasedCounter.sol";

contract BlockMetaTest is Test {
    address controller;                         // AutomationController address
    BlockMeta blockMeta;                        // BlockMeta instance on proxy address
    BlockBasedCounter counter;                  // Counter instance for test purposes
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
        bytes memory blockMetaInitData = abi.encodeCall(BlockMeta.initialize, ());
        ERC1967Proxy blockMetaProxy = new ERC1967Proxy(address(blockMetaImpl), blockMetaInitData);
        blockMeta = BlockMeta(address(blockMetaProxy));

	BlockBasedCounter counterImpl = new BlockBasedCounter();
        bytes memory counterInitData = abi.encodeCall(BlockBasedCounter.initialize, (address(blockMeta)));
        ERC1967Proxy counterProxy = new ERC1967Proxy(address(counterImpl), counterInitData);
        counter = BlockBasedCounter(address(counterProxy));

	counterAddress = address(counter);
	selector = BlockBasedCounter.increment.selector;

        vm.stopPrank();
    }

    /// @dev Test to ensure 'register' adds new entry
    function testEntryRegistration() public {
        assertEq(blockMeta.getTargets().length, 0);

        vm.prank(admin);
        blockMeta.register(counterAddress, selector);
        assertEq(blockMeta.getTargets().length, 1);
        assertEq(blockMeta.getSelectors(counterAddress).length, 1);
    }

    /// @dev Test to ensure 'register' emits event 'NewTargetAdded'.
    function testRegisterEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit BlockMeta.NewTargetAdded(counterAddress, selector);

        vm.prank(admin);
        blockMeta.register(counterAddress, selector);
    }

    /// @dev Test to ensure 'register' reverts if caller is not owner.
    function testRegisterRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector,alice));

        vm.prank(alice);
        blockMeta.register(counterAddress, selector);
    }

    /// @dev Test to ensure 'register' reverts if address(0) is passed.
    function testRegisterRevertsIfAddressZero() public {
        vm.expectRevert(BlockMeta.AddressCannotBeZero.selector);

        vm.prank(admin);
        blockMeta.register(address(0), selector);
    }

    /// @dev Test to ensure 'register' reverts if EOA is passed.
    function testRegisterRevertsIfEOA() public {
        vm.expectRevert(BlockMeta.AddressCannotBeEOA.selector);

        vm.prank(admin);
        blockMeta.register(alice, selector);
    }

    /// @dev Test to ensure 'blockPrologue' executes.
    function testBlockPrologue() public {
        testEntryRegistration();

        vm.prank(address(0x5355500000000000000000000000000000000000));
        blockMeta.blockPrologue();
	assertEq(counter.counter(), 1);
    }

    /// @dev Test to ensure 'blockPrologue' reverts if caller is not SUP0.
    function testBlockPrologueRevertsIfNotSUP0() public {
        vm.expectRevert(BlockMeta.InvalidCaller.selector);

        vm.prank(alice);
        blockMeta.blockPrologue();
    }

}
