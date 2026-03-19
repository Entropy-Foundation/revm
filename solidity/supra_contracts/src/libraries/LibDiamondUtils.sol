// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Diamond} from "../Diamond.sol";
import {DiamondCutFacet} from "../facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../facets/OwnershipFacet.sol";
import {ConfigFacet} from "../facets/ConfigFacet.sol";
import {RegistryFacet} from "../facets/RegistryFacet.sol";
import {CoreFacet} from "../facets/CoreFacet.sol";
import {DiamondInit} from "../upgradeInitializers/DiamondInit.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

// =============================================================
//                         STRUCTS
// =============================================================

struct Deployment {
    address diamondCutFacet;
    address diamond;
    address loupeFacet;
    address ownershipFacet;
    address configFacet;
    address registryFacet;
    address coreFacet;
    address diamondInit;
}

struct InitParams {
    uint64 taskDurationCapSecs;
    uint128 registryMaxGasCap;
    uint128 automationBaseFeeWeiPerSec;
    uint128 flatRegistrationFeeWei;
    uint8 congestionThresholdPercentage;
    uint128 congestionBaseFeeWeiPerSec;
    uint8 congestionExponent;
    uint16 taskCapacity;
    uint64 cycleDurationSecs;
    uint64 sysTaskDurationCapSecs;
    uint128 sysRegistryMaxGasCap;
    uint16 sysTaskCapacity;
    bool automationEnabled;
    bool registrationEnabled;
}
    
