// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Counter} from "./Counter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MultiSignatureWallet} from "../src/MultiSignatureWallet.sol";
import {IMultiSignatureWallet} from "../src/interfaces/IMultiSignatureWallet.sol";
import {MultisigBeacon, UpgradeableBeacon} from "../src/MultisigBeacon.sol";

contract MultiSignatureWalletTest is Test {
    Counter counter;
    MultisigBeacon beacon;
    address multiSigImplV1;
    MultiSignatureWallet multiSig;

    address[] owners;
    address[] newOwners;
    address alice = address(0xA11CE);

    /// @dev Sets up initial state for testing.
    /// @dev Deploys all required contracts.
    function setUp() public {
        vm.deal(alice, 10 ether);
        
        address owner1 = address(1001);
        address owner2 = address(1002);
        address owner3 = address(1003);
        address owner4 = address(1004);
        address owner5 = address(1005);
        owners.push(owner1);
        owners.push(owner2);
        owners.push(owner3);
        owners.push(owner4);
        owners.push(owner5);

        vm.startPrank(alice);
        // Deploy Beacon contract
        multiSigImplV1 = address(new MultiSignatureWallet());
        beacon = new MultisigBeacon(multiSigImplV1, 0xE64Bd5C4810e6C7666C544a05c980C9Fe617283f); // Pre-determined address of multisigProxy
        
        // Deploy BeaconProxy for MultiSig
        bytes memory multiSigInitData = abi.encodeCall(MultiSignatureWallet.initialize, (owners, 4));
        BeaconProxy multisigProxy = new BeaconProxy(address(beacon), multiSigInitData);
        multiSig = MultiSignatureWallet(payable(multisigProxy));
        
        vm.stopPrank();


        vm.startPrank(address(multisigProxy));
        // Deploy Counter proxy contract
        Counter counterImpl = new Counter();
        bytes memory counterInitData = abi.encodeCall(Counter.initialize, (address(multiSig)));
        ERC1967Proxy counterProxy = new ERC1967Proxy(address(counterImpl), counterInitData);
        counter = Counter(address(counterProxy));
        vm.stopPrank();
    }    

    /// @dev Test to ensure ownership and implementation address is initialized correctly. 
    function testOwnerAndImplementation() public view {
        assertEq(beacon.owner(), address(multiSig));
        assertEq(counter.owner(), address(multiSig));
        assertEq(beacon.implementation(), multiSigImplV1);
    }

    /// @dev Test to ensure contract is initialized correctly.
    function testInitialize() public view {
        assertEq(multiSig.getOwners(), owners);
        assertEq(multiSig.numConfirmationsRequired(), 4);
        assertEq(multiSig.txCount(), 0);
    }

    /// @dev Test to ensure 'initialize' reverts if array of owners is empty.
    function testInitializeRevertsIfOwnersArrayEmpty() public {
        address[] memory emptyOwners;        
        vm.expectRevert(IMultiSignatureWallet.OwnersRequired.selector);

        bytes memory initData = abi.encodeCall(MultiSignatureWallet.initialize, (emptyOwners, 1));
        new BeaconProxy(address(beacon), initData);
    }

    /// @dev Test to ensure 'initialize' reverts if number of confirmations required is zero.
    function testInitializeRevertsIfNumConfirmationsZero() public {
        vm.expectRevert(IMultiSignatureWallet.InvalidNumberOfConfirmations.selector);

        bytes memory initData = abi.encodeCall(MultiSignatureWallet.initialize, (owners, 0));
        new BeaconProxy(address(beacon), initData);
    }

    /// @dev Test to ensure 'initialize' reverts if number of confirmations required is more than the number of owners.
    function testInitializeRevertsIfNumConfirmationsMoreThanOwners() public {
        vm.expectRevert(IMultiSignatureWallet.InvalidNumberOfConfirmations.selector);

        bytes memory initData = abi.encodeCall(MultiSignatureWallet.initialize, (owners, 6));
        new BeaconProxy(address(beacon), initData);
    }

    /// @dev Test to ensure 'initialize' reverts if any of the owner is address(0).
    function testInitializeRevertsIfOwnerAddressZero() public {
        address[] memory invalidOwners = new address[](3);
        invalidOwners[0] = address(1001);
        invalidOwners[1] = address(0);          // Invalid owner
        invalidOwners[2] = address(1002);

        vm.expectRevert(IMultiSignatureWallet.InvalidOwner.selector);

        bytes memory initData = abi.encodeCall(MultiSignatureWallet.initialize, (invalidOwners, 1));
        new BeaconProxy(address(beacon), initData);
    }

    /// @dev Test to ensure 'initialize' reverts if a duplicate owner is passed.
    function testInitializeRevertsIfDuplicateOwner() public {
        address[] memory duplicateOwners = new address[](3);
        duplicateOwners[0] = address(1001);
        duplicateOwners[1] = address(1001);       // Duplicate owner
        duplicateOwners[2] = address(1002);

        vm.expectRevert(IMultiSignatureWallet.OwnerNotUnique.selector);

        bytes memory initData = abi.encodeCall(MultiSignatureWallet.initialize, (duplicateOwners, 1));
        new BeaconProxy(address(beacon), initData);
    }

    /// @dev Helper function that returns calldata for 'increment' in Counter. 
    function dataForIncrement() private pure returns (bytes memory) {
        return abi.encodeCall(Counter.increment, ());
    }

    /// @dev Helper function to submit a transaction to perform an action in the Counter contract.
    function submitTransaction(bytes memory _data) private {
        vm.prank(address(1001));
        multiSig.submitTransaction(
            address(counter),
            0,
            10000,
            _data
        );
    }

    /// @dev Test to ensure 'submitTransaction' submits a transaction.
    function testSubmitTransactionIncrement() public {
        bytes memory data = dataForIncrement();
        submitTransaction(data);
        
        (address to, uint256 value, uint24 numConfirmations, uint64 timeout, bytes memory storedData) = multiSig.getTransaction(0);
        assertEq(to, address(counter));
        assertEq(value, 0);
        assertEq(numConfirmations, 1);
        assertEq(timeout, block.timestamp + 10000);
        assertEq(storedData, data);
        assertEq(multiSig.txCount(), 1);
    }

    /// @dev Test to ensure 'submitTransaction' reverts if caller is not an owner.
    function testSubmitTransactionIncrementRevertsIfNotOwner() public {
        bytes memory data = dataForIncrement();

        vm.expectRevert(IMultiSignatureWallet.NotAnOwner.selector);

        vm.prank(alice);                    // Not an owner
        multiSig.submitTransaction(
            address(counter),
            0,
            100000,
            data
        );
    }

    /// @dev Test to ensure 'submitTransaction' reverts if address(0) is passed as recipient.
    function testSubmitTransactionIncrementRevertsIfAddressZero() public {
        bytes memory data = dataForIncrement();

        vm.expectRevert(IMultiSignatureWallet.InvalidRecipient.selector);

        vm.prank(address(1001));
        multiSig.submitTransaction(
            address(0),
            0,
            100000,
            data
        );
    }

    /// @dev Helper function to confirm a transaction.
    function confirmTransaction(address _owner, uint256 _txnId) private {
        vm.prank(_owner);
        multiSig.confirmTransaction(_txnId);
    }
    
    /// @dev Helper function to grant sufficient confirmations. 
    function grantSufficientConfirmations(uint256 _txnId) private {
        confirmTransaction(address(1002), _txnId);
        confirmTransaction(address(1003), _txnId);
        confirmTransaction(address(1004), _txnId);
    } 

    /// @dev Test to ensure 'confirmTransaction' confirms a transaction.
    function testConfirmTransactionIncrement() public {
        testSubmitTransactionIncrement();
        
        grantSufficientConfirmations(0);

        ( , , uint256 numConfirmations, , ) = multiSig.getTransaction(0);
        assertEq(numConfirmations, 4);
    }

    /// @dev Test to ensure 'confirmTransaction' reverts if caller is not an owner.
    function testConfirmTransactionRevertsIfNotOwner() public {
        testSubmitTransactionIncrement();

        vm.expectRevert(IMultiSignatureWallet.NotAnOwner.selector);
        confirmTransaction(alice, 0);      // Not an owner
    }

    /// @dev Test to ensure 'confirmTransaction' reverts if transaction does not exist.
    function testConfirmTransactionRevertsIfTxDoesNotExist() public {
        testSubmitTransactionIncrement();

        vm.expectRevert(IMultiSignatureWallet.InvalidTxnId.selector);
        confirmTransaction(address(1002), 1);
    }

    /// @dev Test to ensure 'confirmTransaction' reverts if the transaction is already executed.
    function testConfirmTransactionRevertsIfTxAlreadyExecuted() public {
        testSubmitTransactionIncrement();
        
        uint256 txId = 0;
        grantSufficientConfirmations(txId);

        vm.prank(address(1002));
        multiSig.executeTransaction(txId);

        vm.expectRevert(IMultiSignatureWallet.InvalidTxnId.selector);

        confirmTransaction(address(1005), txId);
    }

    /// @dev Test to ensure 'confirmTransaction' reverts if transaction is already confirmed.
    function testConfirmTransactionRevertsIfTxAlreadyConfirmed() public {
        testSubmitTransactionIncrement();

        vm.expectRevert(IMultiSignatureWallet.TxnAlreadyConfirmed.selector);
        confirmTransaction(address(1001), 0);
    }

    /// @dev Test to ensure 'confirmTransaction' removes the tx and emits 'TransactionExpired' if transaction has expired.
    function testConfirmTransactionRemovesTxIfExpired() public {
        vm.warp(500);
        testSubmitTransactionIncrement();

        vm.warp(10501);
        vm.expectEmit(true, false, false, false);
        emit IMultiSignatureWallet.TransactionExpired(0);
        
        confirmTransaction(address(1005), 0);
        assertEq(multiSig.txCount(), 0);
    }

    /// @dev Helper function to revoke confirmation.
    function revokeConfirmation(address _owner, uint256 _txIndex) private {
        vm.prank(_owner);
        multiSig.revokeConfirmation(_txIndex);
    }

    /// @dev Test to ensure 'revokeConfirmation' revokes the confirmation of an owner.
    function testRevokeConfirmation() public {
        testSubmitTransactionIncrement();
        
        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        revokeConfirmation(address(1001), txId);

        ( , , uint256 confirmations , , ) = multiSig.getTransaction(txId);
        assertEq(confirmations, 1);
        assertFalse(multiSig.isConfirmed(txId, address(1001)));
    }

    /// @dev Test to ensure 'revokeConfirmation' reverts if caller is not an owner.
    function testRevokeConfirmationRevertsIfNotOwner() public {
        testSubmitTransactionIncrement();
        
        vm.expectRevert(IMultiSignatureWallet.NotAnOwner.selector);
        revokeConfirmation(alice, 1);
    }

    /// @dev Test to ensure 'revokeConfirmation' reverts if transaction does not exist.
    function testRevokeConfirmationRevertsIfTxDoesNotExist() public {
        testSubmitTransactionIncrement();
        
        vm.expectRevert(IMultiSignatureWallet.InvalidTxnId.selector);
        revokeConfirmation(address(1001), 1);
    }

    /// @dev Test to ensure 'revokeConfirmation' reverts if the transaction is already executed.
    function testRevokeConfirmationRevertsIfTxAlreadyExecuted() public {
        testSubmitTransactionIncrement();
        
        uint256 txId = 0;
        grantSufficientConfirmations(txId);

        vm.prank(address(1002));
        multiSig.executeTransaction(txId);

        vm.expectRevert(IMultiSignatureWallet.InvalidTxnId.selector);
        revokeConfirmation(address(1001), txId);
    }

    /// @dev Test to ensure 'revokeConfirmation' removes the tx and emits 'TransactionExpired' if the transaction has expired.
    function testRevokeConfirmationRemovesTxIfExpired() public {
        vm.warp(500);
        testSubmitTransactionIncrement();

        vm.warp(10501);
        vm.expectEmit(true, false, false, false);
        emit IMultiSignatureWallet.TransactionExpired(0);
        
        revokeConfirmation(address(1001), 0);
        assertEq(multiSig.txCount(), 0);
    }

    /// @dev Test to ensure 'revokeConfirmation' reverts if the transaction was not confirmed.
    function testRevokeConfirmationRevertsIfTxNotConfirmed() public {
        testSubmitTransactionIncrement();

        vm.expectRevert(IMultiSignatureWallet.TransactionNotConfirmed.selector);
        revokeConfirmation(address(1002), 0);
    }

    /// @dev Test to ensure 'executeTransaction' executes a transaction.
    function testExecuteTransaction() public {
        testSubmitTransactionIncrement();

        uint256 txId = 0;
        grantSufficientConfirmations(txId);
        
        vm.prank(address(1001));
        multiSig.executeTransaction(txId);

        assertEq(multiSig.txCount(), 0);
        assertEq(counter.counter(), 1);
    }

    /// @dev Test to ensure 'executeTransaction' reverts if caller is not an owner.
    function testExecuteTransactionRevertsIfCallerNotOwner() public {
        testSubmitTransactionIncrement();

        vm.expectRevert(IMultiSignatureWallet.NotAnOwner.selector);

        vm.prank(alice);
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'executeTransaction' reverts if transaction does not exist.
    function testExecuteTransactionRevertsIfTxDoesNotExist() public {
        vm.expectRevert(IMultiSignatureWallet.InvalidTxnId.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(1);
    }

    /// @dev Test to ensure 'executeTransaction' reverts if transaction is already executed.
    function testExecuteTransactionRevertsIfTxAlreadyExecuted() public {
        testExecuteTransaction();

        vm.expectRevert(IMultiSignatureWallet.InvalidTxnId.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'executeTransaction' removes the tx and emits 'TransactionExpired' if transaction has expired.
    function testExecuteTransactionRemovesTxIfExpired() public {
        vm.warp(500);
        testSubmitTransactionIncrement();

        vm.warp(10501);
        vm.expectEmit(true, false, false, false);
        emit IMultiSignatureWallet.TransactionExpired(0);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);
        assertEq(multiSig.txCount(), 0);
    }

    /// @dev Test to ensure 'executeTransaction' reverts if the transaction has insufficient number of confirmations.
    function testExecuteTransactionRevertsIfInsufficientConfirmations() public {
        testSubmitTransactionIncrement();

        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);
        
        vm.expectRevert(IMultiSignatureWallet.NotEnoughConfirmation.selector);

        vm.prank(address(1001));
        multiSig.executeTransaction(txId);
    }

    /// @dev Helper function to build calldata to remove a single owner via multisig and execute it.
    /// @dev Submits from owner1 (implicit confirmation) then confirms with the three given confirmers before executing.
    function removeOwnerViaMultiSig(address _ownerToRemove, uint256 _txIndex, address _confirmer1, address _confirmer2, address _confirmer3) private {
        address[] memory ownersToRemove = new address[](1);
        ownersToRemove[0] = _ownerToRemove;
        bytes memory data = abi.encodeCall(MultiSignatureWallet.removeOwners, (ownersToRemove));
        submitTransactionToMultiSig(data);

        confirmTransaction(_confirmer1, _txIndex);
        confirmTransaction(_confirmer2, _txIndex);
        confirmTransaction(_confirmer3, _txIndex);

        vm.prank(address(1001));
        multiSig.executeTransaction(_txIndex);
    }

    /// @dev Test to ensure 'hasValidNumberOfConfirmations' reverts if the transaction does not exist.
    function testHasValidNumberOfConfirmationsRevertsIfTxDoesNotExist() public {
        vm.expectRevert(IMultiSignatureWallet.InvalidTxnId.selector);
        multiSig.hasValidNumberOfConfirmations(0);
    }

    /// @dev Test to ensure 'hasValidNumberOfConfirmations' stops counting confirmations from an owner once removed,
    /// @dev even though those confirmations were valid at the time they were given.
    function testHasValidNumberOfConfirmationsExcludesRemovedOwner() public {
        testSubmitTransactionIncrement(); // txId 0, implicitly confirmed by owner1 (address(1001))

        confirmTransaction(address(1002), 0);
        confirmTransaction(address(1003), 0);
        confirmTransaction(address(1004), 0);
        assertTrue(multiSig.hasValidNumberOfConfirmations(0)); // 4 confirmations, 4 required

        // Remove owner(1002), one of the addresses that confirmed txId 0, via a second multisig transaction.
        removeOwnerViaMultiSig(address(1002), 1, address(1003), address(1004), address(1005));

        // owner(1002)'s earlier confirmation of txId 0 must no longer count: 3 valid confirmations remain, 4 required.
        assertFalse(multiSig.hasValidNumberOfConfirmations(0));
    }

    /// @dev Test to ensure 'executeTransaction' reverts if a confirming owner is removed after confirming,
    /// @dev dropping the number of *currently valid* confirmations below the required threshold.
    /// @dev This guards against relying on the stale 'numConfirmations' counter, which is never decremented on owner removal.
    function testExecuteTransactionRevertsIfConfirmingOwnerRemovedAfterConfirmation() public {
        testSubmitTransactionIncrement(); // txId 0, implicitly confirmed by owner1 (address(1001))

        confirmTransaction(address(1002), 0);
        confirmTransaction(address(1003), 0);
        confirmTransaction(address(1004), 0);

        // Remove owner(1002), one of the addresses that confirmed txId 0, via a second multisig transaction.
        removeOwnerViaMultiSig(address(1002), 1, address(1003), address(1004), address(1005));

        vm.expectRevert(IMultiSignatureWallet.NotEnoughConfirmation.selector);

        vm.prank(address(1001));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'executeTransaction' still succeeds if an owner who did NOT confirm the transaction
    /// @dev is removed, since the remaining valid confirmations still satisfy the required threshold.
    function testExecuteTransactionSucceedsIfNonConfirmingOwnerRemoved() public {
        testSubmitTransactionIncrement(); // txId 0, implicitly confirmed by owner1 (address(1001))

        confirmTransaction(address(1002), 0);
        confirmTransaction(address(1003), 0);
        confirmTransaction(address(1004), 0);
        // owner(1005) never confirms txId 0.

        // Remove owner(1005), which did not confirm txId 0, via a second multisig transaction.
        removeOwnerViaMultiSig(address(1005), 1, address(1002), address(1003), address(1004));

        vm.prank(address(1001));
        multiSig.executeTransaction(0);

        assertEq(multiSig.txCount(), 0);
        assertEq(counter.counter(), 1);
    }

    /// @dev Helper function that returns calldata to transfer ownership.
    function dataToTransferOwnership() private view returns (bytes memory) {
        return abi.encodeCall(OwnableUpgradeable.transferOwnership, (alice));
    }

    /// @dev Test to ensure ownership transfer works correctly. 
    function testChangeOwnership() public {
        submitTransaction(dataToTransferOwnership());
        grantSufficientConfirmations(0);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(0);
        
        assertEq(counter.owner(), alice);
    }

    /// @dev Helper function to return calldata to add an owner in multisig.
    function dataToAddOwnerInMultiSig() private returns (bytes memory) {
        newOwners.push(address(5001));
        return abi.encodeCall(MultiSignatureWallet.addOwners, (newOwners));
    }

    /// @dev Helper function to submit a transaction to perform an action in the MultiSignatureWallet.
    function submitTransactionToMultiSig(bytes memory _data) private {
        vm.prank(address(1001));
        multiSig.submitTransaction(
            address(multiSig),
            0,
            10000,
            _data
        );
    }

    /// @dev Test to ensure 'addOwners' adds an array of owners in multisig.
    function testAddOwners() public {
        submitTransactionToMultiSig(dataToAddOwnerInMultiSig());
        grantSufficientConfirmations(0);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(0);

        address[] memory updatedOwners = multiSig.getOwners();
        assertEq(updatedOwners[5], newOwners[0]);
        assertEq(multiSig.getOwners().length, 6);
    }

    /// @dev Test to ensure 'addOwners' reverts if array of owners is empty.
    function testAddOwnersRevertsIfOwnersArrayEmpty() public {
        address[] memory emptyOwners;
        bytes memory data = abi.encodeCall(MultiSignatureWallet.addOwners, (emptyOwners));
        submitTransactionToMultiSig(data);

        grantSufficientConfirmations(0);

        vm.expectRevert(IMultiSignatureWallet.ExecutionFailed.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'addOwners' reverts if any of the owners is address(0).
    function testAddOwnersRevertsIfOwnerAddressZero() public {
        newOwners.push(address(0));
        submitTransactionToMultiSig(dataToAddOwnerInMultiSig());

        grantSufficientConfirmations(0);

        vm.expectRevert(IMultiSignatureWallet.ExecutionFailed.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'addOwners' reverts if caller is not an owner.
    function testAddOwnersRevertsIfCallerNotOwner() public {
        submitTransactionToMultiSig(dataToAddOwnerInMultiSig());    
        grantSufficientConfirmations(0);

        vm.expectRevert(IMultiSignatureWallet.NotAnOwner.selector);        

        vm.prank(alice);            // Not an owner
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'addOwners' removes the tx and emits 'TransactionExpired' if transaction has expired.
    function testAddOwnersRemovesTxIfExpired() public {
        vm.warp(500);
        submitTransactionToMultiSig(dataToAddOwnerInMultiSig());
        assertEq(multiSig.txCount(), 1);
    
        grantSufficientConfirmations(0);

        vm.warp(10501);
        vm.expectEmit(true, false, false, false);
        emit IMultiSignatureWallet.TransactionExpired(0);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);
        assertEq(multiSig.txCount(), 0);
    }

    /// @dev Test to ensure 'addOwners' reverts if transaction has insufficient number of confirmations.
    function testAddOwnersRevertsIfInsufficientConfirmations() public {
        submitTransactionToMultiSig(dataToAddOwnerInMultiSig());

        uint256 txId = 0;
        confirmTransaction(address(1004), txId);
        confirmTransaction(address(1005), txId);

        vm.expectRevert(IMultiSignatureWallet.NotEnoughConfirmation.selector);        
        
        vm.prank(address(1002));
        multiSig.executeTransaction(txId);
    }

    /// @dev Helper function to return calldata to remove an array of owners from multisig.
    function dataToRemoveOwnerFromMultiSig() private returns (bytes memory) {
        newOwners.push(address(1001));
        return abi.encodeCall(MultiSignatureWallet.removeOwners, (newOwners));
    }

    /// @dev Test to ensure 'removeOwners' removes an array of owners from multisig.
    function testRemoveOwners() public {
        testAddOwners();

        submitTransactionToMultiSig(dataToRemoveOwnerFromMultiSig());
        grantSufficientConfirmations(1);
                    
        vm.prank(address(1002));
        multiSig.executeTransaction(1);

        assertEq(multiSig.getOwners().length, 4);
    }

    /// @dev Test to ensure 'removeOwners' reverts if array of owners is empty.
    function testRemoveOwnersRevertsIfOwnersArrayEmpty() public {
        address[] memory emptyOwners;
        bytes memory data = abi.encodeCall(MultiSignatureWallet.removeOwners, (emptyOwners));
        submitTransactionToMultiSig(data);

        grantSufficientConfirmations(0);

        vm.expectRevert(IMultiSignatureWallet.ExecutionFailed.selector);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'removeOwners' reverts if number of owners goes below the number of confirmations required.
    function testRemoveOwnersRevertsIfNumOfOwnersGoesBelowNumConfirmations() public {
        newOwners.push(address(1003));
        newOwners.push(address(1004));
        newOwners.push(address(1005));

        bytes memory data = abi.encodeCall(MultiSignatureWallet.removeOwners, (newOwners));
        submitTransactionToMultiSig(data);

        grantSufficientConfirmations(0);

        vm.expectRevert(IMultiSignatureWallet.ExecutionFailed.selector);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'removeOwners' reverts if caller is not an owner.
    function testRemoveOwnersRevertsIfnotOwner() public {
        testAddOwners();

        submitTransactionToMultiSig(dataToRemoveOwnerFromMultiSig());
        
        grantSufficientConfirmations(1);

        vm.expectRevert(IMultiSignatureWallet.NotAnOwner.selector);
        
        vm.prank(alice);        // Not an owner
        multiSig.executeTransaction(1);
    }

    /// @dev Test to ensure 'removeOwners' removes the tx and emits 'TransactionExpired' if transaction has expired.
    function testRemoveOwnersRemovesTxIfExpired() public {
        testAddOwners();

        vm.warp(500);
        submitTransactionToMultiSig(dataToRemoveOwnerFromMultiSig());
        assertEq(multiSig.txCount(), 1);

        grantSufficientConfirmations(1);

        vm.warp(10501);
        vm.expectEmit(true, false, false, false);
        emit IMultiSignatureWallet.TransactionExpired(1);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(1);
        assertEq(multiSig.txCount(), 0);
    }

    /// @dev Test to ensure 'removeOwners' reverts if transaction has insufficient number of confirmations.
    function testRemoveOwnersRevertsIfInsufficientConfirmations() public {
        testAddOwners();
        
        submitTransactionToMultiSig(dataToRemoveOwnerFromMultiSig());

        uint256 txId = 1;
        confirmTransaction(address(1004), txId);
        confirmTransaction(address(1005), txId);

        vm.expectRevert(IMultiSignatureWallet.NotEnoughConfirmation.selector);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(txId);
    }

    /// @dev Helper to set up a tx with 4 confirmations, then execute removal of owner 1004.
    function prepareRemovedConfirmingOwner() private {
        testSubmitTransactionIncrement();
        grantSufficientConfirmations(0);

        address[] memory ownersToRemove = new address[](1);
        ownersToRemove[0] = address(1004);
        
        bytes memory data = abi.encodeCall(MultiSignatureWallet.removeOwners, (ownersToRemove));
        submitTransactionToMultiSig(data);

        confirmTransaction(address(1002), 1);
        confirmTransaction(address(1003), 1);
        confirmTransaction(address(1005), 1);

        vm.prank(address(1002));
        multiSig.executeTransaction(1);
    }

    /// @dev Test to ensure 'removeOwners' clears confirmations of removed owners.
    function testRemoveOwnersClearsConfirmations() public {
        assertEq(multiSig.getOwners().length, 5);
        prepareRemovedConfirmingOwner();

        assertEq(multiSig.getOwners().length, 4);

        assertFalse(multiSig.isConfirmed(0, address(1004)));

        ( , , uint256 confirmations, , ) = multiSig.getTransaction(0);
        assertEq(confirmations, 3);
    }

    /// @dev Test to ensure 'executeTransaction' reverts if a confirming owner was removed.
    function testExecuteTransactionRevertsIfConfirmingOwnerRemoved() public {
        prepareRemovedConfirmingOwner();
        assertFalse(multiSig.isConfirmed(0, address(1004)));

        vm.expectRevert(IMultiSignatureWallet.NotEnoughConfirmation.selector);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure removing a non-confirming owner does not affect execution.
    function testRemoveNonConfirmingOwnerDoesNotAffectTx() public {
        testSubmitTransactionIncrement();
        grantSufficientConfirmations(0);

        address[] memory ownersToRemove = new address[](1);
        ownersToRemove[0] = address(1005);
        
        bytes memory data = abi.encodeCall(MultiSignatureWallet.removeOwners, (ownersToRemove));
        submitTransactionToMultiSig(data);

        confirmTransaction(address(1002), 1);
        confirmTransaction(address(1003), 1);
        confirmTransaction(address(1004), 1);

        vm.prank(address(1002));
        multiSig.executeTransaction(1);

        assertEq(multiSig.getOwners().length, 4);

        // tx0 still has 4 confirmations from current owners — should execute
        vm.prank(address(1002));
        multiSig.executeTransaction(0);

        assertEq(counter.counter(), 1);
    }

    /// @dev Test to ensure execution succeeds when enough confirmations remain after removal.
    function testExecuteTransactionSucceedsWithEnoughRemaining() public {
        // tx0 (index 0): Lower threshold from 4 to 3
        submitTransactionToMultiSig(dataToUpdateNumConfimationsMultiSig(3));
        grantSufficientConfirmations(0);
        vm.prank(address(1002));
        multiSig.executeTransaction(0);
        assertEq(multiSig.numConfirmationsRequired(), 3);

        // tx1 (index 1): Submit and confirm increment with 4 confirmations
        submitTransaction(dataForIncrement());
        grantSufficientConfirmations(1);

        // tx2 (index 2): Remove owner 1004
        address[] memory ownersToRemove = new address[](1);
        ownersToRemove[0] = address(1004);
        bytes memory data = abi.encodeCall(MultiSignatureWallet.removeOwners, (ownersToRemove));
        submitTransactionToMultiSig(data);

        confirmTransaction(address(1002), 2);
        confirmTransaction(address(1003), 2);
        confirmTransaction(address(1005), 2);

        vm.prank(address(1002));
        multiSig.executeTransaction(2);

        assertEq(multiSig.getOwners().length, 4);
        ( , , uint24 numConfirmations, , ) = multiSig.getTransaction(1);
        assertEq(numConfirmations, 3);

        // tx1 has 3 remaining confirmations (1001, 1002, 1003) >= threshold 3
        vm.prank(address(1002));
        multiSig.executeTransaction(1);

        assertEq(counter.counter(), 1);
    }

    /// @dev Test to ensure a removed and re-added owner must re-confirm transactions.
    function testRemovedOwnerReAddedNeedsReConfirmation() public {
        prepareRemovedConfirmingOwner();
        assertEq(multiSig.getOwners().length, 4);

        // tx2 (index 2): Re-add owner 1004
        address[] memory ownersToAdd = new address[](1);
        ownersToAdd[0] = address(1004);
        
        bytes memory addData = abi.encodeCall(MultiSignatureWallet.addOwners, (ownersToAdd));
        submitTransactionToMultiSig(addData);

        confirmTransaction(address(1002), 2);
        confirmTransaction(address(1003), 2);
        confirmTransaction(address(1005), 2);

        vm.prank(address(1002));
        multiSig.executeTransaction(2);

        assertEq(multiSig.getOwners().length, 5);

        // Old confirmation should be gone
        assertFalse(multiSig.isConfirmed(0, address(1004)));

        // tx0 should still fail (only 3 confirmations from current owners)
        vm.expectRevert(IMultiSignatureWallet.NotEnoughConfirmation.selector);
        vm.prank(address(1002));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure removing an owner clears confirmations across all pending transactions.
    function testRemoveOwnersClearsConfirmationsAcrossMultipleTxs() public {
        bytes memory data = dataForIncrement();

        // tx0 (index 0): 4 confirmations including 1004
        submitTransaction(data);
        grantSufficientConfirmations(0);

        // tx1 (index 1): 4 confirmations also including 1004
        submitTransaction(data);    
        grantSufficientConfirmations(1);

        // tx2 (index 2): Remove owner 1004
        address[] memory ownersToRemove = new address[](1);
        ownersToRemove[0] = address(1004);
        bytes memory removeData = abi.encodeCall(MultiSignatureWallet.removeOwners, (ownersToRemove));
        submitTransactionToMultiSig(removeData);

        confirmTransaction(address(1002), 2);
        confirmTransaction(address(1003), 2);
        confirmTransaction(address(1005), 2);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(2);

        // 1004's confirmation cleared from both txs
        assertFalse(multiSig.isConfirmed(0, address(1004)));
        assertFalse(multiSig.isConfirmed(1, address(1004)));

        // numConfirmations decremented in both txs
        ( , , uint256 confs0, , ) = multiSig.getTransaction(0);
        ( , , uint256 confs1, , ) = multiSig.getTransaction(1);
        assertEq(confs0, 3);
        assertEq(confs1, 3);
    }

    /// @dev Helper function to return calldata to update the number of confirmations required in the multisig.
    function dataToUpdateNumConfimationsMultiSig(uint256 _num) private pure returns (bytes memory) {
        return abi.encodeCall(MultiSignatureWallet.updateNumConfirmations, (_num));
    }

    /// @dev Test to ensure 'updateNumConfirmations' updates the number of confirmations required.
    function testUpdateNumConfimations() public {
        submitTransactionToMultiSig(dataToUpdateNumConfimationsMultiSig(3));
        grantSufficientConfirmations(0);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);

        assertEq(multiSig.numConfirmationsRequired(), 3);
    }

    /// @dev Test to ensure 'updateNumConfirmations' reverts if the number of confirmations required is zero.
    function testUpdateNumConfimationsRevertsIfNumConfirmationsZero() public {
        submitTransactionToMultiSig(dataToUpdateNumConfimationsMultiSig(0));
        grantSufficientConfirmations(0);

        vm.expectRevert(IMultiSignatureWallet.ExecutionFailed.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'updateNumConfirmations' reverts if the number of confirmations required is more than the number of owners.
    function testUpdateNumConfimationsRevertsIfNumConfirmationsMoreThanOwners() public {
        submitTransactionToMultiSig(dataToUpdateNumConfimationsMultiSig(6));
        grantSufficientConfirmations(0);

        vm.expectRevert(IMultiSignatureWallet.ExecutionFailed.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'updateNumConfirmations' reverts if the caller is not an owner.
    function testUpdateNumConfimationsRevertsIfNotOwner() public {
        submitTransactionToMultiSig(dataToUpdateNumConfimationsMultiSig(3));
        grantSufficientConfirmations(0);

        vm.expectRevert(IMultiSignatureWallet.NotAnOwner.selector);

        vm.prank(alice);        // Not an owner
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'updateNumConfirmations' removes the tx and emits 'TransactionExpired' if the transaction has expired.
    function testUpdateNumConfimationsRemovesTxIfExpired() public {
        vm.warp(500);
        submitTransactionToMultiSig(dataToUpdateNumConfimationsMultiSig(3));
        assertEq(multiSig.txCount(), 1);

        grantSufficientConfirmations(0);

        vm.warp(10501);
        vm.expectEmit(true, false, false, false);
        emit IMultiSignatureWallet.TransactionExpired(0);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);    
        assertEq(multiSig.txCount(), 0);
    }

    /// @dev Test to ensure 'updateNumConfirmations' reverts if the transaction has insufficient number of confirmations.
    function testUpdateNumConfimationsRevertsIfInsufficientConfirmations() public {
        submitTransactionToMultiSig(dataToUpdateNumConfimationsMultiSig(3));

        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);

        vm.expectRevert(IMultiSignatureWallet.NotEnoughConfirmation.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(txId);
    }

    
    /// @dev Test to ensure 'upgradeTo' upgrades the implementation address of the beacon.
    function testUpgradeBeacon() public {
        MultiSignatureWallet implV2 = new MultiSignatureWallet();
        bytes memory data = abi.encodeWithSelector(UpgradeableBeacon.upgradeTo.selector, address(implV2));

        vm.prank(address(1001));
        multiSig.submitTransaction(
            address(beacon),
            0,
            100000,
            data
        );

        grantSufficientConfirmations(0);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);

        assertEq(beacon.implementation(), address(implV2));
        assertNotEq(beacon.implementation(), multiSigImplV1);
    }

    /// @dev Test to ensure 'upgradeTo' reverts if caller is not the owner.  
    function testUpgradeBeaconRevertIfNotOwner() public {        
        MultiSignatureWallet implV2 = new MultiSignatureWallet();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        
        vm.prank(alice);
        beacon.upgradeTo(address(implV2));
    }
    
    /// @dev Helper function to submit a transaction for contract deployment and grant sufficient confirmations.
    function submitToDeploy(bytes memory _creationCode, uint256 _value, uint256 _txIndex) private {
        bytes memory data = abi.encodeCall(MultiSignatureWallet.deployContract, (_creationCode, _value));
        submitTransactionToMultiSig(data);
        grantSufficientConfirmations(_txIndex);   
    }

    /// @dev Helper function that returns creation code to deploy ERC1967 proxy contract.
    function proxyCreationCode(address _impl) private view returns (bytes memory) {
        bytes memory initData = abi.encodeCall(Counter.initialize, (address(multiSig)));        
        
        return abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(_impl, initData)
        );
    }

    /// @dev Test to ensure 'deployContract' deploys contract and assigns MultiSig as contract owner.
    function testDeployContract() public {
        // Deploy implementation
        submitToDeploy(type(Counter).creationCode, 0, 0);
        
        vm.prank(address(1002));
        bytes memory dataImpl =  multiSig.executeTransaction(0);
        address impl = abi.decode(dataImpl, (address));

        
        // Deploy proxy
        bytes memory creationCode = proxyCreationCode(impl);        
        submitToDeploy(creationCode, 0, 1);

        vm.prank(address(1002));
        bytes memory dataProxy =  multiSig.executeTransaction(1);
        address proxy = abi.decode(dataProxy, (address));
        assertEq(Counter(proxy).owner(), address(multiSig));
    }

    /// @dev Test to ensure 'deployContract' reverts if caller is not MultiSig itself.
    function testDeployContractRevertsIfCallerNotMultiSig() public {
        bytes memory creationCode = type(Counter).creationCode;

        vm.expectRevert(IMultiSignatureWallet.OnlyMultisigAccountCanCall.selector);

        vm.prank(alice);
        multiSig.deployContract(creationCode, 0);
    }

    /// @dev Test to ensure 'deployContract' reverts if contract creation code is empty.
    function testDeployContractRevertsIfCreationCodeEmpty() public {
        // Deploy implementation
        submitToDeploy("", 0, 0);   // Empty creation code
        
        vm.expectRevert(IMultiSignatureWallet.ExecutionFailed.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'deployContract' reverts if initialize function is non-payable.
    function testDeployContractRevertsIfInitializerNonPayable() public {
        vm.deal(address(multiSig), 4 ether);

        // Deploy implementation
        submitToDeploy(type(Counter).creationCode, 0, 0);
        
        vm.prank(address(1002));
        bytes memory dataImpl =  multiSig.executeTransaction(0);
        address impl = abi.decode(dataImpl, (address));

        
        // Deploy proxy
        bytes memory creationCode = proxyCreationCode(impl);        
        submitToDeploy(creationCode, 1 ether, 1);

        vm.expectRevert(IMultiSignatureWallet.ExecutionFailed.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(1);
    }

    /// @dev Test to ensure 'deployContract' reverts if creation code is invalid.
    function testDeployContractRevertsIfInvalidCreationCode() public {
        // Deploy implementation
        submitToDeploy(hex"f1", 0, 0);  // Invalid creation code

        vm.expectRevert(IMultiSignatureWallet.ExecutionFailed.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(0);
    }

    /// @dev Test to ensure 'receive' works correctly.
    function testReceive() public {
        assertEq(address(multiSig).balance, 0);

        // Send ETH to multisig
        vm.prank(alice);
        (bool success, ) = address(multiSig).call{value: 1 ether}("");
        assertTrue(success);

        assertEq(address(multiSig).balance, 1 ether);
    }

    /// @dev Test to ensure 'receive' emits event 'Deposit'.
    function testReceiveEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IMultiSignatureWallet.Deposit(alice, 1 ether, 1 ether);

        testReceive();
    }

    /// @dev Test to ensure 'getTransaction' reverts if transaction does not exist.
    function testGetTransactionRevertsIfTxDoesNotExist() public {
        vm.expectRevert(IMultiSignatureWallet.InvalidTxnId.selector);
        multiSig.getTransaction(0);
    }
    
    /// @dev Test to ensure expired transaction is removed and accessing it results in a revert.
    function testGetTransactionRevertsIfTxExpiredAndCleanedUp() public {
        vm.warp(500);
        testSubmitTransactionIncrement();

        vm.warp(10501);
        confirmTransaction(address(1005), 0);
        assertEq(multiSig.txCount(), 0);

        vm.expectRevert(IMultiSignatureWallet.InvalidTxnId.selector);
        multiSig.getTransaction(0);
    }

    /// @dev Test to ensure 'getNextTransactionIndex' returns correct value.
    function testGetNextTransactionIndex() public {
        assertEq(multiSig.getNextTransactionIndex(), 0);

        testSubmitTransactionIncrement();

        assertEq(multiSig.getNextTransactionIndex(), 1);
    }
}
