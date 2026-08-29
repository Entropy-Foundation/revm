// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Automation Registry status
/// @notice Kept separate from IDiamondLoupe so adding it does not change
/// type(IDiamondLoupe).interfaceId away from the well-known EIP-2535 value.
interface IRegistryStatus {
    /// @notice Returns true if the Automation Registry has completed its DiamondInit initialization.
    function isInitialized() external view returns (bool);
}
