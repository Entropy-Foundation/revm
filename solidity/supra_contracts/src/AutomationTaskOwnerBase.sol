// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC165} from "./interfaces/IERC165.sol";
import {AUTOMATION_TASK_OWNER_INTERFACE_ID, IAutomationTaskOwner} from "./interfaces/IAutomationTaskOwner.sol";

/// @dev The AutomationRegistry functions `AutomationTaskOwnerBase` calls.
interface IAutomationTaskOwnerRegistry {
    function register(
        bytes memory _payloadTx,
        bytes memory _predicate,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority,
        bytes[] memory _auxData
    ) external;
    function registerSystemTask(
        bytes memory _payloadTx,
        bytes memory _predicate,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _priority,
        bytes[] memory _auxData
    ) external;
    function cancelTasks(uint64[] memory _taskIndexes) external;
    function cancelSystemTasks(uint64[] memory _taskIndexes) external;
    function stopTasks(uint64[] memory _taskIndexes) external;
    function stopSystemTasks(uint64[] memory _taskIndexes) external;
    function erc20Supra() external view returns (address);
}

/// @dev The WrappedSupra functions `AutomationTaskOwnerBase` calls.
interface IAutomationTaskOwnerFeeToken {
    function deposit() external payable;
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Optional base for a contract that owns SupraEVM automation tasks (#4469).
/// @dev It declares `IAutomationTaskOwner` through ERC-165, accepts native SUPRA for the gas of
///      the tasks' executions, and wraps the AutomationRegistry calls an owner makes in internal
///      functions. It exposes no external function that registers, cancels, stops, funds or
///      withdraws: the inheriting contract adds those, with its own access control, so that only
///      accounts it trusts can make it act. See `IAutomationTaskOwner` for the obligations.
abstract contract AutomationTaskOwnerBase is IAutomationTaskOwner {
    /// @notice The AutomationRegistry this contract registers its tasks with.
    IAutomationTaskOwnerRegistry internal immutable AUTOMATION_REGISTRY;
    /// @notice The WrappedSupra token the registry charges fees in, read from the registry.
    IAutomationTaskOwnerFeeToken internal immutable AUTOMATION_FEE_TOKEN;

    /// @notice A WrappedSupra approval or transfer returned `false`, or a native transfer failed.
    error AutomationFundsTransferFailed();

    constructor(address _automationRegistry) {
        AUTOMATION_REGISTRY = IAutomationTaskOwnerRegistry(_automationRegistry);
        AUTOMATION_FEE_TOKEN = IAutomationTaskOwnerFeeToken(AUTOMATION_REGISTRY.erc20Supra());
    }

    /// @notice ERC-165: `IERC165` and `IAutomationTaskOwner`. An override that declares further
    /// interfaces must keep both and must return `false` for `0xffffffff`.
    function supportsInterface(bytes4 _interfaceId) public view virtual returns (bool) {
        return _interfaceId == type(IERC165).interfaceId || _interfaceId == AUTOMATION_TASK_OWNER_INTERFACE_ID;
    }

    /// @notice Accepts native SUPRA, which pays the gas of this contract's user tasks and any
    /// value they send.
    receive() external payable virtual {}

    /// @notice Wraps `_amount` of this contract's native SUPRA into WrappedSupra and approves the
    /// registry to draw fees from it without limit.
    function _fundAutomationFees(uint256 _amount) internal {
        AUTOMATION_FEE_TOKEN.deposit{value: _amount}();
        if (!AUTOMATION_FEE_TOKEN.approve(address(AUTOMATION_REGISTRY), type(uint256).max)) {
            revert AutomationFundsTransferFailed();
        }
    }

    /// @notice Registers a user task owned by this contract; the arguments are `register`'s.
    function _registerAutomationTask(
        bytes memory _payloadTx,
        bytes memory _predicate,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority,
        bytes[] memory _auxData
    ) internal {
        AUTOMATION_REGISTRY.register(
            _payloadTx, _predicate, _expiryTime, _maxGasAmount, _gasPriceCap, _automationFeeCapForCycle, _priority, _auxData
        );
    }

    /// @notice Registers a system task owned by this contract, which must be an authorized
    /// submitter; the arguments are `registerSystemTask`'s.
    function _registerSystemAutomationTask(
        bytes memory _payloadTx,
        bytes memory _predicate,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint64 _priority,
        bytes[] memory _auxData
    ) internal {
        AUTOMATION_REGISTRY.registerSystemTask(_payloadTx, _predicate, _expiryTime, _maxGasAmount, _priority, _auxData);
    }

    /// @notice Cancels user tasks owned by this contract.
    function _cancelAutomationTasks(uint64[] memory _taskIndexes) internal {
        AUTOMATION_REGISTRY.cancelTasks(_taskIndexes);
    }

    /// @notice Stops user tasks owned by this contract; the refund is paid to this contract.
    function _stopAutomationTasks(uint64[] memory _taskIndexes) internal {
        AUTOMATION_REGISTRY.stopTasks(_taskIndexes);
    }

    /// @notice Cancels system tasks owned by this contract.
    function _cancelSystemAutomationTasks(uint64[] memory _taskIndexes) internal {
        AUTOMATION_REGISTRY.cancelSystemTasks(_taskIndexes);
    }

    /// @notice Stops system tasks owned by this contract.
    function _stopSystemAutomationTasks(uint64[] memory _taskIndexes) internal {
        AUTOMATION_REGISTRY.stopSystemTasks(_taskIndexes);
    }

    /// @notice Sends this contract's whole WrappedSupra and native SUPRA balances to `_to`.
    function _withdrawAutomationFunds(address payable _to) internal {
        uint256 wrapped = AUTOMATION_FEE_TOKEN.balanceOf(address(this));
        if (wrapped > 0 && !AUTOMATION_FEE_TOKEN.transfer(_to, wrapped)) { revert AutomationFundsTransferFailed(); }
        uint256 native = address(this).balance;
        if (native > 0) {
            (bool sent,) = _to.call{value: native}("");
            if (!sent) { revert AutomationFundsTransferFailed(); }
        }
    }
}
