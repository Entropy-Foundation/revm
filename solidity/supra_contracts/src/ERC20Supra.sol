// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {LibUtils} from "../src/libraries/LibUtils.sol";
import {IERC20Supra} from "../src/interfaces/IERC20Supra.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract ERC20Supra is ERC20Upgradeable, ERC20PermitUpgradeable, IERC20Supra, OwnableUpgradeable, UUPSUpgradeable {
    using LibUtils for address;
    
    /// @notice Address of the bridge contract.
    address public bridge;
    /// @notice Address of the ERC20SupraHandler contract.
    address public erc20SupraHandler;
    
    /// @notice Thrown when a function is called by an address that is not authorized to perform the operation.    
    error UnauthorizedCaller();

    /**
    * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    *                                                              CONSTRUCTOR AND INITIALIZER
    * :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    */
    /// @dev Disables the initialization for the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the ERC20Supra token contract.
    /// @param _initialOwner Address that will be assigned ownership of the contract.
    /// @param _bridge Address of the bridge contract authorized to mint and burn tokens.
    /// @param _erc20SupraHandler Address of the handler contract responsible for native ↔ ERC20Supra conversions.
    function initialize(address _initialOwner, address _bridge, address _erc20SupraHandler) public initializer {
        __ERC20_init("ERC20Supra", "SUPRA");
        __Ownable_init(_initialOwner);
        __ERC20Permit_init("ERC20Supra");

        _bridge.validateAddress();
        _erc20SupraHandler.validateAddress();
        bridge = _bridge;
        erc20SupraHandler = _erc20SupraHandler;
    }

    /// @notice Mints ERC20Supra tokens to a specified address.
    /// @dev Can only be called by the authorized bridge or ERC20SupraHandler contract.
    /// @param _to Address receiving the minted tokens.
    /// @param _amount Amount of tokens to mint.
    function mint(address _to, uint256 _amount) external {
        isAuthorized();
        _mint(_to, _amount);
    }

    /// @notice Burns ERC20Supra tokens from a specified address.
    /// @dev Can only be called by the authorized bridge or ERC20SupraHandler contract.
    /// @param _from Address whose tokens will be burned.
    /// @param _amount Amount of tokens to burn.
    function burn(address _from, uint256 _amount) external {
        isAuthorized();
        _burn(_from, _amount);
    }

    /// @notice Sets an allowance on behalf of a token owner.
    /// @dev Callable only by the ERC20SupraHandler to allow atomic mint + approve flows.
    /// @param _owner Address that owns the tokens.
    /// @param _spender Address that will be allowed to spend the tokens.
    /// @param _amount Amount of tokens approved for spending.
    function approveFor(
        address _owner,
        address _spender,
        uint256 _amount
    ) external {
        if (msg.sender != erc20SupraHandler) revert UnauthorizedCaller();
        _approve(_owner, _spender, _amount);
    }
    
    /// @notice Checks whether the caller is authorized to mint or burn tokens.
    /// @dev Reverts if the caller is not the bridge or ERC20SupraHandler contract.
    function isAuthorized() private view {
        require(msg.sender == bridge || msg.sender == erc20SupraHandler, UnauthorizedCaller());
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
