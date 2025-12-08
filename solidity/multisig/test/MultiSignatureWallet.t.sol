// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import {console} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";
import {BlockMeta} from "../src/BlockMeta.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "../lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {Ownable2StepUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {MultiSignatureWallet} from "../src/MultiSignatureWallet.sol";
import {MultisigBeacon} from "../src/MultisigBeacon.sol";

contract Multisig is Test {
    BlockMeta blockMeta;
    MultisigBeacon beacon;
    MultiSignatureWallet multiSig;

    address[] owners;
    address[] newOwners;
    address alice = address(0xA11CE);

    /// @dev Sets up initial state for testing.
    /// @dev Deploys all required contracts.
    function setUp() public {
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
        MultiSignatureWallet multisigImpl = new MultiSignatureWallet();
        beacon = new MultisigBeacon(address(multisigImpl));
        
        // Deploy BeaconProxy for MultiSig
        bytes memory multiSigInitData = abi.encodeCall(MultiSignatureWallet.initialize, (owners, 4));
        BeaconProxy multisigProxy = new BeaconProxy(address(beacon), multiSigInitData);
        multiSig = MultiSignatureWallet(payable(multisigProxy));
        
        // Transfer Beacon's ownership to multisig
        beacon.transferOwnership(address(multisigProxy));
        vm.stopPrank();


        vm.startPrank(address(multisigProxy));
        // Deploy BlockMeta proxy contract
        BlockMeta blockMetaImpl = new BlockMeta();
        bytes memory blockMetaInitData = abi.encodeCall(BlockMeta.initialize, ());
        ERC1967Proxy blockMetaProxy = new ERC1967Proxy(address(blockMetaImpl), blockMetaInitData);
        blockMeta = BlockMeta(address(blockMetaProxy));
        vm.stopPrank();
    }
    
    /// @dev Helper function that returns calldata to set automation controller in BlockMeta. 
    function dataToSetAutomationController(address _controller) private pure returns (bytes memory) {
        return (abi.encodeCall(BlockMeta.setAutomationController, (_controller)));
    }

    /// @dev Helper function that returns calldata to transfer ownership.
    function dataToTransferOwnership() private view returns (bytes memory) {
        return abi.encodeCall(Ownable2StepUpgradeable.transferOwnership, (alice));
    }

    /// @dev Test to ensure ownership is initialized correctly. 
    function testOwner() public view {
        assertEq(beacon.owner(), address(multiSig));
        assertEq(blockMeta.owner(), address(multiSig));
    }

    /// @dev Test to ensure owners and number of confirmations required are initialized correctly.
    function testInitialize() public view {
        assertEq(multiSig.getOwners(), owners);
        assertEq(multiSig.numConfirmationsRequired(), 4);
    }

    /// @dev Test to ensure 'initialize' reverts if array of owners is empty.
    function testInitializeRevertsIfOwnersArrayEmpty() public {
        address[] memory emptyOwners;        
        vm.expectRevert(MultiSignatureWallet.OwnersRequired.selector);

        bytes memory initData = abi.encodeCall(MultiSignatureWallet.initialize, (emptyOwners, 1));
        new BeaconProxy(address(beacon), initData);
    }

    /// @dev Test to ensure 'initialize' reverts if number of confirmations required is zero.
    function testInitializeRevertsIfNumConfirmationsZero() public {
        vm.expectRevert(MultiSignatureWallet.InvalidNumberOfConfirmations.selector);

        bytes memory initData = abi.encodeCall(MultiSignatureWallet.initialize, (owners, 0));
        new BeaconProxy(address(beacon), initData);
    }

    /// @dev Test to ensure 'initialize' reverts if number of confirmations required is more than the number of owners.
    function testInitializeRevertsIfNumConfirmationsMoreThanOwners() public {
        vm.expectRevert(MultiSignatureWallet.InvalidNumberOfConfirmations.selector);

        bytes memory initData = abi.encodeCall(MultiSignatureWallet.initialize, (owners, 6));
        new BeaconProxy(address(beacon), initData);
    }

    /// @dev Test to ensure 'initialize' reverts if any of the owner is address(0).
    function testInitializeRevertsIfInvalidOwner() public {
        address[] memory invalidOwners = new address[](3);
        invalidOwners[0] = address(1001);
        invalidOwners[1] = address(0);          // Invalid owner
        invalidOwners[2] = address(1002);

        vm.expectRevert(MultiSignatureWallet.InvalidOwner.selector);

        bytes memory initData = abi.encodeCall(MultiSignatureWallet.initialize, (invalidOwners, 1));
        new BeaconProxy(address(beacon), initData);
    }

    /// @dev Test to ensure 'initialize' reverts if a duplicate owner is passed.
    function testInitializeRevertsIfDuplicateOwner() public {
        address[] memory duplicateOwners = new address[](3);
        duplicateOwners[0] = address(1001);
        duplicateOwners[1] = address(1001);       // Duplicate owner
        duplicateOwners[2] = address(1002);

        vm.expectRevert(MultiSignatureWallet.OwnerNotUnique.selector);

        bytes memory initData = abi.encodeCall(MultiSignatureWallet.initialize, (duplicateOwners, 1));
        new BeaconProxy(address(beacon), initData);
    }


    /// @dev Helper function to submit a transaction to perform an action in the BlockMeta contract.
    function submitTransaction(bytes memory _data) private {
        vm.prank(address(1001));
        multiSig.submitTransaction(
            address(blockMeta),
            0,
            10000,
            _data
        );
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

    /// @dev Helper function to revoke confirmation.
    function revokeConfirmation(address _owner, uint256 _txIndex) private {
        vm.prank(_owner);
        multiSig.revokeConfirmation(_txIndex);
    }

    /// @dev Helper function to confirm a transaction.
    function confirmTransaction(address _owner, uint256 txnId) private {
        vm.prank(_owner);
        multiSig.confirmTransaction(txnId);
    }

    /// @dev Test to ensure 'submitTransaction' submits a transaction.
    function testSubmitTransactionSetAutomationController() public {
        BlockMeta impl = new BlockMeta();
        bytes memory data = dataToSetAutomationController(address(impl));
        submitTransaction(data);
        
        (address to, uint256 value, bool executed, uint24 numConfirmations, uint64 timeout, bytes memory storedData) = multiSig.getTransaction(0);
        assertEq(to, address(blockMeta));
        assertEq(value, 0);
        assertEq(executed, false);
        assertEq(numConfirmations, 1);
        assertEq(timeout, block.timestamp + 10000);
        assertEq(storedData, data);
    }

    /// @dev Test to ensure 'revokeConfirmation' revokes the confirmation of an owner.
    function testRevokeConfirmation() public {
        testSubmitTransactionSetAutomationController();
        
        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        revokeConfirmation(address(1001), txId);
        (, , , uint256 confirmations , ,) = multiSig.getTransaction(txId);
        assertEq(confirmations, 1);
    }

    /// @dev Test to ensure 'revokeConfirmation' reverts if an invalid transaction id is passed.
    function testRevokeConfirmationRevertsIfInvalidTxId() public {
        testSubmitTransactionSetAutomationController();
        
        vm.expectRevert(MultiSignatureWallet.InvalidTxnId.selector);
        revokeConfirmation(address(1001), 1);
    }

    /// @dev Test to ensure 'submitTransaction' reverts if caller is not an owner.
    function testSubmitTransactionSetAutomationControllerRevertsIfNotOwner() public {
        BlockMeta impl = new BlockMeta();
        bytes memory data = dataToSetAutomationController(address(impl));

        vm.expectRevert(MultiSignatureWallet.NotAnOwner.selector);

        vm.prank(alice);                    // Not an owner
        multiSig.submitTransaction(
            address(blockMeta),
            0,
            100000,
            data
        );
    }

    /// @dev Test to ensure 'confirmTransaction' confirms a transaction.
    function testConfirmTransactionSetAutomationController() public {
        testSubmitTransactionSetAutomationController();
        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);
        confirmTransaction(address(1004), txId);

        ( , , , uint256 numConfirmations, ,) = multiSig.getTransaction(txId);
        assertEq(numConfirmations, 4);
    }

    /// @dev Test to ensure 'confirmTransaction' reverts if caller is not an owner.
    function testConfirmTransactionRevertsIfNotOwner() public {
        testSubmitTransactionSetAutomationController();

        vm.expectRevert(MultiSignatureWallet.NotAnOwner.selector);
        confirmTransaction(alice, 0);      // Not an owner
    }

    /// @dev Test to ensure 'confirmTransaction' reverts if tx id does not exist.
    function testConfirmTransactionRevertsIfTxDoesNotExist() public {
        testSubmitTransactionSetAutomationController();

        vm.expectRevert(MultiSignatureWallet.InvalidTxnId.selector);
        confirmTransaction(address(1002), 1);
    }

    /// @dev Test to ensure 'confirmTransaction' reverts if transaction is already confirmed.
    function testConfirmTransactionRevertsIfTxAlreadyConfirmed() public {
        BlockMeta impl = new BlockMeta();
        bytes memory data = dataToSetAutomationController(address(impl));
        submitTransaction(data);
        
        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);
        confirmTransaction(address(1004), txId);

        vm.expectRevert(MultiSignatureWallet.TxnAlreadyConfirmed.selector);
        confirmTransaction(address(1001), txId);
    }

    /// @dev Test to ensure 'executeTransaction' reverts if the transaction has insufficient number of confirmations.
    function testExecuteTransactionRevertsIfInsufficientConfirmations() public {
        testSubmitTransactionSetAutomationController();

        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);
        
        vm.expectRevert(MultiSignatureWallet.NotEnoughConfirmation.selector);

        vm.prank(address(1001));
        multiSig.executeTransaction(txId);
    }

    /// @dev Test to ensure ownership transfer works correctly. 
    function testChangeOwnership() public {
        submitTransaction(dataToTransferOwnership());
        
        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);
        confirmTransaction(address(1004), txId);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(txId);
        
        vm.prank(alice);
        blockMeta.acceptOwnership();

        assertEq(blockMeta.owner(), alice);
    }

    /// @dev Helper function to return calldata to add an owner in multisig.
    function dataToAddOwnerInMultiSig() private returns (bytes memory) {
        newOwners.push(address(5001));
        return abi.encodeCall(MultiSignatureWallet.addOwners, (newOwners));
    }

    /// @dev Test to ensure 'addOwners' adds an array of owners in multisig.
    function testAddOwners() public {
        submitTransactionToMultiSig(dataToAddOwnerInMultiSig());

        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);
        confirmTransaction(address(1004), txId);
        confirmTransaction(address(1005), txId);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(txId);

        address[] memory updatedOwners = multiSig.getOwners();
        assertEq(updatedOwners[5], newOwners[0]);
        assertEq(multiSig.getOwners().length, 6);
    }

    /// @dev Test to ensure 'addOwners' reverts if transaction has insufficient number of confirmations.
    function testAddOwnerRevertsIfInsufficientConfirmations() public {
        submitTransactionToMultiSig(dataToAddOwnerInMultiSig());

        uint256 txId = 0;
        confirmTransaction(address(1004), txId);
        confirmTransaction(address(1005), txId);

        vm.expectRevert(MultiSignatureWallet.NotEnoughConfirmation.selector);        
        
        vm.prank(address(1002));
        multiSig.executeTransaction(txId);
    }

    /// @dev Test to ensure 'addOwners' reverts if transaction has expired.
    function testAddOwnerRevertsIfTimestampExpired() public {
        vm.warp(500);
        submitTransactionToMultiSig(dataToAddOwnerInMultiSig());
    
        uint256 txId = 0;
        confirmTransaction(address(1004), txId);
        confirmTransaction(address(1005), txId);

        vm.warp(10501);
        vm.expectRevert(MultiSignatureWallet.TransactionAlreadyExpired.selector);        

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
        
        uint256 txId = 1;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);
        confirmTransaction(address(1004), txId);
        confirmTransaction(address(1005), txId);
                    
        vm.prank(address(1002));
        multiSig.executeTransaction(txId);

        assertEq(multiSig.getOwners().length, 4);
    }

    /// @dev Test to ensure 'removeOwners' reverts if transaction has expired.
    function testRemoveOwnerRevertsIfTimestampExpired() public {
        testAddOwners();

        vm.warp(500);
        submitTransactionToMultiSig(dataToRemoveOwnerFromMultiSig());

        uint256 txId = 1;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);
        confirmTransaction(address(1004), txId);
        confirmTransaction(address(1005), txId);

        vm.warp(10501);
        vm.expectRevert(MultiSignatureWallet.TransactionAlreadyExpired.selector);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(txId);
    }

    /// @dev Test to ensure 'removeOwners' reverts if transaction has insufficient number of confirmations.
    function testRemoveOwnerRevertsIfInsufficientConfirmations() public {
        testAddOwners();
        
        submitTransactionToMultiSig(dataToRemoveOwnerFromMultiSig());

        uint256 txId = 1;
        confirmTransaction(address(1004), txId);
        confirmTransaction(address(1005), txId);

        vm.expectRevert(MultiSignatureWallet.NotEnoughConfirmation.selector);
        
        vm.prank(address(1002));
        multiSig.executeTransaction(txId);
    }

    /// @dev Test to ensure 'removeOwners' reverts if caller is not an owner.
    function testRemoveOwnerRevertsIfnotOwner() public {
        testAddOwners();

        submitTransactionToMultiSig(dataToRemoveOwnerFromMultiSig());
        
        uint256 txId = 1;
        confirmTransaction(address(1004), txId);
        confirmTransaction(address(1005), txId);

        vm.expectRevert(MultiSignatureWallet.NotAnOwner.selector);
        
        vm.prank(alice);        // Not an owner
        multiSig.executeTransaction(txId);
    }

    /// @dev Helper function to return calldata to update the number of confirmations required in the multisig.
    function dataToUpdateNumConfimationsMultiSig(uint256 _num) private pure returns (bytes memory) {
        return abi.encodeCall(MultiSignatureWallet.updateNumConfirmations, (_num));
    }

    /// @dev Test to ensure 'updateNumConfirmations' updates the number of confirmations required.
    function testUpdateNumConfimations() public {
        submitTransactionToMultiSig(dataToUpdateNumConfimationsMultiSig(3));
        
        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);
        confirmTransaction(address(1004), txId);
        confirmTransaction(address(1005), txId);

        vm.prank(address(1002));
        multiSig.executeTransaction(txId);

        assertEq(multiSig.numConfirmationsRequired(), 3);
    }

    /// @dev Test to ensure 'updateNumConfirmations' reverts if the transaction has insufficient number of confirmations.
    function testUpdateNumConfimationsRevertsIfInsufficientConfirmations() public {
        submitTransactionToMultiSig(dataToUpdateNumConfimationsMultiSig(3));

        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);

        vm.expectRevert(MultiSignatureWallet.NotEnoughConfirmation.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(txId);
    }

    /// @dev Test to ensure 'updateNumConfirmations' reverts if the caller is not an owner.
    function testUpdateNumConfimationsRevertsIfNotOwner() public {
        submitTransactionToMultiSig(dataToUpdateNumConfimationsMultiSig(3));

        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);

        vm.expectRevert(MultiSignatureWallet.NotAnOwner.selector);

        vm.prank(alice);        // Not an owner
        multiSig.executeTransaction(txId);
    }

    /// @dev Test to ensure 'updateNumConfirmations' reverts if the transaction has expired.
    function testUpdateNumConfimationsRevertsIftimestampExpired() public {
        vm.warp(500);
        submitTransactionToMultiSig(dataToUpdateNumConfimationsMultiSig(3));

        uint256 txId = 0;
        confirmTransaction(address(1002), txId);
        confirmTransaction(address(1003), txId);
        confirmTransaction(address(1004), txId);
        confirmTransaction(address(1005), txId);

        vm.warp(10501);
        vm.expectRevert(MultiSignatureWallet.TransactionAlreadyExpired.selector);

        vm.prank(address(1002));
        multiSig.executeTransaction(txId);        
    }
}
