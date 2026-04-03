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
    
    /// @notice Mapping of addresses authorized to mint and burn tokens.
    mapping(address => bool) public authorizedAddresses;

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
    /// @param _authorizedAddresses Array of addresses authorized to mint and burn tokens.
    function initialize(address _initialOwner, address[] memory _authorizedAddresses) public initializer {
        _initialOwner.validateAddress();

        __ERC20_init("ERC20Supra", "SUPRA");
        __Ownable_init(_initialOwner);
        __ERC20Permit_init("ERC20Supra");

        uint256 len = _authorizedAddresses.length;
        for (uint256 i = 0; i < len; i++) {
            address addr = _authorizedAddresses[i];

            addr.validateAddress();
            if (authorizedAddresses[addr]) revert AddressAlreadyAuthorized();
            authorizedAddresses[addr] = true;
        }
    }

    /// @notice Mints ERC20Supra tokens to a specified address.
    /// @dev Can only be called by authorized addresses.
    /// @param _to Address receiving the minted tokens.
    /// @param _amount Amount of tokens to mint.
    function mint(address _to, uint256 _amount) external {
        isAuthorized();
        _mint(_to, _amount);
    }

    /// @notice Burns ERC20Supra tokens from a specified address.
    /// @dev Can only be called by authorized addresses.
    /// @param _from Address whose tokens will be burned.
    /// @param _amount Amount of tokens to burn.
    function burn(address _from, uint256 _amount) external {
        isAuthorized();
        _burn(_from, _amount);
    }
    
    /// @notice Adds an address to the authorization whitelist.
    /// @dev Can only be called by the owner.
    /// @param _addr Address to authorize.
    function addAuthorizedAddress(address _addr) external onlyOwner {
        _addr.validateAddress();
        if (authorizedAddresses[_addr]) revert AddressAlreadyAuthorized();
        
        authorizedAddresses[_addr] = true;
        emit AuthorizedAddressAdded(_addr, msg.sender);
    }

    /// @notice Removes an address from the authorization whitelist.
    /// @dev Can only be called by the owner.
    /// @param _addr Address to deauthorize.
    function removeAuthorizedAddress(address _addr) external onlyOwner {
        require(authorizedAddresses[_addr], AddressNotAuthorized());

        delete authorizedAddresses[_addr];
        emit AuthorizedAddressRemoved(_addr, msg.sender);
    }

    /// @notice Checks whether the caller is authorized to mint or burn tokens.
    /// @dev Reverts if the caller is not in the authorized whitelist.
    function isAuthorized() private view {
        require(authorizedAddresses[msg.sender], UnauthorizedCaller());
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UPGRADEABILITY FUNCTIONS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @notice Helper function that reverts when 'msg.sender' is not authorized to upgrade the contract.
    /// @dev called by 'upgradeTo' and 'upgradeToAndCall' in UUPSUpgradeable
    /// @dev must be called by 'owner'
    /// @param newImplementation address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner{ }
}
