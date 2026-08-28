// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMultiSignatureWallet} from "./interfaces/IMultiSignatureWallet.sol";

/**
 * @title MultiSignatureWallet
 * @dev A multisignature wallet contract that requires multiple owners to confirm transactions.
 */
contract MultiSignatureWallet is Initializable, IMultiSignatureWallet {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private owners;
    uint256 public numConfirmationsRequired;

    /// @dev Default cap on submitTransaction's timeout duration, seeded at initialize() and
    ///      adjustable afterwards via updateMaxTimeoutDuration.
    uint64 private constant DEFAULT_MAX_TIMEOUT_DURATION = 30 days;

    /// @notice Maximum timeout duration, in seconds, allowed for a newly submitted transaction.
    uint64 public maxTimeoutDuration;

    // Structure to hold transaction details
    struct Transaction {
        address to; // Transaction target address
        uint64 timeout; // Expiry timestamp of the transaction
        uint256 value; // Amount of ether sent with the transaction
        bytes data; // Data payload of the transaction
    }

    // Mapping to track confirmations for each transaction.
    mapping(uint256 => EnumerableSet.AddressSet) private confirmations;

    // Mapping from transaction index to Transaction
    mapping(uint256 => Transaction) private transactions;

    // Auto-incrementing transaction index
    uint256 private txIndex;

    // Number of active transactions
    uint256 public txCount;

    /// @dev Bumped whenever numConfirmationsRequired is lowered. A confirmation is only valid if
    ///      it was stamped under the current value (see confirmationTxEpoch), so a threshold
    ///      decrease can never retroactively satisfy a transaction that fell short of the old,
    ///      higher threshold - every owner (including the original submitter) must re-confirm.
    ///      Deliberately a plain counter compared live, rather than a bulk "clear all existing
    ///      confirmations" step: Solidity's `delete` cannot clear a nested mapping (like
    ///      EnumerableSet's internal position-tracking mapping), so a bulk clear of an
    ///      still-in-use confirmation set would leave stale membership behind. Comparing
    ///      per-confirmation stamps against this live counter sidesteps that entirely.
    uint32 private currentEpoch;

    /// @dev Per-owner "incarnation" counter, bumped once whenever that address is removed via
    ///      removeOwners. A confirmation is only valid if it was stamped under the owner's
    ///      current incarnation (see ownerConfirmationEpoch), so if a removed owner is later
    ///      re-added, any confirmation they left behind before removal no longer counts.
    mapping(address => uint32) private ownerEpoch;

    /// @dev Records, per (txIndex, owner), the ownerEpoch value the owner's confirmation was
    ///      stamped under. Compared against the owner's current ownerEpoch to decide validity.
    mapping(uint256 => mapping(address => uint32)) private ownerConfirmationEpoch;

    /// @dev Records, per (txIndex, owner), the currentEpoch value the owner's confirmation was
    ///      stamped under. Compared against the live currentEpoch to decide validity.
    mapping(uint256 => mapping(address => uint32)) private confirmationTxEpoch;

    // Function to ensure the caller is an owner
    function onlyOwner(address owner) private view {
        if (!owners.contains(owner))
        revert NotAnOwner();
    }

    // Function to ensure the caller is the multisig contract itself
    function onlyMultiSig() private view {
        if (msg.sender != address(this)) {
            revert OnlyMultisigAccountCanCall();
        }
    }

    // Function to check if a transaction exists
    function txExists(uint256 _txIndex) private view {
        if (transactions[_txIndex].to == address(0))
        revert InvalidTxnId();
    }

    /// @dev Reverts if the transaction's timeout has passed but it hasn't been swept from storage
    ///      yet. View-only: never mutates state. Actual cleanup happens via
    ///      removeExpiredTransaction. Uses a distinct error from txExists so callers can tell an
    ///      expired transaction apart from one that never existed.
    function notExpired(uint256 _txIndex) private view {
        if (transactions[_txIndex].timeout < block.timestamp) revert TransactionAlreadyExpired();
    }

    /// @dev Whether owner's confirmation on _txIndex is still valid: they must still be a member
    ///      of the confirmation set, their confirmation must have been stamped under their
    ///      current owner-incarnation, AND it must have been stamped under the current
    ///      threshold-epoch. The membership check must come first: a never-confirmed owner has
    ///      both epoch mappings defaulting to 0, which would otherwise spuriously read as valid
    ///      whenever ownerEpoch/currentEpoch also happen to still be 0.
    function _isOwnerConfirmationValid(uint256 _txIndex, address owner) private view returns (bool) {
        return confirmations[_txIndex].contains(owner) &&
            ownerConfirmationEpoch[_txIndex][owner] == ownerEpoch[owner] &&
            confirmationTxEpoch[_txIndex][owner] == currentEpoch;
    }

    /// @dev Counts confirmations from current valid owners only.
    /// @param _txIndex Index of the transaction to count confirmations for.
    /// @return uint24 Number of confirmations from current valid owners.
    function validNumberOfConfirmations(uint256 _txIndex) private view returns (uint24) {
        EnumerableSet.AddressSet storage confirmation = confirmations[_txIndex];
        uint24 validNumOfConfirmations = 0;
        for (uint64 i = 0; i < confirmation.length(); i++) {
            address owner = confirmation.at(i);
            if (owners.contains(owner) && _isOwnerConfirmationValid(_txIndex, owner)) {
                validNumOfConfirmations++;
            }
        }
        return validNumOfConfirmations;
    }

    /// @dev Helper function to remove a transaction from storage.
    /// @param _txIndex Index of the transaction to remove.
    function removeTransaction(uint256 _txIndex) private {
        // Remove the transaction from storage
        delete transactions[_txIndex];

        // Remove confirmations mapping
        delete confirmations[_txIndex];

        txCount--;
    }

    // Function to check if a transaction has not been confirmed by the caller
    function notConfirmed(uint256 _txIndex) private view {
        if (_isOwnerConfirmationValid(_txIndex, msg.sender)) revert TxnAlreadyConfirmed();
    }

    /// @dev Records owner's confirmation of _txIndex, stamping both epochs current at the time of
    ///      confirmation. Shared by submitTransaction's implicit self-confirmation and
    ///      confirmTransaction so the two paths can't drift apart.
    function _recordConfirmation(uint256 _txIndex, address owner) private {
        confirmations[_txIndex].add(owner);
        ownerConfirmationEpoch[_txIndex][owner] = ownerEpoch[owner];
        confirmationTxEpoch[_txIndex][owner] = currentEpoch;
    }

    /**
     * @dev Disables the initialization for the implementation contract.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract with initial owners and required confirmations.
     * @param _owners Array of initial owner addresses.
     * @param _numConfirmationsRequired Number of confirmations required for transactions.
     */
    function initialize(address[] memory _owners, uint256 _numConfirmationsRequired) public initializer {
        if (_owners.length == 0) revert OwnersRequired();
        if (
            _numConfirmationsRequired == 0 ||
            _numConfirmationsRequired > _owners.length
        ) revert InvalidNumberOfConfirmations();

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            if (owner == address(0)) revert InvalidOwner();
            require(owners.add(owner), OwnerNotUnique());
        }

        numConfirmationsRequired = _numConfirmationsRequired;
        maxTimeoutDuration = DEFAULT_MAX_TIMEOUT_DURATION;
    }

    /**
     * @dev Fallback function to receive ether and emit a deposit event.
     */
    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    /**
     * @dev Function to submit a new transaction to the wallet.
     * @param _to Address of the contract the transaction is directed to.
     * @param _value Amount of ether to be sent with the transaction.
     * @param _timeoutDuration Duration after which the transaction will get expire.
     * @param _data Data payload of the transaction.
     */
    function submitTransaction(
        address _to,
        uint256 _value,
        uint64 _timeoutDuration,
        bytes memory _data
    ) external payable {
        onlyOwner(msg.sender);
        if (_to == address(0)) revert InvalidRecipient();
        if (_timeoutDuration > maxTimeoutDuration) revert TimeoutTooLong();

        uint256 currentTxIndex = txIndex;

        transactions[currentTxIndex]  = Transaction({
            to: _to,
            timeout: uint64(block.timestamp) + _timeoutDuration,
            value: _value,
            data: _data
        });

        //We assume the act of submission is an implicit confirmation
        _recordConfirmation(currentTxIndex, msg.sender);
        txIndex++;
        txCount++;

        emit SubmitTransaction(msg.sender, currentTxIndex, _to, _value, _data);
    }

    /**
     * @dev Function to confirm an existing transaction.
     * @dev Reverts if the transaction has expired; call removeExpiredTransaction to clean it up.
     * @param _txIndex Index of the transaction to confirm.
     */
    function confirmTransaction(uint256 _txIndex) public {
        onlyOwner(msg.sender);
        txExists(_txIndex);
        notExpired(_txIndex);
        notConfirmed(_txIndex);

        _recordConfirmation(_txIndex, msg.sender);

        emit ConfirmTransaction(msg.sender, _txIndex);
    }

    /**
     * @dev Function to execute a confirmed transaction.
     * @dev Reverts if the transaction has expired; call removeExpiredTransaction to clean it up.
     * @param _txIndex Index of the transaction to execute.
     */
    function executeTransaction(uint256 _txIndex) public returns (bytes memory) {
        onlyOwner(msg.sender);
        txExists(_txIndex);
        notExpired(_txIndex);

        Transaction memory transaction = transactions[_txIndex];
        if (validNumberOfConfirmations(_txIndex) < numConfirmationsRequired)
            revert NotEnoughConfirmation();

        removeTransaction(_txIndex);

        (bool success, bytes memory data) = transaction.to.call{value: transaction.value}(transaction.data);
        if (!success) { revert ExecutionFailed(); }

        emit ExecuteTransaction(msg.sender, _txIndex, data);
        return data;
    }

    /**
     * @dev Function to revoke a previously given confirmation for a transaction.
     * @dev Reverts if the transaction has expired; call removeExpiredTransaction to clean it up.
     * @param _txIndex Index of the transaction to revoke confirmation.
     */
    function revokeConfirmation(uint256 _txIndex) external {
        onlyOwner(msg.sender);
        txExists(_txIndex);
        notExpired(_txIndex);
        // Gated on raw membership rather than _isOwnerConfirmationValid: an owner whose
        // confirmation went stale (threshold lowered, or removed and re-added) is no longer
        // counted anywhere, but should still be able to clear their own now-inert set entry
        // instead of being permanently stuck as an unrevocable member.
        if (!confirmations[_txIndex].contains(msg.sender)) revert TransactionNotConfirmed();

        confirmations[_txIndex].remove(msg.sender);
        delete ownerConfirmationEpoch[_txIndex][msg.sender];
        delete confirmationTxEpoch[_txIndex][msg.sender];

        emit RevokeConfirmation(msg.sender, _txIndex);
    }

    /**
     * @dev Permissionlessly removes a transaction whose timeout has passed. Its only effect is
     *      discarding an already-worthless transaction, so no access control is needed - anyone
     *      (e.g. an ops keeper) can call this to garbage-collect.
     * @param _txIndex Index of the expired transaction to remove.
     */
    function removeExpiredTransaction(uint256 _txIndex) external {
        txExists(_txIndex);
        if (transactions[_txIndex].timeout >= block.timestamp) revert NotExpired();

        removeTransaction(_txIndex);
        emit TransactionExpired(_txIndex);
    }

    /**
     * @dev Function to cancel a pending transaction that is stuck or no longer wanted. Reachable
     * only through the multisig's own submit/confirm/execute flow.
     * @param _txIndex Index of the transaction to cancel.
     */
    function cancelTransaction(uint256 _txIndex) external {
        onlyMultiSig();
        txExists(_txIndex);

        removeTransaction(_txIndex);
        emit TransactionCancelled(_txIndex);
    }

    /**
     * @dev Function to add new owners to the wallet.
     * @param _owners Array of new owner addresses to be added.
     */
    function addOwners(address[] memory _owners) external {
        onlyMultiSig();
        if (_owners.length == 0) revert OwnersRequired();

        address[] memory ownersToUpdate = new address[](_owners.length);
        uint256 c = 0;

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            if (owner == address(0)) revert InvalidOwner();
            if (owners.add(owner)) {
                ownersToUpdate[c++] = owner;
            }
        }
        if (c > 0) {
            // Trim the array to the addresses actually written before emitting, so the event
            // doesn't carry trailing address(0) entries for no-op inputs.
            assembly ("memory-safe") {
                mstore(ownersToUpdate, c)
            }
            emit OwnersAdded(ownersToUpdate);
        }
    }

    /**
     * @dev Function to remove existing owners from the wallet.
     * @dev Bumps ownerEpoch for each removed address so that any confirmation they left behind
     * on a still-pending transaction stops counting immediately. A later re-add via addOwners
     * does not restore it - see ownerEpoch.
     * @param _owners Array of existing owner addresses to be removed.
     */
    function removeOwners(address[] memory _owners) external {
        onlyMultiSig();
        if (_owners.length == 0) revert OwnersRequired();
        address[] memory ownersToUpdate = new address[](_owners.length);
        uint256 c = 0;

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            if (owners.remove(owner)) {
                ownerEpoch[owner]++;
                ownersToUpdate[c++] = owner;
            }
        }

        if (owners.length() < numConfirmationsRequired) {
            revert InvalidNumberOfConfirmations();
        }

        if (c > 0) {
            assembly ("memory-safe") {
                mstore(ownersToUpdate, c)
            }
            emit OwnersRemoved(ownersToUpdate);
        }
    }

    /**
     * @dev Function to update the number of required confirmations for transactions.
     * @dev Lowering the threshold bumps currentEpoch, invalidating confirmations on every
     * pending transaction system-wide, so a decrease can never retroactively satisfy a
     * transaction that fell short of the old, higher threshold. Raising the threshold is
     * self-enforcing via the live comparison in hasValidNumberOfConfirmations and does not
     * need invalidation.
     * @param _numConfirmationsRequired New number of confirmations required for transactions.
     */
    function updateNumConfirmations(uint256 _numConfirmationsRequired) external {
        onlyMultiSig();
        if (
            _numConfirmationsRequired == 0 ||
            _numConfirmationsRequired > owners.length()
        ) revert InvalidNumberOfConfirmations();

        if (_numConfirmationsRequired < numConfirmationsRequired) {
            currentEpoch++;
        }

        numConfirmationsRequired = _numConfirmationsRequired;
        emit NumConfirmationUpdated(_numConfirmationsRequired);
    }

    /**
     * @dev Function to update the maximum timeout duration allowed for newly submitted
     * transactions. Only affects transactions submitted after the update.
     * @param _newMaxTimeoutDuration New maximum timeout duration, in seconds.
     */
    function updateMaxTimeoutDuration(uint64 _newMaxTimeoutDuration) external {
        onlyMultiSig();
        if (_newMaxTimeoutDuration == 0) revert InvalidMaxTimeoutDuration();

        maxTimeoutDuration = _newMaxTimeoutDuration;
        emit MaxTimeoutDurationUpdated(_newMaxTimeoutDuration);
    }

    /**
     * @dev Function to retrieve the list of current owners of the wallet.
     * @return Array of addresses representing the current owners.
     */
    function getOwners() public view returns (address[] memory) {
        return owners.values();
    }

    /**
     * @dev Function to retrieve the potential index of the next transaction.
     * @return Index of the next transaction of uint256 type.
     */
    function getNextTransactionIndex() public view returns (uint256) {
        return txIndex;
    }

    /**
     * @dev Checks if a transaction is confirmed by an owner.
     * @param _txIndex Index of the transaction to check for.
     * @param _owner Address of the owner.
     */
    function isConfirmed(uint256 _txIndex, address _owner) external view returns (bool) {
        onlyOwner(_owner);
        txExists(_txIndex);
        notExpired(_txIndex);
        return _isOwnerConfirmationValid(_txIndex, _owner);
    }

    /**
     * @dev Function to retrieve details of a specific transaction.
     * @param _txIndex Index of the transaction to retrieve details for.
     * @return to Transaction target address.
     * @return value Amount of ether sent with the transaction.
     * @return numConfirmations Number of confirmations received for the transaction.
     * @return timeout Expiry timestamp of the transaction.
     * @return data Data payload of the transaction.
     */
    function getTransaction(
        uint256 _txIndex
    )
        public
        view
        returns (
            address to,
            uint256 value,
            uint24 numConfirmations,
            uint64 timeout,
            bytes memory data
        )
    {
        txExists(_txIndex);
        notExpired(_txIndex);
        Transaction storage transaction = transactions[_txIndex];

        return (
            transaction.to,
            transaction.value,
            validNumberOfConfirmations(_txIndex),
            transaction.timeout,
            transaction.data
        );
    }

    /**
     * @notice Deploys a contract using raw CREATE opcode
     * @param _creationCode The creation bytecode of the contract to deploy
     * @param _value Amount of ETH to sent along with contract creation.
     * @return deployed The address of the deployed contract
     */
    function deployContract(bytes memory _creationCode, uint256 _value) external returns (address deployed) {
        onlyMultiSig();
        if (_creationCode.length == 0) { revert EmptyCreationCode(); }

        assembly ("memory-safe") {
            // CREATE(value, offset, size)
            deployed := create(
                _value,                         // forward ETH if any
                add(_creationCode, 0x20),       // skip the length slot
                mload(_creationCode)            // size of creation code
            )
        }
        if (deployed == address(0)) { revert ContractCreationFailed(); }
        emit ContractDeployed(deployed);
    }

    /**
     * @dev Function to check if a transaction has a valid number of confirmations.
     * @param _txIndex Index of the transaction to check for.
     * @return bool True if the transaction has a valid number of confirmations counting only valid owners, false otherwise.
     */
    function hasValidNumberOfConfirmations(uint256 _txIndex) public view returns (bool) {
        txExists(_txIndex);
        notExpired(_txIndex);
        return validNumberOfConfirmations(_txIndex) >= numConfirmationsRequired;
    }
}
