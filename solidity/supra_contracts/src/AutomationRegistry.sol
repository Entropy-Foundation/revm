// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {EnumerableSet} from "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {CommonUtils} from "./CommonUtils.sol";
import {LibRegistry} from "./LibRegistry.sol";

import {IAutomationCore} from "./IAutomationCore.sol";
import {IAutomationController} from "./IAutomationController.sol";
import {IAutomationRegistry} from "./IAutomationRegistry.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";

contract AutomationRegistry is IAutomationRegistry, Ownable2StepUpgradeable, UUPSUpgradeable {
    using EnumerableSet for *;
    using CommonUtils for *;
    using LibRegistry for *;

    /// @dev Defines divisor for refunds of deposit fees with penalty
    /// Factor of `2` suggests that `1/2` of the deposit will be refunded.
    uint8 constant REFUND_FACTOR = 2;

    /// @notice Address of the transaction hash precompile.
    address public constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;

    /// @dev State variables 
    LibRegistry.RegistryState regState;
    address public automationCore;
    address public automationController;

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

    /// @notice Emitted when the AutomationCore contract address is updated.
    event AutomationCoreUpdated(address indexed oldAutomationCore, address indexed newAutomationCore);

    /// @notice Emitted when the AutomationController contract address is updated.
    event AutomationControllerUpdated(address indexed oldAutomationController, address indexed newAutomationController);
    
    /// @notice Emitted when a task is cancelled.
    event TaskCancelled(
        uint64 indexed taskIndex,
        address indexed owner,
        bytes32 indexed regHash
    );

    /// @notice Emitted when a task is stopped.
    event TasksStopped(
        LibRegistry.TaskStopped[] indexed stoppedTasks,
        address indexed owner
    );

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::: CONSTRUCTOR AND INITIALIZER ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the owner and AutomationCore contract address, can only be called once.
    /// @param _automationCore Address of the AutomationCore contract.
    /// @param _automationController Address of the AutomationController contract.
    /// @param _owner Address of the contract owner.
    function initialize(address _automationCore, address _automationController, address _owner) public initializer {
        _automationCore.validateAddress();
        _automationController.validateAddress();
        if(_owner == address(0)) revert CommonUtils.AddressCannotBeZero();

        automationCore = _automationCore;
        automationController = _automationController;

        __Ownable2Step_init();
        __Ownable_init(_owner);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: TASKS RELATED FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Function used to register a user task for automation.
    /// @param _payloadTx Includes the target smart contract address and the data to call in abi encoded form.
    /// @param _expiryTime Time after which the task gets expired.
    /// @param _maxGasAmount Maximum amount of gas for the automation task.
    /// @param _gasPriceCap Maximum gas willing to pay for the task.
    /// @param _automationFeeCapForCycle Maximum automation fee for a cycle to be paid ever.
    /// @param _priority Priority for the task. 0 for default priority.
    /// @param _auxData Auxiliary data to be passed.
    function register(
        bytes memory _payloadTx,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority,
        bytes[] memory _auxData
    ) external {        
        uint64 regTime = uint64(block.timestamp);


        (bool ok, bytes memory out) = TX_HASH_PRECOMPILE.staticcall("");
        require(ok, "txhash precompile call failed");

        if (out.length != 32) { revert TxnHashLengthShouldBe32(uint64 (out.length)); }
        bytes32 _txHash = bytes32(out);

        IAutomationCore core = IAutomationCore(automationCore);
        core.updateStateForValidRegistration(
            totalTasks(),
            regTime,
            _expiryTime,
            CommonUtils.TaskType.UST,
            _payloadTx, 
            _maxGasAmount, 
            _gasPriceCap,
            _automationFeeCapForCycle
        );

        uint64 taskIndex = regState.currentIndex; 

        LibRegistry.TaskMetadata memory taskMetadata = LibRegistry.createTaskMetadata(
            _maxGasAmount,
            _gasPriceCap,
            _automationFeeCapForCycle,
            _automationFeeCapForCycle ,
            readTxHash(),
            taskIndex,
            regTime,
            _expiryTime,
            taskIndex,      // priority set to taskIndex
            msg.sender,
            CommonUtils.TaskType.UST,
            CommonUtils.TaskState.PENDING,
            _payloadTx,
            _auxData
        );
        
        regState.tasks[taskIndex] = taskMetadata; 
        require(regState.taskIdList.add(taskIndex), TaskIndexNotUnique());
        regState.currentIndex += 1;

        core.incTotalDepositedAutomationFees(_automationFeeCapForCycle);
        uint128 flatRegistrationFeeWei = core.flatRegistrationFeeWei();
        uint128 fee = flatRegistrationFeeWei + _automationFeeCapForCycle;
        core.chargeFees(msg.sender, fee);

        emit TaskRegistered(taskIndex, msg.sender, flatRegistrationFeeWei, _automationFeeCapForCycle, regState.tasks[taskIndex].getTaskDetails());
    }

    /// @notice Function to register a system task. Reverts if caller is not authorized.
    /// @param _payloadTx Includes the target smart contract address and the data to call in abi encoded form.
    /// @param _expiryTime Time after which the task gets expired.
    /// @param _maxGasAmount Maximum amount of gas for the automation task.
    /// @param _priority Priority for the task. 0 for default priority.
    /// @param _auxData Auxiliary data to be passed.
    function registerSystemTask(
        bytes memory _payloadTx,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _priority,
        bytes[] memory _auxData
    ) external {
        if(!isAuthorizedSubmitter(msg.sender)) { revert UnauthorizedAccount(); }
        
        uint64 regTime = uint64(block.timestamp);
        IAutomationCore(automationCore).updateStateForValidRegistration(
            totalSystemTasks(),
            regTime,
            _expiryTime,
            CommonUtils.TaskType.GST,
            _payloadTx, 
            _maxGasAmount, 
            0,
            0
        );
                
        uint64 taskIndex = regState.currentIndex; 
        uint64 taskPriority = _priority == 0 ? taskIndex : _priority;   // Defaults to taskIndex as priority if 0 is passed
        LibRegistry.TaskMetadata memory taskMetadata = LibRegistry.createTaskMetadata(
            _maxGasAmount,
            0,
            0,
            0,
            readTxHash(),
            taskIndex,
            regTime,
            _expiryTime,
            taskPriority,
            msg.sender,
            CommonUtils.TaskType.GST,
            CommonUtils.TaskState.PENDING,
            _payloadTx,
            _auxData
        );

        regState.tasks[taskIndex] = taskMetadata; 
        require(regState.taskIdList.add(taskIndex), TaskIndexNotUnique());
        require(regState.sysTaskIds.add(taskIndex), TaskIndexNotUnique());
        regState.currentIndex += 1;

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
    function cancelTask(
        uint64 _taskIndex
    ) external {
        // Check if automation is enabled
        IAutomationController controller = IAutomationController(automationController);
        if (!controller.isAutomationEnabled()) { revert AutomationNotEnabled(); }

        if(!controller.isCycleStarted()) { revert CycleTransitionInProgress(); }
        if(!ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        
        CommonUtils.TaskDetails memory task = regState.tasks[_taskIndex].getTaskDetails();

        if(task.taskType == CommonUtils.TaskType.GST) { revert UnsupportedTaskOperation(); }
        if(task.owner != msg.sender) { revert UnauthorizedAccount(); }
        if(task.state == CommonUtils.TaskState.CANCELLED) { revert AlreadyCancelled(); }
        
        IAutomationCore core = IAutomationCore(automationCore);
        if (task.state == CommonUtils.TaskState.PENDING) {
            // When Pending tasks are cancelled, refund of the deposit fee is done with penalty
            _removeTask(_taskIndex, false); 
            bool result = core.safeDepositRefund(
                _taskIndex,
                task.owner,
                task.depositFee / REFUND_FACTOR,
                task.depositFee
            );
            if(!result) { revert ErrorDepositRefund(); }            
        } else { 
            // It is safe not to check the state as above, the cancelled tasks are already rejected.
            // Active tasks will be refunded the deposited amount fully at the end of the cycle.
            LibRegistry.setState(regState.tasks[_taskIndex], uint8(CommonUtils.TaskState.CANCELLED));
        }

        // This check means the task was expected to be executed in the next cycle, but it has been cancelled.
        // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
        if (task.expiryTime > controller.getCycleEndTime()) {
            core.updateGasCommittedForNextCycle(task.taskType, task.maxGasAmount);
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
    ) external {
        // Check if automation is enabled
        IAutomationController controller = IAutomationController(automationController);
        if (!controller.isAutomationEnabled()) { revert AutomationNotEnabled(); }

        if(!controller.isCycleStarted()) { revert CycleTransitionInProgress(); }
        if(!ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        if(!ifSysTaskExists(_taskIndex)) { revert SystemTaskDoesNotExist(); }

        CommonUtils.TaskDetails memory task = regState.tasks[_taskIndex].getTaskDetails();

        // Check if GST
        if(task.taskType == CommonUtils.TaskType.UST) { revert UnsupportedTaskOperation(); }

        if(task.owner != msg.sender) { revert UnauthorizedAccount(); }
        if(task.state == CommonUtils.TaskState.CANCELLED) { revert AlreadyCancelled(); }

        if(task.state == CommonUtils.TaskState.PENDING) {
            _removeTask(_taskIndex, true);
        } else {
            LibRegistry.setState(regState.tasks[_taskIndex], uint8(CommonUtils.TaskState.CANCELLED));
        }

        // This check means the task was expected to be executed in the next cycle, but it has been cancelled.
        // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
        if(task.expiryTime > controller.getCycleEndTime()) {
            IAutomationCore(automationCore).updateGasCommittedForNextCycle(task.taskType, task.maxGasAmount);
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
    ) external {
        // Check if automation is enabled
        IAutomationController controller = IAutomationController(automationController);
        if (!controller.isAutomationEnabled()) { revert AutomationNotEnabled(); }

        if(!controller.isCycleStarted()) { revert CycleTransitionInProgress(); }
        if(_taskIndexes.length == 0) { revert TaskIndexesCannotBeEmpty(); }

        LibRegistry.TaskStopped[] memory stoppedTaskDetails = new LibRegistry.TaskStopped[](_taskIndexes.length);
        uint256 counter = 0;
        
        uint128 totalRefundFee = 0;

        // Calculate refundable fee for this remaining time task in current cycle
        uint64 currentTime = uint64(block.timestamp);
        uint64 cycleEndTime = controller.getCycleEndTime();
        uint64 residualInterval = cycleEndTime <= currentTime ? 0 : (cycleEndTime - currentTime);

        IAutomationCore core = IAutomationCore(automationCore);

        // Loop through each task index to validate and stop the task
        for (uint256 i = 0; i < _taskIndexes.length; i++) {
            if(ifTaskExists(_taskIndexes[i])) {
                CommonUtils.TaskDetails memory task = regState.tasks[_taskIndexes[i]].getTaskDetails();

                // Check if authorised
                if(msg.sender != task.owner) { revert UnauthorizedAccount(); }
                
                // Check if UST
                if(task.taskType == CommonUtils.TaskType.GST) { revert UnsupportedTaskOperation(); }

                // Remove task from the registry
                _removeTask(_taskIndexes[i], false);
                // Remove from active tasks
                require(regState.activeTaskIds.remove(_taskIndexes[i]), TaskIndexNotFound());

                // This check means the task was expected to be executed in the next cycle, but it has been stopped.
                // We need to remove its gas commitment from `gasCommittedForNextCycle` for this particular task.
                // Also it checks that task should not be cancelled.
                if(task.state != CommonUtils.TaskState.CANCELLED && task.expiryTime > cycleEndTime) {
                    // Reduce committed gas by the stopped task's max gas
                    core.updateGasCommittedForNextCycle(task.taskType, task.maxGasAmount);
                }

                (uint128 cycleFeeRefund, uint128 depositRefund) = core.unlockDepositAndCycleFee(
                    _taskIndexes[i],
                    task.state,
                    task.expiryTime,
                    task.maxGasAmount,
                    residualInterval,
                    uint64(currentTime),
                    task.depositFee
                );
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
            core.refund(msg.sender, totalRefundFee);

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
    ) external {
        // Check if automation is enabled
        IAutomationController controller = IAutomationController(automationController);
        if (!controller.isAutomationEnabled()) { revert AutomationNotEnabled(); }

        if(!controller.isCycleStarted()) { revert CycleTransitionInProgress(); }

        // Ensure that task indexes are provided
        if(_taskIndexes.length == 0) { revert TaskIndexesCannotBeEmpty(); }

        LibRegistry.TaskStopped[] memory stoppedTaskDetails = new LibRegistry.TaskStopped[](_taskIndexes.length);
        uint256 counter = 0;

        // Loop through each task index to validate and stop the task
        for (uint256 i = 0; i < _taskIndexes.length; i++) {
            if(ifTaskExists(_taskIndexes[i])) {
                CommonUtils.TaskDetails memory task = regState.tasks[_taskIndexes[i]].getTaskDetails();

                if(task.owner != msg.sender) { revert UnauthorizedAccount(); }

                // Check if GST
                if(task.taskType == CommonUtils.TaskType.UST) { revert UnsupportedTaskOperation(); }
                _removeTask(_taskIndexes[i], true);
                // Remove from active tasks
                require(regState.activeTaskIds.remove(_taskIndexes[i]), TaskIndexNotFound());

                if(task.state != CommonUtils.TaskState.CANCELLED && task.expiryTime > controller.getCycleEndTime()) {
                    IAutomationCore(automationCore).updateGasCommittedForNextCycle(task.taskType, task.maxGasAmount);
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

    /// @notice Read tx hash via precompile. Reverts if precompile missing/fails.
    function readTxHash() private view returns (bytes32) {
        (bool ok, bytes memory out) = TX_HASH_PRECOMPILE.staticcall("");
        require(ok, FailedToCallTxHashPrecompile());
        require(out.length == 32, TxnHashLengthShouldBe32(uint64(out.length)));
        return abi.decode(out, (bytes32));
    }
    
    /// @notice Function to remove a task from the registry.
    /// @param _taskIndex Index of the task to remove. 
    /// @param _removeFromSysReg Wheather to remove from system task registry.
    function _removeTask(uint64 _taskIndex, bool _removeFromSysReg) private {
        if(_removeFromSysReg) {
            require(regState.sysTaskIds.remove(_taskIndex), TaskIndexNotFound());
        }

        delete regState.tasks[_taskIndex];
        require(regState.taskIdList.remove(_taskIndex), TaskIndexNotFound());
    }

    /// @notice Function to ensure that AutomationController contract is the caller.
    function onlyController() private view {
        if(msg.sender != automationController) { revert CallerNotController(); }
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: ADMIN FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Grants authorization to the input account to submit system automation tasks.
    /// @param _account Address to grant authorization to.
    function grantAuthorization(address _account) external onlyOwner {
        require(regState.authorizedAccounts.add(_account), AddressAlreadyExists());
        emit AuthorizationGranted(_account, block.timestamp);
    }

    /// @notice Revokes authorization from the input account to submit system automation tasks. 
    /// @param _account Address to revoke authorization from. 
    function revokeAuthorization(address _account) external onlyOwner {
        require(regState.authorizedAccounts.remove(_account), AddressDoesNotExist());
        emit AuthorizationRevoked(_account, block.timestamp);
    }

    /// @notice Function to update the AutomationCore contract address.
    /// @param _automationCore Address of the AutomationCore contract.
    function setAutomationCore(address _automationCore) external onlyOwner {
        _automationCore.validateContractAddress();
        
        address oldAutomationCore = automationCore;
        automationCore = _automationCore;
        
        emit AutomationCoreUpdated(oldAutomationCore, _automationCore);
    }

    /// @notice Function to update the AutomationController contract address.
    /// @param _automationController Address of the AutomationController contract.
    function setAutomationController(address _automationController) external onlyOwner {
        _automationController.validateContractAddress();

        address oldAutomationController = automationController;
        automationController = _automationController;
        
        emit AutomationControllerUpdated(oldAutomationController, _automationController);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: CONTROLLER FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    
    /// @notice Internally calls _removeTask, reverts if caller is not AutomationController.
    function removeTask(uint64 _taskIndex, bool _removeFromSysReg) external {
        onlyController();
        _removeTask(_taskIndex, _removeFromSysReg);
    }
    
    /// @notice Function to update state of the task.
    /// @param _taskIndex Index of the task.
    /// @param _taskState State to update task to.
    function updateTaskState(uint64 _taskIndex, CommonUtils.TaskState _taskState) external {
        onlyController();
        LibRegistry.setState(regState.tasks[_taskIndex], uint8(_taskState));
    }

    /// @notice Function to update tasks lists.
    /// @param _state Cycle transition state executing the update.
    function updateTaskIds(CommonUtils.CycleState _state) external {
        onlyController();

        regState.activeTaskIds.clear();

        if(_state == CommonUtils.CycleState.FINISHED) {
            uint256[] memory taskIds = regState.taskIdList.values();
            for (uint256 i = 0; i < taskIds.length; i++) {
                regState.activeTaskIds.add(taskIds[i]);
            }
        } else {
            regState.sysTaskIds.clear();
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
    ) external {
        onlyController();
        // Check if task is UST
        if (regState.tasks[_taskIndex].taskType() == CommonUtils.TaskType.GST) { revert RegisteredTaskInvalidType(); }

        // Remove task from the registry state
        _removeTask(_taskIndex, false);

        // Refund
        IAutomationCore(automationCore).safeDepositRefund(
            _taskIndex,
            _taskOwner,
            _refundableDeposit,
            _lockedDeposit
        );
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::  

    /// @notice Retrieves the details of automation tasks by their task index. Skips a task if it doesn't exist.
    /// @param _taskIndexes Input task indexes to get details of.
    /// @return Task details of the tasks that exist.
    function getTaskDetailsBulk(uint64[] memory _taskIndexes) external view returns (CommonUtils.TaskDetails[] memory) {
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
    function getTaskIdList() external view returns (uint256[] memory) {
        return regState.taskIdList.values();
    }

    /// @notice Returns the number of total tasks.
    function totalTasks() public view returns (uint256) {
        return regState.taskIdList.length();
    }

    /// @notice Returns the number of total system tasks.
    function totalSystemTasks() public view returns (uint256) {
        return regState.sysTaskIds.length();
    }

    /// @notice Returns the next task index.
    function getNextTaskIndex() external view returns (uint64) {
        return regState.currentIndex;
    }

    /// @notice Returns the details of a task. Reverts if task doesn't exist.
    /// @param _taskIndex Task index to get details for.
    function getTaskDetails(uint64 _taskIndex) external view returns (CommonUtils.TaskDetails memory) {
        if(!ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        return regState.tasks[_taskIndex].getTaskDetails();
    }
    
    /// @notice Checks if a task exist.
    /// @param _taskIndex Task index to check if a task exists against it.
    function ifTaskExists(uint64 _taskIndex) public view returns (bool) {
        return regState.tasks[_taskIndex].owner() != address(0) && regState.taskIdList.contains(_taskIndex);
    }

    /// @notice Checks if a system task exist.
    /// @param _taskIndex Task index to check if a system task exists against it.
    function ifSysTaskExists(uint64 _taskIndex) public view returns (bool) {
        return regState.sysTaskIds.contains(_taskIndex);
    }

    /// @notice Validates the input task type against the task type.
    /// @param _taskIndex Index of the task.
    /// @param _type Input task type.
    function checkTaskType(uint64 _taskIndex, CommonUtils.TaskType _type) external view returns (bool) {
        if (!ifTaskExists(_taskIndex)) { revert TaskDoesNotExist(); }
        return _type == regState.tasks[_taskIndex].taskType();
    }

    /// @notice Returns the owner of the task 
    /// @param _taskIndex Task index of the task to query.
    function getTaskOwner(uint64 _taskIndex) external view returns (address) {
        return regState.tasks[_taskIndex].owner();
    }

    /// @notice Returns the state of the task 
    /// @param _taskIndex Task index of the task to query.
    function getTaskState(uint64 _taskIndex) external view returns (CommonUtils.TaskState) {
        return LibRegistry.state(regState.tasks[_taskIndex]);
    }
    
    /// @notice Checks if the input account is an authorized submitter to submit system automation tasks.
    /// @param _account Address to check if it's authorized.
    function isAuthorizedSubmitter(address _account) public view returns (bool) {
        return regState.authorizedAccounts.contains(_account);
    }

    /// @notice Returns the total number of active tasks.
    function getTotalActiveTasks() external view returns (uint256) {
        return regState.activeTaskIds.length();
    }

    /// @notice Returns all the active task indexes.
    function getAllActiveTaskIds() external view returns (uint256[] memory) {
        return regState.activeTaskIds.values();
    }

    /// @notice Checks whether there is an active task in registry with specified input task index.
    function hasActiveUserTask(address _account, uint64 _taskIndex) external view returns (bool) {
        return hasActiveTaskOfType(_account, _taskIndex, CommonUtils.TaskType.UST);
    }

    /// @notice Checks whether there is an active system task in registry with specified input task index.
    function hasActiveSystemTask(address _account, uint64 _taskIndex) external view returns (bool) {
        return hasActiveTaskOfType(_account, _taskIndex, CommonUtils.TaskType.GST);
    }

    /// @notice Checks whether there is an active task in registry with specified input task index of the input type.
    /// The type can be either 0 for user submitted tasks, and 1 for governance authorized tasks.
    function hasActiveTaskOfType(address _account, uint64 _taskIndex, CommonUtils.TaskType _type) public view returns (bool) {
        LibRegistry.TaskMetadata storage task = regState.tasks[_taskIndex]; 
        return task.owner() == _account && task.state() != CommonUtils.TaskState.PENDING && task.taskType() == _type;
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
