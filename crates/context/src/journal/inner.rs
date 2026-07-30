//! Module containing the [`JournalInner`] that is part of [`crate::Journal`].
use crate::{entry::SelfdestructionRevertStatus, warm_addresses::WarmAddresses};

use super::JournalEntryTr;
use bytecode::Bytecode;
use context_interface::{
    context::{SStoreResult, SelfDestructResult, StateLoad},
    journaled_state::{AccountLoad, JournalCheckpoint, TransferError},
};
use core::mem;
use database_interface::Database;
use primitives::{
    hardfork::SpecId::{self, *},
    hash_map::Entry,
    Address, HashMap, Log, StorageKey, StorageValue, B256, KECCAK_EMPTY, U256,
};
use state::{Account, EvmState, EvmStorageSlot, TransientStorage};
use std::vec::Vec;
/// Inner journal state that contains journal and state changes.
///
/// Spec Id is a essential information for the Journal.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct JournalInner<ENTRY> {
    /// The current state
    pub state: EvmState,
    /// Transient storage that is discarded after every transaction.
    ///
    /// See [EIP-1153](https://eips.ethereum.org/EIPS/eip-1153).
    pub transient_storage: TransientStorage,
    /// Emitted logs
    pub logs: Vec<Log>,
    /// The current call stack depth
    pub depth: usize,
    /// The journal of state changes, one for each transaction
    pub journal: Vec<ENTRY>,
    /// Global transaction id that represent number of transactions executed (Including reverted ones).
    /// It can be different from number of `journal_history` as some transaction could be
    /// reverted or had a error on execution.
    ///
    /// This ID is used in `Self::state` to determine if account/storage is touched/warm/cold.
    pub transaction_id: usize,
    /// The spec ID for the EVM. Spec is required for some journal entries and needs to be set for
    /// JournalInner to be functional.
    ///
    /// If spec is set it assumed that precompile addresses are set as well for this particular spec.
    ///
    /// This spec is used for two things:
    ///
    /// - [EIP-161]: Prior to this EIP, Ethereum had separate definitions for empty and non-existing accounts.
    /// - [EIP-6780]: `SELFDESTRUCT` only in same transaction
    ///
    /// [EIP-161]: https://eips.ethereum.org/EIPS/eip-161
    /// [EIP-6780]: https://eips.ethereum.org/EIPS/eip-6780
    pub spec: SpecId,
    /// Warm addresses containing both coinbase and current precompiles.
    pub warm_addresses: WarmAddresses,
}

impl<ENTRY: JournalEntryTr> Default for JournalInner<ENTRY> {
    fn default() -> Self {
        Self::new()
    }
}

impl<ENTRY: JournalEntryTr> JournalInner<ENTRY> {
    /// Creates new [`JournalInner`].
    ///
    /// `warm_preloaded_addresses` is used to determine if address is considered warm loaded.
    /// In ordinary case this is precompile or beneficiary.
    pub fn new() -> JournalInner<ENTRY> {
        Self {
            state: HashMap::default(),
            transient_storage: TransientStorage::default(),
            logs: Vec::new(),
            journal: Vec::default(),
            transaction_id: 0,
            depth: 0,
            spec: SpecId::default(),
            warm_addresses: WarmAddresses::new(),
        }
    }

    /// Returns the logs
    #[inline]
    pub fn take_logs(&mut self) -> Vec<Log> {
        mem::take(&mut self.logs)
    }

    /// Prepare for next transaction, by committing the current journal to history, incrementing the transaction id
    /// and returning the logs.
    ///
    /// This function is used to prepare for next transaction. It will save the current journal
    /// and clear the journal for the next transaction.
    ///
    /// `commit_tx` is used even for discarding transactions so transaction_id will be incremented.
    pub fn commit_tx(&mut self) {
        // Clears all field from JournalInner. Doing it this way to avoid
        // missing any field.
        let Self {
            state,
            transient_storage,
            logs,
            depth,
            journal,
            transaction_id,
            spec,
            warm_addresses,
        } = self;
        // Spec precompiles and state are not changed. It is always set again execution.
        let _ = spec;
        let _ = state;
        transient_storage.clear();
        *depth = 0;

        // Do nothing with journal history so we can skip cloning present journal.
        journal.clear();

        // Clear coinbase address warming for next tx
        warm_addresses.clear_coinbase();
        // increment transaction id.
        *transaction_id += 1;
        logs.clear();
    }

    /// Discard the current transaction, by reverting the journal entries and incrementing the transaction id.
    pub fn discard_tx(&mut self) {
        // if there is no journal entries, there has not been any changes.
        let Self {
            state,
            transient_storage,
            logs,
            depth,
            journal,
            transaction_id,
            spec,
            warm_addresses,
        } = self;
        let is_spurious_dragon_enabled = spec.is_enabled_in(SPURIOUS_DRAGON);
        // iterate over all journals entries and revert our global state
        journal.drain(..).rev().for_each(|entry| {
            entry.revert(state, None, is_spurious_dragon_enabled);
        });
        transient_storage.clear();
        *depth = 0;
        logs.clear();
        *transaction_id += 1;

        // Clear coinbase address warming for next tx
        warm_addresses.clear_coinbase();
    }

    /// Take the [`EvmState`] and clears the journal by resetting it to initial state.
    ///
    /// Note: Precompile addresses and spec are preserved and initial state of
    /// warm_preloaded_addresses will contain precompiles addresses.
    #[inline]
    pub fn finalize(&mut self) -> EvmState {
        // Clears all field from JournalInner. Doing it this way to avoid
        // missing any field.
        let Self {
            state,
            transient_storage,
            logs,
            depth,
            journal,
            transaction_id,
            spec,
            warm_addresses,
        } = self;
        // Spec is not changed. And it is always set again in execution.
        let _ = spec;
        // Clear coinbase address warming for next tx
        warm_addresses.clear_coinbase();

        let state = mem::take(state);
        logs.clear();
        transient_storage.clear();

        // clear journal and journal history.
        journal.clear();
        *depth = 0;
        // reset transaction id.
        *transaction_id = 0;

        state
    }

