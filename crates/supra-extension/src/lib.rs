//! # revm-supra-extension
//! Supra extensions of the transactions to support automation feature and block based checks

#[cfg(feature = "build-utils")]
pub mod build_utils;
pub mod contracts;
pub mod errors;
#[allow(missing_docs, missing_debug_implementations)]
#[allow(elided_lifetimes_in_paths)]
mod supra_contract_bindings;
pub mod transactions;
pub use crate::supra_contract_bindings::supra_contracts_bindings::{
    LibCommon::{CycleDetails, CycleState, TaskState, TaskType},
    SupraContractsBindings::*,
};
