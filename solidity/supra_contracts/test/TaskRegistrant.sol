// SPDX-License-Identifier: MIT
// The pragma is a range, not the repository's fixed version, because the smr-moonshot EVM
// automation e2e test compiles an identical copy of this file with whichever solc it has.
pragma solidity ^0.8.0;

/// @dev The WrappedSupra functions a registrant uses to pay automation fees.
interface ITaskRegistrantWrappedSupra {
    function deposit() external payable;
    function approve(address spender, uint256 value) external returns (bool);
}

/// @dev The AutomationRegistry functions a registrant calls.
interface ITaskRegistrantRegistry {
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
    function cancelTasks(uint64[] memory _taskIndexes) external;
    function stopTasks(uint64[] memory _taskIndexes) external;
}

/// @notice A contract that registers, cancels and stops user automation tasks in its own name,
/// so that it is the owner of each task it registers (#4469).
/// @dev Anyone may call it. It is a test fixture, not a pattern for production registrants.
contract TaskRegistrant {
    /// @dev ERC-165 identifier of `IERC165`.
    bytes4 private constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    /// @dev ERC-165 identifier of the AutomationRegistry's `IAutomationTaskOwner`.
    bytes4 public constant AUTOMATION_TASK_OWNER_INTERFACE_ID = bytes4(keccak256("IAutomationTaskOwner"));

    ITaskRegistrantRegistry public immutable registry;
    ITaskRegistrantWrappedSupra public immutable wsupra;
    /// @dev Whether this registrant declares `IAutomationTaskOwner`, without which the registry
    /// refuses it as a task owner.
    bool public immutable declaresTaskOwnerInterface;

    constructor(address _registry, address _wsupra, bool _declaresTaskOwnerInterface) {
        registry = ITaskRegistrantRegistry(_registry);
        wsupra = ITaskRegistrantWrappedSupra(_wsupra);
        declaresTaskOwnerInterface = _declaresTaskOwnerInterface;
    }

    /// @notice ERC-165.
    function supportsInterface(bytes4 _interfaceId) external view returns (bool) {
        return _interfaceId == ERC165_INTERFACE_ID
            || (declaresTaskOwnerInterface && _interfaceId == AUTOMATION_TASK_OWNER_INTERFACE_ID);
    }

    /// @notice Wraps the attached value into WSUPRA held by this contract and lets the registry
    /// draw fees from it without limit.
    function fund() external payable {
        wsupra.deposit{value: msg.value}();
        require(wsupra.approve(address(registry), type(uint256).max), "approve failed");
    }

    /// @notice Registers a user task whose owner is this contract.
    function registerUst(
        bytes memory _payloadTx,
        bytes memory _predicate,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle,
        uint64 _priority
    ) external {
        bytes[] memory auxData;
        registry.register(
            _payloadTx, _predicate, _expiryTime, _maxGasAmount, _gasPriceCap, _automationFeeCapForCycle, _priority, auxData
        );
    }

    /// @notice Cancels tasks owned by this contract.
    function cancel(uint64[] memory _taskIndexes) external {
        registry.cancelTasks(_taskIndexes);
    }

    /// @notice Stops tasks owned by this contract.
    function stop(uint64[] memory _taskIndexes) external {
        registry.stopTasks(_taskIndexes);
    }

    /// @notice Accepts native value, e.g. for a task action's `value` or its gas.
    receive() external payable {}
}

/// @notice A contract that registers one user task from its constructor, while it has no code
/// yet, and has no function to cancel or stop it.
contract ConstructorTaskRegistrant {
    constructor(
        address _registry,
        address _wsupra,
        bytes memory _payloadTx,
        bytes memory _predicate,
        uint64 _expiryTime,
        uint128 _maxGasAmount,
        uint128 _gasPriceCap,
        uint128 _automationFeeCapForCycle
    ) payable {
        ITaskRegistrantWrappedSupra(_wsupra).deposit{value: msg.value}();
        require(ITaskRegistrantWrappedSupra(_wsupra).approve(_registry, type(uint256).max), "approve failed");
        bytes[] memory auxData;
        ITaskRegistrantRegistry(_registry).register(
            _payloadTx, _predicate, _expiryTime, _maxGasAmount, _gasPriceCap, _automationFeeCapForCycle, 2, auxData
        );
    }
}