    /// Return reference to state.
    #[inline]
    pub fn state(&mut self) -> &mut EvmState {
        &mut self.state
    }

    /// Sets SpecId.
    #[inline]
    pub fn set_spec_id(&mut self, spec: SpecId) {
        self.spec = spec;
    }

    /// Mark account as touched as only touched accounts will be added to state.
    /// This is especially important for state clear where touched empty accounts needs to
    /// be removed from state.
    #[inline]
    pub fn touch(&mut self, address: Address) {
        if let Some(account) = self.state.get_mut(&address) {
            Self::touch_account(&mut self.journal, address, account);
        }
    }

    /// Mark account as touched.
    #[inline]
    fn touch_account(journal: &mut Vec<ENTRY>, address: Address, account: &mut Account) {
        if !account.is_touched() {
            journal.push(ENTRY::account_touched(address));
            account.mark_touch();
        }
    }

    /// Returns the _loaded_ [Account] for the given address.
    ///
    /// This assumes that the account has already been loaded.
    ///
    /// # Panics
    ///
    /// Panics if the account has not been loaded and is missing from the state set.
    #[inline]
    pub fn account(&self, address: Address) -> &Account {
        self.state
            .get(&address)
            .expect("Account expected to be loaded") // Always assume that acc is already loaded
    }

    /// Set code and its hash to the account.
    ///
    /// Note: Assume account is warm and that hash is calculated from code.
    #[inline]
    pub fn set_code_with_hash(&mut self, address: Address, code: Bytecode, hash: B256) {
        let account = self.state.get_mut(&address).unwrap();
        Self::touch_account(&mut self.journal, address, account);

        self.journal.push(ENTRY::code_changed(address));

        account.info.code_hash = hash;
        account.info.code = Some(code);
    }

    /// Use it only if you know that acc is warm.
    ///
    /// Assume account is warm.
    ///
    /// In case of EIP-7702 code with zero address, the bytecode will be erased.
    #[inline]
    pub fn set_code(&mut self, address: Address, code: Bytecode) {
        if let Bytecode::Eip7702(eip7702_bytecode) = &code {
            if eip7702_bytecode.address().is_zero() {
                self.set_code_with_hash(address, Bytecode::default(), KECCAK_EMPTY);
                return;
            }
        }

        let hash = code.hash_slow();
        self.set_code_with_hash(address, code, hash)
    }

    /// Add journal entry for caller accounting.
    #[inline]
    pub fn caller_accounting_journal_entry(
        &mut self,
        address: Address,
        old_balance: U256,
        bump_nonce: bool,
    ) {
        // account balance changed.
        self.journal
            .push(ENTRY::balance_changed(address, old_balance));
        // Mark the caller touched through the guarded `touch()` helper rather than pushing an
        // unconditional `AccountTouched` entry. `Touched` is a sticky, block-scoped flag (see
        // `AccountStatus` docs) — once a prior transaction has committed with this account
        // touched, a later transaction must NOT record another touch entry for it, otherwise
        // discarding that later transaction (e.g. a `ExecutionMode::ReadOnly` predicate call)
        // would incorrectly unmark the account as touched, dropping the earlier committed
        // transaction's changes from the state diff at `finalize()`. The caller must not call
        // `mark_touch()` itself before this, or the guard below would always see the account as
        // already touched and never record the entry needed to undo a genuine first touch.
        self.touch(address);

        if bump_nonce {
            // nonce changed.
            self.journal.push(ENTRY::nonce_changed(address));
        }
    }

