use alloy_primitives::Address;

#[macro_export]
macro_rules! define_reserved_addresses {
    (
        $(
            $name:ident = $value:expr
        ),+ $(,)?
    ) => {
        $(
            pub const $name: Address = $value;
        )+
    };
}

pub const fn u64_to_address(x: u64) -> Address {
    let x = x.to_be_bytes();
    Address::new([
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7],
    ])
}

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

/// [0x5355_0000, 0x53555_00FF] addresses are reserved as SUPRA special addresses.
pub const SUPRA_RESERVED_ADDRESSES: [Address; 0xff] = generate_address_range::<0xff>(0x5355_0000);

/// Checks whether specified input address is one of the SUPRA
pub fn is_supra_reserved(address: &Address) -> bool {
    SUPRA_RESERVED_ADDRESSES.contains(address)
}

define_reserved_addresses!(
    VM_SIGNER = SUPRA_RESERVED_ADDRESSES[0],
    TXN_HASH = SUPRA_RESERVED_ADDRESSES[1],
);

