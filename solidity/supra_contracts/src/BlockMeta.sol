// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OwnableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {CommonUtils} from "./CommonUtils.sol";

contract BlockMeta is OwnableUpgradeable, UUPSUpgradeable {
    using CommonUtils for address;

    /// @dev Custom errors
    error CallerNotVmSigner();
    error InvalidIndex();
    error InvalidSelector();
    error SelectorAlreadyRegistered();
    error SelectorNotRegistered();

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                        STORAGE
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */

    /// @notice Ordered list of functions to be executed
    /// @dev Layout: [target[160] | selector[32] | 0[64]]
    uint256[] private executions;

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                        EVENTS
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */

    /// @notice Emitted when a selector is registered.
    /// @param targetContract Address of the target contract.
    /// @param selector Function selector to be called on target contract.
    event SelectorRegistered(address indexed targetContract, bytes4 indexed selector);

    /// @notice Emitted when a selector is deregistered.
    /// @param targetContract Address of the target contract.
    /// @param selector Deregistered function selector.
    event SelectorDeregistered(address indexed targetContract, bytes4 indexed selector);

    /// @notice Emitted when the execution order is updated.
    /// @param executionOrder Updated execution order.
    event ExecutionOrderUpdated(uint256[] indexed executionOrder);

    /// @notice Emitted when call to a function fails.
    /// @param targetContract Address of the target contract.
    /// @param selector Called function selector.
    /// @param returndata Returned data.
    event CallFailed(
        address indexed targetContract,
        bytes4 indexed selector,
        bytes returndata
    );

    /// @notice Emitted when call to a function is successful.
    /// @param targetContract Address of the target contract.
    /// @param selector Called function selector.
    event CallSucceeded(
        address indexed targetContract, 
        bytes4 indexed selector 
    );

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                              CONSTRUCTOR AND INITIALIZER
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */
    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the owner of the contract.
    function initialize() public initializer {
        __Ownable_init(msg.sender);
    }

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                  ADMIN FUNCTIONS
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */

    /// @notice Registers a function selector.
    /// @param _targetContract The target contract address.
    /// @param _selector Function selector to be called on target contract.
    function register(address _targetContract, bytes4 _selector) external onlyOwner {
        _targetContract.validateContractAddress();
        require(_selector != bytes4(0), InvalidSelector());

        uint256 executionEntry = packExecution(_targetContract, _selector);

        // Check to prevent duplicate entries, reverts if already registered
        checkDuplicate(executionEntry);

        // Add to the execution order
        executions.push(executionEntry);

        emit SelectorRegistered(_targetContract, _selector);
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
    /// @dev _executions entries must be packed as [target(160) | selector(32) | 0(64)]
    /// @param _executions An array of packed execution entries representing the new execution order.
    function updateExecutionOrder(uint256[] calldata _executions) external onlyOwner {
        uint256 inputCount = _executions.length;

        // Clear existing array
        delete executions;

        for (uint256 i = 0; i < inputCount; i++) {
            uint256 inputExecution = _executions[i];
            (address target, bytes4 selector) = unpackExecution(inputExecution);

            // Input validation
            target.validateContractAddress();
            require(selector != bytes4(0), InvalidSelector());

            // Check to prevent duplicate entries, reverts if already registered
            checkDuplicate(inputExecution);

            executions.push(inputExecution);
        }

        emit ExecutionOrderUpdated(_executions);
    }

    /// @notice Calls all registered functions for the targets.
    function blockPrologue() external {
        if (!msg.sender.isVmSigner()) revert CallerNotVmSigner();   // Caller must be VM Signer

        uint256 len = executions.length;
        for (uint256 i = 0; i < len; i++) {
            (address target, bytes4 selector) = unpackExecution(executions[i]);

            (bool ok, bytes memory data) = target.call(abi.encodePacked(selector));
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

    /// @notice Checks whether a given execution entry is already registered.
    /// @param _executionEntry The packed execution entry to check.
    function checkDuplicate(uint256 _executionEntry) private view {
        uint256 len = executions.length;
        for (uint256 i = 0; i < len; i++) {
            if (executions[i] == _executionEntry) {
                revert SelectorAlreadyRegistered();
            }
        }
    }

    /// @notice Finds the index of a given execution entry in the `executions` array.
    /// @param _executionEntry The packed execution entry to search for.
    /// @return index The index of the execution entry in the `executions` array.
    function findIndex(uint256 _executionEntry) private view returns (uint256) {
        uint256 len = executions.length;
        for (uint256 i = 0; i < len; i++) {
            if (executions[i] == _executionEntry) { 
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

        for (uint256 i = _index; i < len - 1; i++) {
            executions[i] = executions[i + 1];
        }

        executions.pop();

        (address target, bytes4 selector) = unpackExecution(removedEntry);

        emit SelectorDeregistered(target, selector);
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
