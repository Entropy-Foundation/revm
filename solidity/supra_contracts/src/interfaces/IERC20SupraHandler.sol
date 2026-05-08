// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

interface IERC20SupraHandler {
    /// @notice Thrown when a user has insufficient ERC20Supra balance to withdraw.
    error InsufficientBalance();
    /// @notice Thrown when the contract holds insufficient native balance to fulfil a withdrawal.
    error InsufficientContractBalance();
    /// @notice Thrown when zero is passed as an amount.
    error InvalidAmount();
    /// @notice Thrown when the low-level native-token transfer fails.
    error TransferFailed();

    /// @notice Emitted when native tokens are deposited and ERC20Supra tokens are minted 1:1.
    /// @param account Address of the depositor.
    /// @param amount Amount of native tokens deposited.
    event Deposit(address indexed account, uint256 indexed amount);

    /// @notice Emitted when ERC20Supra tokens are burned and native tokens are returned 1:1.
    /// @param account Address of the withdrawer.
    /// @param amount Amount of native tokens withdrawn.
    event Withdrawal(address indexed account, uint256 indexed amount);

    /// @notice Returns the address of the ERC20Supra contract.
    function erc20Supra() external view returns (address);

    /// @notice Deposits native tokens and mints an equal amount of ERC20Supra tokens to the caller.
    function deposit() external payable;

    /// @notice Burns ERC20Supra tokens and returns an equal amount of native tokens to the caller.
    /// @param _amount Amount of tokens to withdraw.
    function withdraw(uint256 _amount) external;
}