    /// Increments the balance of the account.
    ///
    /// Mark account as touched.
    #[inline]
    pub fn balance_incr<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
        balance: U256,
    ) -> Result<(), DB::Error> {
        let account = self.load_account(db, address)?.data;
        let old_balance = account.info.balance;
        account.info.balance = account.info.balance.saturating_add(balance);

        // march account as touched.
        if !account.is_touched() {
            account.mark_touch();
            self.journal.push(ENTRY::account_touched(address));
        }

        // add journal entry for balance increment.
        self.journal
            .push(ENTRY::balance_changed(address, old_balance));
        Ok(())
    }

    /// Increments the nonce of the account.
    #[inline]
    pub fn nonce_bump_journal_entry(&mut self, address: Address) {
        self.journal.push(ENTRY::nonce_changed(address));
    }

    /// Transfers balance from two accounts. Returns error if sender balance is not enough.
    #[inline]
    pub fn transfer<DB: Database>(
        &mut self,
        db: &mut DB,
        from: Address,
        to: Address,
        balance: U256,
    ) -> Result<Option<TransferError>, DB::Error> {
        if balance.is_zero() {
            self.load_account(db, to)?;
            let to_account = self.state.get_mut(&to).unwrap();
            Self::touch_account(&mut self.journal, to, to_account);
            return Ok(None);
        }
        // load accounts
        self.load_account(db, from)?;
        self.load_account(db, to)?;

        // sub balance from
        let from_account = self.state.get_mut(&from).unwrap();
        Self::touch_account(&mut self.journal, from, from_account);
        let from_balance = &mut from_account.info.balance;

        let Some(from_balance_decr) = from_balance.checked_sub(balance) else {
            return Ok(Some(TransferError::OutOfFunds));
        };
        *from_balance = from_balance_decr;

        // add balance to
        let to_account = &mut self.state.get_mut(&to).unwrap();
        Self::touch_account(&mut self.journal, to, to_account);
        let to_balance = &mut to_account.info.balance;
        let Some(to_balance_incr) = to_balance.checked_add(balance) else {
            return Ok(Some(TransferError::OverflowPayment));
        };
        *to_balance = to_balance_incr;
        // Overflow of U256 balance is not possible to happen on mainnet. We don't bother to return funds from from_acc.

        self.journal
            .push(ENTRY::balance_transfer(from, to, balance));

        Ok(None)
    }

    /// Creates account or returns false if collision is detected.
    ///
    /// There are few steps done:
    /// 1. Make created account warm loaded (AccessList) and this should
    ///    be done before subroutine checkpoint is created.
    /// 2. Check if there is collision of newly created account with existing one.
    /// 3. Mark created account as created.
    /// 4. Add fund to created account
    /// 5. Increment nonce of created account if SpuriousDragon is active
    /// 6. Decrease balance of caller account.
    ///
    /// # Panics
    ///
    /// Panics if the caller is not loaded inside the EVM state.
    /// This should have been done inside `create_inner`.
    #[inline]
    pub fn create_account_checkpoint(
        &mut self,
        caller: Address,
        target_address: Address,
        balance: U256,
        spec_id: SpecId,
    ) -> Result<JournalCheckpoint, TransferError> {
        // Enter subroutine
        let checkpoint = self.checkpoint();

        // Fetch balance of caller.
        let caller_balance = self.state.get(&caller).unwrap().info.balance;
        // Check if caller has enough balance to send to the created contract.
        if caller_balance < balance {
            self.checkpoint_revert(checkpoint);
            return Err(TransferError::OutOfFunds);
        }

        // Newly created account is present, as we just loaded it.
        let target_acc = self.state.get_mut(&target_address).unwrap();
        let last_journal = &mut self.journal;

        // New account can be created if:
        // Bytecode is not empty.
        // Nonce is not zero
        // Account is not precompile.
        if target_acc.info.code_hash != KECCAK_EMPTY || target_acc.info.nonce != 0 {
            self.checkpoint_revert(checkpoint);
            return Err(TransferError::CreateCollision);
        }

        // set account status to create.
        let is_created_globally = target_acc.mark_created_locally();

        // this entry will revert set nonce.
        last_journal.push(ENTRY::account_created(target_address, is_created_globally));
        target_acc.info.code = None;
        // EIP-161: State trie clearing (invariant-preserving alternative)
        if spec_id.is_enabled_in(SPURIOUS_DRAGON) {
            // nonce is going to be reset to zero in AccountCreated journal entry.
            target_acc.info.nonce = 1;
        }

        // touch account. This is important as for pre SpuriousDragon account could be
        // saved even empty.
        Self::touch_account(last_journal, target_address, target_acc);

        // Add balance to created account, as we already have target here.
        let Some(new_balance) = target_acc.info.balance.checked_add(balance) else {
            self.checkpoint_revert(checkpoint);
            return Err(TransferError::OverflowPayment);
        };
        target_acc.info.balance = new_balance;

        // safe to decrement for the caller as balance check is already done.
        self.state.get_mut(&caller).unwrap().info.balance -= balance;

        // add journal entry of transferred balance
        last_journal.push(ENTRY::balance_transfer(caller, target_address, balance));

        Ok(checkpoint)
    }

    /// Makes a checkpoint that in case of Revert can bring back state to this point.
    #[inline]
    pub fn checkpoint(&mut self) -> JournalCheckpoint {
        let checkpoint = JournalCheckpoint {
            log_i: self.logs.len(),
            journal_i: self.journal.len(),
        };
        self.depth += 1;
        checkpoint
    }

    /// Commits the checkpoint.
    #[inline]
    pub fn checkpoint_commit(&mut self) {
        self.depth -= 1;
    }

    /// Reverts all changes to state until given checkpoint.
    #[inline]
    pub fn checkpoint_revert(&mut self, checkpoint: JournalCheckpoint) {
        let is_spurious_dragon_enabled = self.spec.is_enabled_in(SPURIOUS_DRAGON);
        let state = &mut self.state;
        let transient_storage = &mut self.transient_storage;
        self.depth -= 1;
        self.logs.truncate(checkpoint.log_i);

        // iterate over last N journals sets and revert our global state
        if checkpoint.journal_i < self.journal.len() {
            self.journal
                .drain(checkpoint.journal_i..)
                .rev()
                .for_each(|entry| {
                    entry.revert(state, Some(transient_storage), is_spurious_dragon_enabled);
                });
        }
    }

    /// Performs selfdestruct action.
    /// Transfers balance from address to target. Check if target exist/is_cold
    ///
    /// Note: Balance will be lost if address and target are the same BUT when
    /// current spec enables Cancun, this happens only when the account associated to address
    /// is created in the same tx
    ///
    /// # References:
    ///  * <https://github.com/ethereum/go-ethereum/blob/141cd425310b503c5678e674a8c3872cf46b7086/core/vm/instructions.go#L832-L833>
    ///  * <https://github.com/ethereum/go-ethereum/blob/141cd425310b503c5678e674a8c3872cf46b7086/core/state/statedb.go#L449>
    ///  * <https://eips.ethereum.org/EIPS/eip-6780>
    #[inline]
    pub fn selfdestruct<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
        target: Address,
    ) -> Result<StateLoad<SelfDestructResult>, DB::Error> {
        let spec = self.spec;
        let account_load = self.load_account(db, target)?;
        let is_cold = account_load.is_cold;
        let is_empty = account_load.state_clear_aware_is_empty(spec);

        if address != target {
            // Both accounts are loaded before this point, `address` as we execute its contract.
            // and `target` at the beginning of the function.
            let acc_balance = self.state.get(&address).unwrap().info.balance;

            let target_account = self.state.get_mut(&target).unwrap();
            Self::touch_account(&mut self.journal, target, target_account);
            target_account.info.balance += acc_balance;
        }

        let acc = self.state.get_mut(&address).unwrap();
        let balance = acc.info.balance;

        let destroyed_status = if !acc.is_selfdestructed() {
            SelfdestructionRevertStatus::GloballySelfdestroyed
        } else if !acc.is_selfdestructed_locally() {
            SelfdestructionRevertStatus::LocallySelfdestroyed
        } else {
            SelfdestructionRevertStatus::RepeatedSelfdestruction
        };

        let is_cancun_enabled = spec.is_enabled_in(CANCUN);

        // EIP-6780 (Cancun hard-fork): selfdestruct only if contract is created in the same tx
        let journal_entry = if acc.is_created_locally() || !is_cancun_enabled {
            acc.mark_selfdestructed_locally();
            acc.info.balance = U256::ZERO;
            Some(ENTRY::account_destroyed(
                address,
                target,
                destroyed_status,
                balance,
            ))
        } else if address != target {
            acc.info.balance = U256::ZERO;
            Some(ENTRY::balance_transfer(address, target, balance))
        } else {
            // State is not changed:
            // * if we are after Cancun upgrade and
            // * Selfdestruct account that is created in the same transaction and
            // * Specify the target is same as selfdestructed account. The balance stays unchanged.
            None
        };

        if let Some(entry) = journal_entry {
            self.journal.push(entry);
        };

        Ok(StateLoad {
            data: SelfDestructResult {
                had_value: !balance.is_zero(),
                target_exists: !is_empty,
                previously_destroyed: destroyed_status
                    == SelfdestructionRevertStatus::RepeatedSelfdestruction,
            },
            is_cold,
        })
    }

    /// Loads account into memory. return if it is cold or warm accessed
    #[inline]
    pub fn load_account<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
    ) -> Result<StateLoad<&mut Account>, DB::Error> {
        self.load_account_optional(db, address, false, [])
    }

    /// Loads account into memory. If account is EIP-7702 type it will additionally
    /// load delegated account.
    ///
    /// It will mark both this and delegated account as warm loaded.
    ///
    /// Returns information about the account (If it is empty or cold loaded) and if present the information
    /// about the delegated account (If it is cold loaded).
    #[inline]
    pub fn load_account_delegated<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
    ) -> Result<StateLoad<AccountLoad>, DB::Error> {
        let spec = self.spec;
        let is_eip7702_enabled = spec.is_enabled_in(SpecId::PRAGUE);
        let account = self.load_account_optional(db, address, is_eip7702_enabled, [])?;
        let is_empty = account.state_clear_aware_is_empty(spec);

        let mut account_load = StateLoad::new(
            AccountLoad {
                is_delegate_account_cold: None,
                is_empty,
            },
            account.is_cold,
        );

        // load delegate code if account is EIP-7702
        if let Some(Bytecode::Eip7702(code)) = &account.info.code {
            let address = code.address();
            let delegate_account = self.load_account(db, address)?;
            account_load.data.is_delegate_account_cold = Some(delegate_account.is_cold);
        }

        Ok(account_load)
    }

    /// Loads account and its code. If account is already loaded it will load its code.
    ///
    /// It will mark account as warm loaded. If not existing Database will be queried for data.
    ///
    /// In case of EIP-7702 delegated account will not be loaded,
    /// [`Self::load_account_delegated`] should be used instead.
    #[inline]
    pub fn load_code<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
    ) -> Result<StateLoad<&mut Account>, DB::Error> {
        self.load_account_optional(db, address, true, [])
    }

    /// Loads account. If account is already loaded it will be marked as warm.
    #[inline]
    pub fn load_account_optional<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
        load_code: bool,
        storage_keys: impl IntoIterator<Item = StorageKey>,
    ) -> Result<StateLoad<&mut Account>, DB::Error> {
        let load = match self.state.entry(address) {
            Entry::Occupied(entry) => {
                let account = entry.into_mut();
                let is_cold = account.mark_warm_with_transaction_id(self.transaction_id);
                // if it is cold loaded we need to clear local flags that can interact with selfdestruct
                if is_cold {
                    // if it is cold loaded and we have selfdestructed locally it means that
                    // account was selfdestructed in previous transaction and we need to clear its information and storage.
                    if account.is_selfdestructed_locally() {
                        account.selfdestruct();
                        account.unmark_selfdestructed_locally();
                        // The destruction from that earlier, already-committed
                        // transaction has now been fully realized (storage and
                        // info wiped above) - this account is a blank slate as
                        // of this transaction. Clear the persistent global
                        // flags too, so that if this (or a later) transaction
                        // recreates the account, it is not incorrectly still
                        // treated as destroyed when the block's final state is
                        // computed (EIP-6780), and so that a standalone,
                        // finalize-per-tx execution of the same transaction
                        // sequence - where this account would simply be a
                        // freshly-loaded, never-created object - produces the
                        // same bookkeeping view of this account as this
                        // shared-journal, multi-tx execution does.
                        account.unmark_selfdestruct();
                        account.unmark_created();
                    }
                    // unmark locally created
                    account.unmark_created_locally();
                }
                StateLoad {
                    data: account,
                    is_cold,
                }
            }
            Entry::Vacant(vac) => {
                let account = if let Some(account) = db.basic(address)? {
                    account.into()
                } else {
                    Account::new_not_existing(self.transaction_id)
                };

                // Precompiles among some other account(coinbase included) are warm loaded so we need to take that into account
                let is_cold = self.warm_addresses.is_cold(&address);

                StateLoad {
                    data: vac.insert(account),
                    is_cold,
                }
            }
        };

        // journal loading of cold account.
        if load.is_cold {
            self.journal.push(ENTRY::account_warmed(address));
        }
        if load_code {
            let info = &mut load.data.info;
            if info.code.is_none() {
                let code = if info.code_hash == KECCAK_EMPTY {
                    Bytecode::default()
                } else {
                    db.code_by_hash(info.code_hash)?
                };
                info.code = Some(code);
            }
        }

        for storage_key in storage_keys.into_iter() {
            sload_with_account(
                load.data,
                db,
                &mut self.journal,
                self.transaction_id,
                address,
                storage_key,
            )?;
        }
        Ok(load)
    }

    /// Loads storage slot.
    ///
    /// # Panics
    ///
    /// Panics if the account is not present in the state.
    #[inline]
    pub fn sload<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
        key: StorageKey,
    ) -> Result<StateLoad<StorageValue>, DB::Error> {
        // assume acc is warm
        let account = self.state.get_mut(&address).unwrap();
        // only if account is created in this tx we can assume that storage is empty.
        sload_with_account(
            account,
            db,
            &mut self.journal,
            self.transaction_id,
            address,
            key,
        )
    }

    /// Stores storage slot.
    ///
    /// And returns (original,present,new) slot value.
    ///
    /// **Note**: Account should already be present in our state.
    #[inline]
    pub fn sstore<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
        key: StorageKey,
        new: StorageValue,
    ) -> Result<StateLoad<SStoreResult>, DB::Error> {
        // assume that acc exists and load the slot.
        let present = self.sload(db, address, key)?;
        let acc = self.state.get_mut(&address).unwrap();

        // if there is no original value in dirty return present value, that is our original.
        let slot = acc.storage.get_mut(&key).unwrap();

        // new value is same as present, we don't need to do anything
        if present.data == new {
            return Ok(StateLoad::new(
                SStoreResult {
                    original_value: slot.original_value(),
                    present_value: present.data,
                    new_value: new,
                },
                present.is_cold,
            ));
        }

        self.journal
            .push(ENTRY::storage_changed(address, key, present.data));
        // insert value into present state.
        slot.present_value = new;
        Ok(StateLoad::new(
            SStoreResult {
                original_value: slot.original_value(),
                present_value: present.data,
                new_value: new,
            },
            present.is_cold,
        ))
    }

    /// Read transient storage tied to the account.
    ///
    /// EIP-1153: Transient storage opcodes
    #[inline]
    pub fn tload(&mut self, address: Address, key: StorageKey) -> StorageValue {
        self.transient_storage
            .get(&(address, key))
            .copied()
            .unwrap_or_default()
    }

    /// Store transient storage tied to the account.
    ///
    /// If values is different add entry to the journal
    /// so that old state can be reverted if that action is needed.
    ///
    /// EIP-1153: Transient storage opcodes
    #[inline]
    pub fn tstore(&mut self, address: Address, key: StorageKey, new: StorageValue) {
        let had_value = if new.is_zero() {
            // if new values is zero, remove entry from transient storage.
            // if previous values was some insert it inside journal.
            // If it is none nothing should be inserted.
            self.transient_storage.remove(&(address, key))
        } else {
            // insert values
            let previous_value = self
                .transient_storage
                .insert((address, key), new)
                .unwrap_or_default();

            // check if previous value is same
            if previous_value != new {
                // if it is different, insert previous values inside journal.
                Some(previous_value)
            } else {
                None
            }
        };

        if let Some(had_value) = had_value {
            // insert in journal only if value was changed.
            self.journal
                .push(ENTRY::transient_storage_changed(address, key, had_value));
        }
    }

    /// Pushes log into subroutine.
    #[inline]
    pub fn log(&mut self, log: Log) {
        self.logs.push(log);
    }
}

