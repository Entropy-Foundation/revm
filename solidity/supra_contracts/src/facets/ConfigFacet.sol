// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AppStorage, Config, RegistryState, LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCommon} from "../libraries/LibCommon.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {IConfigFacet} from "../interfaces/IConfigFacet.sol";
import {IFacetSelectors} from "../interfaces/IFacetSelectors.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract ConfigFacet is IConfigFacet, IFacetSelectors {
    using EnumerableSet for *;

    /// @dev State variables
    AppStorage internal s;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ADMIN FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Grants authorization to the input account to submit system automation tasks. 
    /// It is foundation governance responsibility to make sure that the target is and instance of `MultiSignatureWallet`
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

    /// @notice Function to withdraw the accumulated fees.
    /// @param _amount Amount to withdraw.
    /// @param _recipient Address to withdraw fees to.
    function withdrawFees(uint256 _amount, address _recipient) external {
        LibDiamond.enforceIsContractOwner();

        if (_amount == 0) { revert InvalidAmount(); }
        LibUtils.validateAddress(_recipient);
        uint256 balance = IERC20(s.erc20Supra).balanceOf(address(this));

        if (balance < _amount) { revert InsufficientBalance(); }
        
        RegistryState storage registryState = LibAppStorage.registryState();
        if (balance - _amount < registryState.cycleLockedFees + registryState.totalDepositedAutomationFees) { revert RequestExceedsLockedBalance(); }

        bool sent = IERC20(s.erc20Supra).transfer(_recipient, _amount);
        if (!sent) { revert TransferFailed(); }

        emit RegistryFeeWithdrawn(_recipient, _amount);
    }

    /// @notice Function to update the registry configuration buffer.
    /// @dev `_taskCapacity` and `_sysTaskCapacity` bound how many tasks `CoreFacet.monitorCycleEnd()`
    ///      iterates over each cycle, so raising them raises that function's per-call gas cost.
    ///      `monitorCycleEnd()` is invoked once per block as a single registered entry in the
    ///      separate `BlockMeta` contract's `blockPrologue()` dispatch loop, under the fixed
    ///      per-entry gas limit it was registered with there (see `BlockMeta.getExecutionGasLimit`)
    ///      and `BlockMeta`'s own `blockPrologueGasCap`. This contract has no on-chain reference to
    ///      `BlockMeta` and intentionally does not cap `_taskCapacity`/`_sysTaskCapacity` against it,
    ///      so task-capacity growth stays possible without an upgrade here. That means increasing
    ///      these values is NOT automatically safe: before calling this with a higher capacity,
    ///      verify off-chain that the resulting worst-case `monitorCycleEnd()` gas cost still fits
    ///      under `BlockMeta`'s registered gas limit for it, or `blockPrologue()` will start
    ///      reverting/OOG-ing on that entry every block.
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
    ) external {
        LibDiamond.enforceIsContractOwner();

        LibCommon.validateConfigParameters(
            _taskDurationCapSecs,
            _registryMaxGasCap,
            _congestionThresholdPercentage,
            _congestionExponent,
            _maxCongestionExponent,
            _taskCapacity,
            _cycleDurationSecs,
            _sysTaskDurationCapSecs,
            _sysRegistryMaxGasCap,
            _sysTaskCapacity
        );

        RegistryState storage registryState = LibAppStorage.registryState();
        if (registryState.gasCommittedForNextCycle > _registryMaxGasCap) { revert UnacceptableRegistryMaxGasCap(); }
        if (registryState.sysGasCommittedForNextCycle > _sysRegistryMaxGasCap) { revert UnacceptableSysRegistryMaxGasCap(); }

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
            congestionExponent: _congestionExponent,
            maxCongestionExponent: _maxCongestionExponent
        });
        s.configuration[LibAppStorage.BUFFER_CONFIG] = configBuffer;
        s.ifBufferExists = true;

        registryState.nextCycleRegistryMaxGasCap = _registryMaxGasCap;
        registryState.nextCycleSysRegistryMaxGasCap = _sysRegistryMaxGasCap;

        emit ConfigBufferUpdated(configBuffer);
    }

    /// @notice Updates the task-registration input size caps. Takes effect immediately (unlike
    /// updateConfigBuffer) since these only gate new registrations, which are already blocked
    /// outside cycle state STARTED, so there's no mid-cycle-fairness reason to defer them.
    /// @param _maxPayloadLength Max length in bytes of a task's payloadTx.
    /// @param _maxPredicateLength Max length in bytes of a task's predicate.
    /// @param _maxAuxDataLength Max combined length in bytes across all of a task's auxData entries.
    /// @param _maxAuxDataEntries Max number of entries in a task's auxData array, bounded
    /// independently of _maxAuxDataLength.
    function updateDataLengthCaps(
        uint16 _maxPayloadLength,
        uint16 _maxPredicateLength,
        uint16 _maxAuxDataLength,
        uint16 _maxAuxDataEntries
    ) external {
        LibDiamond.enforceIsContractOwner();

        s.maxPayloadLength = _maxPayloadLength;
        s.maxPredicateLength = _maxPredicateLength;
        s.maxAuxDataLength = _maxAuxDataLength;
        s.maxAuxDataEntries = _maxAuxDataEntries;

        emit DataLengthCapsUpdated(_maxPayloadLength, _maxPredicateLength, _maxAuxDataLength, _maxAuxDataEntries);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

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
        return LibAppStorage.activeConfig();
    }

    /// @notice Returns the pending configuration.
    function getConfigBuffer() external view returns (Config memory) {
        return LibAppStorage.bufferConfig();
    }

    /// @notice Returns the current task-registration input size caps.
    function getDataLengthCaps() external view returns (uint16 maxPayloadLength, uint16 maxPredicateLength, uint16 maxAuxDataLength, uint16 maxAuxDataEntries) {
        maxPayloadLength = s.maxPayloadLength;
        maxPredicateLength = s.maxPredicateLength;
        maxAuxDataLength = s.maxAuxDataLength;
        maxAuxDataEntries = s.maxAuxDataEntries;
    }

    function getSelectors() external pure override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](12);
        selectors[0] = ConfigFacet.grantAuthorization.selector;
        selectors[1] = ConfigFacet.revokeAuthorization.selector;
        selectors[2] = ConfigFacet.enableRegistration.selector;
        selectors[3] = ConfigFacet.disableRegistration.selector;
        selectors[4] = ConfigFacet.withdrawFees.selector;
        selectors[5] = ConfigFacet.updateConfigBuffer.selector;
        selectors[6] = ConfigFacet.erc20Supra.selector;
        selectors[7] = ConfigFacet.isRegistrationEnabled.selector;
        selectors[8] = ConfigFacet.getConfig.selector;
        selectors[9] = ConfigFacet.getConfigBuffer.selector;
        selectors[10] = ConfigFacet.updateDataLengthCaps.selector;
        selectors[11] = ConfigFacet.getDataLengthCaps.selector;
    }
}
