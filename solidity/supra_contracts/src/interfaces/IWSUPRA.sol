// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWSUPRA is IERC20 {
    /// @notice Thrown when zero is passed as an amount.
    error InvalidAmount();

    /// @notice Emitted when native tokens are deposited and WSUPRA tokens are minted 1:1.
    /// @param from Address of the depositor.
    /// @param amount Amount of native tokens deposited.
    event Deposit(address indexed from, uint256 indexed amount);

    /// @notice Emitted when WSUPRA tokens are burned and native tokens are returned 1:1.
    /// @param to Address that received the native tokens.
    /// @param amount Amount of native tokens withdrawn.
    event Withdrawal(address indexed to, uint256 indexed amount);
    
    /// @notice Deposits native tokens and mints an equal amount of WSUPRA tokens to the caller.
    function deposit() external payable;

    /// @notice Burns WSUPRA tokens and returns an equal amount of native tokens to the caller.
    /// @param _amount Amount of tokens to withdraw.
    function withdraw(uint256 _amount) external;
}