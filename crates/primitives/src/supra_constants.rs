//! Constants defined by SUPRA to facilitate execution flow extensions.
use alloy_primitives::Address;

/// Converts [`u64`] to [`Address`] type.
pub const fn u64_to_address(x: u64) -> Address {
    let x = x.to_be_bytes();
    Address::new([
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7],
    ])
}

/// Supra Reserved address for VM SIGNER,
pub const VM_SIGNER: Address = u64_to_address(0x5355_5000);

/// Supra Reserved address Precompile address to retrieve transaction hash
pub const TX_HASH_ADDRESS: Address = u64_to_address(0x5355_5001);

/// [0x5355_5000, 0x53555_50FF] addresses are reserved as SUPRA special addresses.
const SUPRA_RESERVED_ADDRESSES_PREFIX_UPPER_BOUND: usize = 19;

/// Checks whether specified input address is one of the SUPRA reserved ones.
pub fn is_supra_reserved(address: &Address) -> bool {
    VM_SIGNER[..SUPRA_RESERVED_ADDRESSES_PREFIX_UPPER_BOUND]
        .eq(&address[..SUPRA_RESERVED_ADDRESSES_PREFIX_UPPER_BOUND])
}

/// Checks whether specified input address is SUPRA reserved VM_SIGNER
pub fn is_vm_signer(address: &Address) -> bool {
    VM_SIGNER.eq(address)
}

#[cfg(test)]
mod tests {
    use crate::supra_constants::{is_supra_reserved, TX_HASH_ADDRESS, VM_SIGNER};

    #[test]
    fn check_reserved_addresses() {
        let addr5 = super::u64_to_address(0x5355_5005);
        let last_reserved = super::u64_to_address(0x5355_50ff);
        let any_low_address = super::u64_to_address(0x5355_4fff);
        let any_up_address = super::u64_to_address(0x5355_5100);
        let any_address = super::u64_to_address(0x1_5355_5000);
        assert!(is_supra_reserved(&addr5));
        assert!(is_supra_reserved(&VM_SIGNER));
        assert!(is_supra_reserved(&TX_HASH_ADDRESS));
        assert!(!is_supra_reserved(&any_address));
        assert!(!is_supra_reserved(&any_low_address));
        assert!(!is_supra_reserved(&any_up_address));
    }
}
