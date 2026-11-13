// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {TaskRegistrant, ConstructorTaskRegistrant} from "./TaskRegistrant.sol";
import {AUTOMATION_TASK_OWNER_INTERFACE_ID} from "../src/interfaces/IAutomationTaskOwner.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {IMultiSignatureWallet} from "../src/interfaces/IMultiSignatureWallet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {IRegistryViewFacet} from "../src/interfaces/IRegistryViewFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {TaskMetadata} from "../src/libraries/LibAppStorage.sol";
import {MultiSignatureWallet} from "../src/MultiSignatureWallet.sol";
import {MultisigBeacon} from "../src/MultisigBeacon.sol";
import {SystemTaskOwner} from "../src/SystemTaskOwner.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";

/// @dev Reports support for every interface, including `0xffffffff`, which ERC-165 forbids.
contract EveryInterfaceClaimant {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @notice Tasks whose owner is a contract (#4469): a user task registered by a contract, and a
/// system task registered by an authorized submitter that is a contract. The registry records the
/// calling contract as the owner, and only that contract can cancel or stop the task. A
/// MultiSignatureWallet is not such an owner (smr-moonshot #4922): the registry refuses it, and
/// the wallet registers system tasks through a task owner contract it deployed, here the reference
/// SystemTaskOwner.
contract ContractOwnedTasksTest is BaseDiamondTest {
    address constant WALLET_OWNER_1 = address(0x1001);
    address constant WALLET_OWNER_2 = address(0x1002);
    // MultiSignatureWallet refuses a timeout above its maximum timeout duration.
    uint64 constant WALLET_TX_TIMEOUT = 10_000;

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Helpers :::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Deploys a TaskRegistrant that declares `IAutomationTaskOwner` and funds it with
    /// `_amount` of WSUPRA.
    function deployFundedRegistrant(uint256 _amount) internal returns (TaskRegistrant registrant) {
        registrant = deployFundedRegistrant(_amount, true);
    }

    /// @dev Deploys a TaskRegistrant, declaring `IAutomationTaskOwner` or not, and funds it with
    /// `_amount` of WSUPRA.
    function deployFundedRegistrant(uint256 _amount, bool _declaresTaskOwnerInterface)
        internal
        returns (TaskRegistrant registrant)
    {
        registrant = new TaskRegistrant(diamondAddr, address(wsupra), _declaresTaskOwnerInterface);
        // WrappedSupra refuses a zero deposit, so a registrant that pays no fee is left unfunded.
        if (_amount > 0) {
            vm.deal(address(this), _amount);
            registrant.fund{value: _amount}();
        }
    }

    /// @dev Registers, through `_registrant`, the same user task as `RegistryFacetTest.testRegister`.
    function registerUstFrom(TaskRegistrant _registrant) internal {
        _registrant.registerUst(
            createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)),
            createPredicate(diamondAddr),
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            4
        );
    }

    /// @dev Deploys a two-of-two MultiSignatureWallet behind a beacon proxy, as genesis deploys it.
    function deployWallet() internal returns (MultiSignatureWallet wallet) {
        address[] memory owners = new address[](2);
        owners[0] = WALLET_OWNER_1;
        owners[1] = WALLET_OWNER_2;
        MultisigBeacon beacon = new MultisigBeacon(address(new MultiSignatureWallet()), address(this));
        BeaconProxy proxy =
            new BeaconProxy(address(beacon), abi.encodeCall(MultiSignatureWallet.initialize, (owners, 2)));
        wallet = MultiSignatureWallet(payable(address(proxy)));
    }

    /// @dev Has owner 1 submit and owner 2 confirm a call from `_wallet` to `_to` with `_data`,
    /// which leaves it ready for execution.
    function walletSubmitAndConfirm(MultiSignatureWallet _wallet, address _to, bytes memory _data)
        internal
        returns (uint256 txIndex, bytes32 contentHash)
    {
        txIndex = _wallet.getNextTransactionIndex();
        contentHash = _wallet.hashTransactionContent(_to, 0, _data);
        vm.prank(WALLET_OWNER_1);
        _wallet.submitTransaction(_to, 0, WALLET_TX_TIMEOUT, _data);
        vm.prank(WALLET_OWNER_2);
        _wallet.confirmTransaction(txIndex, contentHash);
    }

    /// @dev Has `_wallet` call `_to` with `_data`: owner 1 submits, owner 2 confirms, owner 1
    /// executes. Returns what the call returned.
    function walletCall(MultiSignatureWallet _wallet, address _to, bytes memory _data)
        internal
        returns (bytes memory returnData)
    {
        (uint256 txIndex, bytes32 contentHash) = walletSubmitAndConfirm(_wallet, _to, _data);
        vm.prank(WALLET_OWNER_1);
        returnData = _wallet.executeTransaction(txIndex, contentHash);
    }

    /// @dev Has `_wallet` call `_to` with `_data` and expects the execution to fail with the
    /// registry's `UnsupportedTaskOwner(_wallet)`, carried in the wallet's `ExecutionFailed`.
    function expectWalletCallRefusedAsTaskOwner(MultiSignatureWallet _wallet, address _to, bytes memory _data)
        internal
    {
        (uint256 txIndex, bytes32 contentHash) = walletSubmitAndConfirm(_wallet, _to, _data);
        vm.prank(WALLET_OWNER_1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMultiSignatureWallet.ExecutionFailed.selector,
                abi.encodeWithSelector(IRegistryFacet.UnsupportedTaskOwner.selector, address(_wallet))
            )
        );
        _wallet.executeTransaction(txIndex, contentHash);
    }

    /// @dev Has `_wallet` deploy a SystemTaskOwner through `deployContract`, which makes the
    /// wallet its owner, and authorizes that contract as a system task submitter.
    function deployWalletOwnedTaskOwner(MultiSignatureWallet _wallet) internal returns (SystemTaskOwner taskOwner) {
        bytes memory creationCode = abi.encodePacked(type(SystemTaskOwner).creationCode, abi.encode(diamondAddr));
        bytes memory returnData = walletCall(
            _wallet, address(_wallet), abi.encodeCall(MultiSignatureWallet.deployContract, (creationCode, 0))
        );
        taskOwner = SystemTaskOwner(payable(abi.decode(returnData, (address))));

        vm.prank(admin);
        IConfigFacet(diamondAddr).grantAuthorization(address(taskOwner));
    }

    /// @dev Has `_wallet` register a system task through `_taskOwner`.
    function registerSystemTaskThroughTaskOwner(MultiSignatureWallet _wallet, SystemTaskOwner _taskOwner) internal {
        bytes[] memory auxData;
        walletCall(
            _wallet,
            address(_taskOwner),
            abi.encodeCall(
                SystemTaskOwner.registerSystemTask,
                (
                    createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)),
                    createPredicate(diamondAddr),
                    uint64(block.timestamp + 1250),
                    uint128(100_000),
                    2,
                    auxData
                )
            )
        );
    }

    function singleTask(uint64 _taskIndex) internal pure returns (uint64[] memory taskIndexes) {
        taskIndexes = new uint64[](1);
        taskIndexes[0] = _taskIndex;
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::: User tasks owned by a contract :::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev A user task registered by a contract is owned by that contract, which pays its fees.
    function testRegisterFromContractRecordsContractAsOwner() public {
        TaskRegistrant registrant = deployFundedRegistrant(100 ether);
        assertGt(address(registrant).code.length, 0, "the registrant has code");

        registerUstFrom(registrant);

        TaskMetadata memory task = IRegistryViewFacet(diamondAddr).getTaskDetails(0);
        assertEq(task.owner, address(registrant));
        assertEq(uint8(task.taskType), uint8(LibCommon.TaskType.UST));
        uint256[] memory ownedTasks = IRegistryViewFacet(diamondAddr).getTasksByAddress(address(registrant));
        assertEq(ownedTasks.length, 1);
        assertEq(ownedTasks[0], 0);
        assertEq(IRegistryViewFacet(diamondAddr).getGasCommittedForNextCycle(), 100_000);
        // Flat registration fee plus the deposit, as in RegistryFacetTest.testRegister.
        assertEq(wsupra.balanceOf(diamondAddr), 61.1 ether);
        assertEq(wsupra.balanceOf(address(registrant)), 38.9 ether);
    }

    /// @dev A contract owner that stops its active task receives the refund, with the same
    /// amounts as RegistryFacetTest.testStopTasks for an account owner.
    function testStopFromContractRefundsContract() public {
        TaskRegistrant registrant = deployFundedRegistrant(200 ether);
        registerUstFrom(registrant);
        processCycleTransition(diamondAddr, singleTask(0));
        assertEq(wsupra.balanceOf(address(registrant)), 135.9 ether);

        registrant.stop(singleTask(0));

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        assertEq(IRegistryViewFacet(diamondAddr).getTasksByAddress(address(registrant)).length, 0);
        assertEq(IRegistryViewFacet(diamondAddr).getGasCommittedForNextCycle(), 0);
        assertEq(wsupra.balanceOf(diamondAddr), 3.9375 ether);
        assertEq(wsupra.balanceOf(address(registrant)), 196.0625 ether);
    }

    /// @dev A contract owner cancels its pending task.
    function testCancelFromContract() public {
        TaskRegistrant registrant = deployFundedRegistrant(100 ether);
        registerUstFrom(registrant);

        registrant.cancel(singleTask(0));

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        assertEq(IRegistryViewFacet(diamondAddr).getTasksByAddress(address(registrant)).length, 0);
    }

    /// @dev Only the owner can stop a task: the account that deployed the registrant cannot stop
    /// the registrant's task directly.
    function testStopOfContractOwnedTaskByAnotherAccountReverts() public {
        TaskRegistrant registrant = deployFundedRegistrant(100 ether);
        registerUstFrom(registrant);

        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);
        IRegistryFacet(diamondAddr).stopTasks(singleTask(0));
    }

    /// @dev A contract that registers from its constructor has no code at the time of the call,
    /// and is the owner of the task once deployed.
    function testRegisterFromConstructorRecordsContractAsOwner() public {
        vm.deal(address(this), 100 ether);
        ConstructorTaskRegistrant registrant = new ConstructorTaskRegistrant{value: 100 ether}(
            diamondAddr,
            address(wsupra),
            createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)),
            createPredicate(diamondAddr),
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether)
        );

        assertGt(address(registrant).code.length, 0, "the registrant has code once deployed");
        assertEq(IRegistryViewFacet(diamondAddr).getTaskDetails(0).owner, address(registrant));
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: The IAutomationTaskOwner opt-in ::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev A contract that does not declare `IAutomationTaskOwner` cannot register a task.
    function testRegisterFromAContractWithoutTheOwnerInterfaceReverts() public {
        TaskRegistrant registrant = deployFundedRegistrant(100 ether, false);

        vm.expectRevert(abi.encodeWithSelector(IRegistryFacet.UnsupportedTaskOwner.selector, address(registrant)));
        registerUstFrom(registrant);
        assertEq(IRegistryViewFacet(diamondAddr).totalTasks(), 0);
    }

    /// @dev ERC-165 requires `supportsInterface(0xffffffff)` to be false, so a contract that
    /// claims every interface is refused.
    function testRegisterFromAContractClaimingEveryInterfaceReverts() public {
        address claimant = address(new EveryInterfaceClaimant());
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100));

        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRegistryFacet.UnsupportedTaskOwner.selector, claimant));
        IRegistryFacet(diamondAddr).register(
            payload, createPredicate(diamondAddr), uint64(block.timestamp + 1250), 100_000, 4 gwei, 60.1 ether, 4, auxData
        );
    }

    /// @dev An account whose code is an EIP-7702 delegation designation registers without
    /// declaring `IAutomationTaskOwner`, as an account without code does.
    function testRegisterFromADelegatedAccountIsAccepted() public {
        address delegated = address(0xD7702);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(wsupra)));
        vm.deal(delegated, 100 ether);
        bytes[] memory auxData;

        vm.startPrank(delegated);
        wsupra.deposit{value: 100 ether}();
        wsupra.approve(diamondAddr, type(uint256).max);
        IRegistryFacet(diamondAddr).register(
            createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)),
            createPredicate(diamondAddr),
            uint64(block.timestamp + 1250),
            100_000,
            4 gwei,
            60.1 ether,
            4,
            auxData
        );
        vm.stopPrank();

        assertEq(IRegistryViewFacet(diamondAddr).getTaskDetails(0).owner, delegated);
    }

    /// @dev The opt-in applies to system task submitters too: the registry owner cannot authorize
    /// a contract that does not declare `IAutomationTaskOwner`.
    function testGrantAuthorizationToAContractWithoutTheOwnerInterfaceReverts() public {
        TaskRegistrant registrant = deployFundedRegistrant(0, false);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRegistryFacet.UnsupportedTaskOwner.selector, address(registrant)));
        IConfigFacet(diamondAddr).grantAuthorization(address(registrant));
        assertFalse(IRegistryFacet(diamondAddr).isAuthorizedSubmitter(address(registrant)));
    }

    /// @dev The opt-in is checked again at registration, not only when the submitter is
    /// authorized: an authorized account whose code no longer declares `IAutomationTaskOwner`
    /// cannot register a system task.
    function testRegisterSystemTaskFromAnAuthorizedAccountThatNoLongerDeclaresTheOwnerInterfaceReverts() public {
        address submitter = address(0x5B17);
        vm.prank(admin);
        IConfigFacet(diamondAddr).grantAuthorization(submitter);
        assertTrue(IRegistryFacet(diamondAddr).isAuthorizedSubmitter(submitter));

        // A contract that does not declare the interface, placed at the authorized address.
        vm.etch(submitter, address(deployFundedRegistrant(0, false)).code);
        bytes[] memory auxData;

        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(IRegistryFacet.UnsupportedTaskOwner.selector, submitter));
        IRegistryFacet(diamondAddr).registerSystemTask(
            createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)),
            createPredicate(diamondAddr),
            uint64(block.timestamp + 1250),
            100_000,
            2,
            auxData
        );
        assertEq(IRegistryViewFacet(diamondAddr).totalTasks(), 0);
    }

    /// @dev The fixture's copy of the interface identifier is the registry's.
    function testTheRegistrantUsesTheRegistryOwnerInterfaceId() public {
        TaskRegistrant registrant = deployFundedRegistrant(0, true);
        assertEq(registrant.AUTOMATION_TASK_OWNER_INTERFACE_ID(), AUTOMATION_TASK_OWNER_INTERFACE_ID);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::: A MultiSignatureWallet is not a task owner :::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev The MultiSignatureWallet declares neither `IERC165` nor `IAutomationTaskOwner`.
    function testTheMultiSignatureWalletDeclaresNoOwnerInterface() public {
        MultiSignatureWallet wallet = deployWallet();
        assertFalse(ERC165Checker.supportsERC165(address(wallet)));
        assertFalse(ERC165Checker.supportsInterface(address(wallet), AUTOMATION_TASK_OWNER_INTERFACE_ID));
    }

    /// @dev The registry owner cannot authorize the wallet as a system task submitter.
    function testGrantAuthorizationToAMultiSignatureWalletReverts() public {
        MultiSignatureWallet wallet = deployWallet();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRegistryFacet.UnsupportedTaskOwner.selector, address(wallet)));
        IConfigFacet(diamondAddr).grantAuthorization(address(wallet));
        assertFalse(IRegistryFacet(diamondAddr).isAuthorizedSubmitter(address(wallet)));
    }

    /// @dev A wallet cannot register a user task either.
    function testRegisterFromAMultiSignatureWalletIsRefused() public {
        MultiSignatureWallet wallet = deployWallet();
        bytes[] memory auxData;

        expectWalletCallRefusedAsTaskOwner(
            wallet,
            diamondAddr,
            abi.encodeCall(
                IRegistryFacet.register,
                (
                    createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)),
                    createPredicate(diamondAddr),
                    uint64(block.timestamp + 1250),
                    uint128(100_000),
                    uint128(4 gwei),
                    uint128(60.1 ether),
                    4,
                    auxData
                )
            )
        );
        assertEq(IRegistryViewFacet(diamondAddr).totalTasks(), 0);
    }

    // :::::::::::::::::::::::::::::::::::::::: System tasks of a SystemTaskOwner a MultiSignatureWallet owns ::::::::::::::::::::::::::::::::::::::::

    /// @dev A task owner contract the wallet deploys through `deployContract` has the wallet as
    /// its owner, and a system task the wallet registers through it is owned by that contract,
    /// not by the wallet.
    function testRegisterSystemTaskThroughAWalletOwnedTaskOwner() public {
        MultiSignatureWallet wallet = deployWallet();
        SystemTaskOwner taskOwner = deployWalletOwnedTaskOwner(wallet);
        assertEq(taskOwner.owner(), address(wallet));

        registerSystemTaskThroughTaskOwner(wallet, taskOwner);

        TaskMetadata memory task = IRegistryViewFacet(diamondAddr).getTaskDetails(0);
        assertEq(task.owner, address(taskOwner));
        assertEq(uint8(task.taskType), uint8(LibCommon.TaskType.GST));
        assertTrue(IRegistryViewFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(IRegistryViewFacet(diamondAddr).getTasksByAddress(address(taskOwner)).length, 1);
        assertEq(IRegistryViewFacet(diamondAddr).getTasksByAddress(address(wallet)).length, 0);
        assertEq(IRegistryViewFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 100_000);
    }

    /// @dev The wallet cancels the task through a wallet transaction to the task owner.
    function testCancelSystemTaskThroughAWalletOwnedTaskOwner() public {
        MultiSignatureWallet wallet = deployWallet();
        SystemTaskOwner taskOwner = deployWalletOwnedTaskOwner(wallet);
        registerSystemTaskThroughTaskOwner(wallet, taskOwner);

        walletCall(wallet, address(taskOwner), abi.encodeCall(SystemTaskOwner.cancelSystemTasks, (singleTask(0))));

        assertFalse(IRegistryViewFacet(diamondAddr).ifTaskExists(0));
        assertFalse(IRegistryViewFacet(diamondAddr).ifSysTaskExists(0));
        assertEq(IRegistryViewFacet(diamondAddr).getSystemGasCommittedForNextCycle(), 0);
    }

    /// @dev One wallet owner acting alone can stop the task neither through the task owner nor
    /// on the registry, and neither can the wallet itself on the registry: the task is the task
    /// owner's.
    function testStopOfAWalletOwnedSystemTaskOutsideTheWalletFlowReverts() public {
        MultiSignatureWallet wallet = deployWallet();
        SystemTaskOwner taskOwner = deployWalletOwnedTaskOwner(wallet);
        registerSystemTaskThroughTaskOwner(wallet, taskOwner);

        vm.prank(WALLET_OWNER_1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, WALLET_OWNER_1));
        taskOwner.stopSystemTasks(singleTask(0));

        vm.prank(WALLET_OWNER_1);
        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);
        IRegistryFacet(diamondAddr).stopSystemTasks(singleTask(0));

        vm.prank(address(wallet));
        vm.expectRevert(IRegistryFacet.UnauthorizedAccount.selector);
        IRegistryFacet(diamondAddr).stopSystemTasks(singleTask(0));

        assertTrue(IRegistryViewFacet(diamondAddr).ifSysTaskExists(0));
    }
}
