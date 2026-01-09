// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OwnableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {CommonUtils} from "./CommonUtils.sol";

contract BlockMeta is OwnableUpgradeable, UUPSUpgradeable {
    using CommonUtils for address;

    uint256 private constant MAX_UINT256 = type(uint256).max;

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                        STORAGE
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */

    /// @notice Ordered list of functions to be executed
    /// @dev Layout: [target[160] | selector[32] | priority[64]]
    uint256[] private executions;
    
    /// @notice Mapping from function to its index in ordered execution list
    /// @dev Packed uint256[target, selector] => index + 1
    mapping(uint256 => uint256) private executionIndex;

    /// @dev Custom errors
    error CallerNotVmSigner();
    error SelectorAlreadyRegistered();
    error SelectorNotRegistered();

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                        EVENTS
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */

    /// @notice Emitted when a selector is registered.
    /// @param targetContract Address of the target contract.
    /// @param selector Function selector to be called on target contract.
    /// @param priority Priority of the registered function.
    event SelectorRegistered(address indexed targetContract, bytes4 indexed selector, uint64 indexed priority);

    /// @notice Emitted when a selector is deregistered.
    /// @param targetContract Address of the target contract.
    /// @param selector Deregistered function selector.
    /// @param priority Priority of the deregistered function.
    event SelectorDeregistered(address indexed targetContract, bytes4 indexed selector, uint64 indexed priority);

    /// @notice Emitted when call to a function fails.
    /// @param targetContract Address of the target contract.
    /// @param selector Called function selector.
    /// @param priority Priority of the called function.
    /// @param returndata Returned data.
    event CallFailed(
        address indexed targetContract,
        bytes4 indexed selector,
        uint64 indexed priority,
        bytes returndata
    );

    /// @notice Emitted when call to a function is successful.
    /// @param targetContract Address of the target contract.
    /// @param selector Called function selector.
    /// @param priority Priority of the called function.
    event CallSucceeded(
        address indexed targetContract, 
        bytes4 indexed selector, 
        uint64 indexed priority
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
     *                                                          REGISTRATION AND DEREGISTRATION
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */

    /// @notice Registers a function selector.
    /// @param _targetContract The target contract address.
    /// @param _selector Function selector to be called on target contract.
    /// @param _priority The priority of the function entry.
    function register(address _targetContract, bytes4 _selector, uint64 _priority) external onlyOwner {
        _targetContract.validateContractAddress();

        // Adds the function to the execution order, reverts if it already exists
        uint256 key = getKey(_targetContract, _selector);
        require(executionIndex[key] == 0, SelectorAlreadyRegistered());

        uint256 executionEntry = (uint256(uint160(_targetContract)) << 96) | (uint256(uint32(_selector)) << 64) | uint256(_priority);
        uint256 i = executions.length;

        // Inserts in ascending order
        executions.push();
        while (i > 0) {
            uint256 prevExecutionEntry = executions[i - 1];

            // Check priority
            if (uint64(prevExecutionEntry) <= _priority) break;

            executions[i] = prevExecutionEntry;
            uint256 prevKey = prevExecutionEntry & (MAX_UINT256 << 64);
            executionIndex[prevKey] = i + 1;

            i--;
        }

        executions[i] = executionEntry;
        executionIndex[key] = i + 1;

        emit SelectorRegistered(_targetContract, _selector, _priority);
    }
    
    /// @notice Deregisters a function selector.
    /// @param _targetContract The target contract address.
    /// @param _selector The function selector to deregister.
    function deregister(address _targetContract, bytes4 _selector) external onlyOwner {
        // Update the execution order
        uint256 key = getKey(_targetContract, _selector);
        uint256 index = executionIndex[key];
        require(index != 0, SelectorNotRegistered());
        index -= 1;
        uint64 priority = uint64(executions[index]);

        uint256 lastIndex = executions.length - 1;
        
        // Shift all entries to the left
        for (uint256 i = index; i < lastIndex; i++) {
            uint256 executionEntry = executions[i + 1];
            executions[i] = executionEntry;

            uint256 keyToUpdate = executionEntry & (MAX_UINT256 << 64);
            executionIndex[keyToUpdate] = i + 1;
        }

        // Remove last entry
        executions.pop();
        
        // Remove key of the function 
        delete executionIndex[key];

        emit SelectorDeregistered(_targetContract, _selector, priority);
    }

    /// @notice Calls all registered functions for the targets.
    function blockPrologue() external {
        if (!msg.sender.isVmSigner()) revert CallerNotVmSigner();   // Caller must be VM Signer

        uint256 len = executions.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 executionEntry = executions[i];

            address target = address(uint160(executionEntry >> 96));
            bytes4 selector = bytes4(uint32(executionEntry >> 64));
            uint64 priority = uint64(executionEntry);
            (bool ok, bytes memory data) = target.call(abi.encodePacked(selector));
            if (ok) {
                emit CallSucceeded(target, selector, priority); 
            } else {
                emit CallFailed(target, selector, priority, data);
            }
        }
    }

    /// @notice Helper function to return the key for a target contract address and its selector.
    /// @param _targetContract The target contract address.
    /// @param _selector The function selector on the target contract address. 
    /// @return key Packed uint256 representing the key.
    function getKey(address _targetContract, bytes4 _selector) private pure returns (uint256) {
        // Layout: [target[160] | selector[32] | 0[64] ]
        return (uint256(uint160(_targetContract)) << 96)  | (uint256(uint32(_selector)) << 64);
    }

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                    VIEW FUNCTIONS
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */

    /// @notice Returns the functions and their execution order. 
    /// @return targets The list of target contract addresses.
    /// @return selectors The function selectors.
    /// @return priority The list containing priority of each function.
    function getExecutions() external view returns (address[] memory targets, bytes4[] memory selectors, uint64[] memory priority) {
        uint256 len = executions.length;
        targets = new address[](len);
        selectors = new bytes4[](len);
        priority = new uint64[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 executionEntry = executions[i];

            address target = address(uint160(executionEntry >> 96)); 
            bytes4 selector = bytes4(uint32(executionEntry >> 64));

            targets[i] = target;
            selectors[i] = selector;
            priority[i] = uint64(executionEntry);
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
            uint256 executionEntry = executions[i];
            address target = address(uint160(executionEntry >> 96));
    
            if (target == _targetContract) {
                temp[count] = bytes4(uint32(executionEntry >> 64));
                count +=  1;
            }
        }
    
        bytes4[] memory selectors = new bytes4[](count);
        for (uint256 i = 0; i < count; i++) {
            selectors[i] = temp[i];
        }
    
        return selectors;
    }

    /// @notice Returns the priority of a registered function.
    /// @param _targetContract The target contract addresss.
    /// @param _selector The function selector on the target contract address.
    function getPriority(address _targetContract, bytes4 _selector) external view returns (uint64) {
        uint256 key = getKey(_targetContract, _selector);
        uint256 index = executionIndex[key];

        if (index == 0) revert SelectorNotRegistered();
        return uint64(executions[index - 1]);
    }
    
    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
