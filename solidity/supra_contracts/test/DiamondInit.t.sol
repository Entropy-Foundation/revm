// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibDiamond} from "../src/libraries/LibDiamond.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {Config, RecordSizingParameters} from "../src/libraries/LibAppStorage.sol";
import {FacetsDeployment, InitParams, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {IRegistryViewFacet} from "../src/interfaces/IRegistryViewFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {ICoreViewFacet} from "../src/interfaces/ICoreViewFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IFacetSelectors} from "../src/interfaces/IFacetSelectors.sol";
import {IRegistryStatus} from "../src/interfaces/IRegistryStatus.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IOwnable2Step} from "../src/interfaces/IOwnable2Step.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {DiamondInit} from "../src/upgradeInitializers/DiamondInit.sol";
import {Diamond} from "../src//Diamond.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract DiamondInitTest is BaseDiamondTest {

    /// @dev Test to ensure all state variables are initialized correctly.
    function testInitialize() public view {
        assertEq(OwnershipFacet(diamondAddr).owner(), admin);

        (uint64 index, uint64 startTime, uint64 durationSecs, LibCommon.CycleState state) = ICoreViewFacet(diamondAddr).getCycleInfo();
        assertEq(index, 1);
        assertEq(startTime, block.timestamp);
        assertEq(durationSecs, 1200);
        assertEq(uint8(state), uint8(LibCommon.CycleState.STARTED));

        assertEq(IRegistryViewFacet(diamondAddr).getNextCycleRegistryMaxGasCap(), 20_000_000);
        assertEq(IRegistryViewFacet(diamondAddr).getNextCycleSysRegistryMaxGasCap(), 20_000_000);
        assertTrue(IConfigFacet(diamondAddr).isRegistrationEnabled());
        assertTrue(ICoreViewFacet(diamondAddr).isAutomationEnabled());
        assertEq(IConfigFacet(diamondAddr).erc20Supra(), address(wsupra));

        Config memory config = IConfigFacet(diamondAddr).getConfig();

        assertEq(config.registryMaxGasCap, 20_000_000);
        assertEq(config.sysRegistryMaxGasCap, 20_000_000);
        assertEq(config.automationBaseFeeWeiPerSec, 0.5 ether);
        assertEq(config.flatRegistrationFeeWei, 1 ether);
        assertEq(config.congestionBaseFeeWeiPerSec, 0.5 ether);
        assertEq(config.taskDurationCapSecs, 3600 * 24 * 7);
        assertEq(config.sysTaskDurationCapSecs, 3600 * 24 * 180);
        assertEq(config.cycleDurationSecs, 1200);
        assertEq(config.taskCapacity, 160);
        assertEq(config.sysTaskCapacity, 40);
        assertEq(config.congestionThresholdPercentage, 50);
        assertEq(config.congestionExponent, 6);
        assertEq(config.maxCongestionExponent, 6);

        // The record sizing parameters default to the largest percentage the benchmark supports
        // and the capacity it measured (Entropy-Foundation/smr-moonshot#4755), with none buffered.
        RecordSizingParameters memory parameters = IConfigFacet(diamondAddr).getRecordSizingParameters();
        assertEq(parameters.taskSupportPercentage, LibCommon.MAX_RECORD_TASK_SUPPORT_PERCENTAGE);
        assertEq(parameters.taskSupportPercentage, 80);
        assertEq(parameters.maxCapacity, LibCommon.RECORD_GAS_BENCHMARK_CAPACITY);
        assertEq(parameters.maxCapacity, 400);
        RecordSizingParameters memory buffered = IConfigFacet(diamondAddr).getRecordSizingParametersBuffer();
        assertEq(buffered.taskSupportPercentage, 0);
        assertEq(buffered.maxCapacity, 0);
        // The stored-words bound is that of the default caps: 4,096 / 32 + 2,048 / 32 = 192 words.
        assertEq(IConfigFacet(diamondAddr).getTaskStoredWordsBound(), 192);
    }

    /// @dev Test to ensure all interfaces are registered.
    function testInterfacesRegistered() public view {
        assertTrue(IERC165(diamondAddr).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(diamondAddr).supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(IERC165(diamondAddr).supportsInterface(type(IDiamondLoupe).interfaceId));
        assertTrue(IERC165(diamondAddr).supportsInterface(type(IERC173).interfaceId));
        assertTrue(IERC165(diamondAddr).supportsInterface(type(IOwnable2Step).interfaceId));
        assertTrue(IERC165(diamondAddr).supportsInterface(type(IRegistryStatus).interfaceId));
    }

    /// @dev IERC173's interfaceId stays the standard ERC-173 value: the two-step functions live in
    ///      IOwnable2Step rather than being added to IERC173.
    function testErc173InterfaceIdIsStandard() public pure {
        assertEq(type(IERC173).interfaceId, bytes4(0x7f5828d0));
    }
    
    /// @dev Test to ensure 'init' selector is not registered.
    function testInitSelectorNotRegistered() public view {
        address facet = IDiamondLoupe(diamondAddr).facetAddress(DiamondInit.init.selector);
        assertEq(facet, address(0));
    }

    /// @dev Test to ensure Diamond reverts if 'init' is called.
    function testInitReverts() public {
        InitParams memory params = LibDiamondUtils.defaultInitParams();

        vm.expectRevert(LibDiamond.FunctionDoesNotExist.selector);

        vm.prank(admin);
        DiamondInit(diamondAddr).init(
            params,
            address(wsupra)
        );
    }
    
    /// @dev Test to ensure 'init' can only ever run once (smr-moonshot#3451).
    function testInitCannotBeReplayedViaDiamondCut() public {
        IDiamondCut.FacetCut[] memory emptyCut = new IDiamondCut.FacetCut[](0);
        bytes memory initCalldata = abi.encodeCall(DiamondInit.init, (defaultParams, address(wsupra)));

        vm.expectRevert(Initializable.InvalidInitialization.selector);

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(emptyCut, deployment.facets.diamondInit, initCalldata);
    }

    /// @dev Test to ensure a future upgrade initializer tagged `reinitializer(2)` can still
    /// run successfully after DiamondInit.init() has already consumed Initializable's
    /// version 1 in the Diamond's shared storage (smr-moonshot#3451).
    function testReinitializerCanRunAfterInitialInitialization() public {
        MockDiamondInitV2 v2Init = new MockDiamondInitV2();
        IDiamondCut.FacetCut[] memory emptyCut = new IDiamondCut.FacetCut[](0);
        bytes memory initV2Calldata = abi.encodeCall(MockDiamondInitV2.initV2, ());

        vm.expectEmit(false, false, false, false);
        emit MockDiamondInitV2.ReinitializedV2();

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(emptyCut, address(v2Init), initV2Calldata);
    }

    /// @dev Test to ensure Diamond reverts if native token is sent to it.
    function testDiamondTxFailsIfNativeTokenIsSent() public {
        vm.prank(alice);
        (bool success, ) = diamondAddr.call{value: 1 ether}("");
        assertFalse(success);
    }

    /// @dev Test to ensure Diamond reverts if an unknown selector is called.
    function testUnknownSelectorReverts() public {
        vm.expectRevert(LibDiamond.FunctionDoesNotExist.selector);

        INonExistent(diamondAddr).nonExistent();
    }

    /// @dev Test to ensure 'facetAddresses' returns the address of all the facets.
    function testLoupeFacetAddresses() public view {
        address[] memory facets = IDiamondLoupe(diamondAddr).facetAddresses();
        assertEq(facets.length, 8); // diamondCut, loupe, ownership, config, registry, registryView, core, coreView

        bool diamondCutExists;
        bool loupeExists;
        bool ownershipExists;
        bool registryExists;
        bool registryViewExists;
        bool coreExists;
        bool coreViewExists;

        for (uint i; i < facets.length; i++) {
            if (facets[i] == deployment.facets.diamondCutFacet) diamondCutExists = true;
            if (facets[i] == deployment.facets.loupeFacet) loupeExists = true;
            if (facets[i] == deployment.facets.ownershipFacet) ownershipExists = true;
            if (facets[i] == deployment.facets.registryFacet) registryExists = true;
            if (facets[i] == deployment.facets.registryViewFacet) registryViewExists = true;
            if (facets[i] == deployment.facets.coreFacet) coreExists = true;
            if (facets[i] == deployment.facets.coreViewFacet) coreViewExists = true;
        }

        assertTrue(diamondCutExists);
        assertTrue(loupeExists);
        assertTrue(ownershipExists);
        assertTrue(registryExists);
        assertTrue(registryViewExists);
        assertTrue(coreExists);
        assertTrue(coreViewExists);
    }

    /// @dev Test to ensure 'facetAddress' points to correct facet for a selector.
    function testSelectorRouting() public view {
        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryFacet.register.selector),
            deployment.facets.registryFacet
        );

        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(ICoreFacet.enableAutomation.selector),
            deployment.facets.coreFacet
        );

        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(OwnershipFacet.transferOwnership.selector),
            deployment.facets.ownershipFacet
        );

        // OwnershipFacet serves owner, transferOwnership, pendingOwner and acceptOwnership.
        _assertFacetServesAllItsSelectors(deployment.facets.ownershipFacet, 4);
    }

    /// @dev Test to ensure every RegistryFacet and RegistryViewFacet selector routes to the
    /// facet that actually implements it: RegistryViewFacet's own 29 selectors resolve to
    /// registryViewFacet, and RegistryFacet's 11 (6 mutators, the 4 fee views and
    /// `isAuthorizedSubmitter`) resolve to registryFacet. This pins the split
    /// (Entropy-Foundation/smr-moonshot#4101): moving a selector across facets without
    /// updating this test fails it.
    function testRegistryFacetSplitSelectorRouting() public view {
        _assertFacetServesAllItsSelectors(deployment.facets.registryViewFacet, 29);
        _assertFacetServesAllItsSelectors(deployment.facets.registryFacet, 11);

        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryFacet.isAuthorizedSubmitter.selector),
            deployment.facets.registryFacet
        );
        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryFacet.calculateAutomationFeeMultiplierForCommittedOccupancy.selector),
            deployment.facets.registryFacet
        );
        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryFacet.calculateAutomationFeeMultiplierForCurrentCycle.selector),
            deployment.facets.registryFacet
        );
        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryFacet.estimateAutomationFee.selector),
            deployment.facets.registryFacet
        );
        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryFacet.estimateAutomationFeeWithCommittedOccupancy.selector),
            deployment.facets.registryFacet
        );
        // The task-occupancy views (Entropy-Foundation/smr-moonshot#4921) are plain reads of
        // registry state and live with the other views.
        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryViewFacet.getTasksCommittedForNextCycle.selector),
            deployment.facets.registryViewFacet
        );
        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryViewFacet.getTasksCommittedForCurrentCycle.selector),
            deployment.facets.registryViewFacet
        );
        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryViewFacet.getNextCycleTaskCapacity.selector),
            deployment.facets.registryViewFacet
        );
        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryViewFacet.getNextCycleSysTaskCapacity.selector),
            deployment.facets.registryViewFacet
        );
    }

    /// @dev Test to ensure every CoreFacet and CoreViewFacet selector routes to the facet that
    /// actually implements it: CoreViewFacet's 7 cycle-state views resolve to coreViewFacet, and
    /// CoreFacet's 5 state-changing functions resolve to coreFacet
    /// (Entropy-Foundation/smr-moonshot#4989). Moving a selector across facets without updating
    /// this test fails it.
    function testCoreFacetSplitSelectorRouting() public view {
        _assertFacetServesAllItsSelectors(deployment.facets.coreViewFacet, 7);
        _assertFacetServesAllItsSelectors(deployment.facets.coreFacet, 5);

        // Each ICoreViewFacet selector is served by coreViewFacet. Together with the count of 7
        // above, and the diamond rejecting a selector added twice, this means the interface and
        // the facet's getSelectors() list the same 7 selectors.
        bytes4[7] memory views = [
            ICoreViewFacet.getCycleInfo.selector,
            ICoreViewFacet.getCycleDuration.selector,
            ICoreViewFacet.getTransitionInfo.selector,
            ICoreViewFacet.isAutomationEnabled.selector,
            ICoreViewFacet.isAutomationReadyEnabled.selector,
            ICoreViewFacet.getCycleStateDetails.selector,
            ICoreViewFacet.getRecordMaxTaskCount.selector
        ];
        for (uint256 i; i < views.length; i++) {
            assertEq(IDiamondLoupe(diamondAddr).facetAddress(views[i]), deployment.facets.coreViewFacet);
        }

        // The node's VM signer calls these three through the diamond. The values of the
        // processTasks and removeRegisteredTask selectors are pinned by
        // testProcessTasksSelectorIsPinned and testRemoveRegisteredTaskSelectorIsPinned
        // (ConfigUpdateRemoval.t.sol).
        assertEq(IDiamondLoupe(diamondAddr).facetAddress(ICoreFacet.processTasks.selector), deployment.facets.coreFacet);
        assertEq(IDiamondLoupe(diamondAddr).facetAddress(ICoreFacet.monitorCycleEnd.selector), deployment.facets.coreFacet);
        assertEq(IDiamondLoupe(diamondAddr).facetAddress(ICoreFacet.removeRegisteredTask.selector), deployment.facets.coreFacet);
    }

    /// @dev Asserts that `_facet` reports `_expectedCount` selectors through getSelectors() and
    /// that the diamond routes every one of them to `_facet`.
    function _assertFacetServesAllItsSelectors(address _facet, uint256 _expectedCount) internal view {
        bytes4[] memory selectors = IFacetSelectors(_facet).getSelectors();
        assertEq(selectors.length, _expectedCount);
        for (uint256 i; i < selectors.length; i++) {
            assertEq(IDiamondLoupe(diamondAddr).facetAddress(selectors[i]), _facet);
        }
    }

    // ------------------------------------------------------------------------------------------
    // Two-step ownership (Entropy-Foundation/smr-moonshot#4975)
    // ------------------------------------------------------------------------------------------

    /// @dev Applies an empty diamondCut as `_caller`. diamondCut is owner-only and an empty cut
    ///      changes nothing, so this is a side-effect-free probe of "can `_caller` act as owner".
    function _emptyCutAs(address _caller) internal {
        vm.prank(_caller);
        IDiamondCut(diamondAddr).diamondCut(new IDiamondCut.FacetCut[](0), address(0), "");
    }

    /// @dev Asserts that `_caller` is refused an owner-only operation (diamondCut).
    function _assertNotOwner(address _caller) internal {
        vm.expectRevert(LibDiamond.MustBeContractOwner.selector);
        _emptyCutAs(_caller);
    }

    /// @dev Calls 'transferOwnership(_nominee)' as `_caller`.
    function _nominateAs(address _caller, address _nominee) internal {
        vm.prank(_caller);
        OwnershipFacet(diamondAddr).transferOwnership(_nominee);
    }

    /// @dev Asserts that `_caller` is refused 'transferOwnership(_nominee)' as a non-owner.
    function _assertCannotNominate(address _caller, address _nominee) internal {
        vm.expectRevert(LibDiamond.MustBeContractOwner.selector);
        _nominateAs(_caller, _nominee);
    }

    /// @dev Calls 'acceptOwnership()' as `_caller`.
    function _acceptAs(address _caller) internal {
        vm.prank(_caller);
        OwnershipFacet(diamondAddr).acceptOwnership();
    }

    /// @dev Asserts that `_caller` is refused 'acceptOwnership()' as not the pending owner.
    function _assertCannotAccept(address _caller) internal {
        vm.expectRevert(LibDiamond.MustBePendingOwner.selector);
        _acceptAs(_caller);
    }

    /// @dev Asserts the Diamond's current owner and pending owner.
    function _assertOwners(address _owner, address _pending) internal view {
        assertEq(OwnershipFacet(diamondAddr).owner(), _owner, "owner");
        assertEq(OwnershipFacet(diamondAddr).pendingOwner(), _pending, "pending owner");
    }

    /// @dev No nomination is pending after deployment.
    function testPendingOwnerIsZeroAfterDeployment() public view {
        _assertOwners(admin, address(0));
    }

    /// @dev 'transferOwnership' only nominates: the owner and its powers are unchanged, the
    ///      nominee is recorded, and OwnershipTransferStarted is emitted.
    function testTransferOwnershipNominatesPendingOwner() public {
        vm.expectEmit(true, true, false, false, diamondAddr);
        emit IOwnable2Step.OwnershipTransferStarted(admin, alice);

        _nominateAs(admin, alice);

        _assertOwners(admin, alice);
        // The current owner keeps full control until the nominee accepts ...
        _emptyCutAs(admin);
        // ... and the nominee has none yet.
        _assertNotOwner(alice);
    }

    /// @dev 'acceptOwnership' by the nominee moves ownership, clears the nomination and emits
    ///      OwnershipTransferred; the new owner can administer the Diamond, the previous one cannot.
    function testAcceptOwnershipCompletesTransfer() public {
        _nominateAs(admin, alice);

        vm.expectEmit(true, true, false, false, diamondAddr);
        emit LibDiamond.OwnershipTransferred(admin, alice);

        _acceptAs(alice);

        _assertOwners(alice, address(0));
        _emptyCutAs(alice);
        _assertNotOwner(admin);
    }

    /// @dev A completed nomination cannot be accepted a second time.
    function testAcceptOwnershipCannotBeRepeated() public {
        _nominateAs(admin, alice);
        _acceptAs(alice);

        _assertCannotAccept(alice);
    }

    /// @dev 'acceptOwnership' is refused when nothing is nominated, including for the owner itself
    ///      and for the zero address.
    function testAcceptOwnershipRevertsWithoutNomination() public {
        address[3] memory callers = [alice, admin, address(0)];
        for (uint256 i; i < callers.length; i++) {
            _assertCannotAccept(callers[i]);
        }
        _assertOwners(admin, address(0));
    }

    /// @dev Only the nominee can accept; the owner and any third party are refused and the
    ///      nomination survives their attempts.
    function testAcceptOwnershipRevertsIfNotPendingOwner() public {
        _nominateAs(admin, alice);

        _assertCannotAccept(bob);
        _assertCannotAccept(admin);

        _assertOwners(admin, alice);
    }

    /// @dev Only the owner can nominate; neither a third party nor the pending owner can.
    function testTransferOwnershipRevertsIfNotOwner() public {
        _assertCannotNominate(alice, bob);

        _nominateAs(admin, alice);
        _assertCannotNominate(alice, bob);

        _assertOwners(admin, alice);
    }

    /// @dev 'transferOwnership(address(0))' cancels a nomination: the former nominee can no longer
    ///      accept, and the owner (never zero) is unchanged.
    function testTransferOwnershipToZeroCancelsNomination() public {
        _nominateAs(admin, alice);

        vm.expectEmit(true, true, false, false, diamondAddr);
        emit IOwnable2Step.OwnershipTransferStarted(admin, address(0));

        _nominateAs(admin, address(0));

        _assertOwners(admin, address(0));
        _assertCannotAccept(alice);
    }

    /// @dev A new nomination replaces the previous one: only the latest nominee can accept.
    function testTransferOwnershipReplacesNomination() public {
        _nominateAs(admin, alice);
        _nominateAs(admin, bob);
        _assertOwners(admin, bob);

        _assertCannotAccept(alice);

        _acceptAs(bob);
        _assertOwners(bob, address(0));
    }

    /// @dev Ownership can be handed on again after a completed transfer, by the new owner only.
    function testOwnershipCanBeTransferredAgain() public {
        _nominateAs(admin, alice);
        _acceptAs(alice);

        _assertCannotNominate(admin, admin);

        _nominateAs(alice, admin);
        _acceptAs(admin);

        _assertOwners(admin, address(0));
    }

    /// @dev Nominating the current owner is harmless: accepting leaves the owner unchanged and
    ///      clears the nomination.
    function testOwnerCanAcceptSelfNomination() public {
        _nominateAs(admin, admin);
        _acceptAs(admin);

        _assertOwners(admin, address(0));
    }

    /// @dev Fuzz: for any nominee, the owner stays put until that exact account accepts, any other
    ///      caller is refused, and acceptance hands over control. The nominee is kept to accounts
    ///      that can model a real handover: not zero, not a Foundry-reserved address (cheatcodes,
    ///      console, default sender, the test contract) and not the Diamond itself.
    function testFuzzTwoStepTransfer(address _nominee, address _other) public {
        vm.assume(_nominee != address(0));
        assumeNotForgeAddress(_nominee);
        vm.assume(_nominee != diamondAddr);
        vm.assume(_other != _nominee);

        _nominateAs(admin, _nominee);
        _assertOwners(admin, _nominee);

        _assertCannotAccept(_other);

        _acceptAs(_nominee);
        _assertOwners(_nominee, address(0));
        _emptyCutAs(_nominee);
    }

    // ------------------------------------------------------------------------------------------
    // Administration selectors cannot be removed (Entropy-Foundation/smr-moonshot#4975)
    // ------------------------------------------------------------------------------------------

    /// @dev The Diamond's administration selectors, with the facet each must stay routed to.
    function _adminSelectors() internal view returns (bytes4[5] memory selectors, address[5] memory facets) {
        selectors = [
            IDiamondCut.diamondCut.selector,
            IERC173.owner.selector,
            IERC173.transferOwnership.selector,
            IOwnable2Step.pendingOwner.selector,
            IOwnable2Step.acceptOwnership.selector
        ];
        address ownership = deployment.facets.ownershipFacet;
        facets = [deployment.facets.diamondCutFacet, ownership, ownership, ownership, ownership];
    }

    /// @dev Builds a single-entry Remove cut for `_selectors` (facet must be zero for Remove).
    function _removeCut(bytes4[] memory _selectors) internal pure returns (IDiamondCut.FacetCut[] memory cut) {
        cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: _selectors
        });
    }

    /// @dev A Remove action naming any administration selector is refused, and the selector stays
    ///      routed to its facet.
    function testRemoveAdminSelectorIsRefused() public {
        (bytes4[5] memory selectors, address[5] memory facets) = _adminSelectors();
        for (uint256 i; i < selectors.length; i++) {
            bytes4[] memory one = new bytes4[](1);
            one[0] = selectors[i];

            vm.expectRevert(abi.encodeWithSelector(LibDiamond.CannotRemoveProtectedFunction.selector, selectors[i]));
            vm.prank(admin);
            IDiamondCut(diamondAddr).diamondCut(_removeCut(one), address(0), "");

            assertEq(IDiamondLoupe(diamondAddr).facetAddress(selectors[i]), facets[i]);
        }
        // The administration path is intact end to end.
        _emptyCutAs(admin);
    }

    /// @dev A Remove batch that also names an administration selector is refused as a whole: the
    ///      ordinary selector listed before it stays routed too.
    function testRemoveBatchContainingAdminSelectorIsRefused() public {
        bytes4[] memory batch = new bytes4[](2);
        batch[0] = IRegistryFacet.cancelTasks.selector;
        batch[1] = IERC173.transferOwnership.selector;

        vm.expectRevert(
            abi.encodeWithSelector(LibDiamond.CannotRemoveProtectedFunction.selector, IERC173.transferOwnership.selector)
        );
        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(_removeCut(batch), address(0), "");

        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryFacet.cancelTasks.selector),
            deployment.facets.registryFacet
        );
    }

    /// @dev Replace stays available for the administration selectors so a fix can still ship:
    ///      the ownership selectors move to a new OwnershipFacet and keep working, and diamondCut
    ///      moves to a new DiamondCutFacet that can still apply cuts.
    function testReplaceAdminSelectorsIsAllowed() public {
        OwnershipFacet newOwnershipFacet = new OwnershipFacet();
        DiamondCutFacet newCutFacet = new DiamondCutFacet();

        bytes4[] memory cutSelector = new bytes4[](1);
        cutSelector[0] = IDiamondCut.diamondCut.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(newOwnershipFacet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: newOwnershipFacet.getSelectors()
        });
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(newCutFacet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: cutSelector
        });

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");

        (bytes4[5] memory selectors, ) = _adminSelectors();
        assertEq(IDiamondLoupe(diamondAddr).facetAddress(selectors[0]), address(newCutFacet));
        for (uint256 i = 1; i < selectors.length; i++) {
            assertEq(IDiamondLoupe(diamondAddr).facetAddress(selectors[i]), address(newOwnershipFacet));
        }

        // The replaced facets serve the same Diamond storage: the owner is unchanged, can still
        // cut, and the two-step handover still works.
        _assertOwners(admin, address(0));
        _emptyCutAs(admin);
        _nominateAs(admin, alice);
        _acceptAs(alice);
        _assertOwners(alice, address(0));
    }

    /// @dev The protected set is exactly the five administration selectors: among everything the
    ///      Diamond routes at genesis, nothing else is protected, so ordinary selectors stay
    ///      removable (Remove in general is covered by testRemoveSelector).
    function testIsProtectedSelectorMatchesExactlyTheAdminSelectors() public view {
        (bytes4[5] memory selectors, ) = _adminSelectors();
        for (uint256 i; i < selectors.length; i++) {
            assertTrue(LibDiamond.isProtectedSelector(selectors[i]));
        }
        // Every other selector the Diamond routes at genesis is not protected.
        address[] memory facetList = IDiamondLoupe(diamondAddr).facetAddresses();
        uint256 protectedRouted;
        for (uint256 f; f < facetList.length; f++) {
            bytes4[] memory routed = IDiamondLoupe(diamondAddr).facetFunctionSelectors(facetList[f]);
            for (uint256 s; s < routed.length; s++) {
                if (LibDiamond.isProtectedSelector(routed[s])) protectedRouted++;
            }
        }
        assertEq(protectedRouted, selectors.length, "exactly the five admin selectors are protected");
        assertFalse(LibDiamond.isProtectedSelector(IRegistryFacet.cancelTasks.selector));
        assertFalse(LibDiamond.isProtectedSelector(bytes4(0)));
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
            
        vm.expectRevert(LibDiamond.MustBeContractOwner.selector);

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
        selectors[0] = MockRegistryFacet.erc20Supra.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockRegistryFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });

        vm.expectRevert(LibDiamond.FunctionAlreadyExists.selector);

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");
    }

    /// @dev Test to ensure 'diamondCut' reverts if empty array of selectors is passed as selectors to be added.  
    function testAddWithEmptySelectorsReverts() public {
        bytes4[] memory selectors;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: deployment.facets.registryFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });

        vm.expectRevert(LibDiamond.NoSelectorsInFacetToCut.selector);

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

        vm.expectRevert(LibDiamond.AddressCannotBeZero.selector);

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");
    }

    /// @dev Test to ensure removing a selector works correctly.
    function testRemoveSelector() public {
        uint256 numSelectorsBefore =  IDiamondLoupe(diamondAddr).facetFunctionSelectors(deployment.facets.registryFacet).length;

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IRegistryFacet.cancelTasks.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: selectors
        });

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");

        // Verify selector mapping cleared
        address facet = IDiamondLoupe(diamondAddr).facetAddress(IRegistryFacet.cancelTasks.selector);
        assertEq(facet, address(0));

        uint256 numSelectorsAfter =  IDiamondLoupe(diamondAddr).facetFunctionSelectors(deployment.facets.registryFacet).length;
        assertEq(numSelectorsAfter, numSelectorsBefore - 1);

        uint64[] memory taskIndexes = new uint64[](1);
        taskIndexes[0] = 0;
        
        // Verify call now reverts
        vm.expectRevert(LibDiamond.FunctionDoesNotExist.selector);
        IRegistryFacet(diamondAddr).cancelTasks(taskIndexes);
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

        vm.expectRevert(LibDiamond.FunctionDoesNotExist.selector);

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");
    }

    /// @dev Test to ensure replacing a selector works correctly.
    function testReplaceSelector() public {
        // Deploy mock facet
        MockRegistryFacet mockRegistryFacet = new MockRegistryFacet();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IConfigFacet.erc20Supra.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockRegistryFacet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: selectors
        });

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");

        // Verify selector now points to mockRegistryFacet
        address facet = IDiamondLoupe(diamondAddr).facetAddress(IConfigFacet.erc20Supra.selector);
        assertEq(facet, address(mockRegistryFacet));

        // Verify logic changed
        assertEq(IConfigFacet(diamondAddr).erc20Supra(), address(0x999));
    }

    /// @dev Test to ensure replacing a selector with same facet address reverts.
    function testReplaceWithSameFacetReverts() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IConfigFacet.erc20Supra.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: deployment.facets.configFacet,
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: selectors
        });

        vm.expectRevert(LibDiamond.CannotReplaceFunctionWithSameFunction.selector);

        vm.prank(admin);
        IDiamondCut(diamondAddr).diamondCut(cut, address(0), "");
    }

    /// @dev Test to ensure the constructor reverts if the genesis owner is the zero address.
    function testInitializeRevertsIfOwnerIsZero() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();
        vm.expectRevert(LibDiamond.AddressCannotBeZero.selector);
        new Diamond(address(0), facets, address(wsupra), defaultParams);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if WSUPRA address is zero.
    function testInitializeRevertsIfWsupraIsZero() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();
        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);
        // address(0) as WSUPRA
        new Diamond(admin, facets, address(0), defaultParams);
        vm.stopPrank();
    }
  
    /// @dev Test to ensure initialization fails if EOA is passed as WSUPRA address.
    function testInitializeRevertsIfWsupraIsEoa() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();
        vm.expectRevert(LibUtils.AddressCannotBeEOA.selector);
        // EOA address as WSUPRA
        new Diamond(admin, facets, admin, defaultParams);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if task duration is <= cycle duration.
    function testInitializeRevertsIfInvalidTaskDuration() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();

        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 1200,
            registryMaxGasCap: 20_000_000,
            automationBaseFeeWeiPerSec: 0.5 ether,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.5 ether,
            congestionExponent: 6,
            maxCongestionExponent: 6,
            taskCapacity: 400,
            cycleDurationSecs: 1200,
            sysTaskDurationCapSecs: 3600 * 24 * 180,
            sysRegistryMaxGasCap: 20_000_000,
            sysTaskCapacity: 100,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidTaskDuration.selector);
        new Diamond(admin, facets, address(wsupra), initParams);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if registry max gas cap is zero.
    function testInitializeRevertsIfRegistryMaxGasCapZero() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();

        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600 * 24 * 7,
            registryMaxGasCap: 0,
            automationBaseFeeWeiPerSec: 0.5 ether,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.5 ether,
            congestionExponent: 6,
            maxCongestionExponent: 6,
            taskCapacity: 400,
            cycleDurationSecs: 1200,
            sysTaskDurationCapSecs: 3600 * 24 * 180,
            sysRegistryMaxGasCap: 20_000_000,
            sysTaskCapacity: 100,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidRegistryMaxGasCap.selector);
        new Diamond(admin, facets, address(wsupra), initParams);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if congestion threshold percentage is > 100.
    function testInitializeRevertsIfInvalidCongestionThreshold() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();

        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600 * 24 * 7,
            registryMaxGasCap: 20_000_000,
            automationBaseFeeWeiPerSec: 0.5 ether,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 101,
            congestionBaseFeeWeiPerSec: 0.5 ether,
            congestionExponent: 6,
            maxCongestionExponent: 6,
            taskCapacity: 400,
            cycleDurationSecs: 1200,
            sysTaskDurationCapSecs: 3600 * 24 * 180,
            sysRegistryMaxGasCap: 20_000_000,
            sysTaskCapacity: 100,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidCongestionThreshold.selector);
        new Diamond(admin, facets, address(wsupra), initParams);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if congestion exponent is 0.
    function testInitializeRevertsIfCongestionExponentZero() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();

        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600 * 24 * 7,
            registryMaxGasCap: 20_000_000,
            automationBaseFeeWeiPerSec: 0.5 ether,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.5 ether,
            congestionExponent: 0,
            maxCongestionExponent: 6,
            taskCapacity: 400,
            cycleDurationSecs: 1200,
            sysTaskDurationCapSecs: 3600 * 24 * 180,
            sysRegistryMaxGasCap: 20_000_000,
            sysTaskCapacity: 100,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidCongestionExponent.selector);
        new Diamond(admin, facets, address(wsupra), initParams);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if task capacity is 0.
    function testInitializeRevertsIfTaskCapacityZero() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();

        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600 * 24 * 7,
            registryMaxGasCap: 20_000_000,
            automationBaseFeeWeiPerSec: 0.5 ether,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.5 ether,
            congestionExponent: 6,
            maxCongestionExponent: 6,
            taskCapacity: 0,
            cycleDurationSecs: 1200,
            sysTaskDurationCapSecs: 3600 * 24 * 180,
            sysRegistryMaxGasCap: 20_000_000,
            sysTaskCapacity: 100,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidTaskCapacity.selector);
        new Diamond(admin, facets, address(wsupra), initParams);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if cycle duration is 0.
    function testInitializeRevertsIfCycleDurationZero() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600 * 24 * 7,
            registryMaxGasCap: 20_000_000,
            automationBaseFeeWeiPerSec: 0.5 ether,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.5 ether,
            congestionExponent: 6,
            maxCongestionExponent: 6,
            taskCapacity: 400,
            cycleDurationSecs: 0,
            sysTaskDurationCapSecs: 3600 * 24 * 180,
            sysRegistryMaxGasCap: 20_000_000,
            sysTaskCapacity: 100,
            registrationEnabled: true,
            automationEnabled: true
        });
        
        vm.expectRevert(LibCommon.InvalidCycleDuration.selector);
        new Diamond(admin, facets, address(wsupra), initParams);
        vm.stopPrank();
    }
    
    /// @dev Test to ensure initialization fails if system task duration is <= cycle duration.
    function testInitializeRevertsIfInvalidSysTaskDuration() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600 * 24 * 7,
            registryMaxGasCap: 20_000_000,
            automationBaseFeeWeiPerSec: 0.5 ether,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.5 ether,
            congestionExponent: 6,
            maxCongestionExponent: 6,
            taskCapacity: 400,
            cycleDurationSecs: 1200,
            sysTaskDurationCapSecs: 1200,
            sysRegistryMaxGasCap: 20_000_000,
            sysTaskCapacity: 100,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidSysTaskDuration.selector);
        new Diamond(admin, facets, address(wsupra), initParams);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if system registry max gas cap is 0.
    function testInitializeRevertsIfSysRegistryMaxGasCapZero() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600 * 24 * 7,
            registryMaxGasCap: 20_000_000,
            automationBaseFeeWeiPerSec: 0.5 ether,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.5 ether,
            congestionExponent: 6,
            maxCongestionExponent: 6,
            taskCapacity: 400,
            cycleDurationSecs: 1200,
            sysTaskDurationCapSecs: 3600 * 24 * 180,
            sysRegistryMaxGasCap: 0,
            sysTaskCapacity: 100,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidSysRegistryMaxGasCap.selector);
        new Diamond(admin, facets, address(wsupra), initParams);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization fails if system task capacity is 0.
    function testInitializeRevertsIfSysTaskCapacityZero() public {
        vm.startPrank(admin);
        FacetsDeployment memory facets = LibDiamondUtils.deployFacets();
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600 * 24 * 7,
            registryMaxGasCap: 20_000_000,
            automationBaseFeeWeiPerSec: 0.5 ether,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0.5 ether,
            congestionExponent: 6,
            maxCongestionExponent: 6,
            taskCapacity: 400,
            cycleDurationSecs: 1200,
            sysTaskDurationCapSecs: 3600 * 24 * 180,
            sysRegistryMaxGasCap: 20_000_000,
            sysTaskCapacity: 0,
            registrationEnabled: true,
            automationEnabled: true
        });

        vm.expectRevert(LibCommon.InvalidSysTaskCapacity.selector);
        new Diamond(admin, facets, address(wsupra), initParams);
        vm.stopPrank();
    }

    /// @dev Test to ensure 'facets' returns all registered facets.
    function testFacets() public view {
        IDiamondLoupe.Facet[] memory facetList = IDiamondLoupe(diamondAddr).facets();
        assertEq(facetList.length, 8);

        for (uint256 i; i < facetList.length; i++) {
            assertTrue(facetList[i].facetAddress != address(0));
            assertGt(facetList[i].functionSelectors.length, 0);
        }
    }

    /// @dev Test to ensure 'isInitialized' returns true after initialization, and that it is
    /// routed through the diamond's normal selector table (not shadowed by Diamond.sol itself).
    function testIsInitialized() public view {
        assertTrue(IRegistryStatus(diamondAddr).isInitialized());
        assertEq(
            IDiamondLoupe(diamondAddr).facetAddress(IRegistryStatus.isInitialized.selector),
            deployment.facets.loupeFacet
        );
    }

    /// @dev Test to ensure 'isInitialized' genuinely reads live storage
    /// (LibDiamond.DiamondStorage.initialized) rather than being permanently true by construction alone.
    function testIsInitializedReflectsDedicatedFlagDirectly() public {
        assertTrue(IRegistryStatus(diamondAddr).isInitialized());

        // DiamondStorage.initialized packs into relative slot 4, byte offset 20, alongside
        // contractOwner (bytes 0-19 of the same slot) -- confirmed via `forge inspect
        // <probe contract declaring LibDiamond.DiamondStorage internal ds;> storage-layout
        // --json`, not hand-computed. Re-verify if DiamondStorage's field order changes.
        bytes32 slot = bytes32(uint256(LibDiamond.DIAMOND_STORAGE_POSITION) + 4);
        bytes32 currentValue = vm.load(diamondAddr, slot);

        // Clear only the `initialized` byte, leaving contractOwner's low 20 bytes untouched,
        // to prove this is a targeted, single-field read -- not an artifact of also breaking
        // ownership or anything else sharing the slot.
        bytes32 clearedValue = currentValue & bytes32(~(uint256(0xff) << (20 * 8)));
        vm.store(diamondAddr, slot, clearedValue);

        assertFalse(IRegistryStatus(diamondAddr).isInitialized());
        assertEq(OwnershipFacet(diamondAddr).owner(), admin, "contractOwner must be untouched");
    }

    /// @dev Test to ensure IDiamondLoupe's own interfaceId is the well-known EIP-2535 value,
    /// unaffected by IRegistryStatus (isInitialized) being routed through the same facet.
    function testDiamondLoupeInterfaceIdIsStandard() public pure {
        assertEq(type(IDiamondLoupe).interfaceId, bytes4(0x48e2b093));
    }
}

interface INonExistent {
    function nonExistent() external;
}

contract MockRegistryFacet {
    function erc20Supra() external pure returns (address) {
        return address(0x999);
    }

    function counter() external pure returns (uint256) {
        return 1;
    }
}

/// @dev Minimal stand-in for a future upgrade initializer, mirroring DiamondInit's own
/// Initializable pattern but tagged `reinitializer(2)` instead of `initializer` -- see
/// DiamondInit.sol's note on Initializable's version being permanently pinned to 1 by the
/// genesis init() call.
contract MockDiamondInitV2 is Initializable {
    event ReinitializedV2();

    function initV2() external reinitializer(2) {
        emit ReinitializedV2();
    }
}
