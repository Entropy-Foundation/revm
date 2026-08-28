// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IMultiSignatureWallet {
    // ── Errors ────────────────────────────────────────────────────────────────

    /// @notice Thrown when the caller is not a registered owner.
    error NotAnOwner();
    /// @notice Thrown when a transaction index references a non-existent transaction.
    error InvalidTxnId();
    /// @notice Thrown when attempting to act on an already-executed transaction.
    error TxnAlreadyExecuted();
    /// @notice Thrown when an owner tries to confirm a transaction they already confirmed.
    error TxnAlreadyConfirmed();
    /// @notice Thrown when the owners array supplied during initialization is empty.
    error OwnersRequired();
    /// @notice Thrown when the required confirmation count is zero or exceeds the owner count.
    error InvalidNumberOfConfirmations();
    /// @notice Thrown when a zero address is supplied as an owner.
    error InvalidOwner();
    /// @notice Thrown when address(0) is supplied as a transaction recipient.
    error InvalidRecipient();
    /// @notice Thrown when a duplicate owner address is provided.
    error OwnerNotUnique();
    /// @notice Thrown when a transaction does not have enough confirmations to execute.
    error NotEnoughConfirmation();
    /// @notice Thrown when the low-level transaction call fails.
    error ExecutionFailed();
    /// @notice Thrown when empty creation bytecode is passed to deployContract.
    error EmptyCreationCode();
    /// @notice Thrown when a CREATE deployment returns address(0).
    error ContractCreationFailed();
    /// @notice Thrown when revoking a confirmation the caller has not given.
    error TransactionNotConfirmed();
    /// @notice Thrown when an admin function is called by anyone other than the multisig itself.
    error OnlyMultisigAccountCanCall();
    /// @notice Thrown when submitTransaction is given a timeout duration longer than maxTimeoutDuration.
    error TimeoutTooLong();
    /// @notice Thrown when confirming, executing, or revoking a transaction whose timeout has already passed.
    error TransactionAlreadyExpired();
    /// @notice Thrown when removeExpiredTransaction is called on a transaction that has not actually expired.
    error NotExpired();
    /// @notice Thrown when updateMaxTimeoutDuration is called with a zero duration.
    error InvalidMaxTimeoutDuration();

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted when native tokens are received by the wallet.
    /// @param sender Address that sent the funds.
    /// @param amount Amount deposited.
    /// @param balance New contract balance after the deposit.
    event Deposit(address indexed sender, uint256 amount, uint256 balance);

    /// @notice Emitted when a new transaction is submitted.
    /// @param owner Owner who submitted the transaction.
    /// @param txIndex Index assigned to the transaction.
    /// @param to Target contract address.
    /// @param value ETH value attached to the transaction.
    /// @param data Call data payload.
    event SubmitTransaction(
        address indexed owner,
        uint256 indexed txIndex,
        address indexed to,
        uint256 value,
        bytes data
    );

    /// @notice Emitted when a pending transaction expires and is removed.
    /// @param txIndex Index of the expired transaction.
    event TransactionExpired(uint256 indexed txIndex);

    /// @notice Emitted when an owner confirms a transaction.
    /// @param owner Owner who confirmed.
    /// @param txIndex Index of the confirmed transaction.
    event ConfirmTransaction(address indexed owner, uint256 indexed txIndex);

    /// @notice Emitted when an owner revokes a previously given confirmation.
    /// @param owner Owner who revoked.
    /// @param txIndex Index of the transaction.
    event RevokeConfirmation(address indexed owner, uint256 indexed txIndex);

    /// @notice Emitted when a transaction is executed.
    /// @param owner Owner who triggered execution.
    /// @param txIndex Index of the executed transaction.
    /// @param txData Data returned by the executed call.
    event ExecuteTransaction(address indexed owner, uint256 indexed txIndex, bytes txData);

    /// @notice Emitted when a new contract is deployed via deployContract.
    /// @param deployedContract Address of the newly deployed contract.
    event ContractDeployed(address indexed deployedContract);

    /// @notice Emitted when new owners are added to the wallet.
    /// @param owners Array of newly added owner addresses.
    event OwnersAdded(address[] owners);

    /// @notice Emitted when owners are removed from the wallet.
    /// @param owners Array of removed owner addresses.
    event OwnersRemoved(address[] owners);

    /// @notice Emitted when the required confirmation count is updated.
    /// @param newNumConfirmation The new required confirmation count.
    event NumConfirmationUpdated(uint256 newNumConfirmation);

    /// @notice Emitted when a pending transaction is cancelled by the multisig.
    /// @param txIndex Index of the cancelled transaction.
    event TransactionCancelled(uint256 indexed txIndex);

    /// @notice Emitted when the maximum allowed submission timeout duration is updated.
    /// @param newMaxTimeoutDuration The new maximum timeout duration, in seconds.
    event MaxTimeoutDurationUpdated(uint64 newMaxTimeoutDuration);

    // ── State variable getters ────────────────────────────────────────────────

    /// @notice Returns the number of confirmations required to execute a transaction.
    function numConfirmationsRequired() external view returns (uint256);

    /// @notice Returns the current number of pending (non-executed) transactions.
    function txCount() external view returns (uint256);

    /// @notice Returns the maximum timeout duration, in seconds, allowed for a newly submitted transaction.
    function maxTimeoutDuration() external view returns (uint64);

    // ── Core wallet functions ─────────────────────────────────────────────────

    /// @notice Submits a new transaction for confirmation by other owners.
    /// @param _to Target contract address.
    /// @param _value Amount of ETH to send with the transaction.
    /// @param _timeoutDuration Seconds from now after which the transaction expires.
    /// @param _data Call data payload.
    function submitTransaction(
        address _to,
        uint256 _value,
        uint64 _timeoutDuration,
        bytes memory _data
    ) external payable;

    /// @notice Confirms a pending transaction. Removes it if already expired.
    /// @param _txIndex Index of the transaction to confirm.
    function confirmTransaction(uint256 _txIndex) external;

    /// @notice Executes a transaction once enough confirmations are gathered. Removes it if expired.
    /// @param _txIndex Index of the transaction to execute.
    /// @return Data returned by the executed call.
    function executeTransaction(uint256 _txIndex) external returns (bytes memory);

    /// @notice Revokes a previously given confirmation. Removes the transaction if expired.
    /// @param _txIndex Index of the transaction.
    function revokeConfirmation(uint256 _txIndex) external;

    /// @notice Removes an already-expired transaction from storage. Callable by anyone.
    /// @param _txIndex Index of the expired transaction to remove.
    function removeExpiredTransaction(uint256 _txIndex) external;

    // ── Admin functions (callable only by the multisig itself) ────────────────

    /// @notice Adds new owners to the wallet.
    /// @param _owners Array of addresses to add as owners.
    function addOwners(address[] memory _owners) external;

    /// @notice Removes existing owners from the wallet.
    /// @param _owners Array of owner addresses to remove.
    function removeOwners(address[] memory _owners) external;

    /// @notice Updates the required confirmation count.
    /// @param _numConfirmationsRequired New confirmation threshold.
    function updateNumConfirmations(uint256 _numConfirmationsRequired) external;

    /// @notice Cancels a pending transaction, removing it from storage.
    /// @param _txIndex Index of the transaction to cancel.
    function cancelTransaction(uint256 _txIndex) external;

    /// @notice Updates the maximum timeout duration allowed for newly submitted transactions.
    /// @param _newMaxTimeoutDuration New maximum timeout duration, in seconds.
    function updateMaxTimeoutDuration(uint64 _newMaxTimeoutDuration) external;

    /// @notice Deploys a contract using the CREATE opcode.
    /// @param _creationCode Creation bytecode of the contract to deploy.
    /// @param _value Amount of ETH to forward with deployment.
    /// @return deployed Address of the newly deployed contract.
    function deployContract(bytes memory _creationCode, uint256 _value) external returns (address deployed);

    // ── View functions ────────────────────────────────────────────────────────

    /// @notice Returns the list of current owner addresses.
    function getOwners() external view returns (address[] memory);

    /// @notice Returns the index that will be assigned to the next submitted transaction.
    function getNextTransactionIndex() external view returns (uint256);

    /// @notice Returns whether a given owner has confirmed a transaction.
    /// @param _txIndex Index of the transaction.
    /// @param _owner Address of the owner to check.
    function isConfirmed(uint256 _txIndex, address _owner) external view returns (bool);

    /// @notice Returns the details of a pending transaction.
    /// @param _txIndex Index of the transaction.
    /// @return to Target contract address.
    /// @return value ETH value attached to the transaction.
    /// @return numConfirmations Number of confirmations received so far.
    /// @return timeout Expiry timestamp of the transaction.
    /// @return data Call data payload.
    function getTransaction(uint256 _txIndex) external view returns (
        address to,
        uint256 value,
        uint24 numConfirmations,
        uint64 timeout,
        bytes memory data
    );

    /// @notice Function to check if a transaction has a valid number of confirmations.
    /// @param _txIndex Index of the transaction to check for.
    /// @return bool True if the transaction has a valid number of confirmations counting only valid owners, false otherwise.
    function hasValidNumberOfConfirmations(uint256 _txIndex) external view returns (bool);
}