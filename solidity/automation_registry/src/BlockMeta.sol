// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Ownable2StepUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IAutomationController} from "./IAutomationController.sol";
import {CommonUtils} from "./CommonUtils.sol";

contract BlockMeta is Ownable2StepUpgradeable, UUPSUpgradeable {
    using CommonUtils for address;

    address public automationController;

    /// @dev Custom errors
    error AddressCannotBeEOA();
    error AddressCannotBeZero();
    error InvalidCaller();
    error MonitorCycleEndFailed();

    /// @notice Emitted when the address for automation controller smart contract is updated.
    /// @param oldController Address of the old automation controller.
    /// @param newController Address of the new automation controller.
    event AutomationControllerUpdated(address indexed oldController, address indexed newController);

    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the owner of the contract.
    function initialize() public initializer {
        __Ownable2Step_init();
        __Ownable_init(msg.sender);
    }

    /// @notice Sets the address for the automation controller smart contract.
    /// @param _controller Address of the automation controller smart contract.
    function setAutomationController(address _controller) external onlyOwner {
        if (!_controller.isContract()) revert AddressCannotBeEOA();
        if (_controller == address(0)) revert AddressCannotBeZero();

        address oldController = automationController;
        automationController = _controller;

        emit AutomationControllerUpdated(oldController, automationController);
    }

    /// @notice Calls the monitorCycleEnd function in AutomationController.
    function blockPrologue() external {
        require(msg.sender == address(0x5355500000000000000000000000000000000000), InvalidCaller());    // Caller must be SUP0

        (bool sent, ) = automationController.call(abi.encodeCall(IAutomationController.monitorCycleEnd, ()));
        require(sent, MonitorCycleEndFailed());
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
