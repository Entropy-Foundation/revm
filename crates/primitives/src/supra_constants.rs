//! Constants defined by SUPRA to facilitate execution flow extensions.
use alloy_primitives::Address;

/// Defines a constant of Address type for the input value with the specified name
#[macro_export]
macro_rules! define_reserved_addresses {
    (
        $(
            $doc:expr,
            $name:ident = $value:expr
        ),+ $(,)?
    ) => {
        $(
            #[doc = $doc]
            pub const $name: Address = $value;
        )+
    };
}

/// Converts [`u64`] to [`Address`] type.
pub const fn u64_to_address(x: u64) -> Address {
    let x = x.to_be_bytes();
    Address::new([
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7],
    ])
}

/// Generates continues range of address.
///  - start is the start address
///  - N generic parameter specifying the length of the range from the specified start.
pub const fn generate_address_range<const N: usize>(start: u64) -> [Address; N] {
    let start_address = u64_to_address(start);
    let mut reserved_addresses: [Address; N] =  [start_address; N];
    let mut i = 1;
    while i < N {
        let address = u64_to_address(start + i as u64);
        reserved_addresses[i]=  address;
        i += 1;
    }
    reserved_addresses
}

/// [0x5355_5000, 0x53555_50FF] addresses are reserved as SUPRA special addresses.
pub const SUPRA_RESERVED_ADDRESSES: [Address; 0xFF] = generate_address_range::<0xff>(0x5355_5000);

/// Checks whether specified input address is one of the SUPRA
pub fn is_supra_reserved(address: &Address) -> bool {
    SUPRA_RESERVED_ADDRESSES.contains(address)
}

/// Checks whether specified input address is SUPRA reserved VM_SIGNER
pub fn is_vm_signer(address: &Address) -> bool {
    VM_SIGNER.eq(address)
}

define_reserved_addresses!(
    "Supra Reserved address for VM SIGNER",
    VM_SIGNER = SUPRA_RESERVED_ADDRESSES[0],
    "Supra Reserved address Precompile address to retrieve transaction hash",
    TX_HASH_ADDRESS = SUPRA_RESERVED_ADDRESSES[1],
);