/// Loads storage slot with account.
#[inline]
pub fn sload_with_account<DB: Database, ENTRY: JournalEntryTr>(
    account: &mut Account,
    db: &mut DB,
    journal: &mut Vec<ENTRY>,
    transaction_id: usize,
    address: Address,
    key: StorageKey,
) -> Result<StateLoad<StorageValue>, DB::Error> {
    let is_newly_created = account.is_created();
    let (value, is_cold) = match account.storage.entry(key) {
        Entry::Occupied(occ) => {
            let slot = occ.into_mut();
            // EIP-2200/EIP-3529: "original value" must track the value at the
            // start of the CURRENT transaction ("what the value would be if
            // the current transaction is reverted"). If this slot was last
            // touched by an *earlier*, already-committed transaction sharing
            // this journal (revm's single-journal, multi-tx execution mode,
            // e.g. `transact_many()`), its transaction_id will differ from
            // the current one - that earlier transaction's final
            // `present_value` is this transaction's correct origin baseline.
            //
            // This check is keyed off `transaction_id`, not the `is_cold`
            // return value below, because `is_cold` can also become true
            // from an in-transaction revert re-marking the slot cold (same
            // transaction_id), which must NOT reset `original_value`.
            let is_new_tx = slot.transaction_id != transaction_id;
            let is_cold = slot.mark_warm_with_transaction_id(transaction_id);
            if is_new_tx {
                slot.original_value = slot.present_value;
            }
            (slot.present_value, is_cold)
        }
        Entry::Vacant(vac) => {
            // if storage was cleared, we don't need to ping db.
            let value = if is_newly_created {
                StorageValue::ZERO
            } else {
                db.storage(address, key)?
            };

            vac.insert(EvmStorageSlot::new(value, transaction_id));

            (value, true)
        }
    };

    if is_cold {
        // add it to journal as cold loaded.
        journal.push(ENTRY::storage_warmed(address, key));
    }

    Ok(StateLoad::new(value, is_cold))
}

