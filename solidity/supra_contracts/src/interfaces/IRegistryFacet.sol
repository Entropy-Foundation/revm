// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibCommon} from "../libraries/LibCommon.sol";
import {TaskMetadata} from "../libraries/LibAppStorage.sol";

interface IRegistryFacet {
    // =============================================================
    //                          Events
    // =============================================================
    // A struct or array parameter of an event is not declared indexed: an indexed parameter of
    // such a type is logged as the keccak256 of its ABI encoding, which carries none of its
    // fields. The value is ABI-encoded in the log data instead, where a reader decodes it with
    // the event's ABI (Entropy-Foundation/smr-moonshot#4285). Indexing is reserved for the
    // value-typed parameters a reader filters on. Indexing is not part of the event signature,
    // so it does not affect topic0.

    /// @notice Emitted when a user task is registered.
    /// @dev taskIndex and owner are topics 1 and 2. registrationFee, lockedDepositFee and
    ///      taskMetadata are ABI-encoded in the log data; taskMetadata is the task record as
    ///      stored at registration, including payloadTx, predicate and auxData.
    event TaskRegistered(
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 registrationFee,
        uint128 lockedDepositFee,
        TaskMetadata taskMetadata
    );

    /// @notice Emitted when a system task is registered.
    /// @dev taskIndex and owner are topics 1 and 2. timestamp and taskMetadata are ABI-encoded
    ///      in the log data; taskMetadata is the task record as stored at registration.
    event SystemTaskRegistered(
        uint64 indexed taskIndex,
        address indexed owner,
        uint256 timestamp,
        TaskMetadata taskMetadata
    );

    /// @notice Emitted when tasks are cancelled, with one entry per task actually cancelled.
    /// @dev owner is topic 1. cancelledTasks is ABI-encoded in the log data as
    ///      (uint64 taskIndex, TaskType taskType, bytes32 txHash)[].
    event TasksCancelled(
        LibCommon.TaskCancelled[] cancelledTasks,
        address indexed owner
    );

    /// @notice Emitted when tasks are stopped, with one entry per task actually stopped.
    /// @dev owner is topic 1. stoppedTasks is ABI-encoded in the log data as
    ///      (uint64 taskIndex, uint128 depositRefund, uint128 cycleFeeRefund, bytes32 txHash)[],
    ///      the refunds being the amounts paid back for that task.
    event TasksStopped(
        LibCommon.TaskStopped[] stoppedTasks,
        address indexed owner
    );

    /// @notice Emitted when an automation fee is refunded for an automation task at the end of the cycle for excessive
    /// duration paid at the beginning of the cycle due to cycle duration reduction by governance.
    event TaskFeeRefund(
        uint64 indexed taskIndex,
        address indexed owner,
        uint128 indexed amount
    );

    /// @notice Emitted when a deposit fee is refunded for an automation task.
    event TaskDepositFeeRefund(uint64 indexed taskIndex, address indexed owner, uint128 indexed amount);

    /// @notice Emitted when a task cycle fee is being refunded but locked cycle fees is less than the requested refund.
    event ErrorUnlockTaskCycleFee(
        uint64 indexed taskIndex,
        uint256 indexed lockedCycleFees,
        uint128 indexed refund
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
    error AlreadyCancelled();
    error AutomationNotEnabled();
    error CycleTransitionInProgress();
    error ErrorCycleFeeRefund();
    error ErrorDepositRefund();
    error FailedToCallTxHashPrecompile();
    error GasCommittedExceedsMaxGasCap();
    error GasCommittedValueUnderflow();
    /// @notice Thrown when a UST's gas price cap is below the chain's minimum gas price (the base
    /// fee, read from {ISupraEvmGasConfig-minGasPrice}), so its transaction could never be admitted.
    error GasPriceCapBelowMinimum(uint128 gasPriceCap, uint256 minGasPrice);
    error InsufficientFeeCapForCycle(uint128 estimatedAutomationFeeForCycle);
    error InvalidCycleRefundFee(); 
    error InvalidExpiryTime();
    error InvalidGasPriceCap();
    error InvalidMaxGasAmount();
    error InvalidPayloadLength();
    error PayloadTooLarge();
    error PredicateTooLarge();
    error AuxDataTooLarge();
    error InvalidReturnLengthOfPredicate();
    error InvalidReturnTypeOfPredicate();
    error InvalidRegistryState();
    error InvalidTaskDuration();
    /// @notice Thrown when a task's max gas amount is above the chain's per-transaction gas cap
    /// (read from {ISupraEvmGasConfig-txGasLimitCap}), so its transaction could never be admitted.
    error MaxGasAmountExceedsChainCap(uint128 maxGasAmount, uint64 txGasLimitCap);
    error RegistrationDisabled();
    error StaticCallToPredicateFailed();
    error TaskCapacityReached();
    error TaskExpiresBeforeNextCycle();
    error TaskIndexNotFound();
    error TaskIndexNotUnique();
    error TaskIndexesCannotBeEmpty();
    error TransferFailed();
    error TxnHashLengthShouldBe32(uint64);
    error UnauthorizedAccount();
    error UnsupportedTaskOperation();

    // =============================================================
    //                      View functions
    // =============================================================
    function calculateAutomationFeeMultiplierForCommittedOccupancy(uint128 _totalCommittedMaxGas) external view returns (uint128);
    function calculateAutomationFeeMultiplierForCurrentCycle() external view returns (uint128);
    function estimateAutomationFee(uint128 _taskOccupancy) external view returns (uint128);
    function estimateAutomationFeeWithCommittedOccupancy(uint128 _taskOccupancy, uint128 _committedOccupancy) external view returns (uint128);
    function isAuthorizedSubmitter(address _account) external view returns (bool);

    // =============================================================
    //                  State update functions
    // =============================================================
    function register(
        bytes memory _payloadTx,
        bytes memory _predicate,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority,
        bytes[] memory _auxData
    ) external;
    function registerSystemTask(
        bytes memory _payloadTx,
        bytes memory _predicate,
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
