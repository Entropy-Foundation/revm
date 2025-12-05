// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EnumerableSet} from "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/**
 * @title MultiSignatureWallet
 * @dev A multisignature wallet contract that requires multiple owners to confirm transactions.
 */
contract MultiSignatureWallet is Initializable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @dev Emitted when a deposit is made to the contract.
     * @param sender The address that sent the funds.
     * @param amount The amount of funds deposited.
     * @param balance The new balance of the contract after the deposit.
     */
    event Deposit(address indexed sender, uint256 amount, uint256 balance);

    /**
     * @dev Emitted when a new transaction is submitted.
     * @param owner The address of the owner who submitted the transaction.
     * @param txIndex The index of the transaction in the transactions array.
     * @param to The contract address the transaction is directed to.
     * @param value The amount of ether to be sent with the transaction.
     * @param data The data payload of the transaction.
     */
    event SubmitTransaction(
        address indexed owner,
        uint256 indexed txIndex,
        address indexed to,
        uint256 value,
        bytes data
    );

    /**
     * @dev Emitted when a transaction is confirmed by an owner.
     * @param owner The address of the owner who confirmed the transaction.
     * @param txIndex The index of the transaction in the transactions array.
     */
    event ConfirmTransaction(address indexed owner, uint256 indexed txIndex);

    /**
     * @dev Emitted when a confirmation is revoked by an owner.
     * @param owner The address of the owner who revoked the confirmation.
     * @param txIndex The index of the transaction in the transactions array.
     */
    event RevokeConfirmation(address indexed owner, uint256 indexed txIndex);

    /**
     * @dev Emitted when a transaction is executed.
     * @param owner The address of the owner who executed the transaction.
     * @param txIndex The index of the transaction in the transactions array.
     * @param txData The data returned by the transaction call.
     */
    event ExecuteTransaction(address indexed owner, uint256 indexed txIndex, bytes txData);
    
    /**
     * @dev Emitted when a transaction to deploy a contract is executed.
     * @param owner The address of the owner who executed the transaction.
     * @param txIndex The index of the transaction in the transactions array.
     * @param deployed The address of the deployed contract.
     */
    event ExecuteTransactionDeployment(address indexed owner, uint256 indexed txIndex, address indexed deployed);

    /**
     * @dev Emitted when new owners are added to the contract.
     * @param owners An array of addresses representing the newly added owners.
     */
    event OwnersAdded(address[] owners);

    /**
     * @dev Emitted when owners are removed from the contract.
     * @param owners An array of addresses representing the removed owners.
     */
    event OwnersRemoved(address[] owners);

    /**
     * @dev Emitted when the number of confirmations required is updated.
     * @param newNumConfirmation The new number of confirmations required for a transaction.
     */
    event NumConfirmationUpdated(uint256 newNumConfirmation);


    // Custom error definitions

    /**
     * @dev Error for when the function caller is not an owner.
     */
    error NotAnOwner();

    /**
     * @dev Error for when a transaction ID is invalid (e.g., out of bounds).
     */
    error InvalidTxnId();

    /**
     * @dev Error for when a transaction has already been executed.
     */
    error TxnAlreadyExecuted();

    /**
     * @dev Error for when a transaction has already been confirmed by the caller.
     */
    error TxnAlreadyConfirmed();

    /**
     * @dev Error for when the owners array is empty upon contract creation.
     */
    error OwnersRequired();

    /**
     * @dev Error for when the number of required confirmations is invalid (0 or more than the number of owners).
     */
    error InvalidNumberOfConfirmations();

    /**
     * @dev Error for when an invalid owner address is provided (e.g., zero address).
     */
    error InvalidOwner();

    /**
     * @dev Error for when a duplicate owner address is provided.
     */
    error OwnerNotUnique();

    /**
     * @dev Error for when a transaction does not have enough confirmations to be executed.
     */
    error NotEnoughConfirmation();

    /**
     * @dev Error to revert with when a transaction execution fails.
     */
    error ExecutionFailed();

    /**
     * @dev Error to revert with if empty contract creation code is passed.
     */
    error EmptyCreationCode();
    
    /**
     * @dev Error to revert with when contract creation fails.
     */
    error ContractCreationFailed();

    /**
     * @dev Error for when a transaction has not been confirmed by the caller.
     */
    error TransactionNotConfirmed();

    /**
     * @dev Error for when a transaction has already expired.
     */
    error TransactionAlreadyExpired();

    /**
     * @dev Error for when a function is called by an account other than the multisig wallet itself.
     */
    error OnlyMultisigAccountCanCall();

    EnumerableSet.AddressSet private owners;
    uint256 public numConfirmationsRequired;

    // Structure to hold transaction details
    struct Transaction {
        address to; // Transaction target address
        bool executed; // Flag indicating if the transaction has been executed
        uint64 timeout; // Expiry timestamp of the transaction
        uint24 numConfirmations; // Number of confirmations received for the transaction
        uint256 value; // Amount of ether sent with the transaction
        bytes data; // Data payload of the transaction
    }

    // Mapping to track confirmations for each transaction by each owner
    mapping(uint256 transactionIndex => mapping(address owner => bool permissionToExecute)) public isConfirmed;

    // Array to store all transactions
    Transaction[] private transactions;

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
        if (_txIndex >= transactions.length) 
        revert InvalidTxnId();
    }

    // Function to check if a transaction has not been executed
    function notExecuted(uint256 _txIndex) private view {
        if (transactions[_txIndex].executed) 
        revert TxnAlreadyExecuted();
    }

    // Function to check if a transaction has not been expired or not
    function txNotExpired(uint256 _txIndex) private view {
        if (transactions[_txIndex].timeout < block.timestamp)
            revert TransactionAlreadyExpired();
    }

    // Function to check if a transaction has not been confirmed by the caller
    function notConfirmed(uint256 _txIndex) private view {
        if (isConfirmed[_txIndex][msg.sender])  revert TxnAlreadyConfirmed();
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
        uint256 txIndex = transactions.length;

        transactions.push(
            Transaction({
                to: _to,
                executed: false,
                timeout: uint64(block.timestamp) + _timeoutDuration,
               //We assume the act of submission is an implicit confirmation
                numConfirmations: 1,
                value: _value,
                data: _data
            })
        );

        isConfirmed[txIndex][msg.sender] = true;

        emit SubmitTransaction(msg.sender, txIndex, _to, _value, _data);
    }

    /**
     * @dev Function to confirm an existing transaction.
     * @param _txIndex Index of the transaction to confirm.
     */
    function confirmTransaction(uint256 _txIndex) public {
        onlyOwner(msg.sender);
        txExists(_txIndex);
        notExecuted(_txIndex);
        notConfirmed(_txIndex);
        txNotExpired(_txIndex);
        Transaction storage transaction = transactions[_txIndex];
        transaction.numConfirmations += 1;
        isConfirmed[_txIndex][msg.sender] = true;

        emit ConfirmTransaction(msg.sender, _txIndex);
    }

    /**
     * @dev Function to execute a confirmed transaction.
     * @param _txIndex Index of the transaction to execute.
     */
    function executeTransaction(uint256 _txIndex) public {
        onlyOwner(msg.sender);
        txExists(_txIndex);
        notExecuted(_txIndex);
        txNotExpired(_txIndex);
        Transaction storage transaction = transactions[_txIndex];
        if (transaction.numConfirmations < numConfirmationsRequired)
            revert NotEnoughConfirmation();
        transaction.executed = true;
        if (transaction.to == address(0)) {
            address deployed = deploy(transaction.data, transaction.value);

            emit ExecuteTransactionDeployment(msg.sender, _txIndex, deployed);
        } else {
            (bool success, bytes memory data) = transaction.to.call{value: transaction.value}(transaction.data);
            if (!success) { revert ExecutionFailed(); }
            
            emit ExecuteTransaction(msg.sender, _txIndex, data);
        }
    }

    /**
     * @dev Function to revoke a previously given confirmation for a transaction.
     * @param _txIndex Index of the transaction to revoke confirmation.
     */
    function revokeConfirmation(uint256 _txIndex) external {
        onlyOwner(msg.sender);
        txExists(_txIndex);
        notExecuted(_txIndex);
        txNotExpired(_txIndex);
        if (!isConfirmed[_txIndex][msg.sender]) {
            revert TransactionNotConfirmed();
        }

        Transaction storage transaction = transactions[_txIndex];

        transaction.numConfirmations -= 1;
        isConfirmed[_txIndex][msg.sender] = false;

        emit RevokeConfirmation(msg.sender, _txIndex);
    }

    /**
     * @dev Function to add new owners to the wallet.
     * @param _owners Array of new owner addresses to be added.
     */
    function addOwners(address[] memory _owners) public {
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
     * @param _owners Array of existing owner addresses to be removed.
     */
    function removeOwners(address[] memory _owners) public {
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

        if (c > 0)
        emit OwnersRemoved(ownersToUpdate);
    }

    /**
     * @dev Function to update the number of required confirmations for transactions.
     * @param _numConfirmationsRequired New number of confirmations required for transactions.
     */
    function updateNumConfirmations(uint256 _numConfirmationsRequired) public {
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
     * @dev Function to retrieve the count of transactions submitted to the wallet.
     * @return Total number of transactions in the wallet.
     */
    function getTransactionCount() public view returns (uint256) {
        return transactions.length;
    }

    /**
     * @dev Function to retrieve details of a specific transaction.
     * @param _txIndex Index of the transaction to retrieve details for.
     * @return to Transaction target address.
     * @return value Amount of ether sent with the transaction.
     * @return executed Boolean indicating if the transaction has been executed.
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
            bool executed,
            uint256 numConfirmations,
            uint64 timeout,
            bytes memory data
        )
    {
        Transaction storage transaction = transactions[_txIndex];

        return (
            transaction.to,
            transaction.value,
            transaction.executed,
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
    function deploy(bytes memory _creationCode, uint256 _value) private returns (address deployed) {
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
    }
}