#[cfg(test)]
mod eip2200_original_value_tests {
    use super::*;
    use crate::JournalEntry;
    use database::{CacheDB, EmptyDB};

    /// EIP-2200 defines "original value" as "what the value would be if the
    /// CURRENT transaction is reverted" - i.e. the slot's value at the start
    /// of the transaction currently executing.
    ///
    /// This test checks that `EvmStorageSlot::original_value` is refreshed
    /// at the transaction boundary (`commit_tx`) when a single `JournalInner`
    /// is reused across multiple transactions in the same block (revm's
    /// single-journal, multi-tx execution model, e.g. `transact_many()`).
    #[test]
    fn original_value_should_track_start_of_current_tx_not_start_of_block() {
        let mut journal = JournalInner::<JournalEntry>::new();
        let mut db = EmptyDB::new();

        let addr = Address::with_last_byte(1);
        let key = StorageKey::from(1);
        let value_a = StorageValue::from(42);

        // --- Transaction 1 (of this block): slot goes 0 -> A, then commits ---
        journal.load_account(&mut db, addr).unwrap();
        let t1 = journal.sstore(&mut db, addr, key, value_a).unwrap().data;
        assert_eq!(t1.original_value, StorageValue::ZERO, "T1 original should be pre-block DB value (0)");
        assert_eq!(t1.present_value, StorageValue::ZERO);
        assert_eq!(t1.new_value, value_a);

        // Transaction boundary: T1 is done and committed, T2 begins.
        journal.commit_tx();

        // --- Transaction 2 (same block, same journal): slot goes A -> 0 ---
        let t2 = journal.sstore(&mut db, addr, key, StorageValue::ZERO).unwrap().data;

        // Per EIP-2200, T2's "original value" must be A: that's what the slot
        // would revert back to if *T2 alone* were reverted, since T1 already
        // committed. Without the fix this was 0 (stale pre-block DB value),
        // which would cause sstore_refund() to compute an incorrect gas
        // refund for T2 (e.g. its is_original_eq_new() branch firing on
        // 0 == 0, treating T2 as "restoring the original value" when it is
        // not).
        assert_eq!(
            t2.original_value, value_a,
            "T2's original_value is {:?}, expected {:?} (T1's committed value).",
            t2.original_value, value_a
        );
    }

