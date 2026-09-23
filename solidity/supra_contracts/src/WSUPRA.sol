// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IWSUPRA} from "../src/interfaces/IWSUPRA.sol";

/// @notice Wrapped Supra implementation.
contract WSUPRA is ERC20, ERC20Permit, IWSUPRA {
    constructor() ERC20("Wrapped Supra", "WSUPRA") ERC20Permit("Wrapped Supra") {}
    using Address for address payable;

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
}