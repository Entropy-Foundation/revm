// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Config} from "../libraries/LibAppStorage.sol";

interface IConfigFacet {
    // =============================================================
    //                          Events
    // =============================================================
    // A struct or array parameter of an event is not declared indexed: an indexed parameter of
    // such a type is logged as the keccak256 of its ABI encoding, which carries none of its
    // fields. The value is ABI-encoded in the log data instead, where a reader decodes it with
    // the event's ABI (Entropy-Foundation/smr-moonshot#4285). Indexing is reserved for the
    // value-typed parameters a reader filters on, such as a task index or an owner; a fee, refund
    // or balance amount is not filtered on and is placed in the log data. Indexing is not part of
    // the event signature, so it does not affect topic0.

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

    /// @notice Emitted when the task registration input size caps are updated.
    event DataLengthCapsUpdated(uint16 maxPayloadLength, uint16 maxPredicateLength, uint16 maxAuxDataLength, uint16 maxAuxDataEntries);


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
    function getDataLengthCaps() external view returns (uint16 maxPayloadLength, uint16 maxPredicateLength, uint16 maxAuxDataLength, uint16 maxAuxDataEntries);

    // =============================================================
    //                  State update functions
    // =============================================================
    function grantAuthorization(address _account) external;
    function revokeAuthorization(address _account) external;
    function enableRegistration() external;
    function disableRegistration() external;
    function withdrawFees(uint256 _amount, address _recipient) external;
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
}