    /// Same scenario, but modeling `ExecuteEvm::transact()`'s pattern: each
    /// transaction gets its own `JournalInner` session that is finalized
    /// (`finalize()`) and committed to a persistent outer `Database`
    /// immediately after, rather than being reused via `commit_tx()` across
    /// multiple transactions. This is `transact()` / `transact_commit()`
    /// (finalize-per-tx), as opposed to `transact_many()` (one shared journal,
    /// single finalize at the end).
    #[test]
    fn original_value_is_correct_when_each_tx_gets_its_own_finalized_session() {
        use database::DatabaseCommit;

        let mut db = CacheDB::new(EmptyDB::new());

        let addr = Address::with_last_byte(1);
        let key = StorageKey::from(1);
        let value_a = StorageValue::from(42);

        // --- Session 1 (transaction 1): fresh journal, 0 -> A ---
        let mut journal1 = JournalInner::<JournalEntry>::new();
        journal1.load_account(&mut db, addr).unwrap();
        let t1 = journal1.sstore(&mut db, addr, key, value_a).unwrap().data;
        assert_eq!(t1.original_value, StorageValue::ZERO);
        // A real transaction touches every account it modifies (e.g. via
        // deduct_caller / account-load accounting); CacheDB::commit() silently
        // skips untouched accounts, so this is required for the diff to land.
        journal1.touch(addr);

        journal1.commit_tx(); // handler.rs commits the single tx internally
        let state1 = journal1.finalize(); // transact() finalizes right after
        db.commit(state1); // caller commits the diff into the persistent DB

        // --- Session 2 (transaction 2): brand new journal/session, A -> 0 ---
        let mut journal2 = JournalInner::<JournalEntry>::new();
        journal2.load_account(&mut db, addr).unwrap();
        let t2 = journal2.sstore(&mut db, addr, key, StorageValue::ZERO).unwrap().data;

        // Because this session's `state` map starts empty, the slot is loaded
        // fresh from `db` (which already has T1's committed value), so
        // original_value is correct here without needing any fix.
        assert_eq!(
            t2.original_value, value_a,
            "original_value should be sourced fresh from the committed DB \
             value in the finalize-per-tx pattern, independent of the \
             commit_tx()-reuse bug."
        );
    }
}

#[cfg(test)]
mod eip6780_recreate_after_selfdestruct_tests {
    use super::*;
    use crate::JournalEntry;
    use context_interface::journaled_state::TransferError;
    use database::{CacheDB, DatabaseCommit, EmptyDB};
    use primitives::hardfork::SpecId;

    type TestJournal = JournalInner<JournalEntry>;
    type TestDb = CacheDB<EmptyDB>;

    const SPEC: SpecId = SpecId::CANCUN;

    /// Sets up a journal + DB with a funded caller, ready to drive a sequence
    /// of CREATE2/SELFDESTRUCT calls across multiple transactions sharing one
    /// journal (revm's single-journal, multi-tx execution mode, e.g.
    /// `transact_many()` - this is where all the bugs in this module were
    /// found, since `transact()`'s finalize-per-tx pattern starts each
    /// transaction with a fresh, empty `state` map).
    fn setup() -> (TestJournal, TestDb, Address) {
        let mut db = TestDb::new(EmptyDB::new());
        let mut journal = TestJournal::new();
        journal.set_spec_id(SPEC);

        let caller = Address::with_last_byte(1);
        journal.load_account(&mut db, caller).unwrap();
        journal.state.get_mut(&caller).unwrap().info.balance = U256::from(1_000);

        (journal, db, caller)
    }

    /// Creates a contract at `addr` within the current transaction, tagging
    /// it with a distinct `code_hash` so tests can tell which "generation"
    /// of the contract ends up surviving.
    fn create_at(
        journal: &mut TestJournal,
        db: &mut TestDb,
        caller: Address,
        addr: Address,
        code_hash: B256,
    ) -> Result<(), TransferError> {
        journal.load_account(db, addr).unwrap();
        journal.create_account_checkpoint(caller, addr, U256::ZERO, SPEC)?;
        journal.state.get_mut(&addr).unwrap().info.code_hash = code_hash;
        journal.checkpoint_commit();
        journal.touch(addr);
        Ok(())
    }

    /// Selfdestructs the contract at `addr` within the current transaction.
    fn destroy_at(journal: &mut TestJournal, db: &mut TestDb, addr: Address, target: Address) {
        journal.selfdestruct(db, addr, target).unwrap();
        journal.touch(addr);
    }

