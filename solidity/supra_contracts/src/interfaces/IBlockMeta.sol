// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IBlockMeta {
    /// @notice Thrown when the caller is not the VM signer.
    error CallerNotVmSigner();
    /// @notice Thrown when an out-of-bounds index is supplied.
    error InvalidIndex();
    /// @notice Thrown when a zero or otherwise invalid selector is supplied.
    error InvalidSelector();
    /// @notice Thrown when a (target, selector) pair is already registered.
    error SelectorAlreadyRegistered();
    /// @notice Thrown when a (target, selector) pair is not found in the execution list.
    error SelectorNotRegistered();
    /// @notice Thrown when a zero gas limit is supplied.
    error InvalidGasLimit();
    /// @notice Thrown when the gas cap is zero or less than the current total allocated gas.
    error InvalidGasCap();
    /// @notice Thrown when the total allocated gas exceeds the block prologue gas cap taking into account 63/64 forwarding rule.
    error GasCapExceeded();
    /// @notice Thrown when an empty execution array is provided to 'updateExecutionOrder'.
    error InvalidExecutionsLength();

    /// @notice Emitted when a function selector is registered for per-block execution.
    /// @param targetContract Address of the target contract.
    /// @param selector Function selector to be called on the target contract.
    /// @param gasLimit Gas limit allocated for this function.
    event SelectorRegistered(address indexed targetContract, bytes4 indexed selector, uint64 indexed gasLimit);

    /// @notice Emitted when a function selector is removed from per-block execution.
    /// @param targetContract Address of the target contract.
    /// @param selector Deregistered function selector.
    /// @param gasLimit Gas limit that was allocated for this function.
    event SelectorDeregistered(address indexed targetContract, bytes4 indexed selector, uint64 gasLimit);

    /// @notice Emitted when the full execution order is replaced.
    /// @param executionOrder Updated array of packed execution entries.
    event ExecutionOrderUpdated(uint256[] indexed executionOrder);

    /// @notice Emitted when a per-block call to a registered function fails.
    /// @param targetContract Address of the target contract.
    /// @param selector Called function selector.
    /// @param returndata Data returned by the failed call.
    event CallFailed(address indexed targetContract, bytes4 indexed selector, bytes returndata);

    /// @notice Emitted when a per-block call to a registered function succeeds.
    /// @param targetContract Address of the target contract.
    /// @param selector Called function selector.
    event CallSucceeded(address indexed targetContract, bytes4 indexed selector);

    /// @notice Emitted when the block prologue gas cap is updated.
    /// @param cap The new gas cap for the entire block prologue.
    event BlockPrologueGasCapUpdated(uint64 indexed cap);

    /// @notice Registers a (target, selector) pair for per-block execution.
    /// @param _targetContract The target contract address.
    /// @param _selector Function selector to call on the target contract.
    /// @param _gasLimit Gas limit for this function.
    function register(address _targetContract, bytes4 _selector, uint64 _gasLimit) external;

    /// @notice Deregisters a (target, selector) pair by value.
    /// @param _targetContract The target contract address.
    /// @param _selector The function selector to deregister.
    function deregister(address _targetContract, bytes4 _selector) external;

    /// @notice Deregisters the entry at a given index in the execution order.
    /// @param _index Index in the executions array.
    function deregisterAt(uint256 _index) external;

    /// @notice Replaces the entire execution order with a new list of packed entries.
    /// @dev Each entry must be packed as [target(160) | selector(32) | gasLimit(64)].
    /// @param _executions Array of packed execution entries (target|selector|gasLimit) representing the new order.
    function updateExecutionOrder(uint256[] calldata _executions) external;

    /// @notice Sets the total gas cap for the block prologue.
    /// @param _cap The new total gas cap.
    function setBlockPrologueGasCap(uint64 _cap) external;

    /// @notice Returns all registered (target, selector) pairs in execution order.
    /// @return targets Array of target contract addresses.
    /// @return selectors Array of function selectors corresponding to each target.
    function getExecutions() external view returns (address[] memory targets, bytes4[] memory selectors);

    /// @notice Returns the unique set of registered target contract addresses.
    /// @return targetContracts Deduplicated array of registered target addresses.
    function getTargetContracts() external view returns (address[] memory targetContracts);

    /// @notice Returns all selectors registered for a given target contract.
    /// @param _targetContract The target contract address.
    /// @return selectors Array of function selectors registered for the target.
    function getSelectors(address _targetContract) external view returns (bytes4[] memory selectors);

    /// @notice Returns the (target, selector) pair at a given execution index.
    /// @param _index Position in the execution order array.
    /// @return target The target contract address.
    /// @return selector The function selector to be called on the target.
    function getExecutionAt(uint256 _index) external view returns (address target, bytes4 selector);

    /// @notice Returns the execution index for a given (target, selector) pair.
    /// @param _targetContract The target contract address.
    /// @param _selector The function selector registered for the target.
    /// @return index The index in the execution order array.
    function getExecutionIndex(address _targetContract, bytes4 _selector) external view returns (uint256 index);

    /// @notice Returns the gas limit for a given (target, selector) pair.
    /// @param _targetContract The target contract address.
    /// @param _selector The function selector.
    /// @return gasLimit Gas limit allocated for calls to this function.
    function getExecutionGasLimit(address _targetContract, bytes4 _selector) external view returns (uint64 gasLimit);

    /// @notice Returns the total gas cap for the block prologue.
    /// @return cap The total gas cap.
    function blockPrologueGasCap() external view returns (uint64 cap);

    /// @notice Returns the sum of all per-entry gas limits currently registered.
    /// @return totalGas Total allocated gas.
    function totalGasAllocated() external view returns (uint64 totalGas);
}