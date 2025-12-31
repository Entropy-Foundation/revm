// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EnumerableSet} from "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {OwnableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {CommonUtils} from "./CommonUtils.sol";

contract BlockMeta is OwnableUpgradeable, UUPSUpgradeable {
    using CommonUtils for address;
    using EnumerableSet for *;

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                        STORAGE
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */

    /// @notice List of registered target contracts
    EnumerableSet.AddressSet private registeredTargets;
    /// @notice Registry mapping target contract to selectors. 
    mapping(address targetContract => EnumerableSet.Bytes4Set selectors) private registry;

    /// @dev Custom errors
    error AddressCannotBeEOA();
    error AddressCannotBeZero();
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
    event SelectorRegistered(address indexed targetContract, bytes4 indexed selector);

    /// @notice Emitted when a selector is deregistered.
    /// @param targetContract Address of the target contract.
    /// @param selector Deregistered function selector.
    event SelectorDeregistered(address indexed targetContract, bytes4 indexed selector);

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
    event CallSucceeded(address indexed targetContract, bytes4 indexed selector);

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
    function register(address _targetContract, bytes4 _selector) external onlyOwner {
        if (_targetContract == address(0)) revert AddressCannotBeZero();
        if (!_targetContract.isContract()) revert AddressCannotBeEOA();

        // Adds a target contract if it does not exist
        registeredTargets.add(_targetContract);
        
        // Adds a selector, reverts if it already exists
        require(registry[_targetContract].add(_selector), SelectorAlreadyRegistered());

        emit SelectorRegistered(_targetContract, _selector);
    }
    
    /// @notice Deregisters a function selector.
    /// @param _targetContract The target contract address.
    /// @param _selector The function selector to deregister.
    function deregister(address _targetContract, bytes4 _selector) external onlyOwner {
        // Removes a selector, reverts if it doesn't exist
        require(registry[_targetContract].remove(_selector), SelectorNotRegistered());

        // If no selectors left, remove target contract
        if (registry[_targetContract].length() == 0) {
            registeredTargets.remove(_targetContract);
            delete registry[_targetContract];
        }

        emit SelectorDeregistered(_targetContract, _selector);
    }

    /// @notice Calls all registered functions for the targets.
    function blockPrologue() external {
        if (!msg.sender.isVmSigner()) revert CallerNotVmSigner();   // Caller must be VM Signer
    
        uint256 tLen = registeredTargets.length();
        for (uint256 i; i < tLen; i++) {
            address target = registeredTargets.at(i);
            uint256 sLen = registry[target].length();

            for (uint256 j; j < sLen; j++) {
                bytes4 selector = registry[target].at(j);
    
                (bool ok, bytes memory data) = target.call(abi.encodePacked(selector));
                if (!ok) {
                    emit CallFailed(target, selector, data);
                } else {
                    emit CallSucceeded(target, selector);
                }
            }
        }
    }
    

    /**
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     *                                                                    VIEW FUNCTIONS
     * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
     */

    /// @notice Returns all the registered target contracts.
    /// @return An array of addresses representing all registered target contracts.
    function getTargetContracts() external view returns (address[] memory) {
        return registeredTargets.values();
    }

    /// @notice Returns all the selectors of a target contract.
    /// @param _targetContract The target contract addresss.
    /// @return An array of `bytes4` function selectors registered for the target contract.
    function getSelectors(address _targetContract) external view returns (bytes4[] memory) {
        return registry[_targetContract].values();
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
