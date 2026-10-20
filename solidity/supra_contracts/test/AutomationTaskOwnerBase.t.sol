// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {AutomationTaskOwnerBase} from "../src/AutomationTaskOwnerBase.sol";
import {AUTOMATION_TASK_OWNER_INTERFACE_ID} from "../src/interfaces/IAutomationTaskOwner.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {IRegistryViewFacet} from "../src/interfaces/IRegistryViewFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";

/// @dev A contract built on `AutomationTaskOwnerBase` the way the base expects: every action
/// that makes it act on the registry is restricted to its admin.
contract AdminAutomationTaskOwner is AutomationTaskOwnerBase {
    address public immutable admin;

    error NotAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address _registry) AutomationTaskOwnerBase(_registry) {
        admin = msg.sender;
    }

    function feeToken() external view returns (address) {
        return address(AUTOMATION_FEE_TOKEN);
    }

    function fund(uint256 _feeBudget) external payable onlyAdmin {
        _fundAutomationFees(_feeBudget);
    }

    function registerTask(bytes memory _payloadTx, bytes memory _predicate, uint64 _expiryTime) external onlyAdmin {
        bytes[] memory auxData;
        _registerAutomationTask(_payloadTx, _predicate, _expiryTime, 100_000, 4 gwei, 60.1 ether, 0, auxData);
    }

    function registerSystemTask(bytes memory _payloadTx, bytes memory _predicate, uint64 _expiryTime)
        external
        onlyAdmin
    {
        bytes[] memory auxData;
        _registerSystemAutomationTask(_payloadTx, _predicate, _expiryTime, 100_000, 2, auxData);
    }

    function cancel(uint64[] memory _taskIndexes) external onlyAdmin {
        _cancelAutomationTasks(_taskIndexes);
    }

    function stop(uint64[] memory _taskIndexes) external onlyAdmin {
        _stopAutomationTasks(_taskIndexes);
    }

    function cancelSystem(uint64[] memory _taskIndexes) external onlyAdmin {
        _cancelSystemAutomationTasks(_taskIndexes);
    }

    function stopSystem(uint64[] memory _taskIndexes) external onlyAdmin {
        _stopSystemAutomationTasks(_taskIndexes);
    }

    function withdraw(address payable _to) external onlyAdmin {
        _withdrawAutomationFunds(_to);
    }
}

/// @notice `AutomationTaskOwnerBase` (#4469): its ERC-165 answers satisfy the registry, and its
/// internal functions register, cancel, stop and withdraw as the owning contract.
contract AutomationTaskOwnerBaseTest is BaseDiamondTest {
    address constant ADMIN = address(0xAD);

    function deployOwner() internal returns (AdminAutomationTaskOwner owner) {
        vm.prank(ADMIN);
        owner = new AdminAutomationTaskOwner(diamondAddr);
    }

    function payload() internal view returns (bytes memory) {
        return createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100));
    }

    function singleTask(uint64 _taskIndex) internal pure returns (uint64[] memory taskIndexes) {
        taskIndexes = new uint64[](1);
        taskIndexes[0] = _taskIndex;
    }

    function fundedOwner() internal returns (AdminAutomationTaskOwner owner) {
        owner = deployOwner();
        vm.deal(ADMIN, 200 ether);
        vm.prank(ADMIN);
        owner.fund{value: 200 ether}(190 ether);
    }

    function testTheBaseDeclaresTheOwnerInterface() public {
        AdminAutomationTaskOwner owner = deployOwner();
        assertTrue(owner.supportsInterface(type(IERC165).interfaceId));
        assertTrue(owner.supportsInterface(AUTOMATION_TASK_OWNER_INTERFACE_ID));
        assertFalse(owner.supportsInterface(0xffffffff));
    }

    function testTheBaseReadsTheFeeTokenFromTheRegistry() public {
        assertEq(deployOwner().feeToken(), address(wsupra));
    }

    function testFundWrapsTheBudgetAndKeepsTheRestNative() public {
        AdminAutomationTaskOwner owner = fundedOwner();
        assertEq(wsupra.balanceOf(address(owner)), 190 ether);
        assertEq(wsupra.allowance(address(owner), diamondAddr), type(uint256).max);
        assertEq(address(owner).balance, 10 ether);
    }

    function testAUserTaskIsRegisteredOwnedAndCancelledThroughTheBase() public {
        AdminAutomationTaskOwner owner = fundedOwner();
        vm.prank(ADMIN);
        owner.registerTask(payload(), createPredicate(diamondAddr), uint64(block.timestamp + 1250));

        assertEq(IRegistryViewFacet(diamondAddr).getTaskDetails(0).owner, address(owner));

        vm.prank(ADMIN);
        owner.cancel(singleTask(0));
        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
    }

    function testAStoppedTasksRefundIsWithdrawnThroughTheBase() public {
        AdminAutomationTaskOwner owner = fundedOwner();
        vm.prank(ADMIN);
        owner.registerTask(payload(), createPredicate(diamondAddr), uint64(block.timestamp + 1250));
        processCycleTransition(diamondAddr, singleTask(0));

        vm.startPrank(ADMIN);
        owner.stop(singleTask(0));
        uint256 nativeBefore = ADMIN.balance;
        owner.withdraw(payable(ADMIN));
        vm.stopPrank();

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        assertEq(ADMIN.balance - nativeBefore, 10 ether);
        assertGt(wsupra.balanceOf(ADMIN), 0);
        assertEq(wsupra.balanceOf(address(owner)), 0);
    }

    function testASystemTaskIsRegisteredAndStoppedThroughTheBase() public {
        AdminAutomationTaskOwner owner = deployOwner();
        vm.prank(admin);
        IConfigFacet(diamondAddr).grantAuthorization(address(owner));

        vm.prank(ADMIN);
        owner.registerSystemTask(payload(), createPredicate(diamondAddr), uint64(block.timestamp + 1250));
        LibCommon.TaskType taskType = LibCommon.TaskType(IRegistryViewFacet(diamondAddr).getTaskDetails(0).taskType);
        assertEq(uint8(taskType), uint8(LibCommon.TaskType.GST));
        assertEq(IRegistryViewFacet(diamondAddr).getTaskDetails(0).owner, address(owner));

        vm.prank(ADMIN);
        owner.stopSystem(singleTask(0));
        assertFalse(IRegistryViewFacet(diamondAddr).ifSysTaskExists(0));
    }

    function testASystemTaskIsCancelledThroughTheBase() public {
        AdminAutomationTaskOwner owner = deployOwner();
        vm.prank(admin);
        IConfigFacet(diamondAddr).grantAuthorization(address(owner));
        vm.startPrank(ADMIN);
        owner.registerSystemTask(payload(), createPredicate(diamondAddr), uint64(block.timestamp + 1250));
        owner.cancelSystem(singleTask(0));
        vm.stopPrank();
        assertFalse(IRegistryViewFacet(diamondAddr).ifSysTaskExists(0));
    }

    /// @dev The base exposes no task function; the inheriting contract's restriction holds.
    function testOnlyTheAdminCanMakeTheOwnerAct() public {
        AdminAutomationTaskOwner owner = fundedOwner();
        vm.expectRevert(AdminAutomationTaskOwner.NotAdmin.selector);
        owner.registerTask(payload(), createPredicate(diamondAddr), uint64(block.timestamp + 1250));
        vm.expectRevert(AdminAutomationTaskOwner.NotAdmin.selector);
        owner.withdraw(payable(address(this)));
    }
}
