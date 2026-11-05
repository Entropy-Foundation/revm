//! The [EIP-2935](https://eips.ethereum.org/EIPS/eip-2935) pre-block system call, which records the
//! parent block's hash in the history contract the genesis deploys at
//! [`HISTORY_STORAGE_ADDRESS`].
//!
//! The node runs this call at the start of every EVM block, before the block-metadata transaction
//! and every other transaction of the block, so that each of them can read the parent's hash from
//! the contract. The call is not a transaction of the block: it has no receipt and no RPC
//! representation, so it is built directly as the [`TxEnv`] the EVM executes rather than as an
//! alloy transaction type.
//!
//! The node executes it in [`ExecutionMode::System`](context::ExecutionMode::System) on the same
//! path as its other system transactions (`Handler::validate_caller`, then
//! `Handler::run_system_call`), which admits [`SYSTEM_ADDRESS`] as the sender there and only
//! there. The node is responsible for the rest of the EIP's block-processing rule:
//! - If there is no code at [`HISTORY_STORAGE_ADDRESS`], the call is skipped. The node checks
//!   for code before executing it, rather than executing it and ignoring the outcome.
//! - If the call does not succeed, the block is invalid. A failed or halted call is an error of
//!   the block, never a result to discard, because a slot left unwritten would make `get` return
//!   the hash stored one window earlier.

use crate::errors::SupraExtensionError;
use alloy::primitives::ChainId;
use context::{TransactionType, TxEnv};
// The history contract's address is exported once, from `contracts::canonical_singletons`, next
// to the genesis transaction that deploys it; this module only uses it.
use primitives::{
    eip2935::{HISTORY_SERVE_WINDOW, HISTORY_STORAGE_ADDRESS, SYSTEM_ADDRESS},
    eip7825::TX_GAS_LIMIT_CAP,
    Bytes, TxKind, B256, U256,
};

/// Default gas limit of the history write: the transaction gas-limit cap, the figure the node
/// executes the genesis transactions at and the default of the block-metadata transaction
/// ([`DEFAULT_BLOCK_METADATA_GAS_LIMIT`](crate::transactions::block_metadata::DEFAULT_BLOCK_METADATA_GAS_LIMIT)).
///
/// The EIP gives the call 30,000,000 gas. On SupraEVM the call follows the chain's cap like every
/// other system transaction; the contract's `set` path uses about 22,000 gas, far below either.
pub const DEFAULT_HISTORY_STORAGE_WRITE_GAS_LIMIT: u64 = TX_GAS_LIMIT_CAP;

/// Builds the history write for the block at `height`, whose parent's hash is `parent_hash`.
///
/// The transaction is a call from [`SYSTEM_ADDRESS`] to [`HISTORY_STORAGE_ADDRESS`] with the
/// 32-byte `parent_hash` as its input. The contract stores it in the slot
/// [`history_storage_slot`]`(NUMBER - 1)`, where `NUMBER` is the number of the block environment
/// the call executes in, not a field of this transaction. The caller therefore executes it in the
/// block environment of the block at `height` (`BlockEnv::number == height`); executed in any
/// other block environment, it records `parent_hash` as the hash of a different block.
///
/// Its other fields:
/// - `gas_limit` is the caller's; the node passes the transaction gas-limit cap of the epoch it
///   executes, as it does for the genesis transactions
///   ([`DEFAULT_HISTORY_STORAGE_WRITE_GAS_LIMIT`] is the default cap).
/// - Value, gas price and priority fee are zero: a system transaction pays nothing and is paid
///   nothing.
/// - The type is EIP-2930, the fixed-price type the other Supra system transactions report.
/// - The nonce is `height`, which identifies the write in traces. It is not checked against the
///   sender's account nonce: System transactions are not sequenced by nonce
///   (`ExecutionMode::updates_nonce`).
/// - The transaction hash is zero, since the call is no transaction of the block.
///
/// # Errors
///
/// [`SupraExtensionError::HistoryStorageWriteWithoutParent`] for `height == 0`: the block at
/// height 0 has no parent, so there is no hash to record.
pub fn history_storage_write_tx_env(
    chain_id: ChainId,
    height: u64,
    parent_hash: B256,
    gas_limit: u64,
) -> Result<TxEnv, SupraExtensionError> {
    if height == 0 {
        return Err(SupraExtensionError::HistoryStorageWriteWithoutParent);
    }
    Ok(TxEnv {
        tx_type: TransactionType::Eip2930 as u8,
        caller: SYSTEM_ADDRESS,
        gas_limit,
        gas_price: 0,
        kind: TxKind::Call(HISTORY_STORAGE_ADDRESS),
        value: U256::ZERO,
        data: Bytes::copy_from_slice(parent_hash.as_slice()),
        nonce: height,
        chain_id: Some(chain_id),
        gas_priority_fee: Some(0),
        tx_hash: B256::ZERO,
        ..Default::default()
    })
}

