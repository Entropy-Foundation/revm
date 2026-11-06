//! [EIP-2935](https://eips.ethereum.org/EIPS/eip-2935): serve historical block hashes from state.
//!
//! The constants the EIP fixes, shared by the genesis deployment of the history contract, the
//! caller check that admits the EIP's system call, and the node that issues that call before each
//! block. They are defined once here so that the deployer, the writer and the checks cannot drift
//! apart: the window in particular is also a constant inside the contract's bytecode, and a writer
//! that disagreed with it would store hashes where `get` never looks.

use alloy_primitives::{address, Address};

/// Sender of the EIP's system calls, `0xff…fe`.
///
/// The history contract takes its `set` path only when `CALLER` is this address, and then stores
/// the 32-byte input as the parent block's hash. No key is known for it; on SupraEVM it is a sender
/// only of system transactions (see `Handler::validate_caller`).
pub const SYSTEM_ADDRESS: Address = address!("0xfffffffffffffffffffffffffffffffffffffffe");

/// Address of the history contract, the result of the EIP's presigned deployment transaction.
pub const HISTORY_STORAGE_ADDRESS: Address = address!("0x0000F90827F1C53a10cb7A02335B175320002935");

/// Number of block hashes the history contract serves, `HISTORY_SERVE_WINDOW` in the EIP.
///
/// The hash of block `n` is stored in slot `n % HISTORY_SERVE_WINDOW`, and `get(n)` answers only
/// for `block.number - HISTORY_SERVE_WINDOW <= n < block.number`. The value is part of the
/// contract's bytecode; changing it here without replacing the bytecode would be wrong.
pub const HISTORY_SERVE_WINDOW: u64 = 8191;

/// Returns true if `address` is [`SYSTEM_ADDRESS`].
#[inline]
pub fn is_system_address(address: &Address) -> bool {
    SYSTEM_ADDRESS.eq(address)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::supra_constants::{is_supra_reserved, VM_SIGNER};

    /// The EIP's system sender is a sender of its own, outside the Supra reserved range: the
    /// guards on reserved addresses do not apply to it, and it is not `VM_SIGNER`.
    #[test]
    fn system_address_is_not_a_supra_reserved_address() {
        assert!(is_system_address(&SYSTEM_ADDRESS));
        assert!(!is_system_address(&VM_SIGNER));
        assert!(!is_system_address(&HISTORY_STORAGE_ADDRESS));
        assert!(!is_supra_reserved(&SYSTEM_ADDRESS));
    }
}
