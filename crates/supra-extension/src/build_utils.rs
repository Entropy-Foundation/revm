//! Build-time utilities for Solidity contract compilation and bytecode extraction.
//!
//! These utilities are designed for use inside `build.rs` scripts. Other crates can
//! consume them by adding `revm-supra-extension` as a `[build-dependencies]` entry
//! with `features = ["build-utils"]`:
//!
//! ```toml
//! [build-dependencies]
//! revm-supra-extension = { ..., features = ["build-utils"] }
//! ```
//!
//! Then in the consuming `build.rs`:
//!
//! ```rust,ignore
//! use revm_supra_extension::build_utils::{CompileConfig, compile_contracts,
//!     load_contracts_bytecode, dump_bytecodes};
//! use std::collections::BTreeMap;
//! use std::path::Path;
//!
//! fn main() {
//!     let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
//!     let config = CompileConfig::load(manifest_dir).unwrap();
//!     let artifacts = compile_contracts(&config.contracts_dapp_path(manifest_dir)).unwrap();
//!     let mut bytecodes = BTreeMap::new();
//!     load_contracts_bytecode(config.contract_names(), &artifacts, &mut bytecodes).unwrap();
//!     dump_bytecodes(bytecodes, "my_contracts_bytecode").unwrap();
//! }
//! ```

// Shared implementation with build.rs — see build_utils_impl.rs at the crate root.
// Both build.rs (build script) and this module include the same file to avoid
// duplicating ~120 lines of implementation while staying within Rust's constraint
// that a build script cannot depend on its own library crate.
include!("../build_utils_impl.rs");