// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibAppStorage, RegistryState} from "../libraries/LibAppStorage.sol";
import {LibAccounting} from "../libraries/LibAccounting.sol";
import {LibCommon} from "../libraries/LibCommon.sol";
import {LibRegistry} from "../libraries/LibRegistry.sol";
import {IRegistryFacet} from "../interfaces/IRegistryFacet.sol";
import {IFacetSelectors} from "../interfaces/IFacetSelectors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract RegistryFacet is IRegistryFacet, IFacetSelectors {
    using EnumerableSet for *;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: TASKS RELATED FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Function used to register a user task for automation.
    /// @param _payloadTx Includes the target smart contract address and the data to call in abi encoded form.
    /// @param _predicate Payload for predicate of the task.
    /// @param _expiryTime Time after which the task gets expired.
    /// @param _maxGasAmount Maximum amount of gas for the automation task.
    /// @param _gasPriceCap Maximum gas willing to pay for the task.
    /// @param _automationFeeCapForCycle Maximum automation fee for a cycle to be paid ever.
    /// @param _priority Priority for the task. 0 for default priority.
    /// @param _auxData Auxiliary data to be passed.
    function register(
        bytes memory _payloadTx,
        bytes memory _predicate,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority,
        bytes[] memory _auxData
    ) external {        
        uint64 taskIndex = LibRegistry.registerTask(
            _payloadTx,
            _predicate,
            _expiryTime,
            _maxGasAmount,
            _gasPriceCap,
            _automationFeeCapForCycle,
            _priority,
            LibCommon.TaskType.UST,
            _auxData
        );
        
        RegistryState storage registryState = LibAppStorage.registryState();

        registryState.totalDepositedAutomationFees += _automationFeeCapForCycle;

        uint128 flatRegistrationFee = LibAppStorage.activeConfig().flatRegistrationFeeWei;
        uint128 fee = flatRegistrationFee + _automationFeeCapForCycle;

        bool sent = IERC20(LibAppStorage.appStorage().erc20Supra).transferFrom(msg.sender, address(this), fee);
        if (!sent) { revert TransferFailed(); }

        emit TaskRegistered(taskIndex, msg.sender, flatRegistrationFee, _automationFeeCapForCycle, registryState.tasks[taskIndex]);
    }

    /// @notice Function to register a system task. Reverts if caller is not authorized.
    /// @param _payloadTx Includes the target smart contract address and the data to call in abi encoded form.
    /// @param _predicate Payload for predicate of the task.
    /// @param _expiryTime Time after which the task gets expired.
    /// @param _maxGasAmount Maximum amount of gas for the automation task.
    /// @param _priority Priority for the task. 0 for default priority.
    /// @param _auxData Auxiliary data to be passed.
    function registerSystemTask(
        bytes memory _payloadTx,
        bytes memory _predicate,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _priority,
        bytes[] memory _auxData
    ) external {
        if (!isAuthorizedSubmitter(msg.sender)) { revert UnauthorizedAccount(); }
        
        uint64 taskIndex = LibRegistry.registerTask(
            _payloadTx,
            _predicate,
            _expiryTime,
            _maxGasAmount,
            0,
            0,
            _priority,
            LibCommon.TaskType.GST,
            _auxData
        );

        emit SystemTaskRegistered(taskIndex, msg.sender, block.timestamp, LibAppStorage.registryState().tasks[taskIndex]);
    }

    /// @notice Cancels the automation tasks with specified task indexes.
    /// Only existing task, which is PENDING or ACTIVE, can be cancelled and only by task owner.
    /// If the task is
    ///   - active, its state is updated to be CANCELLED.
    ///   - pending, it is removed form the list.
    ///   - cancelled, an error is reported
    /// Committed gas limit is updated by reducing it with the max gas amount of the cancelled task.
    /// @param _taskIndexes Array of task indexes to be cancelled.
    function cancelTasks(
        uint64[] memory _taskIndexes
    ) external {
        validateInput(_taskIndexes);

        LibCommon.TaskCancelled[] memory cancelledTasksBuffer = new LibCommon.TaskCancelled[](_taskIndexes.length);
        uint256 counter;

        for (uint256 i; i < _taskIndexes.length; i++) {
            uint64 taskId = _taskIndexes[i];
            if (LibCommon.ifTaskExists(taskId)) {
                cancelledTasksBuffer[counter++] = LibRegistry.cancelTask(taskId, false);
            }
        }

        if (counter > 0) {
            // Emit only the entries actually written.
            LibCommon.TaskCancelled[] memory cancelledTasks = new LibCommon.TaskCancelled[](counter);
            for (uint256 i; i < counter; i++) {
                cancelledTasks[i] = cancelledTasksBuffer[i];
            }
            emit TasksCancelled(cancelledTasks, msg.sender);
        }
    }

    /// @notice Cancels the system automation tasks with specified task indexes.
    /// Only existing task, which is PENDING or ACTIVE, can be cancelled and only by task owner.
    /// If the task is
    ///   - active, its state is updated to be CANCELLED.
    ///   - pending, it is removed form the list.
    ///   - cancelled, an error is reported
    /// Committed gas limit is updated by reducing it with the max gas amount of the cancelled task.
    /// @param _taskIndexes Array of task indexes to be cancelled.
    function cancelSystemTasks(
        uint64[] memory _taskIndexes
    ) external {
        validateInput(_taskIndexes);

        LibCommon.TaskCancelled[] memory cancelledTasksBuffer = new LibCommon.TaskCancelled[](_taskIndexes.length);
        uint256 counter;

        for (uint256 i; i < _taskIndexes.length; i++) {
            uint64 taskId = _taskIndexes[i];
            if (LibCommon.ifTaskExists(taskId)) {
                cancelledTasksBuffer[counter++] = LibRegistry.cancelTask(taskId, true);
            }
        }

        if (counter > 0) {
            // Emit only the entries actually written.
            LibCommon.TaskCancelled[] memory cancelledTasks = new LibCommon.TaskCancelled[](counter);
            for (uint256 i; i < counter; i++) {
                cancelledTasks[i] = cancelledTasksBuffer[i];
            }
            emit TasksCancelled(cancelledTasks, msg.sender);
        }
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
        validateInput(_taskIndexes);

        LibCommon.TaskStopped[] memory stoppedTasksBuffer = new LibCommon.TaskStopped[](_taskIndexes.length);
        uint64 cycleEndTime = LibCommon.getCycleEndTime();
        uint64 currentTime = uint64(block.timestamp);
        // Calculate refundable fee for this remaining time task in current cycle
        uint64 residualInterval = cycleEndTime <= currentTime ? 0 : (cycleEndTime - currentTime);

        uint256 counter;
        uint128 totalRefundFee;

        // Loop through each task index to validate and stop the task
        for (uint256 i = 0; i < _taskIndexes.length; i++) {
            uint64 taskId = _taskIndexes[i];
            if (LibCommon.ifTaskExists(taskId)) {
                (LibCommon.TaskStopped memory ts, uint128 refund) = LibRegistry.stopTask(
                    taskId,
                    cycleEndTime,
                    currentTime,
                    residualInterval,
                    false
                );
                stoppedTasksBuffer[counter++] = ts;
                totalRefundFee += refund;
            }
        }

        // Refund and emit event if any tasks were stopped
        if (counter > 0) {
            LibAccounting.refund(msg.sender, totalRefundFee);

            // Emit only the entries actually written.
            LibCommon.TaskStopped[] memory stoppedTasks = new LibCommon.TaskStopped[](counter);
            for (uint256 i; i < counter; i++) {
                stoppedTasks[i] = stoppedTasksBuffer[i];
            }

            // Emit task stopped event
            emit TasksStopped(stoppedTasks, msg.sender);
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
        validateInput(_taskIndexes);

        LibCommon.TaskStopped[] memory stoppedTasksBuffer = new LibCommon.TaskStopped[](_taskIndexes.length);
        uint64 cycleEndTime = LibCommon.getCycleEndTime();
        uint64 currentTime = uint64(block.timestamp);
        uint256 counter;

        // Loop through each task index to validate and stop the task
        for (uint256 i = 0; i < _taskIndexes.length; i++) {
            uint64 taskId = _taskIndexes[i];
            if (LibCommon.ifTaskExists(taskId)) {
                (LibCommon.TaskStopped memory ts,) = LibRegistry.stopTask(taskId, cycleEndTime, currentTime, 0, true);
                stoppedTasksBuffer[counter++] = ts;
            }
        }

        if (counter > 0) {
            // Emit only the entries actually written.
            LibCommon.TaskStopped[] memory stoppedTasks = new LibCommon.TaskStopped[](counter);
            for (uint256 i; i < counter; i++) {
                stoppedTasks[i] = stoppedTasksBuffer[i];
            }

            // Emit task stopped event
            emit TasksStopped(stoppedTasks, msg.sender);
        }
    }

    /// @notice Helper function for validation.
    function validateInput(uint64[] memory _taskIndexes) private view {
        if (!LibAppStorage.appStorage().automationEnabled) { revert AutomationNotEnabled(); }
        if (!LibCommon.isCycleStarted()) revert CycleTransitionInProgress();
        if (_taskIndexes.length == 0) revert TaskIndexesCannotBeEmpty();
    }

    // :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: VIEW FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    //
    // Only the views below stay here; the rest moved to RegistryViewFacet
    // (Entropy-Foundation/smr-moonshot#4101). These five stay because moving them would
    // duplicate code this facet already contains: the fee views reach the same
    // `LibAccounting` fee math as `register`, and `isAuthorizedSubmitter` is called
    // directly by `registerSystemTask`.

    /// @notice Checks if the input account is an authorized submitter to submit system automation tasks.
    /// @param _account Address to check if it's authorized.
    function isAuthorizedSubmitter(address _account) public view returns (bool) {
        return LibAppStorage.appStorage().authorizedAccounts.contains(_account);
    }

    /// @notice Calculates automation fee per second for the specified task occupancy
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and current registry
    /// maximum allowed occupancy.
    function calculateAutomationFeeMultiplierForCommittedOccupancy(uint128 _totalCommittedMaxGas) external view returns (uint128) {
        return LibAccounting.calculateAutomationFeeMultiplierForCommittedOccupancy(_totalCommittedMaxGas);
    }
    
    /// @notice Calculates the automation fee multiplier for current cycle. 
    function calculateAutomationFeeMultiplierForCurrentCycle() external view returns (uint128) {
        return LibAccounting.calculateAutomationFeeMultiplierForCurrentCycle();
    }

    /// @notice Estimates automation fee for the next cycle for specified task occupancy for the configured cycle-interval
    /// referencing the current automation registry fee parameters, current total occupancy and registry maximum allowed
    /// occupancy for the next cycle.
    function estimateAutomationFee(uint128 _taskOccupancy) external view returns (uint128) {
        return LibAccounting.estimateAutomationFeeWithCommittedOccupancyInternal(_taskOccupancy, LibAppStorage.registryState().gasCommittedForNextCycle);
    }

    /// @notice Estimates automation fee the next cycle for specified task occupancy for the configured cycle-interval
    /// referencing the current automation registry fee parameters, specified total/committed occupancy and registry
    /// maximum allowed occupancy for the next cycle.
    function estimateAutomationFeeWithCommittedOccupancy(
        uint128 _taskOccupancy,
        uint128 _committedOccupancy
    ) external view returns (uint128) {
        return LibAccounting.estimateAutomationFeeWithCommittedOccupancyInternal(
            _taskOccupancy,
            _committedOccupancy
        );
    }

    function getSelectors() external pure override returns (bytes4[] memory selectors) {
        selectors = new bytes4[](11);
        selectors[0]  = RegistryFacet.register.selector;
        selectors[1]  = RegistryFacet.registerSystemTask.selector;
        selectors[2]  = RegistryFacet.cancelTasks.selector;
        selectors[3]  = RegistryFacet.cancelSystemTasks.selector;
        selectors[4]  = RegistryFacet.stopTasks.selector;
        selectors[5]  = RegistryFacet.stopSystemTasks.selector;
        selectors[6]  = this.isAuthorizedSubmitter.selector;
        selectors[7]  = RegistryFacet.calculateAutomationFeeMultiplierForCommittedOccupancy.selector;
        selectors[8]  = RegistryFacet.calculateAutomationFeeMultiplierForCurrentCycle.selector;
        selectors[9]  = RegistryFacet.estimateAutomationFee.selector;
        selectors[10] = RegistryFacet.estimateAutomationFeeWithCommittedOccupancy.selector;
    }
}
