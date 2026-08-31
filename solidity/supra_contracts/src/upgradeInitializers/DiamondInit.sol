// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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
import { ICoreFacet } from "../interfaces/ICoreFacet.sol";
import { IConfigFacet } from "../interfaces/IConfigFacet.sol";
import { IRegistryFacet } from "../interfaces/IRegistryFacet.sol";
import { IRegistryStatus } from "../interfaces/IRegistryStatus.sol";

import { AppStorage, Config, LibAppStorage, RegistryState} from "../libraries/LibAppStorage.sol";
import { LibCommon } from "../libraries/LibCommon.sol";
import { LibUtils } from "../libraries/LibUtils.sol";
import { InitParams } from "../libraries/DiamondTypes.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

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
/// - `init` runs via delegatecall from `LibDiamond.diamondCut`, so it executes in the
///   Diamond's own storage.
///
/// This initializer performs the following actions:
/// - Registers supported interfaces for ERC-165, IDiamondCut, IDiamondLoupe, ERC-173,
///   IRegistryStatus.
/// - Sets the active registry configuration, protocol feature flags and trusted addresses.
/// - Establishes initial automation cycle state, index, and timestamp.
///
/// Later versions of DiamondInit re-initializing the state must use `reinitializer(N)` function tag
/// to have a successful outcome.
contract DiamondInit is Initializable {

    /// @notice Initializes Automation Registry state in Diamond storage
    /// @param _params Initialization parameters for the Automation Registry.
    /// @param _erc20Supra Address of the ERC20Supra contract.
    function init(
        InitParams memory _params,
        address _erc20Supra
    ) external initializer {
        AppStorage storage s = LibAppStorage.appStorage();

        // Adding ERC165 data. Registered once, at genesis, for the facet set present then;
        // not reconciled by later diamondCut calls — a facet added, replaced or removed
        // post-genesis does not update this mapping.
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;
        ds.supportedInterfaces[type(IRegistryStatus).interfaceId] = true;


        LibCommon.validateConfigParameters(
            _params.taskDurationCapSecs,
            _params.registryMaxGasCap,
            _params.congestionThresholdPercentage,
            _params.congestionExponent,
            _params.maxCongestionExponent,
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
            congestionExponent: _params.congestionExponent,
            maxCongestionExponent: _params.maxCongestionExponent
        });
        
        s.configuration[LibAppStorage.ACTIVE_CONFIG] = activeConfig;

        s.automationEnabled = _params.automationEnabled;
        s.registrationEnabled = _params.registrationEnabled;
        s.erc20Supra = _erc20Supra;

        // Default task-registration input size caps. Generous relative to real CALL-only
        // payloads (CREATE payloads are not supported) — see ConfigFacet.updateDataLengthCaps
        // for the owner-only path to raise them later without a contract upgrade.
        s.maxPayloadLength = 4096;
        s.maxPredicateLength = 2048;
        s.maxAuxDataLength = 0;
        s.maxAuxDataEntries = 0;

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
