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

    /// @notice Error thrown if user has insufficient balance.
    error InsufficientBalance();
    /// @notice Error thrown if contract has insufficient native balance.
    error InsufficientContractBalance();
    /// @notice Error thrown if 0 is passed as amount.
    error InvalidAmount();
    /// @notice Error thrown if low level call fails.
    error TransferFailed();

    /// @notice Emitted when native tokens are deposited to mint and receive ERC20Supra tokens.
    /// @param account Address of the depositer.
    /// @param amount Amount deposited.
    event NativeToERC20Supra(address indexed account, uint256 indexed amount);

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
    function nativeToErc20Supra() public payable {
        if (msg.value == 0) revert InvalidAmount();
        IERC20Supra(erc20Supra).mint(msg.sender, msg.value);

        emit NativeToERC20Supra(msg.sender, msg.value);
    }

    /// @notice Withdraw native token → Burn ERC20Supra 1:1
    /// @param _amount Amount of native tokens to withdraw.
    function erc20SupraToNative(uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();
        if (IERC20(erc20Supra).balanceOf(msg.sender) < _amount) revert InsufficientBalance();
        if (address(this).balance < _amount) revert InsufficientContractBalance();
        
        IERC20Supra(erc20Supra).burn(msg.sender, _amount);
        emit ERC20SupraToNative(msg.sender, _amount);

        (bool sent, ) = payable(msg.sender).call{value: _amount}("");
        if (!sent) revert TransferFailed();
    }    

    /// @notice Allows a user to send native tokens directly and get ERC20Supra.
    receive() external payable {
        nativeToErc20Supra();
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
