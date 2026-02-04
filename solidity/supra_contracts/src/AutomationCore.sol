// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {CommonUtils} from "./CommonUtils.sol";
import {LibConfig} from "./LibConfig.sol";

import {IAutomationCore} from "./IAutomationCore.sol";
import {IAutomationController} from "./IAutomationController.sol";
import {IAutomationRegistry} from "./IAutomationRegistry.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";

contract AutomationCore is IAutomationCore, Ownable2StepUpgradeable, UUPSUpgradeable {
    using CommonUtils for *;
    using LibConfig for *;

    /// @dev Constant for 10^8
    uint256 constant DECIMAL = 100_000_000;

    /// @dev Constants describing REFUND TYPE
    uint8 constant DEPOSIT_CYCLE_FEE = 0;
    uint8 constant CYCLE_FEE = 1;

    /// @dev Refund fraction
    uint8 constant REFUND_FRACTION = 2;

    /// @dev State variables 
    LibConfig.ConfigBuffer configBuffer;
    LibConfig.RegistryConfig regConfig;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: EVENTS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Emitted when a new config is added.
    event ConfigBufferUpdated(LibConfig.ConfigDetails indexed pendingConfig);

    /// @notice Emitted when task registration is enabled.
    event TaskRegistrationEnabled(bool indexed status);

    /// @notice Emitted when task registration is disabled.
    event TaskRegistrationDisabled(bool indexed status);

    /// @notice Emitted when the VM Signer address is updated.
    event VmSignerUpdated(address indexed oldVmSigner, address indexed newVmSigner);

    /// @notice Emitted when the ERC20Supra address is updated.
    event Erc20SupraUpdated(address indexed oldErc20Supra, address indexed newErc20Supra);

    /// @notice Emitted when the automation controller smart contract address is updated. 
    event AutomationControllerUpdated(address indexed oldController, address indexed newController);

    /// @notice Emitted when the automation registry smart contract address is updated. 
    event AutomationRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    /// @notice Emitted when the registry fees is withdrawn by the admin.
    event RegistryFeeWithdrawn(address indexed recipient, uint256 indexed feesWithdrawn);

    /// @notice Emitted when deposit fee is being refunded but total locked deposits is less than the locked deposit for the task.
    event ErrorUnlockTaskDepositFee(
        uint64 indexed taskIndex, 
        uint256 indexed totalDepositedAutomationFees, 
        uint128 indexed lockedDeposit
    );

    /// @notice Emitted during cycle transition when refunds to be paid is not possible due to insufficient contract balance.
    /// Type of the refund can be related either to the deposit paid during registration (0), or to cycle fee caused by
    /// the shortening of the cycle (1)
    event ErrorInsufficientBalanceToRefund(
        uint64 indexed _taskIndex,
        address indexed _owner,
        uint8 indexed _refundType,
        uint128 _amount
    );

    /// @notice Emitted when a deposit fee is refunded for an automation task.
    event TaskDepositFeeRefund(uint64 indexed taskIndex, address owner, uint128 amount);

    /// @notice Emitted when an automation fee is refunded for an automation task at the end of the cycle for excessive
    /// duration paid at the beginning of the cycle due to cycle duration reduction by governance.
    event TaskFeeRefund(
        uint64 indexed taskIndex,
        address indexed owner,
        uint64 indexed amount
    );

    /// @notice Emitted when a task cycle fee is being refunded but locked cycle fees is less than the requested refund.
    event ErrorUnlockTaskCycleFee(
        uint64 indexed taskIndex,
        uint256 indexed lockedCycleFees,
        uint64 indexed refund
    );

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::: CONSTRUCTOR AND INITIALIZER ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

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
    /// @param _taskCapacity Maximum number of tasks that the registry can hold.
    /// @param _cycleDurationSecs Automation cycle duration in seconds.
    /// @param _sysTaskDurationCapSecs Maximum allowable duration (in seconds) from the registration time that a system automation task can run.
    /// @param _sysRegistryMaxGasCap Maximum gas allocation for system automation tasks per cycle.
    /// @param _sysTaskCapacity Maximum number of system tasks that the registry can hold.
    /// @param _vmSigner Address for the VM Signer.
    /// @param _erc20Supra Address of the ERC20Supra contract.
    function initialize(
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
        address _erc20Supra
    ) public initializer {
        validateConfigParameters(
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
        if(_vmSigner == address(0)) revert AddressCannotBeZero();
        _erc20Supra.validateContractAddress();


        LibConfig.Config memory config = LibConfig.createConfig(
            _registryMaxGasCap,
            _sysRegistryMaxGasCap,
            _automationBaseFeeWeiPerSec,
            _flatRegistrationFeeWei,
            _congestionBaseFeeWeiPerSec,
            _taskDurationCapSecs,
            _sysTaskDurationCapSecs,
            _cycleDurationSecs,
            _taskCapacity,
            _sysTaskCapacity,
            _congestionThresholdPercentage,
            _congestionExponent
        );
        
        regConfig = LibConfig.createRegistryConfig(
            _registryMaxGasCap,
            _sysRegistryMaxGasCap,
            true,
            _vmSigner,
            _erc20Supra,
            config  
        );

        __Ownable2Step_init();
        __Ownable_init(msg.sender);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: HELPER FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function to validate the registry configuration parameters.
    function validateConfigParameters(
        uint64 _taskDurationCapSecs,
        uint128 _registryMaxGasCap,
        uint8 _congestionThresholdPercentage,
        uint8 _congestionExponent,
        uint16 _taskCapacity,
        uint64 _cycleDurationSecs,
        uint64 _sysTaskDurationCapSecs,
        uint128 _sysRegistryMaxGasCap,
        uint16 _sysTaskCapacity
    ) private pure {
        if(_taskDurationCapSecs <= _cycleDurationSecs) { revert InvalidTaskDuration(); }
        if(_registryMaxGasCap == 0) { revert InvalidRegistryMaxGasCap(); }
        if(_congestionThresholdPercentage > 100) { revert InvalidCongestionThreshold(); }
        if(_congestionExponent == 0) { revert InvalidCongestionExponent(); }
        if(_taskCapacity == 0) { revert InvalidTaskCapacity(); }
        if(_cycleDurationSecs == 0) { revert InvalidCycleDuration(); }
        if(_sysTaskDurationCapSecs <= _cycleDurationSecs) { revert InvalidSysTaskDuration(); }
        if(_sysRegistryMaxGasCap == 0) { revert InvalidSysRegistryMaxGasCap(); }
        if(_sysTaskCapacity == 0) { revert InvalidSysTaskCapacity(); }
    }

    /// @notice Helper function to validate the task duration.
    function validateTaskDuration(
        uint64 _regTime,
        uint64 _expiryTime,    
        uint64 _taskDurationCap,
        uint64 _cycleEndTime
    ) private pure {
        if(_expiryTime <= _regTime) { revert InvalidExpiryTime(); }
        
        uint64 taskDuration = _expiryTime - _regTime;
        if(taskDuration > _taskDurationCap) { revert InvalidTaskDuration(); }
        
        if( _expiryTime <= _cycleEndTime) { revert TaskExpiresBeforeNextCycle(); }
    }

    /// @notice Helper function to validate the inputs while registering a task.
    function validateInputs(bytes memory _payloadTx, uint128 _maxGasAmount, bytes32 _txHash) private view {
        ( , address payloadTarget, , ) = abi.decode(_payloadTx, (uint128, address, bytes, LibConfig.AccessListEntry[]));
        payloadTarget.validateContractAddress();
        
        if(_maxGasAmount == 0) { revert InvalidMaxGasAmount(); }
        if(_txHash == bytes32(0)) { revert InvalidTxHash(); }
    }

    /// @notice Function to ensure that AutomationController contract is the caller.
    function onlyController() private view {
        if(msg.sender != regConfig.automationController()) { revert CallerNotController(); }
    }

    /// @notice Function to ensure that AutomationRegistry contract is the caller.
    function onlyRegistry() private view {
        if(msg.sender != regConfig.registry) { revert CallerNotRegistry(); }
    }

    /// @notice Helper function to charge fees from the user.
    function chargeFees(address _from, uint256 _amount) external {
        if (msg.sender != regConfig.automationController() && msg.sender != regConfig.registry) { revert UnauthorizedCaller(); }

        bool sent = IERC20(regConfig.erc20Supra).transferFrom(_from, address(this), _amount);
        if(!sent) { revert TransferFailed(); }
    }

    /// @notice Function to calculate the automation congestion fee.
    /// @param _totalCommittedGas Total committed gas.
    /// @param _registryMaxGasCap Registry max gas cap.
    /// @return Returns the automation congestion fee.
    function calculateAutomationCongestionFee(
        uint128 _totalCommittedGas,
        uint128 _registryMaxGasCap
    ) private view returns (uint128) {
        if (regConfig.congestionThresholdPercentage() == 100 || regConfig.congestionBaseFeeWeiPerSec() == 0) { return 0; }
    
        // thresholdUsage = (totalCommittedGas / maxGasCap) * 100
        uint256 thresholdUsageScaled = (uint256(_totalCommittedGas) * DECIMAL * 100) / uint256(_registryMaxGasCap);

        uint256 thresholdPercentageScaled = uint256(regConfig.congestionThresholdPercentage()) * DECIMAL;
    
        // If usage is below threshold → no congestion fee
        if (thresholdUsageScaled <= thresholdPercentageScaled) {
            return 0;
        } else {
            // Calculate how much usage exceeds threshold
            uint256 surplusScaled = (thresholdUsageScaled - thresholdPercentageScaled) / 100;


            // Ensure threshold + threshold surplus does not exceed 1 (1 in scaled terms)
            uint256 thresholdScaledAsFraction = thresholdPercentageScaled / 100;    // DECIMAL-scaled fraction
            uint256 surplusClipped = thresholdScaledAsFraction + surplusScaled > DECIMAL ? DECIMAL - thresholdScaledAsFraction : surplusScaled;

            uint256 baseScaled = DECIMAL + surplusClipped;  // (1 + base)
            uint256 resultScaled = DECIMAL;
            for (uint8 i = 0; i < regConfig.congestionExponent(); i++) {
                resultScaled = (resultScaled * baseScaled) / DECIMAL;
            }
            uint256 exponentResult = resultScaled - DECIMAL;    // subtract 1


            // Multiply base fee (wei/sec) with exponentResult and downscale by DECIMAL
            uint256 acf = (uint256(regConfig.congestionBaseFeeWeiPerSec()) * exponentResult) / DECIMAL;

            return uint128(acf);
        }
    }

    /// @notice Calculates the automation fee multiplier for cycle.
    /// @param _totalCommittedGas Total committed gas.
    /// @param _registryMaxGasCap Registry max gas cap.
    function calculateAutomationFeeMultiplierForCycle(
        uint128 _totalCommittedGas,
        uint128 _registryMaxGasCap
    ) private view returns (uint128) {
        uint128 congesionFee = calculateAutomationCongestionFee(_totalCommittedGas, _registryMaxGasCap);
        return (congesionFee + regConfig.automationBaseFeeWeiPerSec());
    }

    /// @notice Calculates automation task fees for a single task at the time of new cycle.
    /// This is supposed to be called only after removing expired task and must not be called for expired task.
    function calculateAutomationFeeForInterval(
        uint64 _duration,
        uint128 _taskOccupancy,
        uint128 _automationFeePerSec,
        uint128 _registryMaxGasCap
    ) private pure returns (uint128) {
        uint256 taskOccupancyRatioByDuration = (uint256(_duration) * uint256(_taskOccupancy) * DECIMAL) / uint256(_registryMaxGasCap);

        uint256 automationFeeForInterval = _automationFeePerSec * taskOccupancyRatioByDuration;

        return uint128(automationFeeForInterval / DECIMAL);
    }

    /// @notice Calculates automation task fees for a single task at the time of new cycle.
    /// This is supposed to be called only after removing expired task and must not be called for expired task.    
    /// @param _state State of the task.
    /// @param _expiryTime Task expiry time.
    /// @param _maxGasAmount Task's max gas amount
    /// @param _potentialFeeTimeframe Potential time frame to calculate task fees for.
    /// @param _currentTime Current time
    /// @param _automationFeePerSec Automation fee per sec
    /// @return Calculated task fee for the interval the task will be active.
    function _calculateTaskFee(
        CommonUtils.TaskState _state,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _potentialFeeTimeframe,
        uint64 _currentTime,
        uint128 _automationFeePerSec
    ) private view returns (uint128) {
        if (_automationFeePerSec == 0) { return 0; }
        if (_expiryTime <= _currentTime) { return 0; }
        
        uint64 taskActiveTimeframe = _expiryTime - _currentTime;

        // If the task is a new task i.e. in Pending state, then it is charged always for
        // the input _potentialFeeTimeframe(which is cycle-interval),
        // For the new tasks which active-timeframe is less than cycle-interval
        // it would mean it is their first and only cycle and we charge the fee for entire cycle.
        // Note that although the new short tasks are charged for entire cycle, the refunding logic remains the same for
        // them as for the long tasks.
        // This way bad-actors will be discourged to submit small and short tasks with big occupancy by blocking other
        // good-actors register tasks.
        uint64 actualFeeTimeframe; 
        if(_state == CommonUtils.TaskState.PENDING) {
            actualFeeTimeframe = _potentialFeeTimeframe;
        } else {
            actualFeeTimeframe = taskActiveTimeframe < _potentialFeeTimeframe ? taskActiveTimeframe : _potentialFeeTimeframe;
        }
        return calculateAutomationFeeForInterval(
            actualFeeTimeframe,
            _maxGasAmount,
            _automationFeePerSec,
            regConfig.registryMaxGasCap()
        );
    }

    /// @notice Estimates automation fee the next cycle for specified task occupancy for the configured cycle interval
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and registry
    /// maximum allowed occupancy for the next cycle.
    /// Note it is expected that committed_occupancy does not include current task's occupancy.
    function estimateAutomationFeeWithCommittedOccupancyInternal(
        uint128 _taskOccupancy,
        uint128 _committedOccupancy
    ) private view returns (uint128) {
        uint128 totalCommittedGas = _taskOccupancy + _committedOccupancy;
         
        uint128 automationFeePerSec = calculateAutomationFeeMultiplierForCycle(totalCommittedGas, regConfig.nextCycleRegistryMaxGasCap());

        if(automationFeePerSec == 0) return 0;

        uint64 durationSecs = IAutomationController(regConfig.automationController()).getCycleDuration();
        return calculateAutomationFeeForInterval(durationSecs, _taskOccupancy, automationFeePerSec, regConfig.nextCycleRegistryMaxGasCap());
    }

    /// @notice Unlocks the deposit paid by the task from the total automation fees deposited.
    /// @dev Error event is emitted if the total automation fees deposited is less than the requested unlock amount.
    /// @param _taskIndex Index of the task. 
    /// @param _lockedDeposit Locked deposit amount to be unlocked.
    /// @return Bool if _lockedDeposit can be unlocked safely.
    function _safeUnlockLockedDeposit(
        uint64 _taskIndex,
        uint128 _lockedDeposit
    ) private returns (bool) {
        uint256 totalDeposited = regConfig.totalDepositedAutomationFees;
        
        if(totalDeposited >= _lockedDeposit) {
            regConfig.totalDepositedAutomationFees = totalDeposited - _lockedDeposit;
            return true;
        }

        emit ErrorUnlockTaskDepositFee(_taskIndex, totalDeposited, _lockedDeposit);
        return false;
    }

    /// @notice Helper function to transfer refunds.
    /// @param _to Recipeint of the refund
    /// @param _amount Amount to refund
    /// @return Bool representing if refund was successful.
    function _refund(address _to, uint128 _amount) private returns (bool) {
        bool sent = IERC20(regConfig.erc20Supra).transfer(_to, _amount);
        if (!sent) { revert TransferFailed(); }

        return sent;
    }

    /// @notice Refunds the specified amount to the task owner.
    /// @dev Error event is emitted if the registry contract does not have sufficient balance.
    /// @param _taskIndex Index of the task.
    /// @param _taskOwner Owner of the task.
    /// @param _refundableAmount Amount to refund.
    /// @param _refundType Type of refund.
    /// @return Bool representing if refund was successful.
    function safeRefund(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableAmount,
        uint8 _refundType
    ) private returns (bool) {
        uint256 balance = IERC20(regConfig.erc20Supra).balanceOf(address(this));
        if(balance < _refundableAmount) {
            emit ErrorInsufficientBalanceToRefund(_taskIndex, _taskOwner, _refundType, _refundableAmount);
            return false;
        } else {
            return _refund(_taskOwner, _refundableAmount);
        }
    }
    
    /// @notice Refunds the specified amount of deposit to the task owner and unlocks full deposit from the total automation fees deposited.
    /// @param _taskIndex Index of the task.
    /// @param _taskOwner Owner of the task.
    /// @param _refundableDeposit Refundable amount of deposit.
    /// @param _lockedDeposit Total locked deposit.
    function _safeDepositRefund(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) private returns (bool) {
        // Ensures that amount to unlock is not more than the total automation fees deposited.
        bool result = _safeUnlockLockedDeposit(_taskIndex, _lockedDeposit);
        if (!result) {
            return result;
        }

        result = safeRefund(_taskIndex, _taskOwner, _refundableDeposit, DEPOSIT_CYCLE_FEE);

        if (result) { emit TaskDepositFeeRefund(_taskIndex, _taskOwner, _refundableDeposit); }
        return result;
    }

    /// @notice Unlocks the locked fee paid by the task for cycle.
    /// Error event is emitted if the cycle locked fee amount is inconsistent with the requested unlock amount.
    /// @param _cycleLockedFees Locked cycle fees
    /// @param _refundableFee Refundable fees
    /// @param _taskIndex Index of the task
    /// @return Bool if _refundableFee can be unlocked safely.
    /// @return Updated _cycleLockedFees after unlocking _refundableFee.
    function safeUnlockLockedCycleFee(
        uint256 _cycleLockedFees,
        uint64 _refundableFee,
        uint64 _taskIndex
    ) private returns (bool, uint256) {
        // This check makes sure that more than locked amount of the fees will be not be refunded.
        // Any attempt means internal bug.
        bool hasLockedFee = _cycleLockedFees >= _refundableFee;
        if (hasLockedFee) {
            // Unlock the refunded amount
            _cycleLockedFees = _cycleLockedFees - _refundableFee;
        } else {
            emit ErrorUnlockTaskCycleFee(_taskIndex, _cycleLockedFees, _refundableFee);
        }
        return (hasLockedFee, _cycleLockedFees);
    }

    /// @notice Refunds fee paid by the task for the cycle to the task owner.
    /// Note that here we do not unlock the fee, as on cycle change locked cycle-fees for the ended cycle are
    /// automatically unlocked.
    function safeFeeRefund(
        uint64 _taskIndex,
        address _taskOwner,
        uint256 _cycleLockedFees,
        uint64 _refundableFee
    ) private returns (bool, uint256) {
        bool result;
        uint256 remainingLockedFees;
        
        (result, remainingLockedFees) = safeUnlockLockedCycleFee(_cycleLockedFees, _refundableFee, _taskIndex);
        if (!result) { return (result, remainingLockedFees); } 
        
        result = safeRefund( _taskIndex, _taskOwner, _refundableFee, CYCLE_FEE);
        if (result) { emit TaskFeeRefund(_taskIndex, _taskOwner, _refundableFee); }
        return (result, remainingLockedFees);   
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: CONTROLLER FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Function to update the registry configuration, reverts if caller is not AutomationController.
    function applyPendingConfig() external returns (bool, uint64) {
        onlyController();

        if (!configBuffer.ifExists) {
            return (false, 0);
        } 
        uint64 pendingCycleDuration = configBuffer.pendingConfig.cycleDurationSecs();
        regConfig.config = configBuffer.pendingConfig;
        
        delete configBuffer;
        
        return (true, pendingCycleDuration);        
    }

    /// @notice Internally calls _calculateTaskFee, reverts if caller is not AutomationController.
    function calculateTaskFee(
        CommonUtils.TaskState _state,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _potentialFeeTimeframe,
        uint64 _currentTime,
        uint128 _automationFeePerSec
    ) external view returns (uint128) {
        onlyController();

        return _calculateTaskFee(
            _state,
            _expiryTime,
            _maxGasAmount,
            _potentialFeeTimeframe,
            _currentTime,
            _automationFeePerSec
        );
    }

    /// @notice Internally calls _safeUnlockLockedDeposit, reverts if caller is not AutomationController.
    function safeUnlockLockedDeposit(
        uint64 _taskIndex,
        uint128 _lockedDeposit
    ) external returns (bool) {
        onlyController();

        return _safeUnlockLockedDeposit(_taskIndex, _lockedDeposit);
    }

    /// @notice Refunds the deposit fee and any autoamtion fees of the task.
    function refundTaskFees(
        uint64 _currentTime,
        uint64 _refundDuration, 
        uint128 _automationFeePerSec,
        CommonUtils.TaskDetails memory _task
    ) external {
        onlyController();

        // Do not attempt fee refund if remaining duration is 0
        if (_task.state != CommonUtils.TaskState.PENDING && _refundDuration != 0) {
            uint128 _refundFee = _calculateTaskFee(
                _task.state,
                _task.expiryTime,
                _task.maxGasAmount,
                _refundDuration,
                _currentTime,
                _automationFeePerSec
            );
            ( , uint256 remainingCycleLockedFees) = safeFeeRefund(
                    _task.taskIndex,
                    _task.owner,
                    regConfig.cycleLockedFees,
                    uint64(_refundFee)
                );
            regConfig.cycleLockedFees = remainingCycleLockedFees;
        }

        _safeDepositRefund(
            _task.taskIndex,
            _task.owner,
            _task.lockedFeeForNextCycle,
            _task.lockedFeeForNextCycle
        );
    }

    function calculateAutomationFeeMultiplierForCurrentCycleInternal() external view returns (uint128) {
        onlyController();
        // Compute the automation fee multiplier for this cycle
        return calculateAutomationFeeMultiplierForCycle(
            regConfig.gasCommittedForThisCycle(),
            regConfig.registryMaxGasCap()
        );
    }

    /// @notice Calculates automation fee per second for the specified task occupancy
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and current registry
    /// maximum allowed occupancy.
    function calculateAutomationFeeMultiplierForCommittedOccupancy(
        uint128 _totalCommittedMaxGas
    ) external view returns (uint128) {
        onlyController();
        // Compute the automation fee multiplier for cycle        
        return calculateAutomationFeeMultiplierForCycle(
            _totalCommittedMaxGas,
            regConfig.registryMaxGasCap()
        );
    }

    /// @notice Function to update the cycle locked fees and gas committed.
    /// @param _lockedFees Updated cycle locked fees
    /// @param _sysGasCommittedForNextCycle Updated system gas committed for next cycle 
    /// @param _gasCommittedForNextCycle Updated gas committed for next cycle
    /// @param _gasCommittedForNewCycle Updated gas committed for new cycle
    function updateGasCommittedAndCycleLockedFees(
        uint256 _lockedFees,
        uint128 _sysGasCommittedForNextCycle,
        uint128 _gasCommittedForNextCycle,
        uint128 _gasCommittedForNewCycle
    ) external {
        onlyController();

        regConfig.cycleLockedFees  = _lockedFees;
        regConfig.setSysGasCommittedForNextCycle(_sysGasCommittedForNextCycle);
        regConfig.setSysGasCommittedForThisCycle(_sysGasCommittedForNextCycle);
        regConfig.setGasCommittedForNextCycle(_gasCommittedForNextCycle);
        regConfig.setGasCommittedForThisCycle(_gasCommittedForNewCycle);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: REGISTRY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that performs validation and updates state for a valid task.
    function updateStateForValidRegistration(
        uint256 _totalTasks, 
        uint8 _inputType,
        uint64 _regTime,
        uint64 _expiryTime,
        CommonUtils.TaskType _taskType,
        bytes memory _payloadTx, 
        uint128 _maxGasAmount, 
        bytes32 _txHash,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle
    ) external {
        onlyRegistry();

        // Check if automation and registration is enabled
        IAutomationController automationController = IAutomationController(regConfig.automationController()); 
        if (!automationController.isAutomationEnabled()) { revert AutomationNotEnabled(); }
        if (!regConfig.registrationEnabled()) { revert RegistrationDisabled(); }

        if (!automationController.isCycleStarted()) { revert CycleTransitionInProgress(); }
        if(_inputType != uint8(_taskType)) { revert InvalidTaskType(); }
        
        bool isUST = _taskType == CommonUtils.TaskType.UST;
   
        uint64 taskDurationCap;
        uint128 gasCommittedForNextCycle;
        uint128 nextCycleRegistryMaxGasCap;
        if (isUST) {
            if(_totalTasks >= regConfig.taskCapacity()) { revert TaskCapacityReached(); }
            if(_gasPriceCap == 0) { revert InvalidGasPriceCap(); }

            gasCommittedForNextCycle = regConfig.gasCommittedForNextCycle();
            uint128 estimatedAutomationFeeForCycle = estimateAutomationFeeWithCommittedOccupancyInternal(_maxGasAmount, gasCommittedForNextCycle);
            if(_automationFeeCapForCycle < estimatedAutomationFeeForCycle) { revert InsufficientFeeCapForCycle(); }

            taskDurationCap = regConfig.taskDurationCapSecs();
            nextCycleRegistryMaxGasCap = regConfig.nextCycleRegistryMaxGasCap();
        } else {
            if(_totalTasks >= regConfig.sysTaskCapacity()) { revert TaskCapacityReached(); }

            gasCommittedForNextCycle = regConfig.sysGasCommittedForNextCycle();
            taskDurationCap = regConfig.sysTaskDurationCapSecs();
            nextCycleRegistryMaxGasCap = regConfig.nextCycleSysRegistryMaxGasCap();
        }

        validateTaskDuration(_regTime, _expiryTime, taskDurationCap, automationController.getCycleEndTime());
        validateInputs(_payloadTx, _maxGasAmount, _txHash);

        uint128 gasCommitted = _maxGasAmount + gasCommittedForNextCycle;
        if(gasCommitted > nextCycleRegistryMaxGasCap) { revert GasCommittedExceedsMaxGasCap(); }

        if (isUST) {
            regConfig.setGasCommittedForNextCycle(gasCommitted);
        } else {
            regConfig.setSysGasCommittedForNextCycle(gasCommitted);
        } 
    }

    function updateGasCommittedForNextCycle(CommonUtils.TaskType _taskType, uint128 _maxGasAmount) external {
        onlyRegistry();

        bool isUST = _taskType == CommonUtils.TaskType.UST;

        uint128 gasCommittedForNextCycle = isUST ? regConfig.gasCommittedForNextCycle(): regConfig.sysGasCommittedForNextCycle();
        if (gasCommittedForNextCycle < _maxGasAmount) { revert GasCommittedValueUnderflow(); }
       
        // Adjust the gas committed for the next cycle by subtracting the gas amount of the cancelled/stopped task
        if (isUST) {
            regConfig.setGasCommittedForNextCycle(gasCommittedForNextCycle - _maxGasAmount);
        } else {
            regConfig.setSysGasCommittedForNextCycle(gasCommittedForNextCycle - _maxGasAmount);
        }
    }

    /// @notice Helper function to increment the total deposited automation fees.
    function incTotalDepositedAutomationFees(uint256 _amount) external {
        onlyRegistry();
        regConfig.totalDepositedAutomationFees += _amount;
    }

    /// @notice Internally calls _refund, reverts if caller is not AutomationRegistry.
    function refund(address _to, uint128 _amount) external {
        onlyRegistry();
        _refund(_to, _amount);
    }

    /// @notice Internally calls _safeDepositRefund, reverts if caller is not AutomationRegistry.
    function safeDepositRefund(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) external returns (bool) {
        onlyRegistry();
        return _safeDepositRefund(_taskIndex, _taskOwner, _refundableDeposit, _lockedDeposit);
    }

    /// @notice Helper function to unlock locked deposit and cycle fees when stopTasks is called.
    function unlockDepositAndCycleFee(
        uint64 _taskIndex,
        CommonUtils.TaskState _taskState,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _residualInterval,
        uint64 _currentTime,
        uint128 _lockedFeeForNextCycle
    )  external returns (uint128, uint128) {
        onlyRegistry();

        uint128 cycleFeeRefund;
        uint128 depositRefund;

        if(_taskState != CommonUtils.TaskState.PENDING) {
            // Compute the automation fee multiplier for cycle
            uint128 automationFeePerSec = calculateAutomationFeeMultiplierForCycle(regConfig.gasCommittedForThisCycle(), regConfig.registryMaxGasCap());

            uint128 taskFee = _calculateTaskFee(
                _taskState,
                _expiryTime,
                _maxGasAmount,
                _residualInterval,
                _currentTime,
                automationFeePerSec
            );

            // Refund full deposit and the half of the remaining run-time fee when task is active or cancelled stage
            cycleFeeRefund = taskFee / REFUND_FRACTION; 
            depositRefund = _lockedFeeForNextCycle;
        } else {
            cycleFeeRefund = 0;
            depositRefund = _lockedFeeForNextCycle / REFUND_FRACTION;
        }

        bool result = _safeUnlockLockedDeposit(_taskIndex, _lockedFeeForNextCycle);
        if(!result) { revert ErrorDepositRefund(); }

        (bool hasLockedFee, uint256 remainingCycleLockedFees ) = safeUnlockLockedCycleFee(regConfig.cycleLockedFees, uint64(cycleFeeRefund), _taskIndex);
        if(!hasLockedFee) { revert ErrorCycleFeeRefund(); }

        regConfig.cycleLockedFees = remainingCycleLockedFees;

        return (cycleFeeRefund, depositRefund);
    }
    
    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ADMIN FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

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
    ) external onlyOwner {
        validateConfigParameters(
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

        if(regConfig.gasCommittedForNextCycle() > _registryMaxGasCap) { revert UnacceptableRegistryMaxGasCap(); }
        if(regConfig.sysGasCommittedForNextCycle() > _sysRegistryMaxGasCap) { revert UnacceptableSysRegistryMaxGasCap(); }

        // Add new config to the buffer
        LibConfig.Config memory pendingConfig = LibConfig.createConfig(
            _registryMaxGasCap,
            _sysRegistryMaxGasCap,
            _automationBaseFeeWeiPerSec,
            _flatRegistrationFeeWei,
            _congestionBaseFeeWeiPerSec,
            _taskDurationCapSecs,
            _sysTaskDurationCapSecs,
            _cycleDurationSecs,
            _taskCapacity,
            _sysTaskCapacity,
            _congestionThresholdPercentage,
            _congestionExponent
        );
        configBuffer = LibConfig.ConfigBuffer(pendingConfig, true);

        regConfig.setNextCycleRegistryMaxGasCap(_registryMaxGasCap);
        regConfig.setNextCycleSysRegistryMaxGasCap(_sysRegistryMaxGasCap);

        emit ConfigBufferUpdated(pendingConfig.getConfig());
    }

    /// @notice Function to enable the task registration.
    function enableRegistration() external onlyOwner {
        if(regConfig.registrationEnabled()) { revert AlreadyEnabled(); }
        regConfig.setRegistrationEnabled(true);

        emit TaskRegistrationEnabled(regConfig.registrationEnabled());
    }

    /// @notice Function to disable the task registration.
    function disableRegistration() external onlyOwner {
        if(!regConfig.registrationEnabled()) { revert AlreadyDisabled(); }
        regConfig.setRegistrationEnabled(false);

        emit TaskRegistrationDisabled(regConfig.registrationEnabled());   
    }

    /// @notice Function to update the VM Signer address.
    /// @param _vmSigner New address for VM Signer.
    function setVmSigner(address _vmSigner) external onlyOwner {
        if(_vmSigner == address(0)) { revert AddressCannotBeZero(); }

        address oldVmSigner = regConfig.vmSigner;
        regConfig.vmSigner = _vmSigner;

        emit VmSignerUpdated(oldVmSigner, _vmSigner);
    }

    /// @notice Function to update the ERC20Supra address.
    /// @param _erc20Supra New address for ERC20Supra.
    function setErc20Supra(address _erc20Supra) external onlyOwner {
        _erc20Supra.validateContractAddress();

        address oldErc20Supra = regConfig.erc20Supra;
        regConfig.erc20Supra = _erc20Supra;

        emit Erc20SupraUpdated(oldErc20Supra, _erc20Supra);
    }

    /// @notice Function to update the automation controller smart contract address. 
    /// @param _controller Address of the automation controller smart contact.
    function setAutomationController(address _controller) external onlyOwner {
        _controller.validateContractAddress();

        address oldController = regConfig.automationController();
        regConfig.setAutomationController(_controller);

        emit AutomationControllerUpdated(oldController, _controller);
    }

    /// @notice Function to update the automation registry smart contract address. 
    /// @param _registry Address of the automation registry smart contact.
    function setAutomationRegistry(address _registry) external onlyOwner {
        _registry.validateContractAddress();

        address oldRegistry = regConfig.registry;
        regConfig.registry = _registry;

        emit AutomationRegistryUpdated(oldRegistry, _registry);
    }

    /// @notice Function to withdraw the accumulated fees.
    /// @param _amount Amount to withdraw.
    /// @param _recipient Address to withdraw fees to.
    function withdrawFees(uint256 _amount, address _recipient) external onlyOwner {
        if(_amount == 0) { revert InvalidAmount(); }
        if(_recipient == address(0)) { revert AddressCannotBeZero(); }
        uint256 balance = IERC20(regConfig.erc20Supra).balanceOf(address(this));

        if(balance < _amount) { revert InsufficientBalance(); }
        if(balance - _amount < regConfig.cycleLockedFees + regConfig.totalDepositedAutomationFees) { revert RequestExceedsLockedBalance(); }

        bool sent = IERC20(regConfig.erc20Supra).transfer(_recipient, _amount);
        if(!sent) { revert TransferFailed(); }

        emit RegistryFeeWithdrawn(_recipient, _amount);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @notice Returns the VM Signer address.
    function getVmSigner() external view returns (address) {
        return regConfig.vmSigner;
    }

    /// @notice Returns the ERC20Supra address.
    function erc20Supra() external view returns (address) {
        return regConfig.erc20Supra;
    }

    /// @notice Returns the address of AutomationController smart contract.
    function getAutomationController() external view returns (address) {
        return regConfig.automationController();
    }

    /// @notice Returns the address of AutomationRegistry smart contract.
    function getAutomationRegistry() external view returns (address) {
        return regConfig.registry;
    }

    /// @notice Returns if task registration is enabled.
    function isRegistrationEnabled() external view returns (bool) {
        return regConfig.registrationEnabled();
    }

    /// @notice Returns the gas committed for the next cycle.
    function getGasCommittedForNextCycle() external view returns (uint128) {
        return regConfig.gasCommittedForNextCycle();
    }

    /// @notice Returns the gas committed for the current cycle.
    function getGasCommittedForCurrentCycle() external view returns (uint128) {
        return regConfig.gasCommittedForThisCycle();
    }

    /// @notice Returns the system gas committed for the next cycle.
    function getSystemGasCommittedForNextCycle() external view returns (uint128) {
        return regConfig.sysGasCommittedForNextCycle();
    }

    /// @notice Returns the system gas committed for the current cycle.
    function getSystemGasCommittedForCurrentCycle() external view returns (uint128) {
        return regConfig.sysGasCommittedForThisCycle();
    }

    /// @notice Returns the registry max gas cap for the next cycle.    
    function getNextCycleRegistryMaxGasCap() external view returns (uint128) {
        return regConfig.nextCycleRegistryMaxGasCap();
    }

    /// @notice Returns the system registry max gas cap for the next cycle.    
    function getNextCycleSysRegistryMaxGasCap() external view returns (uint128) {
        return regConfig.nextCycleSysRegistryMaxGasCap();
    }

    /// @notice Returns the flat registration fee.
    function flatRegistrationFeeWei() external view returns (uint128) {
        return regConfig.flatRegistrationFeeWei();
    }

    /// @notice Returns the registry configuration.
    function getConfig() external view returns (LibConfig.ConfigDetails memory) {
        return regConfig.config.getConfig();
    }

    /// @notice Returns the pending configuration.
    function getPendingConfig() external view returns (LibConfig.ConfigDetails memory) {
        return configBuffer.pendingConfig.getConfig();
    }
    
    /// @notice Returns the registry max gas cap configured.
    function getRegistryMaxGasCap() external view returns (uint128) {
        return regConfig.registryMaxGasCap();
    }

    /// @notice Returns the system registry max gas cap configured.
    function getSysRegistryMaxGasCap() external view returns (uint128) {
        return regConfig.sysRegistryMaxGasCap();
    }

    /// @notice Returns the automationBaseFeeWeiPerSec configured.
    function getAutomationBaseFeeWeiPerSec() external view returns (uint128) {
        return regConfig.automationBaseFeeWeiPerSec();
    }

    /// @notice Returns the cycle duration configured.
    function cycleDurationSecs() external view returns (uint64) {
        return regConfig.config.cycleDurationSecs();
    }

    /// @notice Returns the locked fees for the cycle. 
    function getCycleLockedFees() external view returns (uint256) {
        return regConfig.cycleLockedFees;
    }

    /// @notice Returns the total amount of automation fees deposited.
    function getTotalDepositedAutomationFees() external view returns (uint256) {
        return regConfig.totalDepositedAutomationFees;
    }

    /// @notice Returns the total amount locked which comprises of 'cycleLockedFees' and 'totalDepositedAutomationFees'. 
    function getTotalLockedBalance() external view returns (uint256) {
        return regConfig.cycleLockedFees + regConfig.totalDepositedAutomationFees;
    }

    /// @notice Estimates automation fee for the next cycle for specified task occupancy for the configured cycle-interval
    /// referencing the current automation registry fee parameters, current total occupancy and registry maximum allowed
    /// occupancy for the next cycle.
    function estimateAutomationFee(uint128 _taskOccupancy) external view returns (uint128) {
        return estimateAutomationFeeWithCommittedOccupancyInternal(_taskOccupancy, regConfig.gasCommittedForNextCycle());
    }

    /// @notice Estimates automation fee the next cycle for specified task occupancy for the configured cycle-interval
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and registry
    /// maximum allowed occupancy for the next cycle.
    function estimateAutomationFeeWithCommittedOccupancy(
        uint128 _taskOccupancy,
        uint128 _committedOccupancy
    ) external view returns (uint128) {
        return estimateAutomationFeeWithCommittedOccupancyInternal(
            _taskOccupancy,
            _committedOccupancy
        );
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}