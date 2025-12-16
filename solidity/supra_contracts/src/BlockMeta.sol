// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Ownable2StepUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {CommonUtils} from "./CommonUtils.sol";

contract BlockMeta is Ownable2StepUpgradeable, UUPSUpgradeable {
    using CommonUtils for address;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/
    struct Entry {
        bytes4[] selectors;
        bool exists;
    }

    // Registered entries
    mapping(address => Entry) private registry;
    // Unique list of registered targets
    address[] private targets;


    /// @dev Custom errors
    error AddressCannotBeEOA();
    error AddressCannotBeZero();
    error InvalidCaller();


    /// @notice Emitted when a new target address is added.
    /// @param target Address of a new target
    /// @param selector Selector of the function to be called for target
    event NewTargetAdded(address indexed target, bytes4 indexed selector);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event CallFailed(
        address indexed target,
        bytes4 indexed selector,
        bytes returndata
    );

    event CallSucceeded(
        address indexed target,
        bytes4 indexed selector
    );


    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the owner of the contract.
    function initialize() public initializer {
        __Ownable2Step_init();
        __Ownable_init(msg.sender);
    }


    /*//////////////////////////////////////////////////////////////
                              REGISTRATION
    //////////////////////////////////////////////////////////////*/
    /// @notice Registers a new entry with input target and selector
    /// @param target Address of a new target
    /// @param selector Selector of the function to be called for target
    function register(address target, bytes4 selector) external onlyOwner {
        if (target == address(0)) revert AddressCannotBeZero();
        if (!target.isContract()) revert AddressCannotBeEOA();

        Entry storage e = registry[target];

        // prevent duplicate target
        if (!e.exists) {
            e.exists = true;
            targets.push(target);
        }

        // prevent duplicate selector per target
        for (uint256 i; i < e.selectors.length; i++) {
            require(e.selectors[i] != selector, "Selector already registered");
        }

        e.selectors.push(selector);
        emit NewTargetAdded(target, selector);
    }


    /// @notice Calls all registered functions for the targets.
    function blockPrologue() external {
        require(msg.sender == address(0x5355500000000000000000000000000000000000), InvalidCaller());    // Caller must be SUP0
        for (uint256 i; i < targets.length; i++) {
            address target = targets[i];
            bytes4[] storage sels = registry[target].selectors;

            for (uint256 j; j < sels.length; j++) {
                bytes4 selector = sels[j];

                (bool ok, bytes memory ret) =
                    target.call(abi.encodePacked(selector));

                if (!ok) {
                    emit CallFailed(target, selector, ret);
                } else {
                    emit CallSucceeded(target, selector);
                }
	    }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/
    function getTargets() external view returns (address[] memory) {
        return targets;
    }

    function getSelectors(address target)
        external
        view
        returns (bytes4[] memory)
    {
        return registry[target].selectors;
    }


    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