    const CODE_V1: B256 = B256::new([1; 32]);
    const CODE_V2: B256 = B256::new([2; 32]);
    const CODE_V3: B256 = B256::new([3; 32]);

    /// create -> destroy (same tx) -> recreate (later tx, no destroy).
    ///
    /// T1 creates a contract at `addr` (e.g. via CREATE2) and selfdestructs
    /// it in the same transaction (EIP-6780 full-delete path). T1 commits.
    /// T2, later in the *same block* (sharing this journal), creates a
    /// contract at the *same* `addr` (e.g. same CREATE2 caller/salt/init-code)
    /// and does NOT selfdestruct it.
    ///
    /// Expected: the account is alive at the end of the block - T2's
    /// creation should be reflected in the final state.
    #[test]
    fn create_destroy_then_recreate_is_alive() {
        let (mut journal, mut db, caller) = setup();
        let addr = Address::with_last_byte(2);

        // --- T1: create at `addr`, then selfdestruct it (same tx) ---
        create_at(&mut journal, &mut db, caller, addr, CODE_V1).unwrap();
        destroy_at(&mut journal, &mut db, addr, caller);
        journal.commit_tx(); // T1 done, T2 begins

        // --- T2 (same block, same journal): recreate, do NOT destroy ---
        create_at(&mut journal, &mut db, caller, addr, CODE_V2).unwrap();
        journal.commit_tx(); // T2 done

        let state = journal.finalize();
        let final_account = state.get(&addr).unwrap().clone();
        assert!(final_account.is_created(), "sanity: account was created");
        assert!(
            !final_account.is_selfdestructed(),
            "account is still flagged globally selfdestructed even though \
             T2 legitimately recreated it afterward without destroying it \
             again"
        );

        // Demonstrate the real-world consequence: commit to a persistent DB
        // and check whether the contract survives.
        db.commit(state);
        let committed = db.basic(addr).unwrap().expect("account should exist in DB");
        assert_eq!(
            committed.code_hash, CODE_V2,
            "T2's contract should be the one persisted, not wiped as destroyed"
        );
    }

    /// create -> destroy -> recreate -> destroy (again, same tx as the
    /// recreate).
    ///
    /// T1 creates and destroys `addr` (same tx). T2 recreates `addr` *and*
    /// destroys it again, both within T2 (same-tx create+destroy, its own
    /// independent EIP-6780 full-delete event).
    ///
    /// Expected: the account ends the block genuinely destroyed - the fix
    /// must not make a same-tx create+destroy in T2 "stick alive" just
    /// because an earlier transaction's destruction was un-marked.
    #[test]
    fn create_destroy_recreate_destroy_ends_destroyed() {
        let (mut journal, mut db, caller) = setup();
        let addr = Address::with_last_byte(2);

        // --- T1: create then destroy (same tx) ---
        create_at(&mut journal, &mut db, caller, addr, CODE_V1).unwrap();
        destroy_at(&mut journal, &mut db, addr, caller);
        journal.commit_tx();

        // --- T2: recreate then destroy again, both in this same tx ---
        create_at(&mut journal, &mut db, caller, addr, CODE_V2).unwrap();
        destroy_at(&mut journal, &mut db, addr, caller);
        journal.commit_tx();

        let state = journal.finalize();
        let final_account = state.get(&addr).unwrap().clone();
        assert!(
            final_account.is_selfdestructed(),
            "account should be destroyed: T2 created AND destroyed it in \
             the same transaction, an independent EIP-6780 full-delete event"
        );
    }

    /// create (T1) -> selfdestruct in a *later*, unrelated transaction (T2).
    ///
    /// Per EIP-6780, since the SELFDESTRUCT happens in a different
    /// transaction than the CREATE, this must NOT take the "same-tx full
    /// delete" path - only the balance is transferred, code/storage survive.
    #[test]
    fn cross_tx_selfdestruct_does_not_fully_delete() {
        let (mut journal, mut db, caller) = setup();
        let addr = Address::with_last_byte(2);
        let target = Address::with_last_byte(3);

        // --- T1: create, do NOT destroy ---
        create_at(&mut journal, &mut db, caller, addr, CODE_V1).unwrap();
        let balance = U256::from(1_000);
        journal.balance_incr(&mut db, addr, balance).unwrap();
        journal.commit_tx();
        let acc = journal.state.get(&addr).unwrap();
        assert_eq!(acc.info.balance, balance, "balance should be non zero");

        // --- T2: a later, unrelated tx selfdestructs it ---
        journal.load_account(&mut db, addr).unwrap();
        destroy_at(&mut journal, &mut db, addr, target);

        let acc = journal.state.get(&addr).unwrap();
        assert!(
            !acc.is_selfdestructed_locally(),
            "cross-tx selfdestruct must not take the same-tx 'full delete' \
             path - it wasn't created in this transaction"
        );
        assert_eq!(acc.info.balance, U256::ZERO, "balance should be transferred out");
        assert_eq!(
            acc.info.code_hash, CODE_V1,
            "code must survive a cross-tx selfdestruct per EIP-6780"
        );

        let target_acc = journal.state.get(&target).unwrap();
        assert_eq!(
            target_acc.info.balance, balance,
            "the destroyed account's balance should land on the target address"
        );
    }

