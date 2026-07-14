// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {LibUtils} from "./libraries/LibUtils.sol";
import {IBlockMeta} from "./interfaces/IBlockMeta.sol";

/**
 * BlockMeta is a system-level execution scheduler — it maintains an ordered queue of (target contract, selector) pairs
 * that the Supra VM fires once per block at block-start time via blockPrologue().
 * Think of it as a deterministic cron-within-a-block for system-level hooks (oracle updates, reward distributions, etc.)
 * that must run on every block without user transactions.
 */

contract BlockMeta is OwnableUpgradeable, UUPSUpgradeable, IBlockMeta {
    using LibUtils for address;

    /// @dev Mask to extract the (target | selector) key, zeroing out the gas limit bits.
    uint256 private constant KEY_MASK = type(uint256).max << 64;

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                        STORAGE
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */


    /// @notice Ordered list of functions to be executed
    /// @dev Layout: [target[160] | selector[32] | gasLimit[64]]
    uint256[] private executions;

    /// @notice Total gas cap for the entire blockPrologue execution.
    /// @dev Checked at registration time; sum of all per-entry gas limits must not exceed this.
    uint64 public blockPrologueGasCap;

    /// @notice Sum of all per-entry gas limits.
    uint64 public totalGasAllocated;

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                              CONSTRUCTOR AND INITIALIZER
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */
    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the owner and sets the block prologue gas cap.
    /// @param _initialOwner Address of the contract owner.
    /// @param _gasCap Total gas cap for blockPrologue execution (sum of per-entry gas limits must not exceed this).
    function initialize(address _initialOwner, uint64 _gasCap) public initializer {
        __Ownable_init(_initialOwner);
        require(_gasCap > 0, InvalidGasCap());
        blockPrologueGasCap = _gasCap;
    }

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                  ADMIN FUNCTIONS
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */

    /// @notice Registers a function selector.
    /// @param _targetContract The target contract address.
    /// @param _selector Function selector to be called on target contract.
    /// @param _gasLimit Gas limit for this function.
    function register(address _targetContract, bytes4 _selector, uint64 _gasLimit) external onlyOwner {
        _targetContract.validateContractAddress();

        require(_selector != bytes4(0), InvalidSelector());
        require(_gasLimit > 0, InvalidGasLimit());
        require(totalGasAllocated + _gasLimit <= blockPrologueGasCap, GasCapExceeded());

        uint256 executionEntry = packExecution(_targetContract, _selector);

        // Check to prevent duplicate entries, reverts if already registered
        checkDuplicate(executionEntry);

        // Add to the execution order with gas limit packed in
        executions.push(executionEntry | _gasLimit);
        totalGasAllocated += _gasLimit;

        emit SelectorRegistered(_targetContract, _selector, _gasLimit);
    }
    
    /// @notice Deregisters a function selector.
    /// @param _targetContract The target contract address.
    /// @param _selector The function selector to deregister.
    function deregister(address _targetContract, bytes4 _selector) external onlyOwner {
        uint256 executionEntry = packExecution(_targetContract, _selector);
        
        uint256 index = findIndex(executionEntry);
        removeAt(index);
    }

    /// @notice Deregisters a function selector.
    /// @param _index Index in the `executions` array.
    function deregisterAt(uint256 _index) external onlyOwner {
        require(_index < executions.length, InvalidIndex());
        removeAt(_index);
    }

    /// @notice Updates the entire execution order.
    /// @dev _executions entries must be packed as [target(160) | selector(32) | gasLimit(64)]
    /// @param _executions An array of packed execution entries representing the new execution order.
    function updateExecutionOrder(uint256[] calldata _executions) external onlyOwner {
        uint256 inputCount = _executions.length;
        require(inputCount > 0, InvalidExecutionsLength());

        // Clear existing array
        delete executions;

        uint64 newTotalGas = 0;

        for (uint256 i = 0; i < inputCount; i++) {
            uint256 inputExecution = _executions[i];
            (address target, bytes4 selector) = unpackExecution(inputExecution);
            uint64 gasLimit = uint64(inputExecution);

            // Input validation
            target.validateContractAddress();
            require(selector != bytes4(0), InvalidSelector());
            require(gasLimit > 0, InvalidGasLimit());

            // Check to prevent duplicate entries, reverts if already registered
            checkDuplicate(inputExecution & KEY_MASK);

            executions.push(inputExecution);
            newTotalGas += gasLimit;
        }

        require(newTotalGas <= blockPrologueGasCap, GasCapExceeded());
        totalGasAllocated = newTotalGas;

        emit ExecutionOrderUpdated(_executions);
    }

    /// @notice Sets the total gas cap for the block prologue.
    /// @param _cap The new total gas cap (must be >= current total allocated gas).
    function setBlockPrologueGasCap(uint64 _cap) external onlyOwner {
        require(_cap > 0 && _cap >= totalGasAllocated, InvalidGasCap());
        blockPrologueGasCap = _cap;
        emit BlockPrologueGasCapUpdated(_cap);
    }

    /// @notice Calls all registered functions for the targets.
    function blockPrologue() external {
        msg.sender.enforceIsVmSigner();     // Caller must be VM Signer

        uint256 len = executions.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 entry = executions[i];
            (address target, bytes4 selector) = unpackExecution(entry);
            (bool ok, bytes memory data) = target.call{gas: uint64(entry)}(abi.encodePacked(selector));
            if (ok) {
                emit CallSucceeded(target, selector); 
            } else {
                emit CallFailed(target, selector, data);
            }
        }
    }

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                    HELPER FUNCTIONS
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */
    
    /// @notice Packs a target contract address and function selector into a single uint256 execution entry.
    /// @param _targetContract The target contract address.
    /// @param _selector The function selector on the target contract.
    /// @return executionEntry The uint256 representing the packed execution entry.
    function packExecution(address _targetContract, bytes4 _selector) private pure returns (uint256) {
        // Layout: [target[160] | selector[32] | 0[64] ]
        return (uint256(uint160(_targetContract)) << 96)  | (uint256(uint32(_selector)) << 64);
    }

    /// @notice Unpacks an execution entry into its target contract and function selector.
    /// @param _executionEntry The packed execution entry to unpack.
    /// @return target The target contract address.
    /// @return selector The function selector on the target contract.
    function unpackExecution(uint256 _executionEntry) private pure returns (address target, bytes4 selector) {
        target = address(uint160(_executionEntry >> 96));
        selector = bytes4(uint32(_executionEntry >> 64));
    }

    /// @notice Checks whether a given (target, selector) pair is already registered.
    /// @dev Compares only the target+selector bits, ignoring the gas limit.
    /// @param _executionEntry The packed execution entry to check (gas bits are masked out).
    function checkDuplicate(uint256 _executionEntry) private view {
        uint256 len = executions.length;
        for (uint256 i = 0; i < len; i++) {
            if ((executions[i] & KEY_MASK) == _executionEntry) {
                revert SelectorAlreadyRegistered();
            }
        }
    }

    /// @notice Finds the index of a given (target, selector) pair in the `executions` array.
    /// @dev Compares only the target+selector bits, ignoring the gas limit.
    /// @param _executionEntry The packed execution entry to search for (gas bits are masked out).
    /// @return index The index of the execution entry in the `executions` array.
    function findIndex(uint256 _executionEntry) private view returns (uint256) {
        uint256 len = executions.length;
        for (uint256 i = 0; i < len; i++) {
            if ((executions[i] & KEY_MASK) == _executionEntry) { 
                return i;
            }
        }
        revert SelectorNotRegistered();
    }

    /// @notice Helper function to remove an entry from the `executions` array.
    /// @param _index Index of the execution entry to be removed.
    function removeAt(uint256 _index) private {
        uint256 len = executions.length;
        uint256 removedEntry = executions[_index];
        uint64 gasLimit = uint64(removedEntry);
        totalGasAllocated -= gasLimit;

        for (uint256 i = _index; i < len - 1; i++) {
            executions[i] = executions[i + 1];
        }

        executions.pop();

        (address target, bytes4 selector) = unpackExecution(removedEntry);

        emit SelectorDeregistered(target, selector, gasLimit);
    }


    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                    VIEW FUNCTIONS
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */

    /// @notice Returns all registered functions in their current execution order.
    /// @return targets An array of target contract addresses corresponding to each registered function.
    /// @return selectors An array of function selectors corresponding to each registered function.
    function getExecutions() external view returns (address[] memory targets, bytes4[] memory selectors) {
        uint256 len = executions.length;
        targets = new address[](len);
        selectors = new bytes4[](len);

        for (uint256 i = 0; i < len; i++) {
            (address target, bytes4 selector) = unpackExecution(executions[i]);

            targets[i] = target;
            selectors[i] = selector;
        }
    }

    /// @notice Returns the gas limit for a given (target, selector) pair.
    /// @param _targetContract The target contract address.
    /// @param _selector The function selector.
    /// @return gasLimit Gas limit allocated for the function.
    function getExecutionGasLimit(address _targetContract, bytes4 _selector) external view returns (uint64 gasLimit) {
        uint256 executionEntry = packExecution(_targetContract, _selector);
        uint256 index = findIndex(executionEntry);
        gasLimit = uint64(executions[index]);
    }

    /// @notice Returns all the registered target contracts.
    /// @return targetContracts Array of addresses representing all registered target contracts.
    function getTargetContracts() external view returns (address[] memory) {
        uint256 len = executions.length;
        address[] memory temp = new address[](len);
        uint256 count;

        for (uint256 i = 0; i < len; i++) {
            address targetContract = address(uint160(executions[i] >> 96));

            bool exists;
            for (uint256 j = 0; j < count; j++) {
                if (temp[j] == targetContract) {
                    exists = true;
                    break;
                }
            }

            if (!exists) {
                temp[count] = targetContract;
                count += 1;
            }
        }

        address[] memory targetContracts = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            targetContracts[i] = temp[i];
        }

        return targetContracts;
    }

    /// @notice Returns all the selectors of a target contract.
    /// @param _targetContract The target contract addresss.
    /// @return selectors Array of function selectors registered for the target contract.
    function getSelectors(address _targetContract) external view returns (bytes4[] memory) {
        uint256 len = executions.length;
        bytes4[] memory temp = new bytes4[](len);
        uint256 count;
    
        for (uint256 i = 0; i < len; i++) {
            (address target, bytes4 selector) = unpackExecution(executions[i]);

            if (target == _targetContract) {
                temp[count] = selector;
                count +=  1;
            }
        }
    
        bytes4[] memory selectors = new bytes4[](count);
        for (uint256 i = 0; i < count; i++) {
            selectors[i] = temp[i];
        }
    
        return selectors;
    }
    
    /// @notice Returns the target contract and selector at a given execution index.
    /// @param _index The position in the execution order array.
    /// @return target The target contract address.
    /// @return selector The function selector to be called on the target.
    function getExecutionAt(uint256 _index) external view returns (address target, bytes4 selector) {
        require(_index < executions.length, InvalidIndex());

        (target, selector) = unpackExecution(executions[_index]);
    }

    /// @notice Returns the execution index for a given target contract and selector.
    /// @param _targetContract The target contract address.
    /// @param _selector The function selector registered for the target.
    /// @return index The index in the execution order array.
    function getExecutionIndex(address _targetContract, bytes4 _selector) external view returns (uint256 index) {
        uint256 executionEntry = packExecution(_targetContract, _selector);

        return findIndex(executionEntry);
    }
    
    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
