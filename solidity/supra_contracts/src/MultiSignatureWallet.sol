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

    // Structure to hold transaction details
    struct Transaction {
        address to; // Transaction target address
        uint64 timeout; // Expiry timestamp of the transaction
        uint24 numConfirmations; // Number of confirmations received for the transaction
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

    /// @dev Helper function to remove a transaction and emit an event if it is expired.
    /// @param _txIndex Index of the transaction.
    /// @return bool True if the transaction was expired and removed.
    function cleanupIfExpired(uint256 _txIndex) private returns (bool) {
        if (transactions[_txIndex].timeout < block.timestamp) {
            removeTransaction(_txIndex);
            emit TransactionExpired(_txIndex);

            return true;
        }
        return false;
    }

    /// @dev Helper function to remove a transaction from the storage.
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
        if (confirmations[_txIndex].contains(msg.sender))  revert TxnAlreadyConfirmed();
    }

    /// @dev Clears all pending confirmations for a set of removed owners.
    /// @param _removedOwners Array of owner addresses that were removed.
    function _clearOwnerConfirmations(address[] memory _removedOwners) private {
        for (uint256 i = 0; i < _removedOwners.length; i++) {
            address removedOwner = _removedOwners[i];
            for (uint256 j = 0; j < txIndex; j++) {
                if (transactions[j].to != address(0) && confirmations[j].contains(removedOwner)) {
                    confirmations[j].remove(removedOwner);
                    transactions[j].numConfirmations -= 1;
                }
            }
        }
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

        uint256 currentTxIndex = txIndex;

        transactions[currentTxIndex]  = Transaction({
            to: _to,
            timeout: uint64(block.timestamp) + _timeoutDuration,
           //We assume the act of submission is an implicit confirmation
            numConfirmations: 1,
            value: _value,
            data: _data
        });

        confirmations[currentTxIndex].add(msg.sender);
        txIndex++;
        txCount++;

        emit SubmitTransaction(msg.sender, currentTxIndex, _to, _value, _data);
    }

    /**
     * @dev Function to confirm an existing transaction.
     * @dev If the transaction is expired, it is deleted and TransactionExpired is emitted.
     * @param _txIndex Index of the transaction to confirm.
     */
    function confirmTransaction(uint256 _txIndex) public {
        onlyOwner(msg.sender);
        txExists(_txIndex);
        notConfirmed(_txIndex);
        if (cleanupIfExpired(_txIndex)) {
            // Transaction expired, action is no longer applicable
            return;
        }
        Transaction storage transaction = transactions[_txIndex];
        transaction.numConfirmations += 1;
        confirmations[_txIndex].add(msg.sender);

        emit ConfirmTransaction(msg.sender, _txIndex);
    }

    /**
     * @dev Function to execute a confirmed transaction.
     * @dev If the transaction is expired, it is deleted and TransactionExpired is emitted.
     * @param _txIndex Index of the transaction to execute.
     */
    function executeTransaction(uint256 _txIndex) public returns (bytes memory) {
        onlyOwner(msg.sender);
        txExists(_txIndex);
        if (cleanupIfExpired(_txIndex)) {
            // Transaction expired, action is no longer applicable
            return bytes("");
        }
        Transaction memory transaction = transactions[_txIndex];
        if (!hasValidNumberOfConfirmations(_txIndex))
            revert NotEnoughConfirmation();

        removeTransaction(_txIndex);

        (bool success, bytes memory data) = transaction.to.call{value: transaction.value}(transaction.data);
        if (!success) { revert ExecutionFailed(); }
            
        emit ExecuteTransaction(msg.sender, _txIndex, data);
        return data;
    }

    /**
     * @dev Function to revoke a previously given confirmation for a transaction.
     * @dev If the transaction is expired, it is deleted and TransactionExpired is emitted.
     * @param _txIndex Index of the transaction to revoke confirmation.
     */
    function revokeConfirmation(uint256 _txIndex) external {
        onlyOwner(msg.sender);
        txExists(_txIndex);
        if (cleanupIfExpired(_txIndex)) {
            // Transaction expired, action is no longer applicable
            return;
        }
        if (!confirmations[_txIndex].contains(msg.sender)) revert TransactionNotConfirmed();

        Transaction storage transaction = transactions[_txIndex];

        transaction.numConfirmations -= 1;
        confirmations[_txIndex].remove(msg.sender);

        emit RevokeConfirmation(msg.sender, _txIndex);
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
        if (c > 0)
        emit OwnersAdded(ownersToUpdate);
    }

    /**
     * @dev Function to remove existing owners from the wallet.
     * @dev It does not clean up existing confirmation from the removed owners to keep complexity low.
     * However, the hasValidNumberOfConfirmations function counts only valid owners when checking for confirmations
     * before executing a transaction.
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
                ownersToUpdate[c++] = owner;
            }
        }

        if (owners.length() < numConfirmationsRequired) {
            revert InvalidNumberOfConfirmations();
        }

        _clearOwnerConfirmations(ownersToUpdate);

        if (c > 0)
        emit OwnersRemoved(ownersToUpdate);
    }

    /**
     * @dev Function to update the number of required confirmations for transactions.
     * @param _numConfirmationsRequired New number of confirmations required for transactions.
     */
    function updateNumConfirmations(uint256 _numConfirmationsRequired) external {
        onlyMultiSig();
        if (
            _numConfirmationsRequired == 0 ||
            _numConfirmationsRequired > owners.length()
        ) revert InvalidNumberOfConfirmations();
        numConfirmationsRequired = _numConfirmationsRequired;
        emit NumConfirmationUpdated(_numConfirmationsRequired);
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
        txExists(_txIndex); 
        return confirmations[_txIndex].contains(_owner);
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
        Transaction storage transaction = transactions[_txIndex];

        return (
            transaction.to,
            transaction.value,
            transaction.numConfirmations,
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

        assembly {
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
        Transaction storage transaction = transactions[_txIndex];
        EnumerableSet.AddressSet storage confirmation = confirmations[_txIndex];
        uint64 valid_number_of_confirmations = 0;
        for (uint64 i = 0; i < confirmation.length(); i++) {
            address owner = confirmation.at(i);
            if (owners.contains(owner)) {
                valid_number_of_confirmations++;
            }
        }
        return valid_number_of_confirmations >= numConfirmationsRequired;
    }
}
