// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {LibCommon} from "../libraries/LibCommon.sol";
import {TaskMetadata} from "../libraries/LibAppStorage.sol";

interface IRegistryFacet {
    // =============================================================
    //                          Events
    // =============================================================
    /// @notice Emitted when a user task is registered.
    event TaskRegistered(
        uint64 indexed taskIndex, 
        address indexed owner, 
        uint128 registrationFee, 
        uint128 lockedDepositFee, 
        TaskMetadata indexed taskMetadata
    );

    /// @notice Emitted when a system task is registered.
    event SystemTaskRegistered(
        uint64 indexed taskIndex, 
        address indexed owner, 
        uint256 timestamp, 
        TaskMetadata taskMetadata
    );
    
    /// @notice Emitted when a task is cancelled.
    event TasksCancelled(
        LibCommon.TaskCancelled[] indexed cancelledTasks,
        address indexed owner
    );

    /// @notice Emitted when a task is stopped.
    event TasksStopped(
        LibCommon.TaskStopped[] indexed stoppedTasks,
        address indexed owner
    );

    /// @notice Emitted when an automation fee is refunded for an automation task at the end of the cycle for excessive
    /// duration paid at the beginning of the cycle due to cycle duration reduction by governance.
    event TaskFeeRefund(
        uint64 indexed taskIndex,
        address indexed owner,
        uint64 indexed amount
    );

    /// @notice Emitted when a deposit fee is refunded for an automation task.
    event TaskDepositFeeRefund(uint64 indexed taskIndex, address indexed owner, uint128 indexed amount);

    /// @notice Emitted when a task cycle fee is being refunded but locked cycle fees is less than the requested refund.
    event ErrorUnlockTaskCycleFee(
        uint64 indexed taskIndex,
        uint256 indexed lockedCycleFees,
        uint64 indexed refund
    );

    /// @notice Emitted during cycle transition when refunds to be paid is not possible due to insufficient contract balance.
    /// Type of the refund can be related either to the deposit paid during registration (0), or to cycle fee caused by
    /// the shortening of the cycle (1)
    event ErrorInsufficientBalanceToRefund(
        uint64 indexed _taskIndex,
        address indexed _owner,
        uint8 indexed _refundType,
        uint128 _amount
    );

    /// @notice Emitted when deposit fee is being refunded but total locked deposits is less than the locked deposit for the task.
    event ErrorUnlockTaskDepositFee(
        uint64 indexed taskIndex, 
        uint256 indexed totalDepositedAutomationFees, 
        uint128 indexed lockedDeposit
    );


    // =============================================================
    //                      Custom errors
    // =============================================================
    error AutomationNotEnabled();
    error CycleTransitionInProgress();
    error TaskIndexesCannotBeEmpty();
    error TransferFailed();
    error UnauthorizedAccount();

    // =============================================================
    //                      View functions
    // =============================================================
    function calculateAutomationFeeMultiplierForCommittedOccupancy(uint128 _totalCommittedMaxGas) external view returns (uint128);
    function calculateAutomationFeeMultiplierForCurrentCycle() external view returns (uint128);
    function estimateAutomationFee(uint128 _taskOccupancy) external view returns (uint128);
    function estimateAutomationFeeWithCommittedOccupancy(uint128 _taskOccupancy, uint128 _committedOccupancy) external view returns (uint128);
    function isAuthorizedSubmitter(address _account) external view returns (bool);
    function ifTaskExists(uint64 _taskIndex) external view  returns (bool);
    function ifSysTaskExists(uint64 _taskIndex) external view returns (bool);
    function getActiveTaskIds() external view returns (uint256[] memory);
    function getCycleLockedFees() external view returns (uint256);
    function getGasCommittedForCurrentCycle() external view returns (uint128);
    function getGasCommittedForNextCycle() external view returns (uint128);
    function getNextCycleRegistryMaxGasCap() external view returns (uint128);
    function getNextCycleSysRegistryMaxGasCap() external view returns (uint128);
    function getNextTaskIndex() external view returns (uint64);
    function getSystemGasCommittedForCurrentCycle() external view returns (uint128);
    function getSystemGasCommittedForNextCycle() external view returns (uint128);
    function getSystemTaskIds() external view returns (uint256[] memory);
    function getTaskDetails(uint64 _taskIndex) external view returns (TaskMetadata memory);
    function getTaskDetailsBulk(uint64[] memory _taskIndexes) external view returns (TaskMetadata[] memory);
    function getTaskIdList() external view returns (uint256[] memory);
    function getTaskOwner(uint64 _taskIndex) external view returns (address);
    function getTotalActiveTasks() external view returns (uint256);
    function getTotalDepositedAutomationFees() external view returns (uint256);
    function getTotalLockedBalance() external view returns (uint256);
    function getUserTasks(address _user) external view returns (uint256[] memory);
    function hasActiveSystemTask(address _account, uint64 _taskIndex) external view returns (bool);
    function hasActiveTaskOfType(address _account, uint64 _taskIndex, LibCommon.TaskType _type) external view returns (bool);
    function hasActiveUserTask(address _account, uint64 _taskIndex) external view returns (bool);
    function totalSystemTasks() external view returns (uint256);
    function totalTasks() external view returns (uint256);

    // =============================================================
    //                  State update functions
    // =============================================================
    function register(
        bytes memory _payloadTx,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority,
        bytes[] memory _auxData
    ) external;
    function registerSystemTask(
        bytes memory _payloadTx,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _priority,
        bytes[] memory _auxData
    ) external;
    function cancelTasks(uint64[] memory _taskIndexes) external;
    function cancelSystemTasks(uint64[] memory _taskIndexes) external;
    function stopTasks(uint64[] memory _taskIndexes) external;
    function stopSystemTasks(uint64[] memory _taskIndexes) external;
}
