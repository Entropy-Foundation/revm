// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Config, DataLengthCaps, RecordSizingParameters} from "../libraries/LibAppStorage.sol";
import {LibCommon} from "../libraries/LibCommon.sol";

interface IConfigFacet {
    // =============================================================
    //                          Events
    // =============================================================
    // Struct, array, string and bytes parameters, and amounts, are carried in the log data, not
    // indexed. script/check_event_indexing.sh states the rule; the forge-tests CI job runs it
    // after forge build and fails on an indexed struct, array, string or bytes parameter (#4285).

    /// @notice Emitted when an account is authorized as submitter for system tasks.
    event AuthorizationGranted(address indexed account, uint256 indexed timestamp);

    /// @notice Emitted when authorization is revoked for an account to submit system tasks.
    event AuthorizationRevoked(address indexed account, uint256 indexed timestamp);

    /// @notice Emitted when task registration is enabled.
    event TaskRegistrationEnabled(bool indexed status);

    /// @notice Emitted when task registration is disabled.
    event TaskRegistrationDisabled(bool indexed status);

    /// @notice Emitted when the registry fees is withdrawn by the admin.
    /// @dev recipient is topic 1; feesWithdrawn is in the log data.
    event RegistryFeeWithdrawn(address indexed recipient, uint256 feesWithdrawn);

    /// @notice Emitted when a new config is added.
    /// @dev The log has no indexed parameter. pendingConfig is ABI-encoded in the log data and is
    ///      the Config that takes effect at the start of the next cycle.
    event ConfigBufferUpdated(Config pendingConfig);

    /// @notice Emitted for each index passed to `removeTasks` that names no task, and is skipped
    /// (#4636).
    /// @dev taskIndex is topic 1.
    event TaskRemovalByGovernanceSkipped(uint64 indexed taskIndex);

    /// @notice Emitted for each task the registry owner removes through `removeTasks` (#4636).
    /// @dev taskIndex, owner and taskType are topics 1, 2 and 3, as in TaskRemovedByConfigUpdate,
    ///      so a reader filters governance removals by task, owner or task type; the rest is in
    ///      the log data. The refunds are those a stop by the owner pays, and are zero for a GST.
    event TaskRemovedByGovernance(
        uint64 indexed taskIndex,
        address indexed owner,
        LibCommon.TaskType indexed taskType,
        bytes32 txHash,
        uint128 depositRefund,
        uint128 cycleFeeRefund
    );

    /// @notice Emitted when task registration input size caps are buffered for the next cycle
    /// boundary (`updateDataLengthCaps`).
    event DataLengthCapsBufferUpdated(DataLengthCaps pendingCaps);

    /// @notice Emitted when the owner-set parameters that size a `processTasks` record are
    /// buffered for the next cycle boundary (`updateRecordSizingParameters`,
    /// Entropy-Foundation/smr-moonshot#4755).
    event RecordSizingParametersBufferUpdated(RecordSizingParameters pendingParameters);


    // =============================================================
    //                      Custom errors
    // =============================================================
    error AddressAlreadyExists();
    error AddressDoesNotExist();
    error AlreadyDisabled();
    error AlreadyEnabled();
    error InvalidAmount();
    error InsufficientBalance();
    error RequestExceedsLockedBalance();
    error TransferFailed();
    error UnacceptableRegistryMaxGasCap();    
    error UnacceptableSysRegistryMaxGasCap();

    // =============================================================
    //                      View functions
    // =============================================================
    function erc20Supra() external view returns (address);
    function getConfig() external view returns (Config memory);
    function getConfigBuffer() external view returns (Config memory);
    function isRegistrationEnabled() external view returns (bool);
    function getDataLengthCaps() external view returns (DataLengthCaps memory);
    function getDataLengthCapsBuffer() external view returns (DataLengthCaps memory);
    function getRecordSizingParameters() external view returns (RecordSizingParameters memory);
    function getRecordSizingParametersBuffer() external view returns (RecordSizingParameters memory);
    function getTaskStoredWordsBound() external view returns (uint32);

    // =============================================================
    //                  State update functions
    // =============================================================
    function grantAuthorization(address _account) external;
    function revokeAuthorization(address _account) external;
    function enableRegistration() external;
    function disableRegistration() external;
    function withdrawFees(uint256 _amount, address _recipient) external;
    function removeTasks(uint64[] memory _taskIndexes) external;
    function updateConfigBuffer(
        uint64 _taskDurationCapSecs,
        uint128 _registryMaxGasCap,
        uint128 _automationBaseFeeWeiPerSec,
        uint128 _flatRegistrationFeeWei,
        uint8 _congestionThresholdPercentage,
        uint128 _congestionBaseFeeWeiPerSec,
        uint8 _congestionExponent,
        uint8 _maxCongestionExponent,
        uint16 _taskCapacity,
        uint64 _cycleDurationSecs,
        uint64 _sysTaskDurationCapSecs,
        uint128 _sysRegistryMaxGasCap,
        uint16 _sysTaskCapacity
    ) external;
    function updateDataLengthCaps(
        uint16 _maxPayloadLength,
        uint16 _maxPredicateLength,
        uint16 _maxAuxDataLength,
        uint16 _maxAuxDataEntries
    ) external;
    function updateRecordSizingParameters(RecordSizingParameters calldata _parameters) external;
}
