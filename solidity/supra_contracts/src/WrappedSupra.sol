// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IWrappedSupra} from "../src/interfaces/IWrappedSupra.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";

/// @notice Wrapped Supra implementation.
contract WrappedSupra is ERC20Upgradeable, ERC20PermitUpgradeable, IWrappedSupra, OwnableUpgradeable, UUPSUpgradeable {
    using Address for address payable;
    using LibUtils for address;


    /**
    * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    *                                                              CONSTRUCTOR AND INITIALIZER
    * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    */
    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the WrappedSupra token contract.
    /// @param _initialOwner Address that will be assigned ownership of the contract.
    function initialize(address _initialOwner) public initializer {
        _initialOwner.validateAddress();

        __ERC20_init("Wrapped Supra", "WSUPRA");
        __ERC20Permit_init("Wrapped Supra");
        __Ownable_init(_initialOwner);
    }

    /// @notice Deposit native token → Mint WSUPRA 1:1
    function deposit() public payable {
        if (msg.value == 0) revert InvalidAmount();
        _mint(msg.sender, msg.value);

        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Withdraw native token → Burn WSUPRA 1:1
    /// @param _amount Amount of native tokens to withdraw.
    function withdraw(uint256 _amount) public {
        if (_amount == 0) revert InvalidAmount();
        _burn(msg.sender, _amount);

        emit Withdrawal(msg.sender, _amount);

        payable(msg.sender).sendValue(_amount);
    }

    /// @notice Allows a user to send native tokens directly and get WSUPRA.
    receive() external payable {
        deposit();
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner { }
}
