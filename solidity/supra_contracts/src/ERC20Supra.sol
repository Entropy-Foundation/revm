// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract ERC20Supra is ERC20, ERC20Burnable, Ownable2Step, ERC20Permit {
    
    /// @notice Error thrown if address(0) is passed. 
    error AddressCannotBeZero();
    /// @notice Error thrown if user has insufficient balance.
    error InsufficientBalance();
    /// @notice Error thrown if 0 is passed as amount.
    error InvalidAmount();
    /// @notice Error thrown if tokens are sent to the token contract itself.
    error InvalidTransfer();
    /// @notice Error thrown if low level call fails.
    error TransferFailed();

    /// @notice Emitted when native tokens are deposited to mint and receive ERC20Supra tokens.
    /// @param account Address of the depositer.
    /// @param amount Amount deposited.
    event NativeToERC20Supra(address indexed account, uint256 indexed amount);

    /// @notice Emitted when native tokens are deposited, ERC20Supra tokens are minted, and an allowance is granted or increased for a spender.
    /// @param account The address that deposited native tokens and received ERC20Supra.
    /// @param amount The amount of native tokens deposited and ERC20Supra minted.
    /// @param spender The address whose allowance was updated.
    /// @param updatedAllowance The new allowance granted to 'spender'.
    event NativeToERC20SupraWithAllowance(
        address indexed account, 
        uint256 indexed amount, 
        address indexed spender, 
        uint256 updatedAllowance
    );

    /// @notice Emitted when native tokens are withdrawn by burning ERC20Supra tokens. 
    /// @param account Address withdrawing.
    /// @param amount Amount withdrawn.
    event ERC20SupraToNative(address indexed account, uint256 indexed amount);

    constructor(address _initialOwner)
        ERC20("ERC20Supra", "SUPRA")
        Ownable(_initialOwner)
        ERC20Permit("ERC20Supra")
    {}

    /// @notice Deposit native token → Mint ERC20Supra 1:1
    function nativeToErc20Supra() external payable {
        if (msg.value == 0) revert InvalidAmount();
        _mint(msg.sender, msg.value);

        emit NativeToERC20Supra(msg.sender, msg.value);
    }

    /// @notice Deposits native tokens, mints ERC20Supra 1:1, and increases the allowance of a specified spender by the deposited amount.
    /// @dev The resulting allowance for '_spender' is the previous allowance plus 'msg.value'.
    /// @param _spender The address that will receive the increased allowance.    
    function nativeToErc20SupraWithAllowance(address _spender) external payable {
        if (msg.value == 0) revert InvalidAmount();
        if (_spender == address(0)) revert AddressCannotBeZero();

        _mint(msg.sender, msg.value);

        // Increment the allowance by minted amount
        uint256 newAllowance = allowance(msg.sender, _spender) + msg.value;
        _approve(msg.sender, _spender, newAllowance);

        emit NativeToERC20SupraWithAllowance(msg.sender, msg.value, _spender, newAllowance);
    }

    /// @notice Withdraw native token → Burn ERC20Supra 1:1
    /// @param _amount Amount of native tokens to withdraw.
    function erc20SupraToNative(uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < _amount) revert InsufficientBalance();
        
        _burn(msg.sender, _amount);
        emit ERC20SupraToNative(msg.sender, _amount);

        (bool sent, ) = payable(msg.sender).call{value: _amount}("");
        if (!sent) revert TransferFailed();
    }    

    /// @notice Allows a user to send native tokens directly and get ERC20Supra.
    receive() external payable {
        if (msg.value == 0) revert InvalidAmount();
        
        _mint(msg.sender, msg.value);
        emit NativeToERC20Supra(msg.sender, msg.value);
    }

    /// @notice Disallows sending tokens to the token contract itself. This prevents accidental locking of tokens.
    function _update(address _from, address _to, uint256 _value) internal override {
        if (_to == address(this)) revert InvalidTransfer();
        super._update(_from, _to, _value);
    }
}
