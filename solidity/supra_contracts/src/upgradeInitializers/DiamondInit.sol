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

import { AppStorage, Config, LibAppStorage, RecordSizingParameters, RegistryState} from "../libraries/LibAppStorage.sol";
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
        
        s.configuration[LibAppStorage.ACTIVE_ENTRY] = activeConfig;

        s.automationEnabled = _params.automationEnabled;
        s.registrationEnabled = _params.registrationEnabled;
        s.erc20Supra = _erc20Supra;

        // Default task-registration input size caps. Generous relative to real CALL-only
        // payloads (CREATE payloads are not supported) — see ConfigFacet.updateDataLengthCaps
        // for the owner-only path to raise them later without a contract upgrade.
        // validateDataLengthCaps enforces word alignment here as in
        // ConfigFacet.updateDataLengthCaps, on the same constants that are stored.
        LibCommon.validateDataLengthCaps(DEFAULT_MAX_PAYLOAD_LENGTH, DEFAULT_MAX_PREDICATE_LENGTH);
        s.dataLengthCaps[LibAppStorage.ACTIVE_ENTRY] = LibCommon.newDataLengthCaps(DEFAULT_MAX_PAYLOAD_LENGTH, DEFAULT_MAX_PREDICATE_LENGTH, 0, 0);

        // Records are sized for the stored-words bound of the caps in force; no task is
        // registered yet (AppStorage.taskStoredWordsBound, Entropy-Foundation/smr-moonshot#4755).
        s.taskStoredWordsBound = LibAppStorage.activeDataLengthCaps().storedWords;

        // Default record sizing parameters (AppStorage.recordSizingParameters,
        // Entropy-Foundation/smr-moonshot#4755): the largest task-support percentage the benchmark
        // supports, and as maxCapacity the capacity the gas figures in LibCommon were measured at,
        // or the initial capacity if larger: InitParams carries no maxCapacity, so a larger
        // genesis capacity declares, as raising maxCapacity later does, that the benchmark was run
        // at that size. Genesis uses MAX_SUPPORTED_AUTOMATION_TASKS (crates/supra-extension),
        // below the measured capacity, and a compile-time assertion there keeps it so. A larger
        // initial capacity is accepted rather than refused because the registry's own gas
        // benchmarks deploy above it (MonitorCycleEndGas.t.sol scans up to 4,000 tasks) and
        // cannot raise the capacity after genesis without a cycle boundary changing what they
        // measure. Only the range checks apply here: the check against the
        // per-transaction cap (LibCommon.requireRecordSizingFits) reads the gas config
        // precompile, which does not serve a value when the registry is initialised.
        uint256 initialCapacity = uint256(_params.taskCapacity) + uint256(_params.sysTaskCapacity);
        uint32 maxCapacity = LibCommon.RECORD_GAS_BENCHMARK_CAPACITY;
        // A sum of two uint16 capacities fits a uint32.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (initialCapacity > maxCapacity) { maxCapacity = uint32(initialCapacity); }
        RecordSizingParameters memory recordSizingParameters = RecordSizingParameters({
            taskSupportPercentage: LibCommon.MAX_RECORD_TASK_SUPPORT_PERCENTAGE,
            maxCapacity: maxCapacity
        });
        LibCommon.validateRecordSizingParameters(recordSizingParameters);
        s.recordSizingParameters[LibAppStorage.ACTIVE_ENTRY] = recordSizingParameters;

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