    /// create (T1) -> cross-tx selfdestruct (T2) -> attempted recreate (T3).
    ///
    /// Once a contract survives past its creating transaction, EIP-6780
    /// means it is never actually removable from the trie by SELFDESTRUCT
    /// again - so a later CREATE2 at the same address must still collide,
    /// since the account still has code. This guards against the fix
    /// over-reaching and allowing recreation where it shouldn't.
    #[test]
    fn cross_tx_destroyed_contract_cannot_be_recreated() {
        let (mut journal, mut db, caller) = setup();
        let addr = Address::with_last_byte(2);
        let target = Address::with_last_byte(3);

        create_at(&mut journal, &mut db, caller, addr, CODE_V1).unwrap();
        journal.commit_tx();

        journal.load_account(&mut db, addr).unwrap();
        destroy_at(&mut journal, &mut db, addr, target);
        journal.commit_tx();

        let err = create_at(&mut journal, &mut db, caller, addr, CODE_V2).unwrap_err();
        assert_eq!(
            err,
            TransferError::CreateCollision,
            "an address whose code survived a cross-tx selfdestruct must \
             still be uncreatable"
        );
    }

    /// create -> destroy (same tx) -> an intervening transaction merely
    /// *touches* the account without recreating it -> a later transaction
    /// recreates it.
    ///
    /// This specifically guards against an off-by-one timing bug: the fix
    /// must clear the stale global `SelfDestructed` flag at the moment of
    /// the lazy cold-load wipe itself, not deferred until whichever
    /// transaction happens to touch the address next after a recreate.
    #[test]
    fn intervening_touch_then_later_recreate_is_alive() {
        let (mut journal, mut db, caller) = setup();
        let addr = Address::with_last_byte(2);

        create_at(&mut journal, &mut db, caller, addr, CODE_V1).unwrap();
        destroy_at(&mut journal, &mut db, addr, caller);
        journal.commit_tx(); // T1 done

        // --- T2: just touches the address, no create, no destroy ---
        journal.load_account(&mut db, addr).unwrap();
        journal.commit_tx(); // T2 done

        // --- T3: recreates it ---
        create_at(&mut journal, &mut db, caller, addr, CODE_V2).unwrap();
        journal.commit_tx(); // T3 done

        let state = journal.finalize();
        let final_account = state.get(&addr).unwrap().clone();
        assert!(final_account.is_created());
        assert!(
            !final_account.is_selfdestructed(),
            "an intervening transaction that only touched (didn't recreate) \
             the address must not prevent a later recreate from being seen \
             as alive"
        );
    }

    /// Multiple full destroy/recreate cycles: create+destroy (T1) ->
    /// recreate+destroy (T2, its own same-tx cycle) -> recreate only (T3).
    ///
    /// Stress-tests that the global flag is correctly cleared and re-set on
    /// every cycle, not just the first one.
    #[test]
    fn multiple_full_destroy_recreate_cycles_end_alive() {
        let (mut journal, mut db, caller) = setup();
        let addr = Address::with_last_byte(2);

        create_at(&mut journal, &mut db, caller, addr, CODE_V1).unwrap();
        destroy_at(&mut journal, &mut db, addr, caller);
        journal.commit_tx(); // T1: create+destroy

        create_at(&mut journal, &mut db, caller, addr, CODE_V2).unwrap();
        destroy_at(&mut journal, &mut db, addr, caller);
        journal.commit_tx(); // T2: recreate+destroy again

        create_at(&mut journal, &mut db, caller, addr, CODE_V3).unwrap();
        journal.commit_tx(); // T3: recreate, no destroy

        let state = journal.finalize();
        let final_account = state.get(&addr).unwrap().clone();
        assert!(
            !final_account.is_selfdestructed(),
            "after two full destroy/recreate cycles, a third recreate with \
             no further destroy must end up alive"
        );
        assert_eq!(
            final_account.info.code_hash, CODE_V3,
            "the surviving contract should be T3's"
        );
    }

    /// create -> destroy (T1, same tx) -> a *middle* transaction (T2) that
    /// neither creates nor destroys, but writes a new balance to the dead
    /// address -> recreate (T3).
    ///
    /// Real Ethereum semantics: sending value to a dead address resurrects a
    /// plain, code-less account holding that balance; a later CREATE2 there
    /// is still allowed (only code_hash/nonce gate the collision check, not
    /// balance) and *adds* its value on top of what's already there rather
    /// than overwriting it. This must hold the same way whether T1/T2/T3
    /// run as three separate finalize-per-tx sessions (each starting from a
    /// clean slate re-read from the DB) or share one journal across
    /// `commit_tx()` calls (where the account object, including its stale
    /// global `Created` flag, is carried forward in memory).
    #[test]
    fn touch_with_new_balance_between_destroy_and_recreate_is_preserved() {
        let (mut journal, mut db, caller) = setup();
        let addr = Address::with_last_byte(2);
        let extra_balance = U256::from(77);

        // --- T1: create then destroy (same tx) ---
        create_at(&mut journal, &mut db, caller, addr, CODE_V1).unwrap();
        destroy_at(&mut journal, &mut db, addr, caller);
        journal.commit_tx();

        // --- T2: neither creates nor destroys - just writes a new balance ---
        journal.load_account(&mut db, addr).unwrap();
        let acc = journal.state.get_mut(&addr).unwrap();
        assert_eq!(
            acc.info.code_hash, KECCAK_EMPTY,
            "sanity: T1's destruction should already be physically wiped by \
             T2's cold-load, before T2 does anything itself"
        );
        acc.info.balance += extra_balance;
        journal.touch(addr);
        journal.commit_tx();

        // --- T3: recreates it ---
        let create_value = U256::from(10);
        journal.load_account(&mut db, addr).unwrap();
        journal
            .create_account_checkpoint(caller, addr, create_value, SPEC)
            .unwrap();
        journal.state.get_mut(&addr).unwrap().info.code_hash = CODE_V3;
        journal.checkpoint_commit();
        journal.touch(addr);
        journal.commit_tx();

        let state = journal.finalize();
        let final_account = state.get(&addr).unwrap().clone();
        assert!(!final_account.is_selfdestructed());
        assert!(final_account.is_created());
        assert_eq!(final_account.info.code_hash, CODE_V3);
        assert_eq!(
            final_account.info.balance,
            extra_balance + create_value,
            "T3's creation must ADD its value on top of T2's balance, not \
             overwrite it"
        );
    }
}
