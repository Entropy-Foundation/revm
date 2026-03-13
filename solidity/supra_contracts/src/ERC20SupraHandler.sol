// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {LibUtils} from "../src/libraries/LibUtils.sol";
import {IERC20Supra} from "../src/interfaces/IERC20Supra.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract ERC20SupraHandler is OwnableUpgradeable, UUPSUpgradeable {
    using LibUtils for address;

    /// @notice Address of the ERC20Supra contract.
    address public erc20Supra;

    /// @notice Error thrown if allowance amount is zero. 
    error InvalidAllowance();
    /// @notice Error thrown if user has insufficient balance.
    error InsufficientBalance();
    /// @notice Error thrown if 0 is passed as amount.
    error InvalidAmount();
    /// @notice Error thrown if low level call fails.
    error TransferFailed();

    /// @notice Emitted when native tokens are deposited to mint and receive ERC20Supra tokens.
    /// @param account Address of the depositer.
    /// @param amount Amount deposited.
    event NativeToERC20Supra(address indexed account, uint256 indexed amount);

    /// @notice Emitted when native tokens are deposited, ERC20Supra tokens are minted, and the spender's allowance is set..
    /// @param account The address that deposited native tokens and received ERC20Supra.
    /// @param amount The amount of native tokens deposited and ERC20Supra minted.
    /// @param spender The address whose allowance was set.
    /// @param allowance The new allowance set for the 'spender'.
    event NativeToERC20SupraWithAllowance(
        address indexed account, 
        uint256 indexed amount, 
        address indexed spender, 
        uint256 allowance
    );

    /// @notice Emitted when native tokens are withdrawn by burning ERC20Supra tokens. 
    /// @param account Address withdrawing.
    /// @param amount Amount withdrawn.
    event ERC20SupraToNative(address indexed account, uint256 indexed amount);

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
    function nativeToErc20Supra() external payable {
        if (msg.value == 0) revert InvalidAmount();
        IERC20Supra(erc20Supra).mint(msg.sender, msg.value);

        emit NativeToERC20Supra(msg.sender, msg.value);
    }

    /// @notice Deposits native tokens, mints ERC20Supra tokens 1:1, and sets an allowance for a spender.
    /// @param _spender The address whose allowance will be set.    
    /// @param _allowanceAmount The new allowance to set for the spender.
    function nativeToErc20SupraWithAllowance(address _spender, uint256 _allowanceAmount) external payable {
        if (msg.value == 0) revert InvalidAmount();
        _spender.validateAddress();
        if (_allowanceAmount == 0) revert InvalidAllowance();

        IERC20Supra(erc20Supra).mint(msg.sender, msg.value);
        IERC20Supra(erc20Supra).approveFor(msg.sender, _spender, _allowanceAmount);

        emit NativeToERC20SupraWithAllowance(msg.sender, msg.value, _spender, _allowanceAmount);
    }

    /// @notice Withdraw native token → Burn ERC20Supra 1:1
    /// @param _amount Amount of native tokens to withdraw.
    function erc20SupraToNative(uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();
        if (IERC20(erc20Supra).balanceOf(msg.sender) < _amount) revert InsufficientBalance();
        
        IERC20Supra(erc20Supra).burn(msg.sender, _amount);
        emit ERC20SupraToNative(msg.sender, _amount);

        (bool sent, ) = payable(msg.sender).call{value: _amount}("");
        if (!sent) revert TransferFailed();
    }    

    /// @notice Allows a user to send native tokens directly and get ERC20Supra.
    receive() external payable {
        if (msg.value == 0) revert InvalidAmount();
        
        IERC20Supra(erc20Supra).mint(msg.sender, msg.value);
        emit NativeToERC20Supra(msg.sender, msg.value);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
