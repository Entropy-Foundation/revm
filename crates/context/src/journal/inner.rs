//! Module containing the [`JournalInner`] that is part of [`crate::Journal`].
use super::warm_addresses::WarmAddresses;
use bytecode::Bytecode;
use context_interface::{
    context::{SStoreResult, SelfDestructResult, StateLoad},
    journaled_state::{
        account::{JournaledAccount, JournaledAccountTr},
        entry::{JournalEntryTr, SelfdestructionRevertStatus},
        AccountLoad, JournalCheckpoint, JournalLoadError, TransferError,
    },
};
use core::mem;
use database_interface::Database;
use primitives::{
    eip7708::{ETH_TRANSFER_LOG_ADDRESS, ETH_TRANSFER_LOG_TOPIC},
    hardfork::SpecId::{self, *},
    hash_map::Entry,
    hints_util::unlikely,
    Address, Bytes, HashMap, Log, LogData, StorageKey, StorageValue, B256, KECCAK_EMPTY, U256,
};
use state::{Account, EvmState, TransactionId, TransientStorage};
use std::vec::Vec;

/// Configuration for the journal that affects EVM execution behavior.
///
/// This struct bundles the spec ID and EIP-7708 configuration flags.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct JournalCfg {
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
    /// Whether EIP-7708 (ETH transfers emit logs) is disabled.
    pub eip7708_disabled: bool,
    /// Whether the EIP-8246 delayed clearing of self-destructed accounts is disabled.
    ///
    /// When enabled, revm tracks all self-destructed addresses and, at the end of the
    /// transaction, clears the code, storage and nonce of any that still have a remaining
    /// balance while preserving the balance (see [EIP-8246]). This can be disabled for
    /// performance reasons as it requires storing and iterating over all self-destructed
    /// accounts. When disabled, this clearing can be done outside of revm when applying
    /// accounts to database state.
    ///
    /// [EIP-8246]: https://eips.ethereum.org/EIPS/eip-8246
    pub eip8246_delayed_clear_disabled: bool,
}
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
    pub transaction_id: TransactionId,
    /// Journal configuration containing spec ID and EIP-7708 flags.
    pub cfg: JournalCfg,
    /// Warm addresses containing both coinbase and current precompiles.
    pub warm_addresses: WarmAddresses,
    /// Running total of native value removed from circulation by self-destructed
    /// accounts. It has two parts:
    ///
    /// - the balance a `SELFDESTRUCT` zeroes when the destroyed account is its own
    ///   beneficiary, which credits no account. This is added at the opcode and
    ///   decremented again when the journal entry that recorded it is reverted, so a
    ///   reverted frame or a discarded transaction contributes nothing;
    /// - the balance each account marked self-destructed in a transaction holds when
    ///   that transaction is committed. The account is deleted with that balance,
    ///   either when a later transaction in the same journal loads it or when the
    ///   state is finalized, so the balance is destroyed even though it was credited
    ///   after the `SELFDESTRUCT`. This is added by [`Self::commit_tx`], after which
    ///   nothing can revert it.
    ///
    /// Supra's EVM native balance mirrors value escrowed outside the EVM and cannot be
    /// minted, so the host has to account for every destruction of it.
    ///
    /// Unlike the other fields this one is deliberately **not** cleared by
    /// [`Self::commit_tx`] or [`Self::finalize`], so that it is still readable after
    /// execution has finished. It is a running total since the last
    /// [`Self::take_selfdestruct_burn`].
    ///
    /// # Drain between transactions only
    ///
    /// [`Self::take_selfdestruct_burn`] must be called between transactions, never
    /// part-way through one. A later revert of an already-drained destruction has
    /// nothing left to take back, and the drained total keeps a burn that did not
    /// happen. That makes this discipline a requirement on the caller rather than
    /// advice.
    ///
    /// A violation is caught by a `debug_assert!` at each revert site, so it is loud in
    /// tests and debug builds. Release builds subtract with `saturating_sub` instead:
    /// on a consensus-critical path a broken caller should cost accounting accuracy,
    /// not a halt.
    ///
    /// # Scope is whatever the caller drains
    ///
    /// The journal has no notion of a block. Supra runs one journal per block and
    /// drains once, after the block's last transaction, which makes the drain a block
    /// total. An embedder that finalizes per transaction instead gets a
    /// per-transaction total from the same field, and those still compose, because
    /// each drain covers exactly the destructions since the previous one.
    pub selfdestruct_burn: U256,
    /// Addresses that were self-destructed for the first time in this transaction.
    ///
    /// This is used by [EIP-8246] to clear (code, storage and nonce) self-destructed accounts
    /// that still have balance at the end of the transaction, preserving their balance.
    ///
    /// The vec is indexed by checkpoint - on revert, entries added after the checkpoint
    /// are removed.
    ///
    /// [EIP-8246]: https://eips.ethereum.org/EIPS/eip-8246
    pub selfdestructed_addresses: Vec<Address>,
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
            transaction_id: TransactionId::ZERO,
            depth: 0,
            cfg: JournalCfg::default(),
            warm_addresses: WarmAddresses::new(),
            selfdestruct_burn: U256::ZERO,
            selfdestructed_addresses: Vec::new(),
        }
    }

    /// Returns the accumulated self-destruct burn total and resets it to zero.
    ///
    /// Call this only between transactions. Draining part-way through one leaves the
    /// total wrong if the destruction is later reverted; that is caught by a
    /// `debug_assert!` in debug builds and tolerated in release. See
    /// [`Self::selfdestruct_burn`] for that contract, and for what is counted and over
    /// what scope.
    #[inline]
    pub fn take_selfdestruct_burn(&mut self) -> U256 {
        mem::take(&mut self.selfdestruct_burn)
    }

    /// Returns the logs.
    ///
    /// Before returning, this function applies EIP-8246 to any self-destructed
    /// accounts that still have a non-zero balance, clearing their code, storage and
    /// nonce while preserving the balance.
    #[inline]
    pub fn take_logs(&mut self) -> Vec<Log> {
        // EIP-8246: clear self-destructed accounts that still hold a balance.
        self.eip8246_clear_selfdestructed_accounts();
        mem::take(&mut self.logs)
    }

    /// Prepare for next transaction, by committing the current journal to history, incrementing the transaction id
    /// and returning the logs.
    ///
    /// This function is used to prepare for next transaction. It will save the current journal
    /// and clear the journal for the next transaction.
    ///
    /// `commit_tx` is used even for discarding transactions so transaction_id will be incremented.
    ///
    /// Adds the balance still held by every account marked self-destructed in this
    /// transaction to [`Self::selfdestruct_burn`], because committing the transaction
    /// is what makes the deletion of those accounts final.
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
            cfg,
            warm_addresses,
            selfdestruct_burn,
            selfdestructed_addresses,
        } = self;
        // Cfg and state are not changed. They are always set again before execution.
        let _ = cfg;
        // Preserved across the transaction boundary so the host can still read it after
        // execution; see the field docs. Counted before `journal` is cleared below,
        // since the journal is what names the accounts this transaction destroyed.
        *selfdestruct_burn =
            selfdestruct_burn.saturating_add(Self::balance_of_destroyed_accounts(state, journal));
        transient_storage.clear();
        *depth = 0;

        // Do nothing with journal history so we can skip cloning present journal.
        journal.clear();

        // Clear coinbase address warming for next tx
        warm_addresses.clear_coinbase_and_access_list();
        // increment transaction id.
        transaction_id.increment();

        logs.clear();
        selfdestructed_addresses.clear();
    }

    /// Returns the summed balance of the accounts that `journal` marks as
    /// self-destructed and that are still marked so in `state`.
    ///
    /// `journal` holds the entries of one transaction that have not been reverted.
    /// An account appears once per self-destruct entry, so addresses are
    /// deduplicated before summing. The self-destructed flag is checked as well
    /// as the entry, because the flag is what decides that the account is deleted.
    fn balance_of_destroyed_accounts(state: &EvmState, journal: &[ENTRY]) -> U256 {
        let mut destroyed: Vec<Address> = journal
            .iter()
            .filter_map(JournalEntryTr::selfdestructed_address)
            .collect();
        destroyed.sort_unstable();
        destroyed.dedup();
        destroyed
            .iter()
            .filter_map(|address| state.get(address))
            .filter(|account| account.is_selfdestructed_locally())
            .fold(U256::ZERO, |sum, account| {
                sum.saturating_add(account.info.balance)
            })
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
            cfg,
            warm_addresses,
            selfdestruct_burn,
            selfdestructed_addresses,
        } = self;
        let is_spurious_dragon_enabled = cfg.spec.is_enabled_in(SPURIOUS_DRAGON);
        // iterate over all journals entries and revert our global state
        let mut reverted_burn = U256::ZERO;
        journal.drain(..).rev().for_each(|entry| {
            reverted_burn += entry.selfdestruct_burn();
            entry.revert(state, None, is_spurious_dragon_enabled);
        });
        // A discarded transaction destroyed nothing, so take back everything it added.
        debug_assert!(
            *selfdestruct_burn >= reverted_burn,
            "reverting a self-destruct burn the accumulator no longer holds: \
             the accumulator was drained mid-transaction; drain only between transactions"
        );
        // Saturating for the same reason as in `checkpoint_revert`.
        *selfdestruct_burn = selfdestruct_burn.saturating_sub(reverted_burn);
        transient_storage.clear();
        *depth = 0;
        logs.clear();
        selfdestructed_addresses.clear();
        transaction_id.increment();

        // Clear coinbase address warming for next tx
        warm_addresses.clear_coinbase_and_access_list();
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
            cfg,
            warm_addresses,
            selfdestruct_burn,
            selfdestructed_addresses,
        } = self;
        // Preserved across the transaction boundary so the host can still read it after
        // execution; see the field docs.
        let _ = selfdestruct_burn;
        // Clear coinbase address warming for next tx
        warm_addresses.clear_coinbase_and_access_list();
        selfdestructed_addresses.clear();

        let mut state = mem::take(state);

        // Pre-EIP-161 normalization: adjust empty touched accounts so the database
        // layer can always apply post-EIP-161 commit semantics (destroy empty touched
        // accounts). For pre-Spurious Dragon blocks, we prevent destruction by either
        // marking the account as created (materialized) or clearing the touched flag.
        if !cfg.spec.is_enabled_in(SPURIOUS_DRAGON) {
            for acc in state.values_mut() {
                if acc.is_touched()
                    && acc.is_empty()
                    && !acc.is_selfdestructed()
                    && !acc.is_created()
                {
                    if acc.is_loaded_as_not_existing() {
                        // Materialize empty account that didn't exist before.
                        acc.mark_created();
                    } else {
                        // Preserve existing empty account, don't let the DB layer destroy it.
                        acc.unmark_touch();
                    }
                }
            }
        }

        logs.clear();
        transient_storage.clear();

        // clear journal and journal history.
        journal.clear();
        *depth = 0;
        // reset transaction id.
        *transaction_id = TransactionId::ZERO;

        state
    }

    /// Apply [EIP-8246] to self-destructed accounts that still have a balance.
    ///
    /// This should be called before `take_logs()` at the end of transaction execution.
    /// It iterates over all accounts that were self-destructed in this transaction and,
    /// for any that still hold a non-zero balance, clears the rest of the account instead
    /// of letting the balance be burned: the nonce is reset to `0`, the code and storage are
    /// cleared, the balance is left unchanged and the self-destruct flag is removed so the
    /// account is preserved in state as a balance-only account.
    ///
    /// A non-zero balance can remain when an account receives ETH after being self-destructed
    /// in the same transaction, or when a contract created in the same transaction
    /// self-destructs to itself (see [`Self::selfdestruct`]).
    ///
    /// Accounts with a zero balance keep their self-destruct flag and are removed from state as
    /// before (they are *empty* and deleted by [EIP-161]).
    ///
    /// Self-destructed accounts can only reach this point if they were created in the same
    /// transaction (EIP-6780 is always active alongside EIP-8246), so they never have storage
    /// stored in the database and clearing the in-memory storage is sufficient.
    ///
    /// [EIP-8246]: https://eips.ethereum.org/EIPS/eip-8246
    /// [EIP-161]: https://eips.ethereum.org/EIPS/eip-161
    #[inline]
    pub fn eip8246_clear_selfdestructed_accounts(&mut self) {
        if !self.cfg.spec.is_enabled_in(AMSTERDAM) || self.cfg.eip8246_delayed_clear_disabled {
            return;
        }

        for address in &self.selfdestructed_addresses {
            let Some(account) = self.state.get_mut(address) else {
                continue;
            };

            // Zero-balance accounts stay self-destructed and are removed from state (EIP-161).
            if account.info.balance.is_zero() {
                continue;
            }

            // EIP-8246: keep the balance but clear the rest of the account.
            account.info.nonce = 0;
            account.info.code_hash = KECCAK_EMPTY;
            account.info.code = Some(Bytecode::default());
            // Wipe storage to zero in place rather than dropping the entries: the
            // slots were accessed during the (now self-destructed) execution and
            // EIP-7928 records those accesses in the block access list. Keeping the
            // entries (present_value = 0) preserves the access — read-only slots
            // stay read-only and written slots become writes-to-zero — while the
            // committed state is still an empty (balance-only) account.
            for slot in account.storage.values_mut() {
                slot.present_value = StorageValue::ZERO;
            }

            // Remove the self-destruct flags so the account is preserved instead of destroyed.
            account.unmark_selfdestruct();
            account.unmark_selfdestructed_locally();
        }
    }

    /// Return reference to state.
    #[inline]
    pub const fn state(&mut self) -> &mut EvmState {
        &mut self.state
    }

    /// Sets SpecId.
    #[inline]
    pub const fn set_spec_id(&mut self, spec: SpecId) {
        self.cfg.spec = spec;
    }

    /// Sets EIP-7708 and EIP-8246 configuration flags.
    #[inline]
    pub const fn set_eip7708_config(
        &mut self,
        disabled: bool,
        eip8246_delayed_clear_disabled: bool,
    ) {
        self.cfg.eip7708_disabled = disabled;
        self.cfg.eip8246_delayed_clear_disabled = eip8246_delayed_clear_disabled;
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

        let had_code_hash = account.info.code_hash;
        let had_code = account.info.code.take();
        self.journal
            .push(ENTRY::code_changed(address, had_code_hash, had_code));

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
        if let Some(eip7702_address) = code.eip7702_address() {
            if eip7702_address.is_zero() {
                self.set_code_with_hash(address, Bytecode::default(), KECCAK_EMPTY);
                return;
            }
        }

        let hash = code.hash_slow();
        self.set_code_with_hash(address, code, hash)
    }

    /// Add journal entry for caller accounting.
    #[inline]
    #[deprecated]
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
            self.journal.push(ENTRY::nonce_bumped(address));
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
        let mut account = self.load_account_mut(db, address)?.data;
        account.incr_balance(balance);
        Ok(())
    }

    /// Increments the nonce of the account.
    #[inline]
    #[deprecated]
    pub fn nonce_bump_journal_entry(&mut self, address: Address) {
        self.journal.push(ENTRY::nonce_bumped(address));
    }

    /// Transfers balance from two accounts. Returns error if sender balance is not enough.
    ///
    /// # Panics
    ///
    /// Panics if from or to are not loaded.
    #[inline]
    pub fn transfer_loaded(
        &mut self,
        from: Address,
        to: Address,
        balance: U256,
    ) -> Option<TransferError> {
        if from == to {
            let from_balance = self.state.get(&to).unwrap().info.balance;
            // Check if from balance is enough to transfer the balance.
            if balance > from_balance {
                return Some(TransferError::OutOfFunds);
            }
            return None;
        }

        if balance.is_zero() {
            Self::touch_account(&mut self.journal, to, self.state.get_mut(&to).unwrap());
            return None;
        }

        // sub balance from
        let from_account = self.state.get_mut(&from).unwrap();
        Self::touch_account(&mut self.journal, from, from_account);
        let from_balance = &mut from_account.info.balance;
        let Some(from_balance_decr) = from_balance.checked_sub(balance) else {
            return Some(TransferError::OutOfFunds);
        };
        *from_balance = from_balance_decr;

        // add balance to
        let to_account = self.state.get_mut(&to).unwrap();
        Self::touch_account(&mut self.journal, to, to_account);
        let to_balance = &mut to_account.info.balance;
        let Some(to_balance_incr) = to_balance.checked_add(balance) else {
            // Overflow of U256 balance is not possible to happen on mainnet. We don't bother to return funds from from_acc.
            return Some(TransferError::OverflowPayment);
        };
        *to_balance = to_balance_incr;

        // add journal entry
        self.journal
            .push(ENTRY::balance_transfer(from, to, balance));

        // EIP-7708: emit ETH transfer log
        self.eip7708_transfer_log(from, to, balance);

        None
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
        self.load_account(db, from)?;
        self.load_account(db, to)?;
        Ok(self.transfer_loaded(from, to, balance))
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

        // If balance is zero, we don't need to add any journal entries or emit any logs.
        if balance.is_zero() {
            return Ok(checkpoint);
        }

        // Add balance to created account, as we already have target here.
        let Some(new_balance) = target_acc.info.balance.checked_add(balance) else {
            self.checkpoint_revert(checkpoint);
            return Err(TransferError::OverflowPayment);
        };
        target_acc.info.balance = new_balance;

        // safe to decrement for the caller as balance check is already done.
        let caller_account = self.state.get_mut(&caller).unwrap();
        caller_account.info.balance -= balance;

        // add journal entry of transferred balance
        last_journal.push(ENTRY::balance_transfer(caller, target_address, balance));

        // EIP-7708: emit ETH transfer log
        self.eip7708_transfer_log(caller, target_address, balance);

        Ok(checkpoint)
    }

    /// Makes a checkpoint that in case of Revert can bring back state to this point.
    #[inline]
    pub const fn checkpoint(&mut self) -> JournalCheckpoint {
        let checkpoint = JournalCheckpoint {
            log_i: self.logs.len(),
            journal_i: self.journal.len(),
            selfdestructed_i: self.selfdestructed_addresses.len(),
        };
        self.depth += 1;
        checkpoint
    }

    /// Commits the checkpoint.
    #[inline]
    pub const fn checkpoint_commit(&mut self) {
        self.depth = self.depth.saturating_sub(1);
    }

    /// Reverts all changes to state until given checkpoint.
    #[inline]
    pub fn checkpoint_revert(&mut self, checkpoint: JournalCheckpoint) {
        let is_spurious_dragon_enabled = self.cfg.spec.is_enabled_in(SPURIOUS_DRAGON);
        let state = &mut self.state;
        let transient_storage = &mut self.transient_storage;
        self.depth = self.depth.saturating_sub(1);
        self.logs.truncate(checkpoint.log_i);
        // EIP-7708: Remove selfdestructed addresses added after checkpoint
        self.selfdestructed_addresses
            .truncate(checkpoint.selfdestructed_i);

        // iterate over last N journals sets and revert our global state
        if checkpoint.journal_i < self.journal.len() {
            let mut reverted_burn = U256::ZERO;
            self.journal
                .drain(checkpoint.journal_i..)
                .rev()
                .for_each(|entry| {
                    reverted_burn += entry.selfdestruct_burn();
                    entry.revert(state, Some(transient_storage), is_spurious_dragon_enabled);
                });
            // The destruction did not happen, so it must not be reported.
            debug_assert!(
                self.selfdestruct_burn >= reverted_burn,
                "reverting a self-destruct burn the accumulator no longer holds: \
                 the accumulator was drained mid-transaction; drain only between transactions"
            );
            // Saturating in release so that a caller that breaks the drain contract
            // costs accounting accuracy rather than halting the node.
            self.selfdestruct_burn = self.selfdestruct_burn.saturating_sub(reverted_burn);
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
        skip_cold_load: bool,
    ) -> Result<StateLoad<SelfDestructResult>, JournalLoadError<DB::Error>> {
        let spec = self.cfg.spec;
        let account_load = self.load_account_optional(db, target, false, skip_cold_load)?;
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

        // Value destroyed outright by this call, credited to no account.
        let mut burned = U256::ZERO;

        // EIP-6780 (Cancun hard-fork): selfdestruct only if contract is created in the same tx
        let journal_entry = if acc.is_created_locally() || !is_cancun_enabled {
            // EIP-8246: Track first self-destruction so the account can be cleared (code, storage
            // and nonce) while preserving its balance at finalization.
            // Only track when account is actually destroyed and delayed clearing is not disabled.
            if destroyed_status == SelfdestructionRevertStatus::GloballySelfdestroyed
                && !self.cfg.eip8246_delayed_clear_disabled
            {
                self.selfdestructed_addresses.push(address);
            }

            acc.mark_selfdestructed_locally();

            // `had_balance` records the balance that left the account so it can be restored
            // on revert.
            let had_balance = if target != address {
                // Balance was transferred to target above; zero out the source.
                acc.info.balance = U256::ZERO;
                // EIP-7708: transfer log for balance moved to a different address.
                self.eip7708_transfer_log(address, target, balance);
                balance
            } else if spec.is_enabled_in(AMSTERDAM) {
                // EIP-8246: self-destruct to self no longer burns the balance. The balance is
                // kept and the account is cleared at finalization
                // (see `eip8246_clear_selfdestructed_accounts`).
                U256::ZERO
            } else {
                // Pre-EIP-8246: self-destruct to self burns the balance. The transfer above
                // runs only for a distinct beneficiary, so this zeroing destroys it.
                acc.info.balance = U256::ZERO;
                burned = balance;
                balance
            };

            Some(ENTRY::account_destroyed(
                address,
                target,
                destroyed_status,
                had_balance,
            ))
        } else if address != target {
            acc.info.balance = U256::ZERO;
            // EIP-7708: emit appropriate log for selfdestruct
            // Transfer log for balance transferred to different address
            self.eip7708_transfer_log(address, target, balance);
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

        self.selfdestruct_burn += burned;

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
    pub fn load_account<'a, 'db, DB: Database>(
        &'a mut self,
        db: &'db mut DB,
        address: Address,
    ) -> Result<StateLoad<&'a Account>, DB::Error>
    where
        'db: 'a,
    {
        self.load_account_optional(db, address, false, false)
            .map_err(JournalLoadError::unwrap_db_error)
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
        let spec = self.cfg.spec;
        let is_eip7702_enabled = spec.is_enabled_in(SpecId::PRAGUE);
        let account = self
            .load_account_optional(db, address, is_eip7702_enabled, false)
            .map_err(JournalLoadError::unwrap_db_error)?;
        let is_empty = account.state_clear_aware_is_empty(spec);

        let mut account_load = StateLoad::new(
            AccountLoad {
                is_delegate_account_cold: None,
                is_empty,
            },
            account.is_cold,
        );

        // load delegate code if account is EIP-7702
        if let Some(address) = account
            .info
            .code
            .as_ref()
            .and_then(Bytecode::eip7702_address)
        {
            let delegate_account = self
                .load_account_optional(db, address, true, false)
                .map_err(JournalLoadError::unwrap_db_error)?;
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
    pub fn load_code<'a, 'db, DB: Database>(
        &'a mut self,
        db: &'db mut DB,
        address: Address,
    ) -> Result<StateLoad<&'a Account>, DB::Error>
    where
        'db: 'a,
    {
        self.load_account_optional(db, address, true, false)
            .map_err(JournalLoadError::unwrap_db_error)
    }

    /// Loads account into memory. If account is already loaded it will be marked as warm.
    #[inline]
    pub fn load_account_optional<'a, 'db, DB: Database>(
        &'a mut self,
        db: &'db mut DB,
        address: Address,
        load_code: bool,
        skip_cold_load: bool,
    ) -> Result<StateLoad<&'a Account>, JournalLoadError<DB::Error>>
    where
        'db: 'a,
    {
        let mut load = self.load_account_mut_optional(db, address, skip_cold_load)?;
        if load_code {
            load.data.load_code_preserve_error()?;
        }
        Ok(load.map(|i| i.into_account()))
    }

    /// Loads account into memory. If account is already loaded it will be marked as warm.
    #[inline]
    pub fn load_account_mut<'a, 'db, DB: Database>(
        &'a mut self,
        db: &'db mut DB,
        address: Address,
    ) -> Result<StateLoad<JournaledAccount<'a, DB, ENTRY>>, DB::Error>
    where
        'db: 'a,
    {
        self.load_account_mut_optional(db, address, false)
            .map_err(JournalLoadError::unwrap_db_error)
    }

    /// Loads account. If account is already loaded it will be marked as warm.
    #[inline]
    pub fn load_account_mut_optional_code<'a, 'db, DB: Database>(
        &'a mut self,
        db: &'db mut DB,
        address: Address,
        load_code: bool,
        skip_cold_load: bool,
    ) -> Result<StateLoad<JournaledAccount<'a, DB, ENTRY>>, JournalLoadError<DB::Error>>
    where
        'db: 'a,
    {
        let mut load = self.load_account_mut_optional(db, address, skip_cold_load)?;
        if load_code {
            load.data.load_code_preserve_error()?;
        }
        Ok(load)
    }

    /// Gets the account mut reference.
    ///
    /// # Load Unsafe
    ///
    /// Use this function only if you know what you are doing. It will not mark the account as warm or cold.
    /// It will not bump transition_id or return if it is cold or warm loaded. This function is useful
    /// when we know account is warm, touched and already loaded.
    ///
    /// It is useful when we want to access storage from account that is currently being executed.
    #[inline]
    pub fn get_account_mut<'a, 'db, DB: Database>(
        &'a mut self,
        db: &'db mut DB,
        address: Address,
    ) -> Option<JournaledAccount<'a, DB, ENTRY>>
    where
        'db: 'a,
    {
        let account = self.state.get_mut(&address)?;
        Some(JournaledAccount::new(
            address,
            account,
            &mut self.journal,
            db,
            self.warm_addresses.access_list(),
            self.transaction_id,
        ))
    }

    /// Loads account. If account is already loaded it will be marked as warm.
    #[inline(never)]
    pub fn load_account_mut_optional<'a, 'db, DB: Database>(
        &'a mut self,
        db: &'db mut DB,
        address: Address,
        skip_cold_load: bool,
    ) -> Result<StateLoad<JournaledAccount<'a, DB, ENTRY>>, JournalLoadError<DB::Error>>
    where
        'db: 'a,
    {
        let (account, is_cold) = match self.state.entry(address) {
            Entry::Occupied(entry) => {
                let account = entry.into_mut();

                // skip load if account is cold.
                let mut is_cold = account.is_cold_transaction_id(self.transaction_id);

                if unlikely(is_cold) {
                    is_cold = self
                        .warm_addresses
                        .check_is_cold(&address, skip_cold_load)?;

                    // mark it warm.
                    account.mark_warm_with_transaction_id(self.transaction_id);

                    // if it is cold loaded and we have selfdestructed locally it means that
                    // account was selfdestructed in previous transaction and we need to clear its information and storage.
                    if account.is_selfdestructed_locally() {
                        account.selfdestruct();
                        account.unmark_selfdestructed_locally();
                        // Only clear the persistent global flags if this
                        // account was itself created somewhere in this
                        // journal's own history (`is_created()`, otherwise
                        // only cleared by an `AccountCreated` revert, which
                        // un-creates the account for the same reason) - that's
                        // the actual invariant that makes "blank slate" safe,
                        // not the hardfork:
                        // an account created within this journal provably
                        // has no pre-existing on-disk storage predating this
                        // block, so treating it as fully fresh cannot lose
                        // anything. This is always true post-Cancun when
                        // this branch is reached at all (`is_selfdestructed_locally()`
                        // there requires `is_created_locally()`, which always
                        // sets the global `Created` flag too), and lets a
                        // later recreate of that same account correctly show
                        // as alive rather than still destroyed (EIP-6780),
                        // matching what a standalone, finalize-per-tx
                        // execution of the same sequence would show.
                        //
                        // Pre-Cancun, `selfdestruct()` also sets this flag
                        // for a cross-tx destroy of a pre-existing contract
                        // that was never created in this journal at all
                        // (`is_created()` false) - there, destruction is
                        // permanent per legacy semantics, and clearing the
                        // global flags would incorrectly let
                        // `apply_account_state`/`CacheDB::commit` skip wiping
                        // that contract's real, possibly large pre-existing
                        // on-disk storage (which this journal never loaded
                        // and has no way to enumerate), resurrecting old data
                        // if the address is ever touched again.
                        if account.is_created() {
                            account.unmark_selfdestruct();
                            account.unmark_created();
                        }
                    }
                    account.set_current_info_as_original();

                    // unmark locally created
                    account.unmark_created_locally();

                    // journal loading of cold account.
                    self.journal.push(ENTRY::account_warmed(address));
                }
                (account, is_cold)
            }
            Entry::Vacant(vac) => {
                // Precompiles,  among some other account(access list and coinbase included)
                // are warm loaded so we need to take that into account
                let is_cold = self
                    .warm_addresses
                    .check_is_cold(&address, skip_cold_load)?;

                let account = if let Some(account) = db.basic(address)? {
                    let mut account: Account = account.into();
                    account.transaction_id = self.transaction_id;
                    account
                } else {
                    Account::new_not_existing(self.transaction_id)
                };
                // journal loading of cold account.
                if is_cold {
                    self.journal.push(ENTRY::account_warmed(address));
                }

                (vac.insert(account), is_cold)
            }
        };

        Ok(StateLoad::new(
            JournaledAccount::new(
                address,
                account,
                &mut self.journal,
                db,
                self.warm_addresses.access_list(),
                self.transaction_id,
            ),
            is_cold,
        ))
    }

    /// Loads storage slot.
    #[inline]
    pub fn sload<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
        key: StorageKey,
        skip_cold_load: bool,
    ) -> Result<StateLoad<StorageValue>, JournalLoadError<DB::Error>> {
        self.load_account_mut(db, address)?
            .sload_concrete_error(key, skip_cold_load)
            .map(|s| s.map(|s| s.present_value))
    }

    /// Loads storage slot.
    ///
    /// If account is not present it will return [`JournalLoadError::ColdLoadSkipped`] error.
    #[inline]
    pub fn sload_assume_account_present<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
        key: StorageKey,
        skip_cold_load: bool,
    ) -> Result<StateLoad<StorageValue>, JournalLoadError<DB::Error>> {
        let Some(mut account) = self.get_account_mut(db, address) else {
            return Err(JournalLoadError::ColdLoadSkipped);
        };

        account
            .sload_concrete_error(key, skip_cold_load)
            .map(|s| s.map(|s| s.present_value))
    }

    /// Stores storage slot.
    ///
    /// If account is not present it will load from database
    #[inline]
    pub fn sstore<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
        key: StorageKey,
        new: StorageValue,
        skip_cold_load: bool,
    ) -> Result<StateLoad<SStoreResult>, JournalLoadError<DB::Error>> {
        self.load_account_mut(db, address)?
            .sstore_concrete_error(key, new, skip_cold_load)
    }

    /// Stores storage slot.
    ///
    /// And returns (original,present,new) slot value.
    ///
    /// **Note**: Account should already be present in our state.
    #[inline]
    pub fn sstore_assume_account_present<DB: Database>(
        &mut self,
        db: &mut DB,
        address: Address,
        key: StorageKey,
        new: StorageValue,
        skip_cold_load: bool,
    ) -> Result<StateLoad<SStoreResult>, JournalLoadError<DB::Error>> {
        let Some(mut account) = self.get_account_mut(db, address) else {
            return Err(JournalLoadError::ColdLoadSkipped);
        };

        account.sstore_concrete_error(key, new, skip_cold_load)
    }

    /// Read transient storage tied to the account.
    ///
    /// EIP-1153: Transient storage opcodes
    #[inline]
    pub fn tload(&mut self, address: Address, key: StorageKey) -> StorageValue {
        self.transient_storage.get_value(address, key)
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
            self.transient_storage.remove_value(address, key)
        } else {
            // insert values
            let previous_value = self
                .transient_storage
                .insert_value(address, key, new)
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

    /// Creates and pushes an EIP-7708 ETH transfer log.
    ///
    /// This emits a LOG3 with the Transfer event signature, matching ERC-20 transfer events.
    /// Only emitted if EIP-7708 is enabled (Amsterdam and later) and balance is non-zero.
    ///
    /// [EIP-7708](https://eips.ethereum.org/EIPS/eip-7708)
    #[inline]
    pub fn eip7708_transfer_log(&mut self, from: Address, to: Address, balance: U256) {
        // Only emit log if EIP-7708 is enabled and balance is non-zero
        if !self.cfg.spec.is_enabled_in(AMSTERDAM) || self.cfg.eip7708_disabled || balance.is_zero()
        {
            return;
        }

        // Create LOG3 with Transfer(address,address,uint256) event signature
        // Topic[0]: Transfer event signature
        // Topic[1]: from address (zero-padded to 32 bytes)
        // Topic[2]: to address (zero-padded to 32 bytes)
        // Data: amount in wei (big-endian uint256)
        let topics = std::vec![
            ETH_TRANSFER_LOG_TOPIC,
            B256::left_padding_from(from.as_slice()),
            B256::left_padding_from(to.as_slice()),
        ];
        let data = Bytes::copy_from_slice(&balance.to_be_bytes::<32>());

        self.logs.push(Log {
            address: ETH_TRANSFER_LOG_ADDRESS,
            data: LogData::new(topics, data).expect("3 topics is valid"),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use context_interface::journaled_state::entry::JournalEntry;
    use database_interface::EmptyDB;
    use primitives::{address, HashSet, U256};
    use state::AccountInfo;

    #[cfg(feature = "account-ext")]
    #[test]
    fn extension_checkpoint_reverts_nested_changes() {
        use state::AccountExtension;
        let address = Address::repeat_byte(1);
        let original = AccountExtension::copy_from_slice(&[1; 32]);
        let mut journal = JournalInner::<JournalEntry>::new();
        journal.state.insert(
            address,
            AccountInfo::default()
                .with_extension(original.clone())
                .into(),
        );
        let mut db = EmptyDB::new();
        let outer = journal.checkpoint();
        let outer_value = AccountExtension::copy_from_slice(&[2; 32]);
        journal
            .get_account_mut(&mut db, address)
            .unwrap()
            .set_extension(outer_value.clone());
        assert!(journal.state[&address].is_touched());
        let inner = journal.checkpoint();
        journal
            .get_account_mut(&mut db, address)
            .unwrap()
            .set_extension(AccountExtension::new());
        journal.checkpoint_revert(inner);
        assert_eq!(journal.state[&address].info.extension, outer_value);
        // A committed child must still revert if its caller later reverts.
        let _child = journal.checkpoint();
        journal
            .get_account_mut(&mut db, address)
            .unwrap()
            .set_extension(AccountExtension::copy_from_slice(&[3; 32]));
        journal.checkpoint_commit();
        journal.checkpoint_revert(outer);
        assert_eq!(journal.state[&address].info.extension, original);
        assert!(!journal.state[&address].is_touched());
        assert!(journal.journal.is_empty());
    }

    #[test]
    fn test_sload_skip_cold_load() {
        let mut journal = JournalInner::<JournalEntry>::new();
        let test_address = address!("1000000000000000000000000000000000000000");
        let test_key = U256::from(1);

        // Insert account into state
        let account_info = AccountInfo {
            balance: U256::from(1000),
            nonce: 1,
            code_hash: KECCAK_EMPTY,
            code: Some(Bytecode::default()),
            ..Default::default()
        };
        journal
            .state
            .insert(test_address, Account::from(account_info));

        // Add storage slot to access list (make it warm)
        let mut access_list = HashMap::default();
        let mut storage_keys = HashSet::default();
        storage_keys.insert(test_key);
        access_list.insert(test_address, storage_keys);
        journal.warm_addresses.set_access_list(access_list);

        // Try to sload with skip_cold_load=true - should succeed because slot is in access list
        let mut db = EmptyDB::new();
        let result = journal.sload_assume_account_present(&mut db, test_address, test_key, true);

        // Should succeed and return as warm
        assert!(result.is_ok());
        let state_load = result.unwrap();
        assert!(!state_load.is_cold); // Should be warm
        assert_eq!(state_load.data, U256::ZERO); // Empty slot
    }
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
        assert_eq!(
            t1.original_value,
            StorageValue::ZERO,
            "T1 original should be pre-block DB value (0)"
        );
        assert_eq!(t1.present_value, StorageValue::ZERO);
        assert_eq!(t1.new_value, value_a);

        // Transaction boundary: T1 is done and committed, T2 begins.
        journal.commit_tx();

        // --- Transaction 2 (same block, same journal): slot goes A -> 0 ---
        let t2 = journal
            .sstore(&mut db, addr, key, StorageValue::ZERO)
            .unwrap()
            .data;

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
        let t2 = journal2
            .sstore(&mut db, addr, key, StorageValue::ZERO)
            .unwrap()
            .data;

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
        // Use the real, journaled code-setting path (as an actual CREATE would
        // via set_code/set_code_with_hash) rather than poking info.code_hash
        // directly - a direct field write wouldn't be journaled and so
        // wouldn't be reverted by discard_tx()/checkpoint_revert(), which
        // would be a test-harness artifact, not real behavior.
        journal.set_code_with_hash(addr, Bytecode::default(), code_hash);
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
        assert_eq!(
            acc.info.balance,
            U256::ZERO,
            "balance should be transferred out"
        );
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

    /// create (T1) -> cross-tx selfdestruct where the target IS the
    /// destroyed account itself (T2, `address == target`).
    ///
    /// Per EIP-6780, a cross-tx (not same-tx-created) selfdestruct only
    /// transfers balance to `target` - but transferring a balance to itself
    /// is a no-op, so this whole call must leave the account completely
    /// untouched: no balance change, no `SelfDestructed` flag set (not even
    /// the global one), no journal entry pushed at all, code/storage intact.
    /// This is a distinct EIP-6780 corner case (the `else { None }` branch
    /// in `selfdestruct()`), separate from the single-journal recreate bug
    /// this module otherwise covers - added specifically to confirm that
    /// bug's fix (clearing `SelfDestructed`/`Created` in the lazy cold-load
    /// wipe) has no effect on this unrelated, already-a-no-op path.
    #[test]
    fn cross_tx_self_targeting_selfdestruct_is_a_no_op() {
        let (mut journal, mut db, caller) = setup();
        let addr = Address::with_last_byte(2);

        // --- T1: create, fund with a balance, do NOT destroy ---
        create_at(&mut journal, &mut db, caller, addr, CODE_V1).unwrap();
        let balance = U256::from(1_000);
        journal.balance_incr(&mut db, addr, balance).unwrap();
        journal.commit_tx();

        // --- T2: a later, unrelated tx selfdestructs it, targeting itself ---
        journal.load_account(&mut db, addr).unwrap();
        let journal_len_before = journal.journal.len();
        journal.selfdestruct(&mut db, addr, addr).unwrap();

        assert_eq!(
            journal.journal.len(),
            journal_len_before,
            "a true no-op selfdestruct must not push any journal entry"
        );

        let acc = journal.state.get(&addr).unwrap();
        assert!(
            !acc.is_selfdestructed_locally(),
            "cross-tx self-targeting selfdestruct must not take the same-tx \
             'full delete' path"
        );
        assert!(
            !acc.is_selfdestructed(),
            "must not even mark globally selfdestructed - this is a no-op, \
             not a destruction"
        );
        assert_eq!(
            acc.info.balance, balance,
            "balance must be completely unchanged - transferring to itself \
             is a no-op, not a zero-out"
        );
        assert_eq!(acc.info.code_hash, CODE_V1, "code must survive untouched");
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

    /// A recreated contract's storage must read as zero (not a stale value
    /// left over from the destroyed generation), and the first read of any
    /// slot must be charged as a COLD access (EIP-2929) - not still-warm
    /// from the destroyed generation's own writes in an earlier transaction.
    #[test]
    fn recreated_contract_storage_is_zero_and_cold() {
        let (mut journal, mut db, caller) = setup();
        let addr = Address::with_last_byte(2);
        let key = StorageKey::from(7);

        // T1: create, write a nonzero value to `key`, destroy (same tx).
        create_at(&mut journal, &mut db, caller, addr, CODE_V1).unwrap();
        journal
            .sstore(&mut db, addr, key, StorageValue::from(999))
            .unwrap();
        destroy_at(&mut journal, &mut db, addr, caller);
        journal.commit_tx();

        // T2: recreate (same address), do NOT write `key` again.
        create_at(&mut journal, &mut db, caller, addr, CODE_V2).unwrap();
        let sload_result = journal.sload(&mut db, addr, key).unwrap();

        assert_eq!(
            sload_result.data,
            StorageValue::ZERO,
            "recreated contract's storage must read as zero, not leak T1's value"
        );
        assert!(
            sload_result.is_cold,
            "first read of this slot in T2 must be charged as a cold access"
        );
    }

    /// T1 create+destroy (same tx), commits. T2 attempts to recreate the
    /// same address but is then discarded (as a `ReadOnly`
    /// automation-predicate call would be) rather than committed. T3, a
    /// real (non-`ReadOnly`) transaction, then tries to recreate the same
    /// address. T2's discarded attempt must leave no residue: it must not
    /// block T3's recreate, and none of T2's (never-committed) contract may
    /// leak into the final state.
    #[test]
    fn readonly_discarded_recreate_leaves_no_residue() {
        let (mut journal, mut db, caller) = setup();
        let addr = Address::with_last_byte(2);

        create_at(&mut journal, &mut db, caller, addr, CODE_V1).unwrap();
        destroy_at(&mut journal, &mut db, addr, caller);
        journal.commit_tx(); // T1 done

        // T2: attempts a recreate, but gets discarded (ReadOnly-style).
        create_at(&mut journal, &mut db, caller, addr, CODE_V2).unwrap();
        journal.discard_tx(); // T2 discarded, not committed

        // T3: a real transaction, tries to recreate at the same address.
        let t3_result = create_at(&mut journal, &mut db, caller, addr, CODE_V3);
        assert!(
            t3_result.is_ok(),
            "T3 should be able to cleanly recreate where T2's discarded attempt failed"
        );
        journal.commit_tx();

        let state = journal.finalize();
        let final_account = state.get(&addr).unwrap().clone();
        assert_eq!(
            final_account.info.code_hash, CODE_V3,
            "only T3's contract should survive"
        );
        assert!(!final_account.is_selfdestructed());
    }
}

#[cfg(test)]
mod pre_cancun_selfdestruct_tests {
    use super::*;
    use crate::JournalEntry;
    use database::EmptyDB;
    use primitives::hardfork::SpecId;
    use state::AccountInfo;

    /// Pre-Cancun, `selfdestruct()`'s `is_created_locally() ||
    /// !is_cancun_enabled` gate takes the "full delete" branch
    /// unconditionally - i.e. for ANY destroy, not just one in the same
    /// transaction as creation. So a cross-tx destroy of a pre-existing
    /// contract (never created in this journal's history at all) still
    /// sets `is_selfdestructed_locally()`.
    ///
    /// A later transaction in the same block merely *touching* (not
    /// recreating) that address must NOT resurrect it by clearing the
    /// global `SelfDestructed` flag: pre-Cancun, destruction is permanent,
    /// and clearing that flag would let `apply_account_state`/
    /// `CacheDB::commit` skip wiping the account's committed storage from
    /// the persisted state.
    #[test]
    fn pre_cancun_cross_tx_destroy_of_pre_existing_contract_stays_destroyed() {
        let mut db = database::CacheDB::new(EmptyDB::new());
        let mut journal = JournalInner::<JournalEntry>::new();
        journal.set_spec_id(SpecId::BERLIN);

        let addr = Address::with_last_byte(2);
        let target = Address::with_last_byte(3);

        // Pre-existing contract - NOT created in this journal's history,
        // loaded straight from the DB with real code already in place.
        db.insert_account_info(
            addr,
            AccountInfo {
                code_hash: B256::from([9; 32]),
                ..Default::default()
            },
        );

        // T1: destroy it (cross-tx relative to its own creation, which
        // predates this block entirely).
        journal.load_account(&mut db, addr).unwrap();
        journal.selfdestruct(&mut db, addr, target).unwrap();
        journal.touch(addr);
        journal.commit_tx();

        // Sanity: pre-Cancun, this must have taken the full-delete path.
        assert!(journal.state.get(&addr).unwrap().is_selfdestructed());

        // T2: a later transaction merely touches the address (e.g. a plain
        // call), without recreating it.
        journal.load_account(&mut db, addr).unwrap();
        journal.commit_tx();

        assert!(
            journal.state.get(&addr).unwrap().is_selfdestructed(),
            "pre-Cancun, a cross-tx destroy of a pre-existing contract must \
             stay permanently destroyed - a later transaction merely \
             touching the address must not clear the global flag"
        );
    }
}

#[cfg(test)]
mod vacant_load_transaction_id_tests {
    use super::*;
    use crate::JournalEntry;
    use database::{CacheDB, EmptyDB};
    use state::AccountInfo;

    /// A pre-existing (DB-loaded) account's first-ever load into a shared
    /// journal must be stamped with the journal's real current
    /// `transaction_id`, not a hardcoded 0 (the bug: `From<AccountInfo> for
    /// Account`, `crates/state/src/lib.rs`, hardcoded `transaction_id: 0`).
    /// Otherwise `mark_warm_with_transaction_id` misreads this account's
    /// very next touch, later in the SAME transaction, as a brand-new
    /// transaction touching it for the first time, charging it cold
    /// instead of warm. This is the general form of the bug that also
    /// manifests as `EXTCODESIZE(CALLER)` being incorrectly charged cold -
    /// see `test_sender_extcodesize_stays_warm_after_prior_committed_tx` in
    /// `crates/ee-tests/src/revm_tests.rs`.
    #[test]
    fn pre_existing_account_first_load_stamps_real_transaction_id() {
        let mut db = CacheDB::new(EmptyDB::new());
        let unrelated = Address::with_last_byte(1);
        let target = Address::with_last_byte(2);

        db.insert_account_info(
            unrelated,
            AccountInfo {
                balance: U256::from(1),
                ..Default::default()
            },
        );
        db.insert_account_info(
            target,
            AccountInfo {
                balance: U256::from(2),
                ..Default::default()
            },
        );

        let mut journal = JournalInner::<JournalEntry>::new();

        // T0: an unrelated transaction, never touching `target`, commits
        // first - advancing transaction_id past 0.
        journal.load_account(&mut db, unrelated).unwrap();
        journal.commit_tx();
        assert_eq!(journal.transaction_id, 1);

        // T1: first-ever load of `target` in this journal - a different,
        // non-first transaction.
        journal.load_account(&mut db, target).unwrap();

        assert_eq!(
            journal.state.get(&target).unwrap().transaction_id,
            journal.transaction_id,
            "a pre-existing account's first load must be stamped with the \
             journal's real current transaction_id, not a hardcoded 0"
        );

        // Concretely: touching it again right now, still within T1, must
        // report warm (is_cold == false) - not misread as a new
        // transaction's first touch.
        let second_touch = journal.load_account(&mut db, target).unwrap();
        assert!(
            !second_touch.is_cold,
            "second touch of the same account within the same transaction \
             must be warm"
        );
    }
}

#[cfg(test)]
mod eip6780_selfdestruct_burn_tests {
    use super::*;
    use crate::JournalEntry;
    use database::{CacheDB, EmptyDB};
    use primitives::hardfork::SpecId;

    type TestJournal = JournalInner<JournalEntry>;
    type TestDb = CacheDB<EmptyDB>;

    const CALLER: Address = Address::with_last_byte(1);
    const CONTRACT: Address = Address::with_last_byte(2);
    const BENEFICIARY: Address = Address::with_last_byte(3);
    const ENDOWMENT: u64 = 500;

    /// A journal with a funded caller, ready to create and destroy contracts.
    fn setup(spec: SpecId) -> (TestJournal, TestDb) {
        let mut db = TestDb::new(EmptyDB::new());
        let mut journal = TestJournal::new();
        journal.set_spec_id(spec);
        journal.load_account(&mut db, CALLER).unwrap();
        journal.state.get_mut(&CALLER).unwrap().info.balance = U256::from(1_000);
        (journal, db)
    }

    /// Creates a contract at `CONTRACT` in the current transaction, endowed from
    /// `CALLER`, and commits the creation checkpoint.
    fn create_endowed_contract(journal: &mut TestJournal, db: &mut TestDb, spec: SpecId) {
        journal.load_account(db, CONTRACT).unwrap();
        journal
            .create_account_checkpoint(CALLER, CONTRACT, U256::from(ENDOWMENT), spec)
            .unwrap();
        journal.checkpoint_commit();
        journal.touch(CONTRACT);
    }

    /// A contract created in this transaction that names itself as beneficiary has
    /// its balance zeroed with no credit anywhere: the value is destroyed and must
    /// be reported.
    #[test]
    fn same_tx_self_targeting_selfdestruct_reports_the_balance() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);

        journal.selfdestruct(&mut db, CONTRACT, CONTRACT).unwrap();

        assert_eq!(
            journal.selfdestruct_burn,
            U256::from(ENDOWMENT),
            "a same-tx self-targeting selfdestruct destroys the whole balance"
        );
        assert_eq!(
            journal.state.get(&CONTRACT).unwrap().info.balance,
            U256::ZERO
        );
    }

    /// Naming a different beneficiary moves the value instead of destroying it, so
    /// nothing may be reported as burned.
    #[test]
    fn same_tx_selfdestruct_to_another_address_reports_nothing() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);

        journal
            .selfdestruct(&mut db, CONTRACT, BENEFICIARY)
            .unwrap();

        assert_eq!(
            journal.selfdestruct_burn,
            U256::ZERO,
            "value credited to another account is moved, not destroyed"
        );
        assert_eq!(
            journal.state.get(&BENEFICIARY).unwrap().info.balance,
            U256::from(ENDOWMENT)
        );
    }

    /// The reported total must follow the same revert rules as the state itself: a
    /// frame that is reverted destroyed nothing.
    #[test]
    fn reverted_frame_reports_nothing() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);

        let checkpoint = journal.checkpoint();
        journal.selfdestruct(&mut db, CONTRACT, CONTRACT).unwrap();
        assert_eq!(journal.selfdestruct_burn, U256::from(ENDOWMENT));

        journal.checkpoint_revert(checkpoint);

        assert_eq!(
            journal.selfdestruct_burn,
            U256::ZERO,
            "a reverted selfdestruct destroyed nothing and must not be reported"
        );
        assert_eq!(
            journal.state.get(&CONTRACT).unwrap().info.balance,
            U256::from(ENDOWMENT),
            "the reverted balance is restored, so it is still in circulation"
        );
    }

    /// An outer frame reverting a *nested* frame's burn must also unreport it, and
    /// must leave an earlier committed burn alone.
    #[test]
    fn nested_revert_keeps_only_the_committed_burn() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);

        // Committed burn: the whole endowment.
        journal.selfdestruct(&mut db, CONTRACT, CONTRACT).unwrap();

        // A second contract is created and destroyed inside a frame that reverts.
        let outer = journal.checkpoint();
        let second = Address::with_last_byte(4);
        journal.load_account(&mut db, second).unwrap();
        journal
            .create_account_checkpoint(CALLER, second, U256::from(7), SpecId::CANCUN)
            .unwrap();
        journal.checkpoint_commit();
        journal.checkpoint();
        journal.selfdestruct(&mut db, second, second).unwrap();
        journal.checkpoint_commit();
        assert_eq!(journal.selfdestruct_burn, U256::from(ENDOWMENT + 7));

        journal.checkpoint_revert(outer);

        assert_eq!(
            journal.selfdestruct_burn,
            U256::from(ENDOWMENT),
            "only the burn that survived the revert is reported"
        );
    }

    /// A discarded transaction reverts every entry, so it reports nothing.
    #[test]
    fn discarded_transaction_reports_nothing() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);
        journal.selfdestruct(&mut db, CONTRACT, CONTRACT).unwrap();
        assert_eq!(journal.selfdestruct_burn, U256::from(ENDOWMENT));

        journal.discard_tx();

        assert_eq!(
            journal.selfdestruct_burn,
            U256::ZERO,
            "a discarded transaction destroyed nothing"
        );
    }

    /// Before Cancun every selfdestruct takes the destroying branch, so a
    /// self-targeting one burns even when the account was not created in this
    /// transaction.
    #[test]
    fn pre_cancun_self_targeting_selfdestruct_reports_the_balance() {
        let (mut journal, mut db) = setup(SpecId::SHANGHAI);
        journal.load_account(&mut db, CONTRACT).unwrap();
        journal.state.get_mut(&CONTRACT).unwrap().info.balance = U256::from(ENDOWMENT);

        journal.selfdestruct(&mut db, CONTRACT, CONTRACT).unwrap();

        assert_eq!(
            journal.selfdestruct_burn,
            U256::from(ENDOWMENT),
            "pre-Cancun a self-targeting selfdestruct destroys the balance"
        );
    }

    /// Before Cancun a selfdestruct to a different beneficiary still only moves the
    /// value, so it is not a burn.
    #[test]
    fn pre_cancun_selfdestruct_to_another_address_reports_nothing() {
        let (mut journal, mut db) = setup(SpecId::SHANGHAI);
        journal.load_account(&mut db, CONTRACT).unwrap();
        journal.state.get_mut(&CONTRACT).unwrap().info.balance = U256::from(ENDOWMENT);

        journal
            .selfdestruct(&mut db, CONTRACT, BENEFICIARY)
            .unwrap();

        assert_eq!(journal.selfdestruct_burn, U256::ZERO);
        assert_eq!(
            journal.state.get(&BENEFICIARY).unwrap().info.balance,
            U256::from(ENDOWMENT)
        );
    }

    /// After Cancun, a contract that was not created in this transaction and names
    /// itself as beneficiary is a no-op: no entry, no state change, no burn.
    #[test]
    fn cross_tx_self_targeting_selfdestruct_reports_nothing() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);
        journal.commit_tx();
        // A cold reload in the next transaction clears the local "created" flag.
        journal.load_account(&mut db, CONTRACT).unwrap();

        journal.selfdestruct(&mut db, CONTRACT, CONTRACT).unwrap();

        assert_eq!(
            journal.selfdestruct_burn,
            U256::ZERO,
            "an EIP-6780 no-op selfdestruct destroys nothing"
        );
        assert_eq!(
            journal.state.get(&CONTRACT).unwrap().info.balance,
            U256::from(ENDOWMENT),
            "the balance is untouched"
        );
    }

    /// Draining part-way through a transaction breaks the accumulator's contract,
    /// because a later revert then has nothing left to take back. Debug builds catch
    /// that at the revert site; release builds saturate instead, so that a broken
    /// caller costs accounting accuracy rather than halting the node.
    #[test]
    #[cfg(debug_assertions)]
    #[should_panic(expected = "drained mid-transaction")]
    fn draining_mid_transaction_is_caught_in_debug_builds() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);

        let checkpoint = journal.checkpoint();
        journal.selfdestruct(&mut db, CONTRACT, CONTRACT).unwrap();
        // The contract violation: the burn is taken while its journal entry is still
        // revertible.
        assert_eq!(journal.take_selfdestruct_burn(), U256::from(ENDOWMENT));

        journal.checkpoint_revert(checkpoint);
    }

    /// Value paid to an account after it self-destructs to another beneficiary is
    /// deleted with the account, so committing the transaction counts it.
    #[test]
    fn value_credited_after_selfdestruct_is_counted_at_commit() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);
        journal
            .selfdestruct(&mut db, CONTRACT, BENEFICIARY)
            .unwrap();
        assert_eq!(journal.selfdestruct_burn, U256::ZERO);

        journal
            .transfer(&mut db, CALLER, CONTRACT, U256::from(55))
            .unwrap();
        journal.commit_tx();

        assert_eq!(
            journal.selfdestruct_burn,
            U256::from(55),
            "the balance a self-destructed account holds at commit is destroyed with it"
        );
    }

    /// A self-targeting self-destruct is counted at the opcode, and a later credit
    /// to the same account is counted at commit; neither is counted twice.
    #[test]
    fn self_targeting_selfdestruct_then_credit_counts_both() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);
        journal.selfdestruct(&mut db, CONTRACT, CONTRACT).unwrap();
        journal
            .transfer(&mut db, CALLER, CONTRACT, U256::from(55))
            .unwrap();

        journal.commit_tx();

        assert_eq!(journal.selfdestruct_burn, U256::from(ENDOWMENT + 55));
    }

    /// Two accounts created in the same transaction that each name the other as
    /// beneficiary are both deleted; whichever holds the value at commit has it
    /// counted.
    #[test]
    fn selfdestruct_to_a_destroyed_beneficiary_is_counted_at_commit() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);
        let second = Address::with_last_byte(4);
        journal.load_account(&mut db, second).unwrap();
        journal
            .create_account_checkpoint(CALLER, second, U256::from(7), SpecId::CANCUN)
            .unwrap();
        journal.checkpoint_commit();

        journal.selfdestruct(&mut db, CONTRACT, second).unwrap();
        journal.selfdestruct(&mut db, second, CONTRACT).unwrap();
        assert_eq!(journal.selfdestruct_burn, U256::ZERO);

        journal.commit_tx();

        assert_eq!(journal.selfdestruct_burn, U256::from(ENDOWMENT + 7));
    }

    /// An account that self-destructs more than once in a transaction is counted
    /// once at commit.
    #[test]
    fn repeated_selfdestruct_is_counted_once_at_commit() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);
        journal
            .selfdestruct(&mut db, CONTRACT, BENEFICIARY)
            .unwrap();
        journal
            .transfer(&mut db, CALLER, CONTRACT, U256::from(55))
            .unwrap();
        journal
            .selfdestruct(&mut db, CONTRACT, BENEFICIARY)
            .unwrap();
        journal
            .transfer(&mut db, CALLER, CONTRACT, U256::from(9))
            .unwrap();

        journal.commit_tx();

        assert_eq!(
            journal.selfdestruct_burn,
            U256::from(9),
            "the second self-destruct moved the 55 to the beneficiary; only the 9 is deleted"
        );
        assert_eq!(
            journal.state.get(&BENEFICIARY).unwrap().info.balance,
            U256::from(ENDOWMENT + 55)
        );
    }

    /// A credit that is reverted is not held at commit, so it is not counted.
    #[test]
    fn reverted_credit_to_a_destroyed_account_is_not_counted() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);
        journal
            .selfdestruct(&mut db, CONTRACT, BENEFICIARY)
            .unwrap();

        let checkpoint = journal.checkpoint();
        journal
            .transfer(&mut db, CALLER, CONTRACT, U256::from(55))
            .unwrap();
        journal.checkpoint_revert(checkpoint);
        journal.commit_tx();

        assert_eq!(journal.selfdestruct_burn, U256::ZERO);
    }

    /// A discarded transaction deletes nothing, including an account that was
    /// credited after self-destructing.
    #[test]
    fn discarded_transaction_with_credit_after_selfdestruct_reports_nothing() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);
        journal
            .selfdestruct(&mut db, CONTRACT, BENEFICIARY)
            .unwrap();
        journal
            .transfer(&mut db, CALLER, CONTRACT, U256::from(55))
            .unwrap();

        journal.discard_tx();

        assert_eq!(journal.selfdestruct_burn, U256::ZERO);
    }

    /// The balance is counted by the commit of the transaction that destroyed the
    /// account. A later transaction that does not destroy it again adds nothing,
    /// whether or not it loads the account.
    #[test]
    fn destroyed_balance_is_counted_by_one_commit_only() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);
        journal
            .selfdestruct(&mut db, CONTRACT, BENEFICIARY)
            .unwrap();
        journal
            .transfer(&mut db, CALLER, CONTRACT, U256::from(55))
            .unwrap();
        journal.commit_tx();
        assert_eq!(journal.selfdestruct_burn, U256::from(55));

        // A transaction that does not load the destroyed account.
        journal.load_account(&mut db, CALLER).unwrap();
        journal.commit_tx();
        assert_eq!(journal.selfdestruct_burn, U256::from(55));

        // A transaction that loads it, which deletes it.
        journal.load_account(&mut db, CONTRACT).unwrap();
        assert_eq!(
            journal.state.get(&CONTRACT).unwrap().info.balance,
            U256::ZERO
        );
        journal.commit_tx();
        assert_eq!(journal.selfdestruct_burn, U256::from(55));
    }

    /// The total survives the transaction boundary and `finalize`, so the host can
    /// read it after execution, and draining it resets it.
    #[test]
    fn total_survives_finalize_and_is_drained_by_take() {
        let (mut journal, mut db) = setup(SpecId::CANCUN);
        create_endowed_contract(&mut journal, &mut db, SpecId::CANCUN);
        journal.selfdestruct(&mut db, CONTRACT, CONTRACT).unwrap();

        journal.commit_tx();
        assert_eq!(journal.selfdestruct_burn, U256::from(ENDOWMENT));
        let _ = journal.finalize();
        assert_eq!(journal.selfdestruct_burn, U256::from(ENDOWMENT));

        assert_eq!(journal.take_selfdestruct_burn(), U256::from(ENDOWMENT));
        assert_eq!(journal.selfdestruct_burn, U256::ZERO);
    }
}
