//! TX_HASH precompile is added to return the transaction hash of the
//! transaction
use crate::{identity::identity_run, Precompile, PrecompileId};

/// TX_HASH precompile
pub const TX_HASH: Precompile = Precompile::new(
    PrecompileId::TxHash,
    crate::u64_to_address(0x5355_5000),
    identity_run,
);
