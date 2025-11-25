// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ERC20Supra is ERC20, ERC20Burnable, Ownable, ERC20Permit {
    
    /// Custom errors
    error InsufficentBalance();
    error InvalidAddress();
    error InvalidAmount();
    error TransferFailed();

    /// @notice Emitted when native token is deposited.
    /// @param account Address of the depositer.
    /// @param amount Amount deposited.
    event Deposit(address indexed account, uint256 amount);
    
    /// @notice Emitted when native token is withdrawn, 
    /// @param account Address withdrawing.
    /// @param amount Amount withdrawn.
    event Withdrawal(address indexed account, uint256 amount);

    constructor(address _initialOwner)
        ERC20("ERC20Supra", "SUPRA")
        Ownable(_initialOwner)
        ERC20Permit("ERC20Supra")
    {}

    /// @notice Deposit native token → Mint ERC20Supra 1:1
    function deposit() external payable {
        if (msg.value == 0) { revert InvalidAmount(); }
        _mint(msg.sender, msg.value);

        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Withdraw native token → Burn ERC20Supra 1:1
    /// @param _amount to withdraw.
    function withdraw(uint256 _amount) external {
        if (balanceOf(msg.sender) < _amount) { revert InsufficentBalance(); }
        
        _burn(msg.sender, _amount);

        (bool sent, ) = payable(msg.sender).call{value: _amount}("");
        if (!sent) { revert TransferFailed(); }

        emit Withdrawal(msg.sender, _amount);
    }    

    /// @notice Fallback deposit support: allow users to send native token directly.
    receive() external payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Owner can rescue accidental ERC20Supra tokens sent to the contract.
    /// @param _amount Amount to withdraw. 
    /// @param _to Address of the recepient.
    function rescueERC20(uint256 _amount, address _to) external onlyOwner {
        if (_to == address(0)) { revert InvalidAddress(); }
        if (balanceOf(address(this)) < _amount ) { revert InsufficentBalance(); }

        _transfer(address(this), _to, _amount);
    }
}
