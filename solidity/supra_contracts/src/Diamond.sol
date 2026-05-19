// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/******************************************************************************\
* Credits: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
*
* Implementation of a diamond.
/******************************************************************************/

import {LibDiamond} from "./libraries/LibDiamond.sol";
import {LibUtils} from "./libraries/LibUtils.sol";
import {IDiamondCut} from "./interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "./interfaces/IDiamondLoupe.sol";
import {IFacetSelectors} from "./interfaces/IFacetSelectors.sol";
import {DiamondInit} from "./upgradeInitializers/DiamondInit.sol";
import {FacetsDeployment, InitParams} from "./libraries/DiamondTypes.sol";
import { IERC173 } from "./interfaces/IERC173.sol";
import { IERC165 } from "./interfaces/IERC165.sol";

contract Diamond {
    using LibUtils for address;

    /// @notice Constructor to initialize the diamond with owner and diamond cut facet.
    /// @param _contractOwner The address of the contract owner.
    /// @param _d                  Addresses of all deployed facets and DiamondInit.
    /// @param _erc20Supra         ERC20Supra contract address passed to DiamondInit.
    /// @param _params             Registry configuration passed to DiamondInit.
    constructor(
        address _contractOwner,
        FacetsDeployment memory _d,
        address _erc20Supra,
        InitParams memory _params
    ) {
        LibDiamond.setContractOwner(_contractOwner);

        _d.configFacet.validateContractAddress();
        _d.coreFacet.validateContractAddress();
        _d.diamondCutFacet.validateContractAddress();
        _d.registryFacet.validateContractAddress();
        _d.ownershipFacet.validateContractAddress();
        _d.loupeFacet.validateContractAddress();
        _d.diamondInit.validateContractAddress();

        // ------------------------------------------------------------------
        // Build the full cut array:
        //   slot 0  — diamondCut function (from DiamondCutFacet)
        //   slots 1-5 — remaining facets, each self-reporting their selectors
        // ------------------------------------------------------------------
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](6);

        bytes4[] memory cutSelectors = new bytes4[](1);
        cutSelectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: _d.diamondCutFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: cutSelectors
        });

        address[5] memory facets = [
            _d.loupeFacet,
            _d.ownershipFacet,
            _d.configFacet,
            _d.registryFacet,
            _d.coreFacet
        ];
        for (uint256 i = 0; i < 5; i++) {
            cut[i + 1] = IDiamondCut.FacetCut({
                facetAddress: facets[i],
                action: IDiamondCut.FacetCutAction.Add,
                functionSelectors: IFacetSelectors(facets[i]).getSelectors()
            });
        }

        // ------------------------------------------------------------------
        // Encode DiamondInit.init calldata and apply all cuts atomically
        // ------------------------------------------------------------------
        bytes memory initCalldata = abi.encodeCall(
            DiamondInit.init,
            (
                _params,
                _erc20Supra
            )
        );

        LibDiamond.diamondCut(cut, _d.diamondInit, initCalldata);
    }

    /// @notice Returns true if registry has been initialized.
    function isInitialized() external view returns (bool) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        return ds.supportedInterfaces[type(IERC165).interfaceId] &&
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] &&
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] &&
        ds.supportedInterfaces[type(IERC173).interfaceId];
    }

    /// @notice Find facet for function that is called and execute the
    /// function if a facet is found and return any value.
    fallback() external {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        // get diamond storage
        assembly {
            ds.slot := position
        }
        // get facet from function selector
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        if (facet == address(0)) { revert LibDiamond.FunctionDoesNotExist(); }
        // Execute external function from facet using delegatecall and return any value.
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // execute function call using the facet
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
                case 0 { revert(0, returndatasize()) }
                default { return(0, returndatasize()) }
        }
    }
}
