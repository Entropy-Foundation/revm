// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {Config} from "../src/libraries/LibAppStorage.sol";
import {Deployment, InitParams, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {DiamondInit} from "../src/upgradeInitializers/DiamondInit.sol";

contract DiamondInitTest is BaseDiamondTest {

    /// @dev Test to ensure all state variables are initialized correctly.
    function testInitialize() public view {
        assertEq(OwnershipFacet(diamondAddr).owner(), admin);

        (uint64 index, uint64 startTime, uint64 durationSecs, LibCommon.CycleState state) = ICoreFacet(diamondAddr).getCycleInfo();
        assertEq(index, 1);
        assertEq(startTime, block.timestamp);
        assertEq(durationSecs, 2000);
        assertEq(uint8(state), uint8(LibCommon.CycleState.STARTED));

        assertEq(IRegistryFacet(diamondAddr).getNextCycleRegistryMaxGasCap(), 10_000_000);
        assertEq(IRegistryFacet(diamondAddr).getNextCycleSysRegistryMaxGasCap(), 5_000_000);
        assertTrue(IConfigFacet(diamondAddr).isRegistrationEnabled());
        assertTrue(ICoreFacet(diamondAddr).isAutomationEnabled());
        assertEq(IConfigFacet(diamondAddr).getVmSigner(), LibUtils.VM_SIGNER);
        assertEq(IConfigFacet(diamondAddr).erc20Supra(), address(erc20Supra));

        Config memory config = IConfigFacet(diamondAddr).getConfig();

        assertEq(config.registryMaxGasCap, 10_000_000);
        assertEq(config.sysRegistryMaxGasCap, 5_000_000);
        assertEq(config.automationBaseFeeWeiPerSec, 0.001 ether);
        assertEq(config.flatRegistrationFeeWei, 0.002 ether);
        assertEq(config.congestionBaseFeeWeiPerSec, 0.002 ether);
        assertEq(config.taskDurationCapSecs, 3600);
        assertEq(config.sysTaskDurationCapSecs, 3600);
        assertEq(config.cycleDurationSecs, 2000);
        assertEq(config.taskCapacity, 500);
        assertEq(config.sysTaskCapacity, 500);
        assertEq(config.congestionThresholdPercentage, 50);
        assertEq(config.congestionExponent, 2);
    }

    /// @dev Test to ensure all interfaces are registered.
    function testInterfacesRegistered() public view {
        assertTrue(IERC165(diamondAddr).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(diamondAddr).supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(IERC165(diamondAddr).supportsInterface(type(IDiamondLoupe).interfaceId));
        assertTrue(IERC165(diamondAddr).supportsInterface(type(IERC173).interfaceId));
    }
    
    /// @dev Test to ensure 'init' selector is not registered.
    function testInitSelectorNotRegistered() public view {
        address facet = IDiamondLoupe(diamondAddr).facetAddress(DiamondInit.init.selector);
        assertEq(facet, address(0));
    }

    /// @dev Test to ensure Diamond reverts if 'init' is called.
    function testInitReverts() public {
        vm.expectRevert(bytes("Diamond: Function does not exist"));

        vm.prank(admin);
        DiamondInit(diamondAddr).init(
            3600,
            10_000_000,
            0.001 ether,
            0.002 ether,
            50,
            0.002 ether,
            2,
            500,
            2000,
            3600,
            5_000_000,
            500,
            LibUtils.VM_SIGNER, 
            address(erc20Supra),
            true,
            true
        );
    }

    /// @dev Test to ensure Diamond reverts if an unknown selector is called.
    function testUnknownSelectorReverts() public {
        vm.expectRevert(bytes("Diamond: Function does not exist"));

        INonExistent(diamondAddr).nonExistent();
    }

    /// @dev Test to ensure 'facetAddresses' returns the address of all the facets.
    function testLoupeFacetAddresses() public view {
        address[] memory facets = IDiamondLoupe(diamondAddr).facetAddresses();
        assertEq(facets.length, 6); // diamondCut, loupe, ownership, config, registry, core

        bool diamondCutExists;
        bool loupeExists;
        bool ownershipExists;
        bool registryExists;
        bool coreExists;

        for (uint i; i < facets.length; i++) {
            if (facets[i] == deployment.diamondCutFacet) diamondCutExists = true;
            if (facets[i] == deployment.loupeFacet) loupeExists = true;
            if (facets[i] == deployment.ownershipFacet) ownershipExists = true;
            if (facets[i] == deployment.registryFacet) registryExists = true;
            if (facets[i] == deployment.coreFacet) coreExists = true;
        }

        assertTrue(diamondCutExists);
        assertTrue(loupeExists);
        assertTrue(ownershipExists);
        assertTrue(registryExists);
        assertTrue(coreExists);
    }

    /// @dev Test to ensure 'facetAddress' points to correct facet for a selector.
    function testSelectorRouting() public view {
        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryFacet.register.selector),
            deployment.registryFacet
        );

        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(ICoreFacet.enableAutomation.selector),
            deployment.coreFacet
        );

        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(OwnershipFacet.transferOwnership.selector),
            deployment.ownershipFacet
        );
    }

    /// @dev Test to ensure 'transferOwnership' transfers the ownership.
    function testTransferOwnership() public {
        vm.prank(admin);
        OwnershipFacet(diamondAddr).transferOwnership(alice);

        assertEq(OwnershipFacet(diamondAddr).owner(), alice);
    }

    /// @dev Test to ensure 'transferOwnership' reverts if caller is not owner.
    function testTransferOwnershipRevertsIfNotOwner() public {
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);
        OwnershipFacet(diamondAddr).transferOwnership(bob);
    }

    /// @dev Test to ensure 'diamondCut' reverts if caller is not owner.
    function testDiamondCutRevertsIfNotOwner() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IRegistryFacet.register.selector;
        selectors[1] = IRegistryFacet.registerSystemTask.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: diamondAddr,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
            
        vm.expectRevert(bytes("LibDiamond: Must be contract owner"));

        vm.prank(alice);    
        IDiamondCut(diamondAddr).diamondCut(
            cut,
            address(0),
            ""
        );
    }

    /// @dev Test to ensure adding a selector works correctly.
    function testAddSelector() public {
        uint256 numFacetsBefore = IDiamondLoupe(diamondAddr).facetAddresses().length; 

        // Deploy mock facet
        MockRegistryFacet mockRegistryFacet = new MockRegistryFacet();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockRegistryFacet.counter.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockRegistryFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");

        assertEq(IDiamondLoupe(diamondAddr).facetAddress(MockRegistryFacet.counter.selector), address(mockRegistryFacet));
        assertEq(IDiamondLoupe(diamondAddr).facetAddresses().length , numFacetsBefore + 1);

        assertEq(MockRegistryFacet(diamondAddr).counter(), 1);
    }

    /// @dev Test to ensure adding an existing selector reverts.
    function testAddExistingSelectorReverts() public {
        // Deploy mock facet
        MockRegistryFacet mockRegistryFacet = new MockRegistryFacet();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockRegistryFacet.getVmSigner.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockRegistryFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });

        vm.expectRevert(bytes("LibDiamondCut: Can't add function that already exists"));

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");
    }

    /// @dev Test to ensure 'diamondCut' reverts if empty array of selectors is passed as selectors to be added.  
    function testAddWithEmptySelectorsReverts() public {
        bytes4[] memory selectors;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: deployment.registryFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });

        vm.expectRevert(bytes("LibDiamondCut: No selectors in facet to cut"));

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");
    }

    /// @dev Test to ensure 'diamondCut' reverts if address(0) is passed as facet address.
    function testAddSelectorWithZeroAddressReverts() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockRegistryFacet.counter.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });

        vm.expectRevert(bytes("LibDiamondCut: Add facet can't be address(0)"));

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");
    }

    /// @dev Test to ensure removing a selector works correclty.
    function testRemoveSelector() public {
        uint256 numSelectorsBefore =  IDiamondLoupe(diamondAddr).facetFunctionSelectors(deployment.registryFacet).length;

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IRegistryFacet.cancelTask.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: selectors
        });

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");

        // Verify selector mapping cleared
        address facet = IDiamondLoupe(diamondAddr).facetAddress(IRegistryFacet.cancelTask.selector);
        assertEq(facet, address(0));

        uint256 numSelectorsAfter =  IDiamondLoupe(diamondAddr).facetFunctionSelectors(deployment.registryFacet).length;
        assertEq(numSelectorsAfter, numSelectorsBefore - 1);

        // Verify call now reverts
        vm.expectRevert(bytes("Diamond: Function does not exist"));
        IRegistryFacet(diamondAddr).cancelTask(0);
    }

    /// @dev Test to ensure 'diamondCut' reverts if tried to remove a selector that doesn't exist.
    function testRemoveNonExistingSelectorReverts() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockRegistryFacet.counter.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: selectors
        });

        vm.expectRevert(bytes("LibDiamondCut: Can't remove function that doesn't exist"));

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");
    }

    /// @dev Test to ensure replacing a selector works correclty.
    function testReplaceSelector() public {
        // Deploy mock facet
        MockRegistryFacet mockRegistryFacet = new MockRegistryFacet();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IConfigFacet.getVmSigner.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockRegistryFacet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: selectors
        });

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");

        // Verify selector now points to mockRegistryFacet
        address facet = IDiamondLoupe(diamondAddr).facetAddress(IConfigFacet.getVmSigner.selector);
        assertEq(facet, address(mockRegistryFacet));

        // Verify logic changed
        assertEq(IConfigFacet(diamondAddr).getVmSigner(), address(0x999));
    }

    /// @dev Test to ensure replacing a selector with same facet address reverts.
    function testReplaceWithSameFacetReverts() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IConfigFacet.getVmSigner.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: deployment.configFacet,
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: selectors
        });

        vm.expectRevert(bytes("LibDiamondCut: Can't replace function with same function"));

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");
    }

    /// @dev Test to ensure initialization fails if zero address is passed as VM Signer.
    function testInitializeRevertsIfVmSignerZero() public {
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);

        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);

        // address(0) as VM signer
        LibDiamondUtils.executeCut(address(0), address(erc20Supra), defaultParams, deployment);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if ERC20Supra address is zero.
    function testInitializeRevertsIfErc20SupraIsZero() public {   
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);

        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);

        // address(0) as ERC20Supra
        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, address(0), defaultParams, deployment);
        vm.stopPrank();
    }
  
    /// @dev Test to ensure initialization fails if EOA is passed as ERC20Supra address.
    function testInitializeRevertsIfErc20SupraIsEoa() public {
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);
        
        vm.expectRevert(LibUtils.AddressCannotBeEOA.selector);

        // EOA address as ERC20Supra
        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, admin, defaultParams, deployment);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if task duration is <= cycle duration.
    function testInitializeRevertsIfInvalidTaskDuration() public {
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);

        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 2000,
            registryMaxGasCap: 10_000_000,
            automationBaseFeeWeiPerSec: 0.001 ether,
            flatRegistrationFeeWei: 0.002 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.002 ether,
            congestionExponent: 2,
            taskCapacity: 500,
            cycleDurationSecs: 2000,
            sysTaskDurationCapSecs: 3600,
            sysRegistryMaxGasCap: 5_000_000,
            sysTaskCapacity: 500,
            registrationEnabled: true,
            automationEnabled: true
        });
        
        vm.expectRevert(LibCommon.InvalidTaskDuration.selector);

        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, address(erc20Supra), initParams, deployment);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if registry max gas cap is zero.
    function testInitializeRevertsIfRegistryMaxGasCapZero() public {
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);
        
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600,
            registryMaxGasCap: 0,
            automationBaseFeeWeiPerSec: 0.001 ether,
            flatRegistrationFeeWei: 0.002 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.002 ether,
            congestionExponent: 2,
            taskCapacity: 500,
            cycleDurationSecs: 2000,
            sysTaskDurationCapSecs: 3600,
            sysRegistryMaxGasCap: 5_000_000,
            sysTaskCapacity: 500,
            registrationEnabled: true,
            automationEnabled: true
        }); 

        vm.expectRevert(LibCommon.InvalidRegistryMaxGasCap.selector);

        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, address(erc20Supra), initParams, deployment);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if congestion threshold percentage is > 100.
    function testInitializeRevertsIfInvalidCongestionThreshold() public {
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);
        
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600,
            registryMaxGasCap: 10_000_000,
            automationBaseFeeWeiPerSec: 0.001 ether,
            flatRegistrationFeeWei: 0.002 ether,
            congestionThresholdPercentage: 101,
            congestionBaseFeeWeiPerSec: 0.002 ether,
            congestionExponent: 2,
            taskCapacity: 500,
            cycleDurationSecs: 2000,
            sysTaskDurationCapSecs: 3600,
            sysRegistryMaxGasCap: 5_000_000,
            sysTaskCapacity: 500,
            registrationEnabled: true,
            automationEnabled: true
        }); 

        vm.expectRevert(LibCommon.InvalidCongestionThreshold.selector);

        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, address(erc20Supra), initParams, deployment);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if congestion exponent is 0.
    function testInitializeRevertsIfCongestionExponentZero() public {
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);

        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600,
            registryMaxGasCap: 10_000_000,
            automationBaseFeeWeiPerSec: 0.001 ether,
            flatRegistrationFeeWei: 0.002 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.002 ether,
            congestionExponent: 0,
            taskCapacity: 500,
            cycleDurationSecs: 2000,
            sysTaskDurationCapSecs: 3600,
            sysRegistryMaxGasCap: 5_000_000,
            sysTaskCapacity: 500,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidCongestionExponent.selector);

        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, address(erc20Supra), initParams, deployment);
        vm.stopPrank();      
    }

    /// @dev Test to ensure initialization fails if task capacity is 0.
    function testInitializeRevertsIfTaskCapacityZero() public {
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);
        
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600,
            registryMaxGasCap: 10_000_000,
            automationBaseFeeWeiPerSec: 0.001 ether,
            flatRegistrationFeeWei: 0.002 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.002 ether,
            congestionExponent: 2,
            taskCapacity: 0,
            cycleDurationSecs: 2000,
            sysTaskDurationCapSecs: 3600,
            sysRegistryMaxGasCap: 5_000_000,
            sysTaskCapacity: 500,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidTaskCapacity.selector);

        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, address(erc20Supra), initParams, deployment);
        vm.stopPrank();     
    }

    /// @dev Test to ensure initialization fails if cycle duration is 0.
    function testInitializeRevertsIfCycleDurationZero() public {
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);
        
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600,
            registryMaxGasCap: 10_000_000,
            automationBaseFeeWeiPerSec: 0.001 ether,
            flatRegistrationFeeWei: 0.002 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.002 ether,
            congestionExponent: 2,
            taskCapacity: 500,
            cycleDurationSecs: 0,
            sysTaskDurationCapSecs: 3600,
            sysRegistryMaxGasCap: 5_000_000,
            sysTaskCapacity: 500,
            registrationEnabled: true,
            automationEnabled: true
        });
        
        vm.expectRevert(LibCommon.InvalidCycleDuration.selector);

        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, address(erc20Supra), initParams, deployment);
        vm.stopPrank();
    }
    
    /// @dev Test to ensure initialization fails if system task duration is <= cycle duration.
    function testInitializeRevertsIfInvalidSysTaskDuration() public {
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);
        
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600,
            registryMaxGasCap: 10_000_000,
            automationBaseFeeWeiPerSec: 0.001 ether,
            flatRegistrationFeeWei: 0.002 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.002 ether,
            congestionExponent: 2,
            taskCapacity: 500,
            cycleDurationSecs: 2000,
            sysTaskDurationCapSecs: 2000,
            sysRegistryMaxGasCap: 5_000_000,
            sysTaskCapacity: 500,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidSysTaskDuration.selector);

        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, address(erc20Supra), initParams, deployment);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if system registry max gas cap is 0.
    function testInitializeRevertsIfSysRegistryMaxGasCapZero() public {
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);
        
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600,
            registryMaxGasCap: 10_000_000,
            automationBaseFeeWeiPerSec: 0.001 ether,
            flatRegistrationFeeWei: 0.002 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.002 ether,
            congestionExponent: 2,
            taskCapacity: 500,
            cycleDurationSecs: 2000,
            sysTaskDurationCapSecs: 3600,
            sysRegistryMaxGasCap: 0,
            sysTaskCapacity: 500,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidSysRegistryMaxGasCap.selector);

        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, address(erc20Supra), initParams, deployment);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if system task capacity is 0.
    function testInitializeRevertsIfSysTaskCapacityZero() public {
        vm.startPrank(admin);
        Deployment memory deployment = LibDiamondUtils.deploy(admin);
        
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600,
            registryMaxGasCap: 10_000_000,
            automationBaseFeeWeiPerSec: 0.001 ether,
            flatRegistrationFeeWei: 0.002 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.002 ether,
            congestionExponent: 2,
            taskCapacity: 500,
            cycleDurationSecs: 2000,
            sysTaskDurationCapSecs: 3600,
            sysRegistryMaxGasCap: 5_000_000,
            sysTaskCapacity: 0,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidSysTaskCapacity.selector);

        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, address(erc20Supra), initParams, deployment);
        vm.stopPrank();
    }
}

interface INonExistent {
    function nonExistent() external;
}

contract MockRegistryFacet {
    function getVmSigner() external pure returns (address) {
        return address(0x999);
    }

    function counter() external pure returns (uint256) {
        return 1;
    }
}
