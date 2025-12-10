// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract ERC20Supra is ERC20, ERC20Burnable, Ownable2Step, ERC20Permit {
    
    /// @notice Error thrown if user has insufficient balance.
    error InsufficientBalance();
    /// @notice Error thrown if 0 is passed as amount.
    error InvalidAmount();
    /// @notice Error thrown if tokens are sent to the token contract itself.
    error InvalidTransfer();
    /// @notice Error thrown if low level call fails.
    error TransferFailed();

    /// @notice Emitted when native token is deposited.
    /// @param account Address of the depositer.
    /// @param amount Amount deposited.
    event Deposit(address indexed account, uint256 indexed amount);
    
    /// @notice Emitted when native token is withdrawn, 
    /// @param account Address withdrawing.
    /// @param amount Amount withdrawn.
    event Withdrawal(address indexed account, uint256 indexed amount);

    constructor(address _initialOwner)
        ERC20("ERC20Supra", "SUPRA")
        Ownable(_initialOwner)
        ERC20Permit("ERC20Supra")
    {}

    /// @notice Deposit native token → Mint ERC20Supra 1:1
    function deposit() external payable {
        if (msg.value == 0) revert InvalidAmount();
        _mint(msg.sender, msg.value);

        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Withdraw native token → Burn ERC20Supra 1:1
    /// @param _amount Amount of native tokens to withdraw.
    function withdraw(uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < _amount) revert InsufficientBalance();
        
        _burn(msg.sender, _amount);
        emit Withdrawal(msg.sender, _amount);

        (bool sent, ) = payable(msg.sender).call{value: _amount}("");
        if (!sent) revert TransferFailed();
    }    

    /// @notice Allows a user to send native tokens directly.
    receive() external payable {
        if (msg.value == 0) revert InvalidAmount();
        
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Disallows sending tokens to the token contract itself. This prevents accidental locking of tokens.
    function _update(address _from, address _to, uint256 _value) internal override {
        if (_to == address(this)) revert InvalidTransfer();
        super._update(_from, _to, _value);
    }
}
