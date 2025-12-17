// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {OwnableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";

contract BlockBasedCounter is OwnableUpgradeable, UUPSUpgradeable {
    uint256 public counter;
    address public privilegedAddress;

    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the owner and privileged address of the contract.
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

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
