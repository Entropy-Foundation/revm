// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {DiamondLoupeFacet} from "../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {ConfigFacet} from "../src/facets/ConfigFacet.sol";
import {RegistryFacet} from "../src/facets/RegistryFacet.sol";
import {CoreFacet} from "../src/facets/CoreFacet.sol";
import {IFacetSelectors} from "../src/interfaces/IFacetSelectors.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// @notice Prints each diamond facet's self-reported `getSelectors()` list, one line per
/// selector, as `SELECTOR <FacetName> <selector>`. Deploys throwaway local instances only
/// (no broadcast) — never run with --broadcast, this is a read-only introspection script.
///
/// Used by check_facet_selectors.sh to cross-check this hand-maintained list against the
/// facet's actual compiled ABI (via `forge inspect <Facet> methods`) — a `getSelectors()`
/// that omits an entry yields a permanently unroutable function with no compiler error,
/// since Solidity has no way to enforce "this list contains every external function".
///
/// DiamondCutFacet does not implement IFacetSelectors: Diamond's constructor wires its
/// single selector directly (`IDiamondCut.diamondCut.selector`), not via `getSelectors()`,
/// so it's reported here the same way, for the same cross-check.
contract CheckFacetSelectors is Script {
    function run() external {
        console.log("SELECTOR", "DiamondCutFacet", vm.toString(abi.encodePacked(IDiamondCut.diamondCut.selector)));
        _print("DiamondLoupeFacet", address(new DiamondLoupeFacet()));
        _print("OwnershipFacet", address(new OwnershipFacet()));
        _print("ConfigFacet", address(new ConfigFacet()));
        _print("RegistryFacet", address(new RegistryFacet()));
        _print("CoreFacet", address(new CoreFacet()));
    }

    function _print(string memory _name, address _facet) internal view {
        bytes4[] memory selectors = IFacetSelectors(_facet).getSelectors();
        for (uint256 i; i < selectors.length; i++) {
            console.log("SELECTOR", _name, vm.toString(abi.encodePacked(selectors[i])));
        }
    }
}
