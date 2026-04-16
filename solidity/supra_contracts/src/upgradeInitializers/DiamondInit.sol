// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/******************************************************************************\
* Credits: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
*
* Implementation of a diamond.
/******************************************************************************/

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { IDiamondLoupe } from "../interfaces/IDiamondLoupe.sol";
import { IDiamondCut } from "../interfaces/IDiamondCut.sol";
import { IERC173 } from "../interfaces/IERC173.sol";
import { IERC165 } from "../interfaces/IERC165.sol";

import { AppStorage, Config, LibAppStorage, RegistryState} from "../libraries/LibAppStorage.sol";
import { LibCommon } from "../libraries/LibCommon.sol";
import { LibUtils } from "../libraries/LibUtils.sol";
import { InitParams } from "../libraries/LibDiamondUtils.sol";

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
    /// @param _params Initialization parameters for the Automation Registry.
    /// @param _erc20Supra Address of the ERC20Supra contract.
    function init(
        InitParams memory _params,
        address _erc20Supra
    ) external {
        // Adding ERC165 data
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;


        LibCommon.validateConfigParameters(
            _params.taskDurationCapSecs,
            _params.registryMaxGasCap,
            _params.congestionThresholdPercentage,
            _params.congestionExponent,
            _params.taskCapacity,
            _params.cycleDurationSecs,
            _params.sysTaskDurationCapSecs,
            _params.sysRegistryMaxGasCap,
            _params.sysTaskCapacity
        );
        LibUtils.validateContractAddress(_erc20Supra);

        // ---------------------------------------------------------------------
        //                          Config initialization
        // ---------------------------------------------------------------------
        Config memory activeConfig = Config({ 
            registryMaxGasCap: _params.registryMaxGasCap, 
            sysRegistryMaxGasCap: _params.sysRegistryMaxGasCap, 
            automationBaseFeeWeiPerSec: _params.automationBaseFeeWeiPerSec, 
            flatRegistrationFeeWei: _params.flatRegistrationFeeWei, 
            congestionBaseFeeWeiPerSec: _params.congestionBaseFeeWeiPerSec, 
            taskDurationCapSecs: _params.taskDurationCapSecs, 
            sysTaskDurationCapSecs: _params.sysTaskDurationCapSecs, 
            cycleDurationSecs: _params.cycleDurationSecs, 
            taskCapacity: _params.taskCapacity, 
            sysTaskCapacity: _params.sysTaskCapacity, 
            congestionThresholdPercentage: _params.congestionThresholdPercentage, 
            congestionExponent: _params.congestionExponent 
        });
        
        s.configuration[LibAppStorage.ACTIVE_CONFIG] = activeConfig;

        s.automationEnabled = _params.automationEnabled;
        s.registrationEnabled = _params.registrationEnabled;
        s.erc20Supra = _erc20Supra;

        // ---------------------------------------------------------------------
        //                          Cycle initialization
        // ---------------------------------------------------------------------
        (
            LibCommon.CycleState cycleState,
            uint64 cycleIndex
        ) = _params.automationEnabled
            ? (LibCommon.CycleState.STARTED, 1)
            : (LibCommon.CycleState.READY, 0);

        s.index  = cycleIndex;
        s.startTime  = uint64(block.timestamp);
        s.durationSecs  = _params.cycleDurationSecs;
        s.cycleState  = cycleState;

        // ---------------------------------------------------------------------
        //                      Registry state initialization
        // ---------------------------------------------------------------------
        RegistryState storage registryState = LibAppStorage.registryState();
        registryState.nextCycleRegistryMaxGasCap = _params.registryMaxGasCap;
        registryState.nextCycleSysRegistryMaxGasCap = _params.sysRegistryMaxGasCap;
    }

}
