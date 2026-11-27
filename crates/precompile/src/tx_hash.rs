//! TX_HASH precompile is added to return the transaction hash of the
//! transaction
use primitives::supra_constants::TX_HASH_ADDRESS;

use crate::{eth_precompile_fn, identity::identity_run, Precompile, PrecompileId};

eth_precompile_fn!(tx_hash_precompile, identity_run);

/// TX_HASH precompile
pub const TX_HASH: Precompile =
    Precompile::new(PrecompileId::TxHash, TX_HASH_ADDRESS, tx_hash_precompile);
