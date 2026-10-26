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
/// - `init` runs via delegatecall from `LibDiamond.diamondCut`, executing in the
///   Diamond's own storage, and is `initializer`-guarded so it runs at most once
///   per Diamond (smr-moonshot#3451).
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

    /// @dev Default task-registration input size caps, in bytes. The payload and predicate caps
    ///      are multiples of 32, the length granularity of an ABI-encoded payloadTx or predicate
    ///      (LibCommon.validateDataLengthCaps); init validates and stores these same constants.
    uint16 internal constant DEFAULT_MAX_PAYLOAD_LENGTH = 4096;
    uint16 internal constant DEFAULT_MAX_PREDICATE_LENGTH = 2048;

    /// @dev Default gas figures that size a `processTasks` bookkeeping record
    ///      (LibCommon.recordMaxTaskCount, Entropy-Foundation/smr-moonshot#4755), from
    ///      test/CycleTransitionGas.t.sol at a 200-task registry, measured with the registry's
    ///      storage cold as in a record transaction. The test asserts the measured batches
    ///      against these figures.
    ///      - A removed task costs 109,099 gas with the fixture's 24 words of payload and
    ///        predicate (scenario 2) and 487,432 with 192 words at the default data-length
    ///        caps (scenario 4): 2,252 gas per stored word on top of 55,051. Rounded up:
    ///        DEFAULT_RECORD_GAS_PER_STORED_WORD = 2,500, DEFAULT_RECORD_GAS_PER_TASK = 60,000.
    ///        A task that survives a transition costs less (scenario 1, about 40,000).
    ///      - The batch finalizing a FINISHED -> STARTED transition costs 1,366,562 gas more than
    ///        its tasks at the average non-final rate, 6,832 per task of the 200 the registry
    ///        holds (scenario 1). Per surviving task the premium grows with the registry: about
    ///        5,970 at 100 tasks and 7,441 at 400, and 7,933 at 310 tasks, where the final batch
    ///        carries 10. DEFAULT_RECORD_FINALIZATION_GAS_PER_TASK = 8,500 covers registries of
    ///        up to 400 tasks; a larger capacity needs the benchmark re-run at that size.
    uint64 internal constant DEFAULT_RECORD_GAS_PER_TASK = 60_000;
    uint64 internal constant DEFAULT_RECORD_GAS_PER_STORED_WORD = 2_500;
    uint64 internal constant DEFAULT_RECORD_FINALIZATION_GAS_PER_TASK = 8_500;

    /// @notice Initializes Automation Registry state in Diamond storage
    /// @param _params Initialization parameters for the Automation Registry.
    /// @param _erc20Supra Address of the WrappedSupra contract.
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
        // validateDataLengthCaps enforces word alignment here as in
        // ConfigFacet.updateDataLengthCaps, on the same constants that are stored.
        LibCommon.validateDataLengthCaps(DEFAULT_MAX_PAYLOAD_LENGTH, DEFAULT_MAX_PREDICATE_LENGTH);
        s.maxPayloadLength = DEFAULT_MAX_PAYLOAD_LENGTH;
        s.maxPredicateLength = DEFAULT_MAX_PREDICATE_LENGTH;
        s.maxAuxDataLength = 0;
        s.maxAuxDataEntries = 0;

        // Default record gas figures. Only the non-zero check applies here: the check against
        // the per-transaction cap (LibCommon.requireRecordBudgetFits) reads the gas config
        // precompile, which does not serve a value when the registry is initialised. The owner
        // changes them with ConfigFacet.updateRecordGasParameters.
        LibCommon.validateRecordGasParameters(
            DEFAULT_RECORD_GAS_PER_TASK,
            DEFAULT_RECORD_GAS_PER_STORED_WORD,
            DEFAULT_RECORD_FINALIZATION_GAS_PER_TASK
        );
        s.recordGasPerTask = DEFAULT_RECORD_GAS_PER_TASK;
        s.recordGasPerStoredWord = DEFAULT_RECORD_GAS_PER_STORED_WORD;
        s.recordFinalizationGasPerTask = DEFAULT_RECORD_FINALIZATION_GAS_PER_TASK;

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

        // Set last, after every other write above has succeeded: this is the single flag
        // DiamondLoupeFacet.isInitialized() (IRegistryStatus) reads. It can never be set back
        // to false -- the `initializer` modifier above makes this whole function unrunnable a
        // second time -- so once true it stays true for the life of this Diamond.
        ds.initialized = true;
    }

}