library LibDiamondUtils {

    // =============================================================
    //                   DEFAULT INIT CONFIG
    // =============================================================

    function defaultInitParams() internal pure returns (InitParams memory p) {
        p = InitParams({
            taskDurationCapSecs: 3600 * 24 * 7,
            registryMaxGasCap: 1_000_000,
            automationBaseFeeWeiPerSec: 0.5 ether,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.5 ether,
            congestionExponent: 6,
            taskCapacity: 400,
            cycleDurationSecs: 1200,
            sysTaskDurationCapSecs: 3600 * 24 * 180,
            sysRegistryMaxGasCap: 1_000_000,
            sysTaskCapacity: 100,
            registrationEnabled: true,
            automationEnabled: true
        });
    }

    // =============================================================
    //                      DEPLOY FUNCTION
    // =============================================================

    function deploy(address _owner) internal returns (Deployment memory d) {

        // 1) Deploy DiamondCutFacet
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        d.diamondCutFacet = address(cutFacet);

        // 2) Deploy Diamond
        Diamond diamond = new Diamond(_owner, address(cutFacet));
        d.diamond = address(diamond);

        // 3. Deploy other facets
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        ConfigFacet configFacet =  new ConfigFacet();
        RegistryFacet registryFacet = new RegistryFacet();
        CoreFacet coreFacet = new CoreFacet();

        d.loupeFacet = address(loupeFacet);
        d.ownershipFacet = address(ownershipFacet);
        d.configFacet = address(configFacet);
        d.registryFacet = address(registryFacet);
        d.coreFacet = address(coreFacet);

        // 4) Deploy DiamondInit
        DiamondInit diamondInit = new DiamondInit();
        d.diamondInit = address(diamondInit);
    }

    // =============================================================
    //                      EXECUTE DIAMOND CUT
    // =============================================================

    function executeCut(
        address _vmSigner,
        address _erc20Supra,
        InitParams memory _params,
        Deployment memory _deployment
    ) internal {

        // 1) Build the facet cuts
        IDiamondCut.FacetCut[] memory cut = buildFacetCuts(
            _deployment.loupeFacet,
            _deployment.ownershipFacet,
            _deployment.configFacet,
            _deployment.registryFacet,
            _deployment.coreFacet
        );
        
        // 2) Prepare init calldata for DiamondInit 
        bytes memory initCalldata = abi.encodeCall(
            DiamondInit.init,
            (
                _params.taskDurationCapSecs,
                _params.registryMaxGasCap,
                _params.automationBaseFeeWeiPerSec,
                _params.flatRegistrationFeeWei,
                _params.congestionThresholdPercentage,
                _params.congestionBaseFeeWeiPerSec,
                _params.congestionExponent,
                _params.taskCapacity,
                _params.cycleDurationSecs,
                _params.sysTaskDurationCapSecs,
                _params.sysRegistryMaxGasCap,
                _params.sysTaskCapacity,
                _vmSigner,
                _erc20Supra,
                _params.registrationEnabled,
                _params.automationEnabled
            )
        );

        // 3) Execute diamondCut to add all the facets and initialize the state
        IDiamondCut(_deployment.diamond).diamondCut(
            cut,
            _deployment.diamondInit,
            initCalldata
        );
    }


    // =============================================================
    //                    FACET CUT BUILDER
    // =============================================================

    function buildFacetCuts(
        address loupeFacet,
        address ownershipFacet,
        address configFacet,
        address registryFacet,
        address coreFacet
    ) internal pure returns (IDiamondCut.FacetCut[] memory cut) {
        cut = new IDiamondCut.FacetCut[](5);

        // ------------------------------------------------------------
        //                      DiamondLoupeFacet
        // ------------------------------------------------------------
        {
            bytes4[] memory selectors = new bytes4[](5);
            selectors[0] = DiamondLoupeFacet.facets.selector;
            selectors[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
            selectors[2] = DiamondLoupeFacet.facetAddresses.selector;
            selectors[3] = DiamondLoupeFacet.facetAddress.selector;
            selectors[4] = DiamondLoupeFacet.supportsInterface.selector;
            
            cut[0] = IDiamondCut.FacetCut({
                facetAddress: loupeFacet,
                action: IDiamondCut.FacetCutAction.Add,
                functionSelectors: selectors
            });
        }
    
        // ------------------------------------------------------------
        //                      OwnershipFacet
        // ------------------------------------------------------------
        {
            bytes4[] memory selectors = new bytes4[](2);
            selectors[0] = OwnershipFacet.owner.selector;
            selectors[1] = OwnershipFacet.transferOwnership.selector;
    
            cut[1] = IDiamondCut.FacetCut({
                facetAddress: ownershipFacet,
                action: IDiamondCut.FacetCutAction.Add,
                functionSelectors: selectors
            });
        }

        // ------------------------------------------------------------
        //                      ConfigFacet
        // ------------------------------------------------------------
        {
            bytes4[] memory selectors = new bytes4[](11);
            selectors[0] = ConfigFacet.grantAuthorization.selector;
            selectors[1] = ConfigFacet.revokeAuthorization.selector;
            selectors[2] = ConfigFacet.enableRegistration.selector;
            selectors[3] = ConfigFacet.disableRegistration.selector;
            selectors[4] = ConfigFacet.withdrawFees.selector;
            selectors[5] = ConfigFacet.updateConfigBuffer.selector;
            
            selectors[6] = ConfigFacet.getVmSigner.selector;
            selectors[7] = ConfigFacet.erc20Supra.selector;
            selectors[8] = ConfigFacet.isRegistrationEnabled.selector;
            selectors[9] = ConfigFacet.getConfig.selector;
            selectors[10] = ConfigFacet.getConfigBuffer.selector;

            cut[2] = IDiamondCut.FacetCut({
                facetAddress: configFacet,
                action: IDiamondCut.FacetCutAction.Add,
                functionSelectors: selectors
            });
        }

        // ------------------------------------------------------------
        //                      RegistryFacet
        // ------------------------------------------------------------
        {
            bytes4[] memory selectors = new bytes4[](36);
            selectors[0] = RegistryFacet.register.selector;
            selectors[1] = RegistryFacet.registerSystemTask.selector;
            selectors[2] = RegistryFacet.cancelTasks.selector;
            selectors[3] = RegistryFacet.cancelSystemTasks.selector;
            selectors[4] = RegistryFacet.stopTasks.selector;
            selectors[5] = RegistryFacet.stopSystemTasks.selector;

            selectors[6] = RegistryFacet.getTaskIdList.selector;
            selectors[7] = RegistryFacet.getSystemTaskIds.selector;
            selectors[8] = RegistryFacet.getTaskOwner.selector;
            selectors[9] = RegistryFacet.getNextTaskIndex.selector;
            selectors[10] = RegistryFacet.totalTasks.selector;
            selectors[11] = RegistryFacet.totalSystemTasks.selector;
            selectors[12] = RegistryFacet.getTaskDetails.selector;
            selectors[13] = RegistryFacet.getTaskDetailsBulk.selector;
            selectors[14] = RegistryFacet.isAuthorizedSubmitter.selector;
            selectors[15] = RegistryFacet.getTotalActiveTasks.selector;
            selectors[16] = RegistryFacet.getActiveTaskIds.selector;
            selectors[17] = RegistryFacet.hasActiveUserTask.selector;
            selectors[18] = RegistryFacet.hasActiveSystemTask.selector;
            selectors[19] = RegistryFacet.hasActiveTaskOfType.selector;
            selectors[20] = RegistryFacet.getGasCommittedForNextCycle.selector;
            selectors[21] = RegistryFacet.getGasCommittedForCurrentCycle.selector;
            selectors[22] = RegistryFacet.getSystemGasCommittedForNextCycle.selector;
            selectors[23] = RegistryFacet.getSystemGasCommittedForCurrentCycle.selector;
            selectors[24] = RegistryFacet.getNextCycleRegistryMaxGasCap.selector;
            selectors[25] = RegistryFacet.getNextCycleSysRegistryMaxGasCap.selector;
            selectors[26] = RegistryFacet.getCycleLockedFees.selector;
            selectors[27] = RegistryFacet.getTotalDepositedAutomationFees.selector;
            selectors[28] = RegistryFacet.getTotalLockedBalance.selector;
            selectors[29] = RegistryFacet.calculateAutomationFeeMultiplierForCommittedOccupancy.selector;
            selectors[30] = RegistryFacet.calculateAutomationFeeMultiplierForCurrentCycle.selector;
            selectors[31] = RegistryFacet.estimateAutomationFee.selector;
            selectors[32] = RegistryFacet.estimateAutomationFeeWithCommittedOccupancy.selector;
            selectors[33] = RegistryFacet.ifTaskExists.selector;
            selectors[34] = RegistryFacet.ifSysTaskExists.selector;
            selectors[35] = RegistryFacet.getTasksByAddress.selector;

            cut[3] = IDiamondCut.FacetCut({
                facetAddress: registryFacet,
                action: IDiamondCut.FacetCutAction.Add,
                functionSelectors: selectors
            });
        }
    
        // ------------------------------------------------------------
        //                          CoreFacet
        // ------------------------------------------------------------
        {
            bytes4[] memory selectors = new bytes4[](8);
            selectors[0] = CoreFacet.processTasks.selector;
            selectors[1] = CoreFacet.monitorCycleEnd.selector;
            selectors[2] = CoreFacet.enableAutomation.selector;
            selectors[3] = CoreFacet.disableAutomation.selector;
            selectors[4] = CoreFacet.getCycleInfo.selector;
            selectors[5] = CoreFacet.getCycleDuration.selector;
            selectors[6] = CoreFacet.getTransitionInfo.selector;
            selectors[7] = CoreFacet.isAutomationEnabled.selector;
                
            cut[4] = IDiamondCut.FacetCut({
                facetAddress: coreFacet,
                action: IDiamondCut.FacetCutAction.Add,
                functionSelectors: selectors
            });
        }
    }
}
