//! Rust bindings for the `SupraContractsBindings` interface, generated at compile time.
//!
//! `sol!` reads the JSON ABI of
//! `solidity/supra_contracts/src/SupraContractsBindings.sol` rather than the Solidity
//! source: the interface imports `LibCommon` and `TaskMetadata` from other files, and
//! `sol!` does not resolve imports. The ABI is written by this crate's build script,
//! which compiles the whole Foundry project before the library is compiled and reruns
//! whenever a Solidity source changes (`compile_contracts` in `build_utils_impl.rs`).
//! The structs and enums the interface takes from `LibCommon` are generated into a
//! `LibCommon` module, named after the `internalType` entries of the ABI.
//!
//! `sol!` embeds the ABI with `include_bytes!`, so a changed interface rebuilds the
//! bindings.
//!
//! The ABI path starts with `COMPILED_CONTRACTS_DIR`, the artifacts directory of the
//! Foundry project the build script compiled, which `compile_contracts` exports with
//! `cargo:rustc-env`. `sol!` evaluates `concat!` and `env!` in its path argument while
//! `rustc` compiles this crate, after the build script has run. The remainder of the
//! path is Foundry's artifact layout, `<Source>.sol/<Contract>.json`.

alloy::sol!(
    // `rpc` generates the contract instance types (`SupraContractsBindingsInstance`).
    // `all_derives` adds `Debug`, `Default`, `PartialEq`, `Eq` and `Hash` where the
    // Solidity types allow them; serde is required by the crate's serialized records.
    #[sol(
        rpc,
        all_derives = true,
        extra_derives(serde::Serialize, serde::Deserialize)
    )]
    SupraContractsBindings,
    concat!(
        env!("COMPILED_CONTRACTS_DIR"),
        "/SupraContractsBindings.sol/SupraContractsBindings.json"
    )
);