/// The storage slot of the history contract that holds the hash of block `block_number`:
/// `block_number % HISTORY_SERVE_WINDOW`, as the contract's bytecode computes it.
///
/// The history write of the block at height `h` stores the hash of block `h - 1`, so it lands
/// in `history_storage_slot(h - 1)`; `get(n)` reads `history_storage_slot(n)`.
pub fn history_storage_slot(block_number: u64) -> U256 {
    U256::from(block_number % HISTORY_SERVE_WINDOW)
}

#[cfg(test)]
mod tests {
    use super::*;
    use context::Transaction;
    use primitives::b256;

    #[test]
    fn history_storage_write_tx_env_calls_the_history_contract_from_the_system_address() {
        let parent = b256!("0x1111111111111111111111111111111111111111111111111111111111111111");
        let tx =
            history_storage_write_tx_env(8, 42, parent, DEFAULT_HISTORY_STORAGE_WRITE_GAS_LIMIT)
                .expect("height 42 has a parent");

        assert_eq!(tx.caller(), SYSTEM_ADDRESS);
        assert_eq!(tx.kind(), TxKind::Call(HISTORY_STORAGE_ADDRESS));
        assert_eq!(tx.input().as_ref(), parent.as_slice());
        assert_eq!(
            tx.input().len(),
            32,
            "the contract's set path takes exactly 32 bytes"
        );
        assert_eq!(tx.gas_limit(), TX_GAS_LIMIT_CAP);
        assert_eq!(tx.value(), U256::ZERO);
        assert_eq!(tx.gas_price(), 0);
        assert_eq!(tx.max_priority_fee_per_gas(), Some(0));
        assert_eq!(tx.tx_type(), TransactionType::Eip2930 as u8);
        assert_eq!(tx.nonce(), 42);
        assert_eq!(tx.chain_id(), Some(8));
        assert_eq!(tx.tx_hash(), B256::ZERO);
        assert!(tx
            .access_list()
            .is_none_or(|mut list| list.next().is_none()));
        assert!(tx.authorization_list_len() == 0);
    }

    #[test]
    fn history_storage_write_tx_env_keeps_the_given_gas_limit() {
        let tx = history_storage_write_tx_env(1, 1, B256::ZERO, 1_000_000)
            .expect("height 1 has a parent");
        assert_eq!(tx.gas_limit(), 1_000_000);
    }

    /// The block at height 0 has no parent, so no history write is built for it; the first
    /// write is the one of the block at height 1.
    #[test]
    fn history_storage_write_tx_env_refuses_height_zero() {
        let result = history_storage_write_tx_env(1, 0, B256::ZERO, TX_GAS_LIMIT_CAP);
        assert!(
            matches!(
                result,
                Err(SupraExtensionError::HistoryStorageWriteWithoutParent)
            ),
            "got {result:?}"
        );
        assert!(history_storage_write_tx_env(1, 1, B256::ZERO, TX_GAS_LIMIT_CAP).is_ok());
        assert!(history_storage_write_tx_env(1, u64::MAX, B256::ZERO, TX_GAS_LIMIT_CAP).is_ok());
    }

    /// The slot index wraps at the window: the hash of block `n` and the hash of block
    /// `n + HISTORY_SERVE_WINDOW` share a slot.
    #[test]
    fn history_storage_slot_wraps_at_the_window() {
        assert_eq!(HISTORY_SERVE_WINDOW, 8191);
        assert_eq!(history_storage_slot(0), U256::ZERO);
        assert_eq!(history_storage_slot(1), U256::from(1));
        assert_eq!(history_storage_slot(8190), U256::from(8190));
        assert_eq!(history_storage_slot(8191), U256::ZERO);
        assert_eq!(history_storage_slot(8192), U256::from(1));
        assert_eq!(history_storage_slot(16382), U256::ZERO);
        assert_eq!(history_storage_slot(16383), U256::from(1));
        assert_eq!(history_storage_slot(u64::MAX), U256::from(u64::MAX % 8191));
    }
}
