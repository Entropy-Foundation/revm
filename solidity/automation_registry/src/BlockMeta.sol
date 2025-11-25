// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IAutomationController} from "./IAutomationController.sol";

contract BlockMeta is Ownable2StepUpgradeable, UUPSUpgradeable {
    address public automationController;
    address public vm;
    
    error CallerNotVM();

    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    function initialize(address _automationController, address _vm) public initializer {
        automationController = _automationController;
        vm = _vm;

        __Ownable2Step_init();
    }

    function monitorCycleEnd() public {
        if (msg.sender != vm) { revert CallerNotVM(); }
        
        // IAutomationController(automationController).monitorCycleEnd();
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
