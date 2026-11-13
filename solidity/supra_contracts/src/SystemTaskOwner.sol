// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AutomationTaskOwnerBase} from "./AutomationTaskOwnerBase.sol";

/**
 * @title SystemTaskOwner
 * @notice Owns system automation tasks on behalf of the account that deploys it. The foundation
 *         `MultiSignatureWallet` does not own automation tasks (smr-moonshot #4922); it deploys
 *         a contract like this one through `deployContract`, which makes the wallet its owner,
 *         has the registry owner authorize it as a system task submitter, and registers, cancels
 *         and stops its system tasks through wallet transactions to it.
 *
 *         This is a reference implementation. It is not deployed at genesis, and no governance
 *         action deploys or drives it yet: those are written, and this contract adapted, once the
 *         foundation has a concrete system task and its requirements (README, "Automation tasks
 *         of the foundation").
 * @dev Every function that makes this contract act on the registry, or move what it holds, is
 *      restricted to its owner, as `IAutomationTaskOwner` requires. A task registered here runs
 *      with this contract as its sender, so this contract is used for nothing except its tasks:
 *      it is never made the owner, pending owner, admin or role holder of any contract, and it
 *      holds no funds. System tasks are charged no fees, so it refuses native SUPRA; anything that
 *      reaches it anyway can be withdrawn by the owner.
 *
 *      Ownership is two-step (Ownable2Step), so the foundation can move these tasks to a new
 *      wallet: `transferOwnership` only nominates the new owner, who must call
 *      `acceptOwnership`. Renouncing is disabled, since a contract without an owner could never
 *      cancel or stop its tasks again; only the registry owner's `removeTasks` would.
 */
contract SystemTaskOwner is AutomationTaskOwnerBase, Ownable2Step {
    /// @notice Thrown by renounceOwnership, which is always disabled on this contract.
    error OwnershipRenunciationDisabled();

    /// @notice Thrown when native SUPRA is sent to this contract, which pays no fees.
    error NativeTransferRefused();

    /// @param _automationRegistry The AutomationRegistry (Diamond) this contract registers with.
    /// The deployer becomes the owner.
    constructor(address _automationRegistry) AutomationTaskOwnerBase(_automationRegistry) Ownable(msg.sender) {}

    /// @notice The AutomationRegistry this contract registers its tasks with.
    function automationRegistry() external view returns (address) {
        return address(AUTOMATION_REGISTRY);
    }

    /// @notice Registers a system task owned by this contract, which must be an authorized
    /// submitter of the registry. The arguments are `registerSystemTask`'s.
    function registerSystemTask(
        bytes memory _payloadTx,
        bytes memory _predicate,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _priority,
        bytes[] memory _auxData
    ) external onlyOwner {
        _registerSystemAutomationTask(_payloadTx, _predicate, _expiryTime, _maxGasAmount, _priority, _auxData);
    }

    /// @notice Cancels system tasks owned by this contract.
    function cancelSystemTasks(uint64[] memory _taskIndexes) external onlyOwner {
        _cancelSystemAutomationTasks(_taskIndexes);
    }

    /// @notice Stops system tasks owned by this contract.
    function stopSystemTasks(uint64[] memory _taskIndexes) external onlyOwner {
        _stopSystemAutomationTasks(_taskIndexes);
    }

    /// @notice Sends this contract's whole WrappedSupra and native SUPRA balances to `_to`.
    function withdrawFunds(address payable _to) external onlyOwner {
        _withdrawAutomationFunds(_to);
    }

    /// @notice Always reverts: system tasks are charged no fees, so this contract holds no funds.
    receive() external payable override {
        revert NativeTransferRefused();
    }

    /// @notice Always reverts with OwnershipRenunciationDisabled for the owner (OwnableUnauthorizedAccount
    /// for anyone else).
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenunciationDisabled();
    }
}
