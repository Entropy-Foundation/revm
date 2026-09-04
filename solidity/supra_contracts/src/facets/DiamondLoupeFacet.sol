// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;
/******************************************************************************\
* Credits: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
/******************************************************************************/

import { LibDiamond } from  "../libraries/LibDiamond.sol";
import { IDiamondLoupe } from "../interfaces/IDiamondLoupe.sol";
import { IERC165 } from "../interfaces/IERC165.sol";
import { IFacetSelectors } from "../interfaces/IFacetSelectors.sol";
import { IRegistryStatus } from "../interfaces/IRegistryStatus.sol";

// The functions in DiamondLoupeFacet MUST be added to a diamond.
// The EIP-2535 Diamond standard requires these functions.

contract DiamondLoupeFacet is IDiamondLoupe, IERC165, IFacetSelectors, IRegistryStatus {

    // Diamond Loupe Functions
    ////////////////////////////////////////////////////////////////////
    /// These functions are expected to be called frequently by tools.
    //
    // struct Facet {
    //     address facetAddress;
    //     bytes4[] functionSelectors;
    // }

    /// @notice Gets all facets and their selectors.
    /// @return facets_ Facet
    function facets() external override view returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 numFacets = ds.facetAddresses.length;
        facets_ = new Facet[](numFacets);
        for (uint256 i; i < numFacets; i++) {
            address facetAddress_ = ds.facetAddresses[i];
            facets_[i].facetAddress = facetAddress_;
            facets_[i].functionSelectors = ds.facetFunctionSelectors[facetAddress_].functionSelectors;
        }
    }

    /// @notice Gets all the function selectors provided by a facet.
    /// @param _facet The facet address.
    /// @return facetFunctionSelectors_
    function facetFunctionSelectors(address _facet) external override view returns (bytes4[] memory facetFunctionSelectors_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facetFunctionSelectors_ = ds.facetFunctionSelectors[_facet].functionSelectors;
    }

    /// @notice Get all the facet addresses used by a diamond.
    /// @return facetAddresses_
    function facetAddresses() external override view returns (address[] memory facetAddresses_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facetAddresses_ = ds.facetAddresses;
    }

    /// @notice Gets the facet that supports the given selector.
    /// @dev If facet is not found return address(0).
    /// @param _functionSelector The function selector.
    /// @return facetAddress_ The facet address.
    function facetAddress(bytes4 _functionSelector) external override view returns (address facetAddress_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facetAddress_ = ds.selectorToFacetAndPosition[_functionSelector].facetAddress;
    }

    // This implements ERC-165.
    function supportsInterface(bytes4 _interfaceId) external override view returns (bool) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        return ds.supportedInterfaces[_interfaceId];
    }

    /// @notice Returns true if the Automation Registry has completed its DiamondInit initialization.
    /// @dev Reads LibDiamond.DiamondStorage.initialized directly -- a dedicated flag, not the
    /// ERC-165 `supportedInterfaces` registry. Those two are unrelated concerns: ERC-165 answers
    /// "which standards does this diamond implement", not "has genesis initialization
    /// completed", and coupling this check to specific interface registrations would mean any
    /// future change to ERC-165 registration has to also reason about whether it disturbs this
    /// signal. `initialized` is set exactly once, at the end of DiamondInit.init(), which is
    /// itself `initializer`-guarded (OpenZeppelin Initializable) so it can never run a second
    /// time -- so this can only ever go false -> true, once, for the life of a given Diamond.
    /// Node's off-chain automation registry manager relies on existence of it.
    /// Update/Replace is acceptable,  but removal should be checked against node-runtime first.
    function isInitialized() external override view returns (bool) {
        return LibDiamond.diamondStorage().initialized;
    }

    function getSelectors() external pure override returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
        s[5] = DiamondLoupeFacet.isInitialized.selector;
    }
}
