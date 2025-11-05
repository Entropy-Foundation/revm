// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AutomationStorage} from "./AutomationStorage.sol";
import {IAutomationController} from "./IAutomationController.sol";
import {IAutomationRegistry} from "./IAutomationRegistry.sol";
import {Ownable2StepUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

contract AutomationRegistry is IAutomationRegistry, Ownable2StepUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using AutomationStorage for *;

    /// @dev Constant to raise to the power of 10^8
    uint256 constant DECIMAL = 100_000_000;

    /// @dev Refund fraction
    uint8 constant REFUND_FRACTION = 2;

    /// @dev Supported auxiliary data count
    uint8 constant SUPPORTED_AUX_DATA_COUNT_MAX = 2;
    /// @dev Index of the auxiliary data holding task type value
    uint8 constant TYPE_AUX_DATA_INDEX = 0;
    /// @dev Index of the auxiliary data holding task priority value
    uint8 constant PRIORITY_AUX_DATA_INDEX = 1;

    
    AutomationStorage.RegistryConfig public config;
    AutomationStorage.RegistryState internal regState;
    AutomationStorage.RegistryStateSystemTasks internal regSysState;
    AutomationStorage.Deposit public deposit;

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: EVENTS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @notice Emitted when a user task is registered.
    event TaskRegistered(uint64 indexed taskIndex, address indexed owner, uint128 registrationFee, uint128 lockedDepositFee);

    /// @notice Emitted when a system task is registered.
    event SystemTaskRegistered(uint64 indexed taskIndex, address indexed owner, uint256 timestamp);
    
    /// @notice Emitted when an account is authorized as submitter for system tasks.
    event AuthorizationGranted(address indexed account, uint256 timestamp);
    
    /// @notice Emitted when authorization is revoked for an account to submit system tasks.
    event AuthorizationRevoked(address indexed account, uint256 timestamp);


    modifier onlyController() {
        if(msg.sender != address(config.controller)) { revert CallerNotController(); }
        _;
    }

    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the configuration parameters of the registry, can only be called once.
    /// @param _taskDurationCapSecs Maximum allowable duration (in seconds) from the registration time that a user automation task can run.
    /// @param _registryMaxGasCap Maximum gas allocation for automation tasks per cycle.
    /// @param _automationBaseFeeWeiPerSec Base fee per second for the full capacity of the automation registry, measured in wei/sec.
    /// @param _flatRegistrationFeeWei Flat registration fee charged by default for each task.
    /// @param _congestionThresholdPercentage Percentage representing the acceptable upper limit of committed gas amount relative to registry_max_gas_cap.
    /// Beyond this threshold, congestion fees apply.
    /// @param _congestionBaseFeeWeiPerSec Base fee per second for the full capacity of the automation registry when the congestion threshold is exceeded.
    /// @param _congestionExponent The congestion fee increases exponentially based on this value, ensuring higher fees as the registry approaches full capacity.
    /// @param _userTaskCapacity Maximum number of user tasks that the registry can hold.
    /// @param _cycleDurationSecs Automation cycle duration in secods
    /// @param _sysTaskDurationCapSecs Maximum allowable duration (in seconds) from the registration time that a system automation task can run.
    /// @param _sysRegistryMaxGasCap Maximum gas allocation for system automation tasks per cycle.
    /// @param _sysTaskCapacity Maximum number of system tasks that registry can hold.
    /// @param _controller Address of the AutomationController.
    function initialize(
        uint64 _taskDurationCapSecs,
        uint64 _registryMaxGasCap,
        uint64 _automationBaseFeeWeiPerSec,
        uint64 _flatRegistrationFeeWei,
        uint8 _congestionThresholdPercentage,
        uint64 _congestionBaseFeeWeiPerSec,
        uint8 _congestionExponent,
        uint16 _userTaskCapacity,
        uint64 _cycleDurationSecs,
        uint64 _sysTaskDurationCapSecs,
        uint64 _sysRegistryMaxGasCap,
        uint16 _sysTaskCapacity,
        address _controller
    ) public initializer {
        config.taskDurationCapSecs = _taskDurationCapSecs;
        config.registryMaxGasCap = _registryMaxGasCap;
        config.automationBaseFeeWeiPerSec = _automationBaseFeeWeiPerSec;
        config.flatRegistrationFeeWei = _flatRegistrationFeeWei;
        config.congestionThresholdPercentage = _congestionThresholdPercentage;
        config.congestionBaseFeeWeiPerSec = _congestionBaseFeeWeiPerSec;
        config.congestionExponent = _congestionExponent;
        config.userTaskCapacity = _userTaskCapacity;
        config.cycleDurationSecs = _cycleDurationSecs;
        config.sysTaskDurationCapSecs = _sysTaskDurationCapSecs;
        config.sysRegistryMaxGasCap = _sysRegistryMaxGasCap;
        config.sysTaskCapacity = _sysTaskCapacity;
        config.registrationEnabled = true;
        config.controller = _controller;

        __Ownable2Step_init();
        __Pausable_init();
    }

    function validateTaskDuration(
        uint64 _regTime,
        uint64 _expiryTime,    
        AutomationStorage.TaskType _type,
        uint64 _taskDurationCapSecs,
        uint64 _sysTaskDurationCapSecs,
        uint64 _cycleStartTime, 
        uint64 _cycleDurationSecs
    ) private pure {
        if(_expiryTime <= _regTime) { revert InvalidExpiryTime(); }
        
        uint64 taskDuration = _expiryTime - _regTime;
        if(_type == AutomationStorage.TaskType.UST) {
            if(taskDuration > _taskDurationCapSecs) { revert InvalidTaskDuration(); }
        } else if(_type == AutomationStorage.TaskType.GST) {
            if ( taskDuration > _sysTaskDurationCapSecs) { revert InvalidTaskDuration(); }
        } else {
            revert InvalidTypeForTask();
        }

        if( _expiryTime <= _cycleStartTime + _cycleDurationSecs) { revert TaskExpiresBeforeNextCycle(); }
    }

    function calculateAutomationCongestionFee(
        uint128 _totalCommittedGas,
        uint128 _registryMaxGasCap
    ) public view returns (uint128 congestionFee) {
        if (config.congestionThresholdPercentage == 100 || config.congestionBaseFeeWeiPerSec == 0) { return 0; }
    
        // Calculate usage percentage in basis points
        // thresholdUsage = (totalCommittedGas / maxGasCap) * 100
        uint256 thresholdUsageScaled = (uint256(_totalCommittedGas) * DECIMAL * 100) / uint256(_registryMaxGasCap);

        uint256 thresholdPercentageScaled = uint256(config.congestionThresholdPercentage) * DECIMAL;
    
        // If below threshold → no congestion fee
        if (thresholdUsageScaled <= thresholdPercentageScaled) {
            return 0;
        } else {
            // Calculate how much usage exceeds threshold (normalized surplus)
            uint256 surplusScaled = (thresholdUsageScaled - thresholdPercentageScaled) / 100;

            uint256 thresholdScaledAsFraction = thresholdPercentageScaled / 100; // still DECIMAL-scaled fraction
            uint256 surplusClipped;
            if (thresholdScaledAsFraction + surplusScaled > DECIMAL) {
                surplusClipped = DECIMAL - thresholdScaledAsFraction;
            } else {
                surplusClipped = surplusScaled;
            }


            // Exponentiation: result = (surplusClipped ^ exponent) in DECIMAL-scaled arithmetic
            // we compute exponentResult as DECIMAL if exponent==0 else multiply iteratively
            uint256 exponentResult = DECIMAL; // start as 1.0 in scaled domain
            uint8 exp = config.congestionExponent;
            if (exp == 0) {
                exponentResult = DECIMAL;
            } else {
                exponentResult = surplusClipped; // first power
                for (uint8 i = 1; i < exp; i++) {
                    // multiply and re-normalize by DECIMAL each iteration
                    exponentResult = (exponentResult * surplusClipped) / DECIMAL;
                }
            }

            // Multiply base fee (wei/sec) with exponentResult and downscale by DECIMAL
            uint256 acf = (uint256(config.congestionBaseFeeWeiPerSec) * exponentResult) / DECIMAL;

            // safe to cast back to uint128 (config uses uint128)
            congestionFee = uint128(acf);
            return congestionFee;
        }
    }

    function calculateAutomationFeeMultiplierForEpoch(
        uint128 _totalCommittedGas,
        uint128 _registryMaxGasCap,
        uint128 _automationBaseFeeWeiPerSec
    ) private view returns (uint128){
        uint128 congesionFee = calculateAutomationCongestionFee(_totalCommittedGas, _registryMaxGasCap);
        return (congesionFee + _automationBaseFeeWeiPerSec);
    }

    function calculateAutomationFeeForInterval(
        uint64 _duration,
        uint128 _taskOccupancy,
        uint128 _automationFeePerSec,
        uint128 _registryMaxGasCap
    ) public pure returns (uint128) {
        uint256 taskOccupancyRatioByDuration = (uint256(_duration) * uint256(_taskOccupancy) * DECIMAL) / uint256(_registryMaxGasCap);

        uint256 automationFeeForInterval = _automationFeePerSec * taskOccupancyRatioByDuration;

        return uint128(automationFeeForInterval);
    }

    function estimateAutomationFeeWithCommittedOccupancy(
        uint128 _taskOccupancy,
        uint128 _committedOccupancy,
        uint64 _duration
    ) private view returns (uint128) {
        uint128 totalCommittedGas = _taskOccupancy + _committedOccupancy;
         
        uint128 automationFeePerSec = calculateAutomationFeeMultiplierForEpoch(totalCommittedGas, config.registryMaxGasCap, config.automationBaseFeeWeiPerSec);

        if(automationFeePerSec == 0) return 0;

        return calculateAutomationFeeForInterval(_duration, _taskOccupancy, automationFeePerSec, config.registryMaxGasCap);
    }

    /// @notice Function to check and validate the input auxiliary data.
    /// @param _auxData Input auxiliary data.
    /// @param _taskType Type of the task.
    /// @return Bool representing if the task has priority.
    function checkAndValidateAuxData(bytes[] memory _auxData, AutomationStorage.TaskType _taskType) private pure returns (bool) {
        if(_auxData.length != SUPPORTED_AUX_DATA_COUNT_MAX) { revert InvalidAuxDataLength(); }

        // Check task type
        bytes memory taskType = _auxData[TYPE_AUX_DATA_INDEX];
        if(taskType.length != 1) { revert InvalidTaskTypeLength(); }
        uint8 typeValue = uint8(taskType[0]);
        if(typeValue != uint8(_taskType)) {revert InvalidTaskType(); }

        // Check if priority exists
        bytes memory priorityBytes = _auxData[PRIORITY_AUX_DATA_INDEX];
        bool hasNoPriority = (priorityBytes.length == 0);
        if (!hasNoPriority) {
            uint64 _priority = abi.decode(priorityBytes, (uint64));
        }

        return hasNoPriority;
    }

    /// @notice Function used to register a user task for automation.
    /// @param _payloadTx Includes the target smart contract address and the data to call in abi encoded form.
    /// @param _expiryTime Time after which the task gets expired.
    /// @param _txHash Transaction hash of the request transaction.
    /// @param _maxGasAmount Maximum amount of gas for the automation task.
    /// @param _gasPriceCap Maximum gas willing to pay for the task.
    /// @param _automationFeeCapForCycle Maximum automation fee for a cycle to be paid ever.
    /// @param _auxData Auxiliary data to be passed.
    function register(
        bytes memory _payloadTx,
        uint64 _expiryTime,
        bytes32 _txHash,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        bytes[] memory _auxData
    ) public payable whenNotPaused {
        // TO_DO: check if native automation is enabled

        bool hasNoPriority = checkAndValidateAuxData(_auxData, AutomationStorage.TaskType.UST);

        if(!config.registrationEnabled) { revert RegistrationDisabled(); }
        if(IAutomationController(config.controller).getCycleState() != 1) { revert CycleNotStarted(); }
        if(totalUserTasks() >= config.userTaskCapacity) { revert TaskCapacityReached(); }

        uint64 regTime = uint64(block.timestamp);
        uint64 startTime;
        uint64 durationSecs;
        (startTime, durationSecs) = IAutomationController(config.controller).getCycleInfo();
        validateTaskDuration(regTime, _expiryTime, AutomationStorage.TaskType.UST, config.taskDurationCapSecs, config.sysTaskDurationCapSecs, startTime, durationSecs);

        address payloadTarget;
        (payloadTarget, ) = abi.decode(_payloadTx, (address, bytes));
        if(payloadTarget == address(0)) { revert InvalidAddress(); }
        if(_maxGasAmount == 0) { revert InvalidMaxGasAmount(); }
        if(_gasPriceCap == 0) { revert InvalidGasPriceCap(); }
        if(_txHash == bytes32(0)) { revert InvalidTxHash(); }

        uint128 gasCommitted = _maxGasAmount + regState.gasCommittedForNextCycle;
        if(gasCommitted > config.registryMaxGasCap) { revert GasCommittedExceedsMaxGasCap(); }

        uint128 estimatedAutomationFeeCapForCycle = estimateAutomationFeeWithCommittedOccupancy(_maxGasAmount, regState.gasCommittedForNextCycle, durationSecs);
        if(_automationFeeCapForCycle < estimatedAutomationFeeCapForCycle) { revert InsufficientFeeCapForCycle(); }

        regState.gasCommittedForNextCycle = gasCommitted;
        uint64 taskIndex = regState.currentIndex; 

        if(hasNoPriority) { _auxData[PRIORITY_AUX_DATA_INDEX] = abi.encode(taskIndex); }
        AutomationStorage.TaskMetadata  memory taskMetadata = AutomationStorage.TaskMetadata (
            taskIndex,
            msg.sender,
            _payloadTx,
            _expiryTime,
            _txHash,
            _maxGasAmount,
            _gasPriceCap,
            _automationFeeCapForCycle,
            _auxData,
            regTime,
            AutomationStorage.TaskState.PENDING,
            _automationFeeCapForCycle 
        );
        
        regState.tasks[taskIndex] = taskMetadata; 
        regState.totalUserTasks += 1;
        regState.currentIndex += 1;

        uint128 fee = config.flatRegistrationFeeWei + _automationFeeCapForCycle;
        if(msg.value < uint256(fee)) {
            revert InsufficentValueSent();
        } else if(msg.value > uint256(fee)) {
            (bool sent, ) = payable(msg.sender).call{value: msg.value - fee}("");
            if(!sent) { revert TransferFailed(); }
        }

        deposit.totalDepositedAutomationFees += _automationFeeCapForCycle;

        emit TaskRegistered(taskIndex, msg.sender, config.flatRegistrationFeeWei, _automationFeeCapForCycle);
    }
    
    /// @notice Function to register a system task. Reverts if caller is not authorized.
    /// @param _payloadTx Includes the target smart contract address and the data to call in abi encoded form.
    /// @param _expiryTime Time after which the task gets expired.
    /// @param _txHash Transaction hash of the request transaction.
    /// @param _maxGasAmount Maximum amount of gas for the automation task.
    /// @param _auxData Auxiliary data to be passed.
    function registerSystemTask(
        bytes memory _payloadTx,
        uint64 _expiryTime,
        bytes32 _txHash,
        uint128 _maxGasAmount,
        bytes[] memory _auxData
    ) public payable whenNotPaused {
        // TO_DO: check if native automation is enabled
        
        bool hasNoPriority = checkAndValidateAuxData(_auxData, AutomationStorage.TaskType.GST);

        if(!config.registrationEnabled) { revert RegistrationDisabled(); }
        if(IAutomationController(config.controller).getCycleState() != 1) { revert CycleNotStarted(); }
        if(totalSystemTasks() >= config.sysTaskCapacity) { revert TaskCapacityReached(); }
        if(!isAuthorizedSubmitter(msg.sender)) { revert UnauthorizedAccount(); }

        uint64 regTime = uint64(block.timestamp);
        uint64 startTime;
        uint64 durationSecs;
        (startTime, durationSecs) = IAutomationController(config.controller).getCycleInfo();
        validateTaskDuration(regTime, _expiryTime, AutomationStorage.TaskType.GST, config.taskDurationCapSecs, config.sysTaskDurationCapSecs, startTime, durationSecs);

        address payloadTarget;
        (payloadTarget, ) = abi.decode(_payloadTx, (address, bytes));
        if( payloadTarget == address(0)) { revert InvalidAddress(); }
        if(_maxGasAmount == 0) { revert InvalidMaxGasAmount(); }
        if(_txHash == bytes32(0)) { revert InvalidTxHash(); }

        uint128 gasCommitted = _maxGasAmount + regSysState.gasCommittedForNextCycle;
        if(gasCommitted > config.sysRegistryMaxGasCap) { revert GasCommittedExceedsMaxGasCap(); }

        regSysState.gasCommittedForNextCycle = gasCommitted;

        uint64 taskIndex = regState.currentIndex; 

        if(hasNoPriority) {_auxData[PRIORITY_AUX_DATA_INDEX] = abi.encode(taskIndex); }
        AutomationStorage.TaskMetadata  memory taskMetadata = AutomationStorage.TaskMetadata (
            taskIndex,
            msg.sender,
            _payloadTx,
            _expiryTime,
            _txHash,
            _maxGasAmount,
            0,
            0,
            _auxData,
            regTime,
            AutomationStorage.TaskState.PENDING,
            0
        );

        regState.tasks[taskIndex] = taskMetadata; 
        regState.currentIndex += 1;
        EnumerableSet.add(regSysState.taskIds, taskIndex);

        emit SystemTaskRegistered(taskIndex, msg.sender, block.timestamp);
    }
    

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::: System Task Submitter ::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Grants authorization to the input account to submit system automation tasks.
    /// @param _account Address to grant authorization to.
    function grantAuthorization(address _account) public onlyOwner {
        if(EnumerableSet.contains(regSysState.authorizedAccounts, _account)) {
            revert AddressAlreadyExists();
        } else {
            EnumerableSet.add(regSysState.authorizedAccounts, _account);
            
            emit AuthorizationGranted(_account, block.timestamp);
        }
    }

    /// @notice Revokes authorization from the input account to submit system automation tasks. 
    /// @param _account Address to revoke authorization from. 
    function revokeAuthorization(address _account) public onlyOwner {
        if(!EnumerableSet.contains(regSysState.authorizedAccounts, _account)) {
            revert AddressDoesNotExist();
        } else {
            EnumerableSet.remove(regSysState.authorizedAccounts, _account);

            emit AuthorizationRevoked(_account, block.timestamp);
        }
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::: View Functions ::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Returns the number of total user tasks.
    function totalUserTasks() public view returns (uint16) {
        return regState.totalUserTasks;
    }

    /// @notice Returns the number of total system tasks.
    function totalSystemTasks() public view returns (uint256) {
        return EnumerableSet.length(regSysState.taskIds);
    }

    /// @notice Returns the next task index.
    function getNextTaskIndex() public view returns (uint64) {
        return regState.currentIndex;
    }

    /// @notice Returns the details of a task.
    /// @param _taskIndex Task index to get details for.
    function getTaskDetails(uint64 _taskIndex) public view returns (AutomationStorage.TaskMetadata memory) {
        return regState.tasks[_taskIndex];
    }
    
    /// @notice Checks if a task exist.
    /// @param _taskIndex Task index to check if a task exists against it.
    function ifTaskExists(uint64 _taskIndex) public view returns (bool) {
        return regState.tasks[_taskIndex].taskIndex != 0;
    }

    /// @notice Checks if a task is UST or GST.
    /// @param _taskIndex Task index of the task to check for.
    function isUST(uint64 _taskIndex) public view returns (bool) {
        bytes memory taskType = regState.tasks[_taskIndex].auxData[TYPE_AUX_DATA_INDEX];
        return uint8(taskType[0]) == uint8(AutomationStorage.TaskType.UST);
    }

    /// @notice Returns the owner of the task 
    /// @param _taskIndex Task index of the task to query.
    function getTaskOwner(uint64 _taskIndex) public view returns (address) {
        return regState.tasks[_taskIndex].owner;
    }

    /// @notice Returns the gas committed for the next cycle.
    function getGasCommittedForNextCycle() public view returns (uint128) {
        return regState.gasCommittedForNextCycle;
    }

    /// @notice Returns the gas committed for the current cycle.
    function getGasCommittedForCurrentCycle() public view returns (uint128) {
        return regState.gasCommittedForThisCycle;
    }

    /// @notice Returns the total amount of automation fees deposited.
    function getTotalDepositedAutomationFees() public view returns (uint256) {
        return deposit.totalDepositedAutomationFees;
    }

    /// @notice Returns the registry max gas cap configured.
    function getRegistryMaxGasCap() public view returns (uint128) {
        return config.registryMaxGasCap;
    }

    /// @notice Checks if the input account is an authorized submitter to submit system automation tasks.
    /// @param _account Address to check if it's authorized.
    function isAuthorizedSubmitter(address _account) public view returns (bool) {
        return EnumerableSet.contains(regSysState.authorizedAccounts, _account);
    }


    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Controller Functions :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    function removeSysTask(uint64 _taskIndex) external onlyController {
        EnumerableSet.remove(regSysState.taskIds, _taskIndex);
    }

    function removeTask(uint64 _taskIndex) external onlyController {
        delete regState.tasks[_taskIndex];
    }

    function updateTaskState(uint64 _taskIndex, AutomationStorage.TaskState _taskState) external onlyController {
        regState.tasks[_taskIndex].state = _taskState;
    }

    function updateTotalDepositedAutomationFees(uint256 _updatedValue) external onlyController {
        deposit.totalDepositedAutomationFees = _updatedValue;
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Upgradeability Functions :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
