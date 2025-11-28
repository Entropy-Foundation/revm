// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EnumerableSet} from "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {CommonUtils} from "./CommonUtils.sol";
import {LibRegistry} from "./LibRegistry.sol";

import {IAutomationController} from "./IAutomationController.sol";
import {IAutomationRegistry} from "./IAutomationRegistry.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";

contract AutomationRegistry is IAutomationRegistry, Ownable2StepUpgradeable, UUPSUpgradeable {
    using EnumerableSet for *;
    using CommonUtils for *;
    using LibRegistry for *;

    /// @dev Constant for 10^8
    uint256 constant DECIMAL = 100_000_000;

    /// @dev Refund fraction
    uint8 constant REFUND_FRACTION = 2;

    /// @dev Defines divisor for refunds of deposit fees with penalty
    /// Factor of `2` suggests that `1/2` of the deposit will be refunded.
    uint8 constant REFUND_FACTOR = 2;

    /// @dev Supported auxiliary data count
    uint8 constant SUPPORTED_AUX_DATA_COUNT_MAX = 2;
    /// @dev Index of the auxiliary data holding task type value
    uint8 constant TYPE_AUX_DATA_INDEX = 0;
    /// @dev Index of the auxiliary data holding task priority value
    uint8 constant PRIORITY_AUX_DATA_INDEX = 1;

    /// @dev Defines the cycle state, used to update the registry.
    uint8 constant SUSPENDED = 0;
    uint8 constant FINISHED = 1;

    /// @dev Constants describing REFUND TYPE
    uint8 constant DEPOSIT_CYCLE_FEE = 0;
    uint8 constant CYCLE_FEE = 1;
    

    LibRegistry.ConfigBuffer internal configBuffer;
    LibRegistry.RegistryConfig internal regConfig;
    LibRegistry.RegistryState internal regState;
    LibRegistry.RegistryStateSystemTasks internal regSysState;
    LibRegistry.Deposit internal deposit;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: EVENTS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @notice Emitted when a user task is registered.
    event TaskRegistered(
        uint64 indexed taskIndex, 
        address indexed owner, 
        uint128 registrationFee, 
        uint128 lockedDepositFee, 
        CommonUtils.TaskDetails taskMetadata
    );

    /// @notice Emitted when a system task is registered.
    event SystemTaskRegistered(
        uint64 indexed taskIndex, 
        address indexed owner, 
        uint256 timestamp, 
        CommonUtils.TaskDetails taskMetadata
    );
    
    /// @notice Emitted when an account is authorized as submitter for system tasks.
    event AuthorizationGranted(address indexed account, uint256 indexed timestamp);
    
    /// @notice Emitted when authorization is revoked for an account to submit system tasks.
    event AuthorizationRevoked(address indexed account, uint256 indexed timestamp);

    /// @notice Emitted when task registration is enabled.
    event TaskRegistrationEnabled(bool indexed status);

    /// @notice Emitted when task registration is disabled.
    event TaskRegistrationDisabled(bool indexed status);

    /// @notice Emitted when automation is enabled.
    event AutomationEnabled(bool indexed status);
    
    /// @notice Emitted when automation is disabled.
    event AutomationDisabled(bool indexed status);

    /// @notice Emitted when the VM address is updated.
    event VmAddressUpdated(address indexed oldVmAddress, address indexed newVmAddress);

    /// @notice Emitted when the SupraERC20 address is updated.
    event SupraERC20Updated(address indexed oldSupraERC20, address indexed newSupraERC20);

    /// @notice Emitted when a new config is added.
    event ConfigBufferUpdated(
        LibRegistry.ConfigDetails indexed pendingConfig
    );

    /// @notice Emitted when the cold wallet address is updated.
    event ColdWalletUpdated(address indexed oldColdWallet, address indexed newColdWallet);

    /// @notice Emitted when the automation controller smart contract address is updated. 
    event AutomationControllerUpdated(address indexed oldController, address indexed newController);
    
    /// @notice Emitted when the registry fees is withdrawn by the admin.
    event RegistryFeeWithdrawn(address indexed coldWallet, uint256 indexed feesWithdrawn);

    /// @notice Emitted when a task is cancelled.
    event TaskCancelled(
        uint64 indexed taskIndex,
        address indexed owner,
        bytes32 indexed regHash
    );

    /// @notice Emitted when a task is stopped.
    event TasksStopped(
        LibRegistry.TaskStopped[] StoppedTasks,
        address indexed owner
    );

    /// @notice Emitted when deposit fee is being refunded but total locked deposits is less than the locked deposit for the task.
    event ErrorUnlockTaskDepositFee(
        uint64 indexed taskIndex, 
        uint256 totalDepositedAutomationFees, 
        uint128 lockedDeposit
    );

    /// @notice Emitted when a task cycle fee is being refunded but locked cycle fees is less than the requested refund.
    event ErrorUnlockTaskCycleFee(
        uint64 indexed taskIndex,
        uint256 indexed lockedCycleFees,
        uint64 indexed refund
    );

    /// @notice Emitted when a deposit fee is refunded for an automation task.
    event TaskDepositFeeRefund(uint64 indexed taskIndex, address owner, uint128 amount);

    /// @notice Emitted during cycle transition when refunds to be paid is not possible due to insufficient contract balance.
    /// Type of the refund can be related either to the deposit paid during registration (0), or to cycle fee caused by
    /// the shortening of the cycle (1)
    event ErrorInsufficientBalanceToRefund(
        uint64 indexed _taskIndex,
        address indexed _owner,
        uint8 _refundType,
        uint128 _amount
    );

    /// @notice Emitted when an automation fee is refunded for an automation task at the end of the cycle for excessive
    /// duration paid at the beginning of the cycle due to cycle duration reduction by governance.
    event TaskFeeRefund(
        uint64 indexed taskIndex,
        address indexed owner,
        uint64 indexed amount
    );

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: MODIFIERS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Modifier to assert that automation controller contract is the caller.
    modifier onlyController() {
        if(msg.sender != regConfig.automationController()) { revert CallerNotController(); }
        _;
    }

    /// @dev Modifier to assert that either controller or registry contract is the caller.
    modifier onlyRegistryAndController() {
        if(msg.sender != regConfig.automationController() && msg.sender != address(this)) { revert UnauthorizedCaller(); }
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
    /// @param _taskCapacity Maximum number of tasks that the registry can hold.
    /// @param _cycleDurationSecs Automation cycle duration in seconds.
    /// @param _sysTaskDurationCapSecs Maximum allowable duration (in seconds) from the registration time that a system automation task can run.
    /// @param _sysRegistryMaxGasCap Maximum gas allocation for system automation tasks per cycle.
    /// @param _sysTaskCapacity Maximum number of system tasks that the registry can hold.
    /// @param _vm Address for the VM.
    /// @param _supraERC20 Address of the ERC20Supra contract.
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
        address _vm,
        address _supraERC20
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
        if(_vm == address(0)) revert AddressCannotBeZero();

        if(_supraERC20 == address(0)) revert AddressCannotBeZero();
        if(!_supraERC20.isContract()) revert AddressCannotBeEOA();

        LibRegistry.Config memory config = LibRegistry.createConfig(
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
        
        regConfig = LibRegistry.createRegistryConfig(
            _registryMaxGasCap,
            _sysRegistryMaxGasCap,
            true,
            true,
            _vm,
            _supraERC20,
            config  
        );

        __Ownable2Step_init();
        __Ownable_init(msg.sender);
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
    ) public {
        // Check if automation is enabled
        if (!regConfig.automationEnabled()) { revert AutomationNotEnabled(); }

        bool hasNoPriority = checkAndValidateAuxData(_auxData, LibRegistry.TaskType.UST);

        if(!regConfig.registrationEnabled()) { revert RegistrationDisabled(); }

        if(IAutomationController(regConfig.automationController()).getCycleState() != 1) { revert CycleNotStarted(); }

        if(totalTasks() >= regConfig.taskCapacity()) { revert TaskCapacityReached(); }


        uint64 regTime = uint64(block.timestamp);
        uint64 startTime;
        uint64 durationSecs;
        ( , startTime, durationSecs) = IAutomationController(regConfig.automationController()).getCycleInfo();

        validateTaskDuration(regTime, _expiryTime, LibRegistry.TaskType.UST, regConfig.taskDurationCapSecs(), regConfig.sysTaskDurationCapSecs(), startTime, durationSecs);

        address payloadTarget;
        (payloadTarget, ) = abi.decode(_payloadTx, (address, bytes));
        if(payloadTarget == address(0)) { revert AddressCannotBeZero(); }
        if(!payloadTarget.isContract()) { revert AddressCannotBeEOA(); }
        if(_maxGasAmount == 0) { revert InvalidMaxGasAmount(); }
        if(_gasPriceCap == 0) { revert InvalidGasPriceCap(); }
        if(_txHash == bytes32(0)) { revert InvalidTxHash(); }

        uint128 gasCommitted = _maxGasAmount + regState.gasCommittedForNextCycle();
        if(gasCommitted > regConfig.nextCycleRegistryMaxGasCap()) { revert GasCommittedExceedsMaxGasCap(); }


        uint128 estimatedAutomationFeeForCycle = estimateAutomationFeeWithCommittedOccupancyInternal(_maxGasAmount, regState.gasCommittedForNextCycle(), durationSecs);
        if(_automationFeeCapForCycle < estimatedAutomationFeeForCycle) { revert InsufficientFeeCapForCycle(); }

        regState.setGasCommittedForNextCycle(gasCommitted);
        uint64 taskIndex = regState.currentIndex; 

        if(hasNoPriority) { _auxData[PRIORITY_AUX_DATA_INDEX] = abi.encode(taskIndex); }
        LibRegistry.TaskMetadata memory taskMetadata = LibRegistry.createTaskMetadata(
            _maxGasAmount,
            _gasPriceCap,
            _automationFeeCapForCycle,
            _automationFeeCapForCycle ,
            _txHash,
            taskIndex,
            regTime,
            _expiryTime,
            msg.sender,
            CommonUtils.TaskState.PENDING,
            _payloadTx,
            _auxData
        );
        
        regState.tasks[taskIndex] = taskMetadata; 
        regState.taskIdList.add(taskIndex);
        regState.currentIndex += 1;

        deposit.totalDepositedAutomationFees += _automationFeeCapForCycle;

        uint128 fee = regConfig.flatRegistrationFeeWei() + _automationFeeCapForCycle;
        bool sent = IERC20(regConfig.supraERC20).transferFrom(msg.sender, address(this), fee);
        if (!sent) { revert TransferFailed(); }

        emit TaskRegistered(taskIndex, msg.sender, regConfig.flatRegistrationFeeWei(), _automationFeeCapForCycle, regState.tasks[taskIndex].getTaskDetails());
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
    ) public {
        // Check if automation is enabled
        if (!regConfig.automationEnabled()) { revert AutomationNotEnabled(); }
        
        bool hasNoPriority = checkAndValidateAuxData(_auxData, LibRegistry.TaskType.GST);

        if(!regConfig.registrationEnabled()) { revert RegistrationDisabled(); }

        if(IAutomationController(regConfig.automationController()).getCycleState() != 1) { revert CycleNotStarted(); }

        if(totalSystemTasks() >= regConfig.sysTaskCapacity()) { revert TaskCapacityReached(); }

        if(!isAuthorizedSubmitter(msg.sender)) { revert UnauthorizedAccount(); }

        uint64 regTime = uint64(block.timestamp);
        uint64 startTime;
        uint64 durationSecs;
        (, startTime, durationSecs) = IAutomationController(regConfig.automationController()).getCycleInfo();

        validateTaskDuration(regTime, _expiryTime, LibRegistry.TaskType.GST, regConfig.taskDurationCapSecs(), regConfig.sysTaskDurationCapSecs(), startTime, durationSecs);

        address payloadTarget;
        (payloadTarget, ) = abi.decode(_payloadTx, (address, bytes));
        if( payloadTarget == address(0)) { revert AddressCannotBeZero(); }
        if(!payloadTarget.isContract()) { revert AddressCannotBeEOA(); }
        if(_maxGasAmount == 0) { revert InvalidMaxGasAmount(); }
        if(_txHash == bytes32(0)) { revert InvalidTxHash(); }

        uint128 gasCommitted = _maxGasAmount + regSysState.gasCommittedForNextCycle();
        if(gasCommitted > regConfig.nextCycleSysRegistryMaxGasCap()) { revert GasCommittedExceedsMaxGasCap(); }

        regSysState.setGasCommittedForNextCycle(gasCommitted);

        uint64 taskIndex = regState.currentIndex; 

        if(hasNoPriority) {_auxData[PRIORITY_AUX_DATA_INDEX] = abi.encode(taskIndex); }
        LibRegistry.TaskMetadata memory taskMetadata = LibRegistry.createTaskMetadata(
            _maxGasAmount,
            0,
            0,
            0,
            _txHash,
            taskIndex,
            regTime,
            _expiryTime,
            msg.sender,
            CommonUtils.TaskState.PENDING,
            _payloadTx,
            _auxData
        );

        regState.tasks[taskIndex] = taskMetadata; 
        regState.taskIdList.add(taskIndex);
        regState.currentIndex += 1;
        regSysState.taskIds.add(taskIndex);

        emit SystemTaskRegistered(taskIndex, msg.sender, block.timestamp, regState.tasks[taskIndex].getTaskDetails());
    }

    /// @notice Cancels an automation task with specified task index.
    /// Only existing task, which is PENDING or ACTIVE, can be cancelled and only by task owner.
    /// If the task is
    ///   - active, its state is updated to be CANCELLED.
    ///   - pending, it is removed form the list.
    ///   - cancelled, an error is reported
    /// Committed gas limit is updated by reducing it with the max gas amount of the cancelled task.
    /// @param _taskIndex Index of the task.
    function cancelTask(uint64 _taskIndex) public {
        // Check if automation is enabled
        if (!regConfig.automationEnabled()) { revert AutomationNotEnabled(); }
        
        (CommonUtils.CycleState state, uint64 startTime, uint64 durationSecs) = IAutomationController(regConfig.automationController()).getCycleInfo();

        if(state != CommonUtils.CycleState.STARTED) { revert CycleTransitionInProgress(); }
        if(!ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        
        CommonUtils.TaskDetails memory task = regState.tasks[_taskIndex].getTaskDetails();

        if(!isUST(_taskIndex)) { revert UnsupportedTaskOperation(); }
        if(task.owner != msg.sender) { revert UnauthorizedAccount(); }
        if(task.state == CommonUtils.TaskState.CANCELLED) { revert AlreadyCancelled(); }
        
        if (task.state == CommonUtils.TaskState.PENDING) {
            // When Pending tasks are cancelled, refund of the deposit fee is done with penalty
            bool result = safeDepositRefund(
                _taskIndex,
                task.owner,
                task.lockedFeeForNextCycle / REFUND_FACTOR,
                task.lockedFeeForNextCycle
            );
            if(!result) { revert ErrorDepositRefund(); }
            removeTask(_taskIndex, false); 
        } else { 
            // It is safe not to check the state as above, the cancelled tasks are already rejected.
            // Active tasks will be refunded the deposited amount fully at the end of the cycle.
            LibRegistry.setState(regState.tasks[_taskIndex], uint8(CommonUtils.TaskState.CANCELLED));
        }

        // This check means the task was expected to be executed in the next cycle, but it has been cancelled.
        // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
        if (task.expiryTime > (startTime + durationSecs)) {
            if(regState.gasCommittedForNextCycle() < task.maxGasAmount) { revert GasCommittedValueUnderflow(); }
          
            // Adjust the gas committed for the next cycle by subtracting the gas amount of the cancelled task
            regState.setGasCommittedForNextCycle(regState.gasCommittedForNextCycle() - task.maxGasAmount);
        }

        emit TaskCancelled( _taskIndex, task.owner, task.txHash);
    }

    /// @notice Cancels a system automation task with specified task index.
    /// Only existing task, which is PENDING or ACTIVE, can be cancelled and only by task owner.
    /// If the task is
    ///   - active, its state is updated to be CANCELLED.
    ///   - pending, it is removed form the list.
    ///   - cancelled, an error is reported
    /// Committed gas limit is updated by reducing it with the max gas amount of the cancelled task.
    /// @param _taskIndex Index of the task.
    function cancelSystemTask(
        uint64 _taskIndex
    ) public {
        // Check if automation is enabled
        if (!regConfig.automationEnabled()) { revert AutomationNotEnabled(); }

        (CommonUtils.CycleState state, uint64 startTime, uint64 durationSecs) = IAutomationController(regConfig.automationController()).getCycleInfo();

        if(state != CommonUtils.CycleState.STARTED) { revert CycleTransitionInProgress(); }
        if(!ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        if(!ifSysTaskExists(_taskIndex)) { revert SystemTaskDoesNotExist(); }
        
        // Check if GST
        if(isUST(_taskIndex)) { revert UnsupportedTaskOperation(); }

        CommonUtils.TaskDetails memory task = regState.tasks[_taskIndex].getTaskDetails();

        if(task.owner != msg.sender) { revert UnauthorizedAccount(); }
        if(task.state == CommonUtils.TaskState.CANCELLED) { revert AlreadyCancelled(); }

        if(task.state == CommonUtils.TaskState.PENDING) {
            removeTask(_taskIndex, true);
        } else {
            LibRegistry.setState(regState.tasks[_taskIndex], uint8(CommonUtils.TaskState.CANCELLED));
        }

        // This check means the task was expected to be executed in the next cycle, but it has been cancelled.
        // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
        if(task.expiryTime > startTime + durationSecs) {
            if(regSysState.gasCommittedForNextCycle() < task.maxGasAmount) { revert GasCommittedValueUnderflow(); }

            // Adjust the gas committed for the next cycle by subtracting the gas amount of the cancelled task
            regSysState.setGasCommittedForNextCycle(regSysState.gasCommittedForNextCycle() - task.maxGasAmount);
        }

        emit TaskCancelled(_taskIndex, msg.sender, task.txHash);
    }

    /// @notice Immediately stops automation tasks for the specified `_taskIndexes`.
    /// Only tasks that exist and are owned by the sender can be stopped.
    /// If any of the specified tasks are not owned by the sender, the transaction will abort.
    /// When a task is stopped, the committed gas for the next cycle is reduced
    /// by the max gas amount of the stopped task. Half of the remaining task fee is refunded.
    /// @param _taskIndexes Array of task indexes to be stopped.
    function stopTasks(
        uint64[] memory _taskIndexes
    ) public {
        // Check if automation is enabled
        if (!regConfig.automationEnabled()) { revert AutomationNotEnabled(); }

        (CommonUtils.CycleState state, uint64 startTime, uint64 durationSecs) = IAutomationController(regConfig.automationController()).getCycleInfo();
        if(state != CommonUtils.CycleState.STARTED) { revert CycleTransitionInProgress(); }
        if(_taskIndexes.length == 0) { revert TaskIndexesCannotBeEmpty(); }

        uint128 totalCommittedGas = getGasCommittedForCurrentCycle();

        // Compute the automation fee multiplier for cycle
        uint128 registryMaxGasCap = getRegistryMaxGasCap();
        uint128 automationBaseFeeWeiPerSec = getAutomationBaseFeeWeiPerSec();
        uint128 automationFeePerSec = calculateAutomationFeeMultiplierForCycle(totalCommittedGas, registryMaxGasCap, automationBaseFeeWeiPerSec);

        LibRegistry.TaskStopped[] memory stoppedTaskDetails = new LibRegistry.TaskStopped[](_taskIndexes.length);
        uint256 counter = 0;
        
        uint128 totalRefundFee = 0;
        uint256 cycleLockedFees = regState.cycleLockedFees;

        // Calculate refundable fee for this remaining time task in current cycle
        uint256 currentTime = block.timestamp;
        uint128 cycleEndTime = startTime + durationSecs;
        uint64 residualInterval = cycleEndTime <= currentTime ? 0 : uint64(cycleEndTime - currentTime);

        // Loop through each task index to validate and stop the task
        for (uint256 i = 0; i < _taskIndexes.length; i++) {
            if(ifTaskExists(_taskIndexes[i])) {
                CommonUtils.TaskDetails memory task = regState.tasks[_taskIndexes[i]].getTaskDetails();

                // Check if authorised
                if(msg.sender != task.owner) { revert UnauthorizedAccount(); }
                
                // Check if UST
                if(!isUST(_taskIndexes[i])) { revert UnsupportedTaskOperation(); }

                // Remove task from the registry
                removeTask(_taskIndexes[i], false);
                // Remove from active tasks
                regState.activeTaskIds.remove(_taskIndexes[i]);


                // This check means the task was expected to be executed in the next cycle, but it has been stopped.
                // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
                // Also it checks that task should not be cancelled.
                if(task.state != CommonUtils.TaskState.CANCELLED && task.expiryTime > cycleEndTime) {
                    // Prevent underflow in gas committed
                    if(regState.gasCommittedForNextCycle() < task.maxGasAmount) { revert GasCommittedValueUnderflow(); }
                    // Reduce committed gas by the stopped task's max gas
                    regState.setGasCommittedForNextCycle(regState.gasCommittedForNextCycle() - task.maxGasAmount);
                }

                uint128 cycleFeeRefund;
                uint128 depositRefund;
                if(task.state != CommonUtils.TaskState.PENDING) {
                    uint128 taskFee = calculateTaskFee(
                        task.state,
                        task.expiryTime,
                        task.maxGasAmount,
                        residualInterval,
                        uint64(currentTime),
                        automationFeePerSec,
                        registryMaxGasCap
                    );

                    // Refund full deposit and the half of the remaining run-time fee when task is active or cancelled stage
                    cycleFeeRefund = taskFee / REFUND_FRACTION; 
                    depositRefund = task.lockedFeeForNextCycle;
                } else {
                    cycleFeeRefund = 0;
                    depositRefund = task.lockedFeeForNextCycle / REFUND_FRACTION;
                }

                bool result = safeUnlockLockedDeposit(_taskIndexes[i], task.lockedFeeForNextCycle);
                if(!result) { revert ErrorDepositRefund(); }

                (bool hasLockedFee, uint256 remainingCycleLockedFees ) = safeUnlockLockedCycleFee(cycleLockedFees, uint64(cycleFeeRefund), _taskIndexes[i]);
                if(!hasLockedFee) { revert ErrorCycleFeeRefund(); }
                cycleLockedFees = remainingCycleLockedFees;
                totalRefundFee += (cycleFeeRefund + depositRefund);


                // Add to stopped tasks
                LibRegistry.TaskStopped memory taskStopped = LibRegistry.TaskStopped(
                    _taskIndexes[i],
                    depositRefund,
                    cycleFeeRefund,
                    task.txHash
                );
                stoppedTaskDetails[counter] = taskStopped;
                counter += 1;
            }
        }

        // Refund and emit event if any tasks were stopped
        if(stoppedTaskDetails.length > 0) {            
            uint256 balance = IERC20(regConfig.supraERC20).balanceOf(address(this));

            if(balance < totalRefundFee) { revert InsufficientBalanceForRefund(); }
            refund(msg.sender, totalRefundFee);

            // Emit task stopped event
            emit TasksStopped(
                stoppedTaskDetails,
                msg.sender
            );
        }
    }

    /// @notice Immediately stops system automation tasks for the specified `_taskIndexes`.
    /// Only tasks that exist and are owned by the sender can be stopped.
    /// If any of the specified tasks are not owned by the sender, the transaction will abort.
    /// When a task is stopped, the committed gas for the next cycle is reduced
    /// by the max gas amount of the stopped task.
    /// @param _taskIndexes Array of task indexes to be stopped.
    function stopSystemTasks(
        uint64[] memory _taskIndexes
    ) public {
        // Check if automation is enabled
        if (!regConfig.automationEnabled()) { revert AutomationNotEnabled(); }
        
        (CommonUtils.CycleState state, uint64 startTime, uint64 durationSecs) = IAutomationController(regConfig.automationController()).getCycleInfo();
        if(state != CommonUtils.CycleState.STARTED) { revert CycleTransitionInProgress(); }

        // Ensure that task indexes are provided
        if(_taskIndexes.length == 0) { revert TaskIndexesCannotBeEmpty(); }

        LibRegistry.TaskStopped[] memory stoppedTaskDetails = new LibRegistry.TaskStopped[](_taskIndexes.length);
        uint256 counter = 0;

        // Calculate refundable fee for this remaining time task in current cycle
        uint128 cycleEndTime = startTime + durationSecs;

        // Loop through each task index to validate and stop the task
        for (uint256 i = 0; i < _taskIndexes.length; i++) {
            if(ifTaskExists(_taskIndexes[i])) {
                CommonUtils.TaskDetails memory task = regState.tasks[_taskIndexes[i]].getTaskDetails();

                if(task.owner != msg.sender) { revert UnauthorizedAccount(); }

                // Check if GST
                if(isUST(_taskIndexes[i])) { revert UnsupportedTaskOperation(); }
                removeTask(_taskIndexes[i], true);
                // Remove from active tasks
                regState.activeTaskIds.remove(_taskIndexes[i]);


                if(task.state != CommonUtils.TaskState.CANCELLED && task.expiryTime > cycleEndTime) {
                    // Prevent underflow in gas committed
                    if(regSysState.gasCommittedForNextCycle() < task.maxGasAmount) { revert GasCommittedValueUnderflow(); } 
                    regSysState.setGasCommittedForNextCycle(regSysState.gasCommittedForNextCycle() - task.maxGasAmount);
                }

                // Add to stopped tasks
                LibRegistry.TaskStopped memory taskStopped = LibRegistry.TaskStopped(
                    _taskIndexes[i],
                    0,
                    0,
                    task.txHash
                );
                stoppedTaskDetails[counter] = taskStopped;
                counter += 1;
            }
        }

        if(stoppedTaskDetails.length > 0) {
            // Emit task stopped event
            emit TasksStopped(
                stoppedTaskDetails,
                msg.sender
            );
        }
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
        LibRegistry.TaskType _type,
        uint64 _taskDurationCapSecs,
        uint64 _sysTaskDurationCapSecs,
        uint64 _cycleStartTime, 
        uint64 _cycleDurationSecs
    ) private pure {
        if(_expiryTime <= _regTime) { revert InvalidExpiryTime(); }
        
        uint64 taskDuration = _expiryTime - _regTime;
        if(_type == LibRegistry.TaskType.UST) {
            if(taskDuration > _taskDurationCapSecs) { revert InvalidTaskDuration(); }
        } else if(_type == LibRegistry.TaskType.GST) {
            if ( taskDuration > _sysTaskDurationCapSecs) { revert InvalidTaskDuration(); }
        } else {
            revert InvalidTypeForTask();
        }

        if( _expiryTime <= _cycleStartTime + _cycleDurationSecs) { revert TaskExpiresBeforeNextCycle(); }
    }

    /// @notice Helper function to transfer refunds.
    /// @param _to Recipeint of the refund
    /// @param _amount Amount to refund
    /// @return Bool representing if refund was successful.
    function refund(address _to, uint128 _amount) private returns (bool) {
        bool sent = IERC20(regConfig.supraERC20).transfer(_to, _amount);
        if (!sent) { revert TransferFailed(); }

        return sent;
    }
    
    /// @notice Helper function to update the active task indexes.
    function updateActiveTaskIds() private {
        uint256[] memory taskIds = regState.taskIdList.values();
        for (uint256 i = 0; i < taskIds.length; i++) {
            regState.activeTaskIds.add(taskIds[i]);
        }
    }

    /// @notice Function to remove a task from the registry.
    /// @param _taskIndex Index of the task to remove. 
    /// @param _removeFromSysReg Wheather to remove from system task registry.
    function removeTask(uint64 _taskIndex, bool _removeFromSysReg) public onlyRegistryAndController {
        if(_removeFromSysReg) {
            regSysState.taskIds.remove(_taskIndex);
        }

        delete regState.tasks[_taskIndex];
        regState.taskIdList.remove(_taskIndex);
    }

    /// @notice Function to update state of the task.
    /// @param _taskIndex Index of the task.
    /// @param _taskState State to update task to.
    function updateTaskState(uint64 _taskIndex, CommonUtils.TaskState _taskState) external onlyController {
        LibRegistry.setState(regState.tasks[_taskIndex], uint8(_taskState));
    }
    
    /// @notice Function to update registry state.
    /// @param _sysGasCommittedForNextCycle Updated system gas committed for next cycle 
    /// @param _gasCommittedForNextCycle Updated gas committed for next cycle
    /// @param _gasCommittedForNewCycle Updated gas committed for new cycle
    /// @param _lockedFees Updated cycle locked fees
    /// @param _state Cycle transition state executing the update.
    function updateRegistryState(
        uint128 _sysGasCommittedForNextCycle,
        uint128 _gasCommittedForNextCycle,
        uint128 _gasCommittedForNewCycle,
        uint256 _lockedFees,
        uint8 _state
    ) external onlyController {
        regSysState.setGasCommittedForNextCycle(_sysGasCommittedForNextCycle);
        regSysState.setGasCommittedForThisCycle(_sysGasCommittedForNextCycle);
        regState.setGasCommittedForNextCycle(_gasCommittedForNextCycle);
        regState.setGasCommittedForThisCycle(_gasCommittedForNewCycle);
        regState.cycleLockedFees  = _lockedFees;

        regState.activeTaskIds.clear();

        if(_state == FINISHED) {
            updateActiveTaskIds();
        } else {
            regSysState.taskIds.clear();
        }
    }
    
    /// @notice Helper function to update the registry configuration, reverts if controller is not the caller.
    function applyPendingConfig() public onlyController {
        regConfig.config = configBuffer.pendingConfig;
        configBuffer.ifExists = false;
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
    /// @param _automationBaseFeeWeiPerSec Automation base fee per second.
    function calculateAutomationFeeMultiplierForCycle(
        uint128 _totalCommittedGas,
        uint128 _registryMaxGasCap,
        uint128 _automationBaseFeeWeiPerSec
    ) public view returns (uint128){
        uint128 congesionFee = calculateAutomationCongestionFee(_totalCommittedGas, _registryMaxGasCap);
        return (congesionFee + _automationBaseFeeWeiPerSec);
    }
 
    /// @notice Calculates automation task fees for a single task at the time of new cycle.
    /// This is supposed to be called only after removing expired task and must not be called for expired task.
    function calculateAutomationFeeForInterval(
        uint64 _duration,
        uint128 _taskOccupancy,
        uint128 _automationFeePerSec,
        uint128 _registryMaxGasCap
    ) public pure returns (uint128) {
        uint256 taskOccupancyRatioByDuration = (uint256(_duration) * uint256(_taskOccupancy) * DECIMAL) / uint256(_registryMaxGasCap);

        uint256 automationFeeForInterval = _automationFeePerSec * taskOccupancyRatioByDuration;

        return uint128(automationFeeForInterval / DECIMAL);
    }

    /// @notice Estimates automation fee the next cycle for specified task occupancy for the configured cycle interval
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and registry
    /// maximum allowed occupancy for the next cycle.
    /// Note it is expected that committed_occupancy does not include current task's occupancy.
    function estimateAutomationFeeWithCommittedOccupancyInternal(
        uint128 _taskOccupancy,
        uint128 _committedOccupancy,
        uint64 _duration
    ) internal view returns (uint128) {
        uint128 totalCommittedGas = _taskOccupancy + _committedOccupancy;
         
        uint128 automationFeePerSec = calculateAutomationFeeMultiplierForCycle(totalCommittedGas, regConfig.nextCycleRegistryMaxGasCap(), regConfig.automationBaseFeeWeiPerSec());

        if(automationFeePerSec == 0) return 0;

        return calculateAutomationFeeForInterval(_duration, _taskOccupancy, automationFeePerSec, regConfig.nextCycleRegistryMaxGasCap());
    }

    /// @notice Function to check and validate the input auxiliary data.
    /// @param _auxData Input auxiliary data.
    /// @param _taskType Type of the task.
    /// @return Bool representing if the task has priority.
    function checkAndValidateAuxData(bytes[] memory _auxData, LibRegistry.TaskType _taskType) private pure returns (bool) {
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

    /// @notice Unlocks the deposit paid by the task from the total automation fees deposited.
    /// @dev Error event is emitted if the total automation fees deposited is less than the requested unlock amount.
    /// @param _taskIndex Index of the task. 
    /// @param _lockedDeposit Locked deposit amount to be unlocked.
    /// @return Bool if _lockedDeposit can be unlocked safely.
    function safeUnlockLockedDeposit(
        uint64 _taskIndex,
        uint128 _lockedDeposit
    ) public onlyRegistryAndController returns (bool) {
        bool hasLockedDeposit = deposit.totalDepositedAutomationFees >= _lockedDeposit;
        
        if(hasLockedDeposit) {
            deposit.totalDepositedAutomationFees -= _lockedDeposit;
        } else {
            emit ErrorUnlockTaskDepositFee(_taskIndex, deposit.totalDepositedAutomationFees, _lockedDeposit);
        }

        return hasLockedDeposit;
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

    /// @notice Calculates automation task fees for a single task at the time of new cycle.
    /// This is supposed to be called only after removing expired task and must not be called for expired task.    
    /// @param _state State of the task.
    /// @param _expiryTime Task expiry time.
    /// @param _maxGasAmount Task's max gas amount
    /// @param _potentialFeeTimeframe Potential time frame to calculate task fees for.
    /// @param _currentTime Current time
    /// @param _automationFeePerSec Automation fee per sec
    /// @param _registryMaxGasCap Registry max gas cap
    /// @return Calculated task fee for the interval the task will be active.
    function calculateTaskFee(
        CommonUtils.TaskState _state,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _potentialFeeTimeframe,
        uint64 _currentTime,
        uint128 _automationFeePerSec,
        uint128 _registryMaxGasCap
    ) public onlyRegistryAndController view returns (uint128) {
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
            _registryMaxGasCap
        );
    }

    /// @notice Refunds the specified amount of deposit to the task owner and unlocks full deposit from the total automation fees deposited.
    /// @param _taskIndex Index of the task.
    /// @param _taskOwner Owner of the task.
    /// @param _refundableDeposit Refundable amount of deposit.
    /// @param _lockedDeposit Total locked deposit.
    function safeDepositRefund(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) private returns (bool) {
        // Ensures that amount to unlock is not more than the total automation fees deposited.
        bool result = safeUnlockLockedDeposit(_taskIndex, _lockedDeposit);
        if (!result) {
            return result;
        }

        result = safeRefund( _taskIndex, _taskOwner, _refundableDeposit, DEPOSIT_CYCLE_FEE);

        if (result) { emit TaskDepositFeeRefund(_taskIndex, _taskOwner, _refundableDeposit); }
        return result;
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
        uint256 balance = IERC20(regConfig.supraERC20).balanceOf(address(this));
        if(balance < _refundableAmount) {
            emit ErrorInsufficientBalanceToRefund(_taskIndex, _taskOwner, _refundType, _refundableAmount);
            return false;
        } else {
            return refund(_taskOwner, _refundableAmount);
        }
    }

    /// @notice Refunds the deposit fee of the task and removes from the registry.
    /// @param _taskIndex Index of the task.
    /// @param _taskOwner Owner of the task.
    /// @param _refundableDeposit Refundable amount of deposit.
    /// @param _lockedDeposit Total locked deposit.
    function refundDepositAndDrop(
        uint64 _taskIndex,
        address _taskOwner,
        uint128 _refundableDeposit,
        uint128 _lockedDeposit
    ) external onlyController {
        // Check if task is UST
        if(!isUST(_taskIndex)) { revert RegisteredTaskInvalidType(); }

        // Remove task from the registry state
        removeTask(_taskIndex, false);

        // Refund
        safeDepositRefund(
            _taskIndex,
            _taskOwner,
            _refundableDeposit,
            _lockedDeposit
        );
    }

    /// Refunds fee paid by the task for the cycle to the task owner.
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

    /// Refunds the deposit fee and any autoamtion fees of the task.
    function refundTaskFees(
        uint64 _taskIndex,
        uint64 _currentTime,
        uint256 _cycleLockedFees
    ) external onlyController returns (uint256) {
        if(!isUST(_taskIndex)) { revert RegisteredTaskInvalidType(); }

        CommonUtils.TaskDetails memory task = regState.tasks[_taskIndex].getTaskDetails();

        uint256 cycleLockedFees;
        // Do not attempt fee refund if remaining duration is 0

        (uint64 refundDuration, uint128 automationFeePerSec) = IAutomationController(regConfig.automationController()).getTransitionInfo();

        if (task.state != CommonUtils.TaskState.PENDING && refundDuration != 0) {
            uint128 registryMaxGasCap = getRegistryMaxGasCap();
            uint128 _refund = calculateTaskFee(
                task.state,
                task.expiryTime,
                task.maxGasAmount,
                refundDuration,
                _currentTime,
                automationFeePerSec,
                registryMaxGasCap
            );
            ( , uint256 remainingCycleLockedFees) = safeFeeRefund(
                    _taskIndex,
                    task.owner,
                    _cycleLockedFees,
                    uint64(_refund)
                );
            cycleLockedFees = remainingCycleLockedFees;
        }

        safeDepositRefund(
            _taskIndex,
            task.owner,
            task.lockedFeeForNextCycle,
            task.lockedFeeForNextCycle
        );

        return cycleLockedFees;
    }

    function calculateAutomationFeeMultiplierForCurrentCycleInternal() external onlyController view returns (uint128) {
        // Compute the automation fee multiplier for this cycle
        return calculateAutomationFeeMultiplierForCycle(
            regState.gasCommittedForThisCycle(),
            regConfig.registryMaxGasCap(),
            regConfig.automationBaseFeeWeiPerSec()
        );
    }

    /// Calculates automation fee per second for the specified task occupancy
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and current registry
    /// maximum allowed occupancy.
    function calculateAutomationFeeMultiplierForCommittedOccupancy(
        uint128 _totalCommittedMaxGas
    ) external onlyController view returns (uint128) {
        // Compute the automation fee multiplier for cycle        
        return calculateAutomationFeeMultiplierForCycle(
            _totalCommittedMaxGas,
            regConfig.registryMaxGasCap(),
            regConfig.automationBaseFeeWeiPerSec()
        );
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ADMIN FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Function to update the registry configuration parameters.
    function updateConfig(
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
    ) public onlyOwner {
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

        if(regState.gasCommittedForNextCycle() > _registryMaxGasCap) { revert UnacceptableRegistryMaxGasCap(); }
        if(regSysState.gasCommittedForNextCycle() > _sysRegistryMaxGasCap) { revert UnacceptableSysRegistryMaxGasCap(); }

        // Add new config to the buffer
        LibRegistry.Config memory pendingConfig = LibRegistry.createConfig(
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
        configBuffer = LibRegistry.ConfigBuffer(pendingConfig, true);

        regConfig.setNextCycleRegistryMaxGasCap(_registryMaxGasCap);
        regConfig.setNextCycleSysRegistryMaxGasCap(_sysRegistryMaxGasCap);

        emit ConfigBufferUpdated(pendingConfig.getConfig());
    }

    /// @notice Grants authorization to the input account to submit system automation tasks.
    /// @param _account Address to grant authorization to.
    function grantAuthorization(address _account) public onlyOwner {
        if(regSysState.authorizedAccounts.contains(_account)) {
            revert AddressAlreadyExists();
        } else {
            regSysState.authorizedAccounts.add(_account);
            
            emit AuthorizationGranted(_account, block.timestamp);
        }
    }

    /// @notice Revokes authorization from the input account to submit system automation tasks. 
    /// @param _account Address to revoke authorization from. 
    function revokeAuthorization(address _account) public onlyOwner {
        if(!regSysState.authorizedAccounts.contains(_account)) {
            revert AddressDoesNotExist();
        } else {
            regSysState.authorizedAccounts.remove(_account);

            emit AuthorizationRevoked(_account, block.timestamp);
        }
    }

    /// @notice Function to enable the task registration.
    function enableRegistration() public onlyOwner {
        if(regConfig.registrationEnabled()) { revert AlreadyEnabled(); }
        regConfig.setRegistrationEnabled(true);

        emit TaskRegistrationEnabled(regConfig.registrationEnabled());
    }

    /// @notice Function to disable the task registration.
    function disableRegistration() public onlyOwner {
        if(!regConfig.registrationEnabled()) { revert AlreadyDisabled(); }
        regConfig.setRegistrationEnabled(false);

        emit TaskRegistrationDisabled(regConfig.registrationEnabled());   
    }

    /// @notice Function to enable the automation.
    function enableAutomation() public onlyOwner {
        if(regConfig.automationEnabled()) { revert AlreadyEnabled(); }
        regConfig.setAutomationEnabled(true);

        emit AutomationEnabled(regConfig.automationEnabled());
    }
    
    /// @notice Function to disable the automation.
    function disableAutomation() public onlyOwner {
        if(!regConfig.automationEnabled()) { revert AlreadyDisabled(); }
        regConfig.setAutomationEnabled(false);

        emit AutomationDisabled(regConfig.automationEnabled());
    }

    /// @notice Function to update the VM address.
    /// @param _vm New address for VM.
    function setVM(address _vm) public onlyOwner {
        if(_vm == address(0)) { revert AddressCannotBeZero(); }

        address oldVM = regConfig.vm;
        regConfig.vm = _vm;

        emit VmAddressUpdated(oldVM, _vm);
    }

    /// @notice Function to update the SupraERC20 address.
    /// @param _supraERC20 New address for SupraERC20.
    function setSupraERC20(address _supraERC20) public onlyOwner {
        if(_supraERC20 == address(0)) { revert AddressCannotBeZero(); }
        if(!_supraERC20.isContract()) { revert AddressCannotBeEOA(); }

        address oldSupraERC20 = regConfig.supraERC20;
        regConfig.supraERC20 = _supraERC20;

        emit SupraERC20Updated(oldSupraERC20, _supraERC20);
    }

    /// @notice Function to withdraw the accumulated automation fees.
    /// @param _amount Amount to withdraw.
    function withdrawAutomationTaskFees(uint256 _amount) public onlyOwner {
        address coldWallet = deposit.coldWallet;
        if(coldWallet == address(0)) { revert ColdWalletNotSet(); }
        uint256 balance = IERC20(regConfig.supraERC20).balanceOf(address(this));

        if(balance < _amount) { revert InsufficientBalance(); }
        if(balance - _amount < regState.cycleLockedFees + deposit.totalDepositedAutomationFees) { revert RequestExceedsLockedBalance(); }

        bool sent = IERC20(regConfig.supraERC20).transfer(coldWallet, _amount);
        if(!sent) { revert TransferFailed(); }

        emit RegistryFeeWithdrawn(coldWallet, _amount);
    }

    /// @notice Function to update the cold wallet address.
    /// @param _coldWallet Address for the new cold wallet.
    function setColdWallet(address _coldWallet) public onlyOwner {
        if(_coldWallet == address(0)) { revert AddressCannotBeZero(); }

        address oldColdWallet = deposit.coldWallet;
        deposit.coldWallet = _coldWallet;

        emit ColdWalletUpdated(oldColdWallet, _coldWallet);
    }

    /// @notice Function to update the automation controller smart contract address. 
    /// @param _controller Address of the automation controller smart contact.
    function setAutomationController(address _controller) public onlyOwner {
        if (_controller == address(0)) { revert AddressCannotBeZero();  }
        if(!_controller.isContract()) { revert AddressCannotBeEOA(); }

        address oldController = regConfig.automationController();
        regConfig.setAutomationController(_controller);

        emit AutomationControllerUpdated(oldController, _controller);
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    function getConfig() public view returns (LibRegistry.ConfigDetails memory) {
        return regConfig.config.getConfig();
    }

    /// @notice Returns the cold wallet address.
    function getColdWallet() public view returns (address) {
        return deposit.coldWallet;
    }

    /// @notice Returns the VM address.
    function getVM() public view returns (address) {
        return regConfig.vm;
    }

    /// @notice Returns the SupraERC20 address.
    function supraERC20() public view returns (address) {
        return regConfig.supraERC20;
    }

    function getAutomationController() public view returns (address) {
        return regConfig.automationController();
    }

    /// @notice Returns if automation is enabled.
    function isAutomationEnabled() public view returns (bool) {
        return regConfig.automationEnabled();
    }

    /// @notice Returns if task registration is enabled.
    function isRegistrationEnabled() public view returns (bool) {
        return regConfig.registrationEnabled();
    }

    function getTotalLockedBalance() public view returns (uint256) {
        return getCycleLockedFees() + getTotalDepositedAutomationFees();
    }    

    /// @notice Retrieves the details of automation tasks by their task index. Skips a task if it doesn't exist.
    /// @param _taskIndexes Input task indexes to get details of.
    /// @return Task details of the tasks that exist.
    function getTaskDetailsBulk(uint64[] memory _taskIndexes) public view returns (CommonUtils.TaskDetails[] memory) {
        uint256 count = _taskIndexes.length;
        CommonUtils.TaskDetails[] memory temp =  new CommonUtils.TaskDetails[](count);
        uint256 exists;

        for (uint256 i = 0; i < count; i++) {
            if(ifTaskExists(_taskIndexes[i])) {
                temp[exists] = regState.tasks[_taskIndexes[i]].getTaskDetails();
                exists += 1; 
            }
        }

        CommonUtils.TaskDetails[] memory taskDetails =  new CommonUtils.TaskDetails[](exists);
        for (uint256 i = 0; i < exists; i++) {
            taskDetails[i] = temp[i];            
        }
        return taskDetails;
    }

    /// @notice Returns all the automation tasks available in the registry.
    function getTaskIdList() public view returns (uint256[] memory) {
        return regState.taskIdList.values();
    }

    /// @notice Returns the registry max gas cap for the next cycle.    
    function getNextCycleRegistryMaxGasCap() public view returns (uint128) {
        return regConfig.nextCycleRegistryMaxGasCap();
    }

    /// @notice Returns the system registry max gas cap for the next cycle.    
    function getNextCycleSysRegistryMaxGasCap() public view returns (uint128) {
        return regConfig.nextCycleSysRegistryMaxGasCap();
    }

    /// @notice Returns the number of total tasks.
    function totalTasks() public view returns (uint256) {
        return regState.taskIdList.length();
    }

    /// @notice Returns the number of total system tasks.
    function totalSystemTasks() public view returns (uint256) {
        return regSysState.taskIds.length();
    }

    /// @notice Returns the next task index.
    function getNextTaskIndex() public view returns (uint64) {
        return regState.currentIndex;
    }

    /// @notice Returns the details of a task. Reverts if task doesn't exist.
    /// @param _taskIndex Task index to get details for.
    function getTaskDetails(uint64 _taskIndex) public view returns (CommonUtils.TaskDetails memory) {
        if(!ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        return regState.tasks[_taskIndex].getTaskDetails();
    }
    
    /// @notice Checks if a task exist.
    /// @param _taskIndex Task index to check if a task exists against it.
    function ifTaskExists(uint64 _taskIndex) public view returns (bool) {
        return regState.tasks[_taskIndex].owner != address(0) && regState.taskIdList.contains(_taskIndex);
    }

    /// @notice Checks if a system task exist.
    /// @param _taskIndex Task index to check if a system task exists against it.
    function ifSysTaskExists(uint64 _taskIndex) public view returns (bool) {
        return regSysState.taskIds.contains(_taskIndex);
    }

    /// @notice Checks if a task is UST or GST.
    /// @param _taskIndex Task index of the task to check for.
    function isUST(uint64 _taskIndex) public view returns (bool) {
        bytes memory taskType = regState.tasks[_taskIndex].auxData[TYPE_AUX_DATA_INDEX];
        return uint8(taskType[0]) == uint8(LibRegistry.TaskType.UST);
    }

    /// @notice Validates the input task type against the task type.
    /// @param _taskIndex Index of the task.
    /// @param _type Input task type.
    function checkTaskType(uint64 _taskIndex, LibRegistry.TaskType _type) public view returns (bool) {
        bytes memory taskType = regState.tasks[_taskIndex].auxData[TYPE_AUX_DATA_INDEX];
        return uint8(taskType[0]) == uint8(_type);
    }

    /// @notice Returns the owner of the task 
    /// @param _taskIndex Task index of the task to query.
    function getTaskOwner(uint64 _taskIndex) public view returns (address) {
        return regState.tasks[_taskIndex].owner;
    }

    /// @notice Returns the state of the task 
    /// @param _taskIndex Task index of the task to query.
    function getTaskState(uint64 _taskIndex) public view returns (CommonUtils.TaskState) {
        return LibRegistry.state(regState.tasks[_taskIndex]);
    }

    /// @notice Returns the gas committed for the next cycle.
    function getGasCommittedForNextCycle() public view returns (uint128) {
        return regState.gasCommittedForNextCycle();
    }

    /// @notice Returns the gas committed for the current cycle.
    function getGasCommittedForCurrentCycle() public view returns (uint128) {
        return regState.gasCommittedForThisCycle();
    }

    /// @notice Returns the system gas committed for the next cycle.
    function getSystemGasCommittedForNextCycle() public view returns (uint128) {
        return regSysState.gasCommittedForNextCycle();
    }

    /// @notice Returns the system gas committed for the current cycle.
    function getSystemGasCommittedForCurrentCycle() public view returns (uint128) {
        return regSysState.gasCommittedForThisCycle();
    }

    /// @notice Returns the total amount of automation fees deposited.
    function getTotalDepositedAutomationFees() public view returns (uint256) {
        return deposit.totalDepositedAutomationFees;
    }

    /// @notice Returns the registry max gas cap configured.
    function getRegistryMaxGasCap() public view returns (uint128) {
        return regConfig.registryMaxGasCap();
    }

    /// @notice Returns the system registry max gas cap configured.
    function getSysRegistryMaxGasCap() public view returns (uint128) {
        return regConfig.sysRegistryMaxGasCap();
    }

    /// @notice Returns the automationBaseFeeWeiPerSec configured.
    function getAutomationBaseFeeWeiPerSec() public view returns (uint128) {
        return regConfig.automationBaseFeeWeiPerSec();
    }

    /// @notice Checks if the input account is an authorized submitter to submit system automation tasks.
    /// @param _account Address to check if it's authorized.
    function isAuthorizedSubmitter(address _account) public view returns (bool) {
        return regSysState.authorizedAccounts.contains(_account);
    }

    /// @notice Returns the total number of active tasks.
    function getTotalActiveTasks() public view returns (uint256) {
        return regState.activeTaskIds.length();
    }

    /// @notice Returns all the active task indexes.
    function getAllActiveTaskIds() public view returns (uint256[] memory) {
        return regState.activeTaskIds.values();
    }
    
    /// @notice Returns the locked fees for the cycle. 
    function getCycleLockedFees() public view returns (uint256) {
        return regState.cycleLockedFees;
    }

    /// @notice Checks whether there is an active task in registry with specified input task index.
    function hasActiveUserTask(address _account, uint64 _taskIndex) public view returns (bool) {
        return hasActiveTaskOfType(_account, _taskIndex, LibRegistry.TaskType.UST);
    }

    /// @notice Checks whether there is an active system task in registry with specified input task index.
    function hasActiveSystemTask(address _account, uint64 _taskIndex) public view returns (bool) {
        return hasActiveTaskOfType(_account, _taskIndex, LibRegistry.TaskType.GST);
    }

    /// @notice Checks whether there is an active task in registry with specified input task index of the input type.
    /// The type can be either 1 for user submitted tasks, and 2 for governance authorized tasks.
    function hasActiveTaskOfType(address _account, uint64 _taskIndex, LibRegistry.TaskType _type) public view returns (bool) {
        return regState.tasks[_taskIndex].owner == _account && LibRegistry.state(regState.tasks[_taskIndex]) != CommonUtils.TaskState.PENDING && checkTaskType(_taskIndex, _type);
    }

    /// @notice Checks if config buffer exists.
    /// @return Bool representing if config buffer exists.
    function ifConfigBufferExists() public view returns (bool) {
        return configBuffer.ifExists; 
    }

    function getPendingConfig() public view returns (LibRegistry.ConfigDetails memory) {
        return configBuffer.pendingConfig.getConfig();
    }
    
    /// @notice Returns the cycle duration of config buffer.
    function getBufferCycleDurationSecs() public view returns (uint64) {
        return configBuffer.pendingConfig.cycleDurationSecs();
    }

    /// @notice Estimates automation fee for the next cycle for specified task occupancy for the configured cycle-interval
    /// referencing the current automation registry fee parameters, current total occupancy and registry maximum allowed
    /// occupancy for the next cycle.
    function estimateAutomationFee(uint128 _taskOccupancy) public view returns (uint128) {
        return estimateAutomationFeeWithCommittedOccupancy(_taskOccupancy, regState.gasCommittedForNextCycle());
    }

    /// @notice Estimates automation fee the next cycle for specified task occupancy for the configured cycle-interval
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and registry
    /// maximum allowed occupancy for the next cycle.
    function estimateAutomationFeeWithCommittedOccupancy(
        uint128 _taskOccupancy,
        uint128 _committedOccupancy
    ) public view returns (uint128) {
        ( , , uint64 durationSecs) = IAutomationController(regConfig.automationController()).getCycleInfo();
        return estimateAutomationFeeWithCommittedOccupancyInternal(
            _taskOccupancy,
            _committedOccupancy,
            durationSecs
        );
    }

    function cycleDurationSecs() public view returns (uint64) {
        return regConfig.config.cycleDurationSecs();
    }


    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
