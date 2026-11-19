// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Two-step ownership handover for the automation registry Diamond
/// @notice Completes the IERC173 surface of the Diamond: on this Diamond 'transferOwnership' only
///         nominates a pending owner, and ownership moves when that account calls 'acceptOwnership'.
/// @dev Declared separately from IERC173 so that `type(IERC173).interfaceId` stays the standard
///      ERC-173 identifier (0x7f5828d0); adding functions to IERC173 itself would change it.
///      Both identifiers are registered for ERC-165 by DiamondInit.
///      Same names and event shape as OpenZeppelin's Ownable2Step, so tooling written against
///      BlockMeta / MultisigBeacon can drive the Diamond's handover unchanged.
///      See Entropy-Foundation/smr-moonshot#4975.
interface IOwnable2Step {
    /// @dev Emitted when the owner nominates `newOwner`, or cancels a nomination
    ///      (`newOwner == address(0)`).
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice Returns the account nominated by 'transferOwnership' that has not accepted yet,
    ///         or the zero address if there is no pending nomination.
    function pendingOwner() external view returns (address pendingOwner_);

    /// @notice Completes a transfer started by 'transferOwnership'. Callable only by the pending owner.
    /// @dev Reverts with LibDiamond.MustBePendingOwner for any other caller, and for every caller
    ///      when no nomination is pending.
    function acceptOwnership() external;
}
