// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Config} from "../libraries/LibAppStorage.sol";

interface IConfigFacet {
    // =============================================================
    //                          Events 
    // =============================================================
    /// @notice Emitted when an account is authorized as submitter for system tasks.
    event AuthorizationGranted(address indexed account, uint256 indexed timestamp);

    /// @notice Emitted when authorization is revoked for an account to submit system tasks.
    event AuthorizationRevoked(address indexed account, uint256 indexed timestamp);

    /// @notice Emitted when task registration is enabled.
    event TaskRegistrationEnabled(bool indexed status);

    /// @notice Emitted when task registration is disabled.
    event TaskRegistrationDisabled(bool indexed status);

    /// @notice Emitted when the VM Signer address is updated.
    event VmSignerUpdated(address indexed oldVmSigner, address indexed newVmSigner);

    /// @notice Emitted when the ERC20Supra address is updated.
    event Erc20SupraUpdated(address indexed oldErc20Supra, address indexed newErc20Supra);

    /// @notice Emitted when the registry fees is withdrawn by the admin.
    event RegistryFeeWithdrawn(address indexed recipient, uint256 indexed feesWithdrawn);

    /// @notice Emitted when a new config is added.
    event ConfigBufferUpdated(Config indexed pendingConfig);


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
    function getVmSigner() external view returns (address);
    function isRegistrationEnabled() external view returns (bool);

    // =============================================================
    //                  State update functions
    // =============================================================
    function grantAuthorization(address _account) external;
    function revokeAuthorization(address _account) external;
    function enableRegistration() external;
    function disableRegistration() external;
    function setVmSigner(address _vmSigner) external;
    function setErc20Supra(address _erc20Supra) external;
    function withdrawFees(uint256 _amount, address _recipient) external;
    function updateConfigBuffer(
        uint64 _taskDurationCapSecs,
        uint128 _registryMaxGasCap,
        uint128 _automationBaseFeeWeiPerSec,
        uint128 _flatRegistrationFeeWei,
        uint8 _congestionThresholdPercentage,
        uint128 _congestionBaseFeeWeiPerSec,
        uint8 _congestionExponent,
        uint16 _taskCapacity,
        uint64 _cycleDurationSecs,
        uint64 _sysTaskDurationCapSecs,
        uint128 _sysRegistryMaxGasCap,
        uint16 _sysTaskCapacity
    ) external;
}
