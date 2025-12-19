//! TX_HASH precompile is added to return the transaction hash of the
//! transaction
use primitives::supra_constants::TX_HASH_ADDRESS;

use crate::{identity::identity_run, Precompile, PrecompileId};

/// TX_HASH precompile
pub const TX_HASH: Precompile =
    Precompile::new(PrecompileId::TxHash, TX_HASH_ADDRESS, identity_run);
