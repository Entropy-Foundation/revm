// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title ERC-173 Contract Ownership Standard
///  Note: the ERC-165 identifier for this interface is 0x7f5828d0
/* is ERC165 */
interface IERC173 {
    /// @dev This emits when ownership of a contract changes.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Get the address of the owner
    /// @return owner_ The address of the owner.
    function owner() external view returns (address owner_);

    /// @notice Set the address of the new owner of the contract
    /// @dev On the automation registry Diamond this is the first step of a two-step handover
    ///      (see IOwnable2Step): it records `_newOwner` as the pending owner, and ownership moves
    ///      only when that account calls 'acceptOwnership'. The current owner keeps full control
    ///      until then. Passing the zero address cancels a pending nomination.
    ///      Renouncing ownership is intentionally not supported: the owner is never the zero address.
    ///      The function keeps its ERC-173 name and selector so that `type(IERC173).interfaceId`
    ///      stays the standard identifier.
    /// @param _newOwner The account to nominate as the next owner, or zero to cancel a nomination
    function transferOwnership(address _newOwner) external;
}
