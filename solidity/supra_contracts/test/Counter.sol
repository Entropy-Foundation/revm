// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract Counter is OwnableUpgradeable, UUPSUpgradeable {
    uint256 public counter;
    address public privilegedAddress;

    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the owner and privileged address of the contract.
    /// @param _privileged Privileged address.
    function initialize(address _privileged) public initializer {
        privilegedAddress = _privileged;
        __Ownable_init(msg.sender);
    }

    /// @notice Increments the counter by 1.
    function increment() external {
        if (msg.sender == privilegedAddress) {
            counter = counter + 1;
	    }
    }

    /// @notice Returns true if the counter is not divisible by 3, false otherwise.
    /// Used during testing register automation task with condition "counter is not divisible by 3".
    function isNotDivisibleBy3() external view returns (bool) {
        return counter % 3 != 0;
    }

    /// @notice Updates the counter to a new value.
    /// @param newValue New value for the counter.
    /// Used during testing to register trigger automation task execution by making isNotDivisibleBy3 condition to be true.
    function update(uint256 newValue) external {
        if (msg.sender == privilegedAddress) {
            counter = newValue;
        }
    }
    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
