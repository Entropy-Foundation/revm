// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibUtils} from "../src/libraries/LibUtils.sol";
import {IERC20Supra} from "../src/interfaces/IERC20Supra.sol";
import {IERC20SupraHandler} from "../src/interfaces/IERC20SupraHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract ERC20SupraHandler is OwnableUpgradeable, UUPSUpgradeable, IERC20SupraHandler {
    using LibUtils for address;

    /// @notice Address of the ERC20Supra contract.
    address public erc20Supra;

    /**
    * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    *                                                              CONSTRUCTOR AND INITIALIZER
    * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    */
    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the owner of the contract and address of the ERC20Supra.
    function initialize(address _initialOwner, address _erc20Supra) public initializer {
        __Ownable_init(_initialOwner);

        _erc20Supra.validateContractAddress();
        erc20Supra = _erc20Supra;
    }

    /// @notice Deposit native token → Mint ERC20Supra 1:1
    function deposit() public payable {
        if (msg.value == 0) revert InvalidAmount();
        IERC20Supra(erc20Supra).mint(msg.sender, msg.value);

        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Withdraw native token → Burn ERC20Supra 1:1
    /// @param _amount Amount of native tokens to withdraw.
    function withdraw(uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();
        if (IERC20(erc20Supra).balanceOf(msg.sender) < _amount) revert InsufficientBalance();
        if (address(this).balance < _amount) revert InsufficientContractBalance();
        
        IERC20Supra(erc20Supra).burnFrom(msg.sender, _amount);
        emit Withdrawal(msg.sender, _amount);

        (bool sent, ) = payable(msg.sender).call{value: _amount}("");
        if (!sent) revert TransferFailed();
    }    

    /// @notice Allows a user to send native tokens directly and get ERC20Supra.
    receive() external payable {
        deposit();
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
