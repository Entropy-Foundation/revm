// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
*
* Implementation of a diamond.
/******************************************************************************/

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { IDiamondLoupe } from "../interfaces/IDiamondLoupe.sol";
import { IDiamondCut } from "../interfaces/IDiamondCut.sol";
import { IERC173 } from "../interfaces/IERC173.sol";
import { IERC165 } from "../interfaces/IERC165.sol";

import { AppStorage, Config } from "../libraries/LibAppStorage.sol";
import { LibUtils } from "../libraries/LibUtils.sol";

/// @title DiamondInit
/// @notice Initialization contract for the Automation Registry
/// @dev
/// EIP-2535 specifies that the `diamondCut` function takes two optional 
/// arguments: address _init and bytes calldata _calldata
/// These arguments are used to execute an arbitrary function using delegatecall
/// in order to set state variables in the diamond during deployment or an upgrade
/// More info here: https://eips.ethereum.org/EIPS/eip-2535#diamond-interface 
///
/// - This contract is NOT a facet and MUST NOT be added to the Diamond.
/// - The `init` function selector is never registered and is therefore
///   not callable through the Diamond after deployment.
///
/// This initializer performs the following actions:
/// - Registers supported interfaces for ERC-165, IDiamondCut, IDiamondLoupe, and ERC-173.
/// - Sets the active registry configuration, protocol feature flags and trusted addresses.
/// - Establishes initial automation cycle state, index, and timestamp.
contract DiamondInit {   
    AppStorage internal s;

    /// @notice Initializes Automation Registry state in Diamond storage
    /// @param _taskDurationCapSecs Maximum allowable duration (in seconds) from the registration time that a user automation task can run.
    /// @param _registryMaxGasCap Maximum gas allocation for automation tasks per cycle.
    /// @param _automationBaseFeeWeiPerSec Base fee per second for the full capacity of the automation registry, measured in wei/sec.
    /// @param _flatRegistrationFeeWei Flat registration fee charged by default for each task.
    /// @param _congestionThresholdPercentage Percentage representing the acceptable upper limit of committed gas amount relative to registry_max_gas_cap.
    /// Beyond this threshold, congestion fees apply.
    /// @param _congestionBaseFeeWeiPerSec Base fee per second for the full capacity of the automation registry when the congestion threshold is exceeded.
    /// @param _congestionExponent The congestion fee increases exponentially based on this value, ensuring higher fees as the registry approaches full capacity.
    /// @param _taskCapacity Maximum number of tasks that the registry can hold.
    /// @param _cycleDurationSecs Automation cycle duration in seconds.
    /// @param _sysTaskDurationCapSecs Maximum allowable duration (in seconds) from the registration time that a system automation task can run.
    /// @param _sysRegistryMaxGasCap Maximum gas allocation for system automation tasks per cycle.
    /// @param _sysTaskCapacity Maximum number of system tasks that the registry can hold.
    /// @param _vmSigner Address for the VM Signer.
    /// @param _erc20Supra Address of the ERC20Supra contract.
    /// @param _automationEnabled Whether automation should start immediately
    /// @param _registrationEnabled Whether registration should start immediately
    function init(
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
        uint16 _sysTaskCapacity,
        address _vmSigner,
        address _erc20Supra,
        bool _automationEnabled,
        bool _registrationEnabled
    ) external {
        // Adding ERC165 data
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;


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
        require(_vmSigner != address(0), LibUtils.AddressCannotBeZero());
        LibUtils.validateContractAddress(_erc20Supra);

        // ---------------------------------------------------------------------
        //                          Config initialization
        // ---------------------------------------------------------------------
        Config memory activeConfig = Config({ 
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
        
        s.activeConfig = activeConfig;

        s.automationEnabled = _automationEnabled;
        s.registrationEnabled = _registrationEnabled;
        s.vmSigner = _vmSigner;
        s.erc20Supra = _erc20Supra;

        // ---------------------------------------------------------------------
        //                          Cycle initialization
        // ---------------------------------------------------------------------
        (
            LibUtils.CycleState cycleState,
            uint64 cycleIndex
        ) = _automationEnabled
            ? (LibUtils.CycleState.STARTED, 1)
            : (LibUtils.CycleState.READY, 0);

        s.index  = cycleIndex;
        s.startTime  = uint64(block.timestamp);
        s.durationSecs  = _cycleDurationSecs;
        s.cycleState  = cycleState;

        // ---------------------------------------------------------------------
        //                      Registry state initialization
        // ---------------------------------------------------------------------
        s.registryState.nextCycleRegistryMaxGasCap = _registryMaxGasCap;
        s.registryState.nextCycleSysRegistryMaxGasCap = _sysRegistryMaxGasCap;
    }
}
