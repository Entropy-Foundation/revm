// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, Config} from "../libraries/LibAppStorage.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {IConfigFacet} from "../interfaces/IConfigFacet.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract ConfigFacet is IConfigFacet {
    using EnumerableSet for *;

    /// @dev State variables 
    AppStorage internal s;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: EVENTS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

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

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ADMIN FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Grants authorization to the input account to submit system automation tasks.
    /// @param _account Address to grant authorization to.
    function grantAuthorization(address _account) external {
        LibDiamond.enforceIsContractOwner();

        require(s.authorizedAccounts.add(_account), AddressAlreadyExists());
        emit AuthorizationGranted(_account, block.timestamp);
    }

    /// @notice Revokes authorization from the input account to submit system automation tasks. 
    /// @param _account Address to revoke authorization from.
    function revokeAuthorization(address _account) external {
        LibDiamond.enforceIsContractOwner();

        require(s.authorizedAccounts.remove(_account), AddressDoesNotExist());
        emit AuthorizationRevoked(_account, block.timestamp);
    }

    /// @notice Function to enable the task registration.
    function enableRegistration() external {
        LibDiamond.enforceIsContractOwner();

        if (s.registrationEnabled) { revert AlreadyEnabled(); }
        s.registrationEnabled = true;

        emit TaskRegistrationEnabled(s.registrationEnabled);
    }

    /// @notice Function to disable the task registration.
    function disableRegistration() external {
        LibDiamond.enforceIsContractOwner();

        if (!s.registrationEnabled) { revert AlreadyDisabled(); }
        s.registrationEnabled = false;

        emit TaskRegistrationDisabled(s.registrationEnabled);   
    }

    /// @notice Function to update the VM Signer address.
    /// @param _vmSigner New address for VM Signer.
    function setVmSigner(address _vmSigner) external {
        LibDiamond.enforceIsContractOwner();

        if (_vmSigner == address(0)) { revert AddressCannotBeZero(); }

        address oldVmSigner = s.vmSigner;
        s.vmSigner = _vmSigner;

        emit VmSignerUpdated(oldVmSigner, _vmSigner);
    }

    /// @notice Function to update the ERC20Supra address.
    /// @param _erc20Supra New address for ERC20Supra.
    function setErc20Supra(address _erc20Supra) external {
        LibDiamond.enforceIsContractOwner();

        LibUtils.validateContractAddress(_erc20Supra);

        address oldErc20Supra = s.erc20Supra;
        s.erc20Supra = _erc20Supra;

        emit Erc20SupraUpdated(oldErc20Supra, _erc20Supra);
    }

    /// @notice Function to withdraw the accumulated fees.
    /// @param _amount Amount to withdraw.
    /// @param _recipient Address to withdraw fees to.
    function withdrawFees(uint256 _amount, address _recipient) external {
        LibDiamond.enforceIsContractOwner();

        if (_amount == 0) { revert InvalidAmount(); }
        if (_recipient == address(0)) { revert AddressCannotBeZero(); }
        uint256 balance = IERC20(s.erc20Supra).balanceOf(address(this));

        if (balance < _amount) { revert InsufficientBalance(); }
        if (balance - _amount < s.registryState.cycleLockedFees + s.registryState.totalDepositedAutomationFees) { revert RequestExceedsLockedBalance(); }

        bool sent = IERC20(s.erc20Supra).transfer(_recipient, _amount);
        if (!sent) { revert TransferFailed(); }

        emit RegistryFeeWithdrawn(_recipient, _amount);
    }

    /// @notice Function to update the registry configuration buffer.
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
    ) external {
        LibDiamond.enforceIsContractOwner();

        LibUtils.validateConfigParameters(
            _taskDurationCapSecs,
            _registryMaxGasCap,
            _congestionThresholdPercentage,
            _congestionExponent,
            _taskCapacity,
            _cycleDurationSecs,
            _sysTaskDurationCapSecs,
            _sysRegistryMaxGasCap,
            _sysTaskCapacity
        );

        if (s.registryState.gasCommittedForNextCycle > _registryMaxGasCap) { revert UnacceptableRegistryMaxGasCap(); }
        if (s.registryState.sysGasCommittedForNextCycle > _sysRegistryMaxGasCap) { revert UnacceptableSysRegistryMaxGasCap(); }

        // Add new config to the buffer
        Config memory configBuffer = Config({ 
            registryMaxGasCap: _registryMaxGasCap, 
            sysRegistryMaxGasCap: _sysRegistryMaxGasCap, 
            automationBaseFeeWeiPerSec: _automationBaseFeeWeiPerSec, 
            flatRegistrationFeeWei: _flatRegistrationFeeWei, 
            congestionBaseFeeWeiPerSec: _congestionBaseFeeWeiPerSec, 
            taskDurationCapSecs: _taskDurationCapSecs, 
            sysTaskDurationCapSecs: _sysTaskDurationCapSecs, 
            cycleDurationSecs: _cycleDurationSecs, 
            taskCapacity: _taskCapacity, 
            sysTaskCapacity: _sysTaskCapacity, 
            congestionThresholdPercentage: _congestionThresholdPercentage, 
            congestionExponent: _congestionExponent
        });
        s.configBuffer = configBuffer;
        s.ifBufferExists = true;

        s.registryState.nextCycleRegistryMaxGasCap = _registryMaxGasCap;
        s.registryState.nextCycleSysRegistryMaxGasCap = _sysRegistryMaxGasCap;

        emit ConfigBufferUpdated(configBuffer);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::  

    /// @notice Returns the VM Signer address.
    function getVmSigner() external view returns (address) {
        return s.vmSigner;
    }

    /// @notice Returns the ERC20Supra address.
    function erc20Supra() external view returns (address) {
        return s.erc20Supra;
    }

    /// @notice Returns if task registration is enabled.
    function isRegistrationEnabled() external view returns (bool) {
        return s.registrationEnabled;
    }

    /// @notice Returns the registry configuration.
    function getConfig() external view returns (Config memory) {
        return s.activeConfig;
    }

    /// @notice Returns the pending configuration.
    function getConfigBuffer() external view returns (Config memory) {
        return s.configBuffer;
    }
}