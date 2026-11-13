// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {SystemTaskOwner} from "../src/SystemTaskOwner.sol";
import {AUTOMATION_TASK_OWNER_INTERFACE_ID} from "../src/interfaces/IAutomationTaskOwner.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {IRegistryViewFacet} from "../src/interfaces/IRegistryViewFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {TaskMetadata} from "../src/libraries/LibAppStorage.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";

/// @notice `SystemTaskOwner`: the contract the foundation wallet deploys to own its system tasks
/// (smr-moonshot #4922). Only its owner can make it act, ownership moves in two steps and cannot
/// be renounced, and it holds no funds.
contract SystemTaskOwnerTest is BaseDiamondTest {
    address constant OWNER = address(0x0E1);
    address constant NEW_OWNER = address(0x0E2);
    address constant STRANGER = address(0xBAD);

    SystemTaskOwner taskOwner;

    /// @dev Deploys the task owner as OWNER and has the registry owner authorize it. A modifier
    /// rather than a setUp override: BaseDiamondTest.setUp is not virtual.
    modifier withAuthorizedTaskOwner() {
        vm.prank(OWNER);
        taskOwner = new SystemTaskOwner(diamondAddr);
        vm.prank(admin);
        IConfigFacet(diamondAddr).grantAuthorization(address(taskOwner));
        _;
    }

    function singleTask(uint64 _taskIndex) internal pure returns (uint64[] memory taskIndexes) {
        taskIndexes = new uint64[](1);
        taskIndexes[0] = _taskIndex;
    }

    /// @dev Has `_caller` register the fixture's system task through the task owner.
    function registerAs(address _caller) internal {
        bytes[] memory auxData;
        vm.prank(_caller);
        taskOwner.registerSystemTask(
            createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)),
            createPredicate(diamondAddr),
            uint64(block.timestamp + 1250),
            100_000,
            2,
            auxData
        );
    }

    function testTheDeployerOwnsItAndItIsBoundToTheRegistry() public withAuthorizedTaskOwner {
        assertEq(taskOwner.owner(), OWNER);
        assertEq(taskOwner.automationRegistry(), diamondAddr);
    }

    /// @dev The registry accepts it as a task owner: `IERC165` and `IAutomationTaskOwner`, and not
    /// `0xffffffff`.
    function testItDeclaresTheOwnerInterface() public withAuthorizedTaskOwner {
        assertTrue(taskOwner.supportsInterface(type(IERC165).interfaceId));
        assertTrue(taskOwner.supportsInterface(AUTOMATION_TASK_OWNER_INTERFACE_ID));
        assertFalse(taskOwner.supportsInterface(0xffffffff));
    }

    /// @dev A system task registered through it is owned by it, and its owner stops it.
    function testTheOwnerRegistersAndStopsASystemTask() public withAuthorizedTaskOwner {
        registerAs(OWNER);

        TaskMetadata memory task = IRegistryViewFacet(diamondAddr).getTaskDetails(0);
        assertEq(task.owner, address(taskOwner));
        assertEq(uint8(task.taskType), uint8(LibCommon.TaskType.GST));

        vm.prank(OWNER);
        taskOwner.stopSystemTasks(singleTask(0));
        assertFalse(IRegistryViewFacet(diamondAddr).ifSysTaskExists(0));
    }

    /// @dev Every function that makes it act is owner-only, including for a call from the task
    /// owner itself, which is what a task whose payload targets the task owner would make.
    function testOnlyTheOwnerCanMakeItAct() public withAuthorizedTaskOwner {
        address[2] memory others = [STRANGER, address(taskOwner)];
        for (uint256 i = 0; i < others.length; i++) {
            bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, others[i]);
            bytes[] memory auxData;

            vm.prank(others[i]);
            vm.expectRevert(unauthorized);
            taskOwner.registerSystemTask(
                createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)),
                createPredicate(diamondAddr),
                uint64(block.timestamp + 1250),
                100_000,
                2,
                auxData
            );

            vm.prank(others[i]);
            vm.expectRevert(unauthorized);
            taskOwner.cancelSystemTasks(singleTask(0));

            vm.prank(others[i]);
            vm.expectRevert(unauthorized);
            taskOwner.stopSystemTasks(singleTask(0));

            vm.prank(others[i]);
            vm.expectRevert(unauthorized);
            taskOwner.withdrawFunds(payable(others[i]));

            vm.prank(others[i]);
            vm.expectRevert(unauthorized);
            taskOwner.transferOwnership(others[i]);
        }
        assertEq(IRegistryViewFacet(diamondAddr).totalTasks(), 0);
    }

    /// @dev A nominated owner takes over only by accepting; the previous owner keeps control
    /// until then and loses it afterwards.
    function testOwnershipMovesInTwoSteps() public withAuthorizedTaskOwner {
        vm.prank(OWNER);
        taskOwner.transferOwnership(NEW_OWNER);
        assertEq(taskOwner.owner(), OWNER);
        assertEq(taskOwner.pendingOwner(), NEW_OWNER);

        vm.prank(NEW_OWNER);
        taskOwner.acceptOwnership();
        assertEq(taskOwner.owner(), NEW_OWNER);

        registerAs(NEW_OWNER);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        taskOwner.cancelSystemTasks(singleTask(0));

        vm.prank(NEW_OWNER);
        taskOwner.cancelSystemTasks(singleTask(0));
        assertFalse(IRegistryViewFacet(diamondAddr).ifSysTaskExists(0));
    }

    function testOwnershipCannotBeRenounced() public withAuthorizedTaskOwner {
        vm.prank(OWNER);
        vm.expectRevert(SystemTaskOwner.OwnershipRenunciationDisabled.selector);
        taskOwner.renounceOwnership();
        assertEq(taskOwner.owner(), OWNER);
    }

    /// @dev System tasks are charged no fees, so it refuses native SUPRA.
    function testANativeTransferIsRefused() public withAuthorizedTaskOwner {
        vm.deal(STRANGER, 1 ether);
        vm.prank(STRANGER);
        (bool sent, bytes memory returnData) = payable(address(taskOwner)).call{value: 1 ether}("");
        assertFalse(sent);
        assertEq(returnData, abi.encodeWithSelector(SystemTaskOwner.NativeTransferRefused.selector));
        assertEq(address(taskOwner).balance, 0);
    }

    /// @dev WrappedSupra that reaches it anyway is withdrawn by the owner.
    function testTheOwnerWithdrawsWrappedSupraSentToIt() public withAuthorizedTaskOwner {
        vm.deal(STRANGER, 5 ether);
        vm.startPrank(STRANGER);
        wsupra.deposit{value: 5 ether}();
        wsupra.transfer(address(taskOwner), 5 ether);
        vm.stopPrank();

        vm.prank(OWNER);
        taskOwner.withdrawFunds(payable(OWNER));
        assertEq(wsupra.balanceOf(OWNER), 5 ether);
        assertEq(wsupra.balanceOf(address(taskOwner)), 0);
    }
}
