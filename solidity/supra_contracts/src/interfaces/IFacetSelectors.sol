// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Implemented by every facet so the Diamond constructor can
///         retrieve its function selectors without a central registry.
interface IFacetSelectors {
    function getSelectors() external pure returns (bytes4[] memory);
}