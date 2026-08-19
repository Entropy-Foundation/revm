// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Diamond} from "../Diamond.sol";
import {DiamondCutFacet} from "../facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../facets/OwnershipFacet.sol";
import {ConfigFacet} from "../facets/ConfigFacet.sol";
import {RegistryFacet} from "../facets/RegistryFacet.sol";
import {CoreFacet} from "../facets/CoreFacet.sol";
import {DiamondInit} from "../upgradeInitializers/DiamondInit.sol";
import {FacetsDeployment, InitParams} from "../libraries/DiamondTypes.sol";

struct Deployment {
    FacetsDeployment facets;
    address diamond;
}

library LibDiamondUtils {

    // =============================================================
    //                   DEFAULT INIT CONFIG
    // =============================================================

    function defaultInitParams() internal pure returns (InitParams memory p) {
        p = InitParams({
            taskDurationCapSecs: 3600 * 24 * 7,
            registryMaxGasCap: 20_000_000,
            automationBaseFeeWeiPerSec: 0.5 ether,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.5 ether,
            congestionExponent: 6,
            maxCongestionExponent: 6,
            taskCapacity: 160,
            cycleDurationSecs: 1200,
            sysTaskDurationCapSecs: 3600 * 24 * 180,
            sysRegistryMaxGasCap: 20_000_000,
            sysTaskCapacity: 40,
            registrationEnabled: true,
            automationEnabled: true
        });
    }

    // =============================================================
    //                      DEPLOY FUNCTION
    // =============================================================

    /// @notice Deploys all facets, DiamondInit, and a fully-initialized Diamond
    ///         in a single call. The Diamond constructor applies all facet cuts
    ///         and runs DiamondInit atomically.
    function deploy(
        address _owner,
        address _erc20Supra,
        InitParams memory _params
    ) internal returns (Deployment memory d) {
        d.facets = deployFacets();
        d.diamond = address (new Diamond(_owner, d.facets,  _erc20Supra, _params));
    }

    /// @notice Deploys all facets, DiamondInit.
    function deployFacets() internal returns (FacetsDeployment memory d) {

        // 1) Deploy DiamondCutFacet
        d.diamondCutFacet = address(new DiamondCutFacet());

        // 2) Deploy remaining facets
        d.loupeFacet     = address(new DiamondLoupeFacet());
        d.ownershipFacet = address(new OwnershipFacet());
        d.configFacet    = address(new ConfigFacet());
        d.registryFacet  = address(new RegistryFacet());
        d.coreFacet      = address(new CoreFacet());

        // 3) Deploy DiamondInit
        d.diamondInit = address(new DiamondInit());
    }
}
