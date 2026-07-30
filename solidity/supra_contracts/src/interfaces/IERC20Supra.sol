// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20Supra is IERC20 {
    /// @notice Thrown when a function is called by an address that is not authorized to perform the operation.    
    error UnauthorizedCaller();
    /// @notice Thrown when trying to add an already authorized address.
    error AddressAlreadyAuthorized();
    /// @notice Thrown when trying to remove an address that is not authorized.
    error AddressNotAuthorized();

    /// @notice Emitted when the contract is initialized with authorized addresses.
    /// @param authorizedAddresses The list of authorized addresses.
    event InitializedAuthorizedAddresses(address[] indexed authorizedAddresses);

    /// @notice Emitted when an address is added to the authorization whitelist.
    /// @param authorizedAddress The address that was added.
    /// @param addedBy The address that added the authorized address.
    event AuthorizedAddressAdded(address indexed authorizedAddress, address indexed addedBy);
    
    /// @notice Emitted when an address is removed from the authorization whitelist.
    /// @param authorizedAddress The address that was removed.
    /// @param removedBy The address that removed the authorized address.
    event AuthorizedAddressRemoved(address indexed authorizedAddress, address indexed removedBy);

    function mint(address _to, uint256 _amount) external;
    function burn(uint256 _amount) external;
    function burnFrom(address _from, uint256 _amount) external;
    function addAuthorizedAddress(address _addr) external;
    function removeAuthorizedAddress(address _addr) external;
}
