//! Prepares supra-extension by compiling the Solidity contracts and dumping their bytecode.
//!
//! The compiled artifacts include the JSON ABI from which `sol!` generates the Rust
//! bindings in `src/supra_contract_bindings/supra_contracts_bindings.rs`.

// Utility functions shared with the `build-utils` library feature — see src/build_utils.rs.
// Using include! keeps a single source of truth for CompileConfig, compile_contracts,
// load_contracts_bytecode, and dump_bytecodes without introducing a circular dependency
// between the build script and the library crate.
include!("build_utils_impl.rs");

const CURRENT_DIR: &str = env!("CARGO_MANIFEST_DIR");

fn main() {
    let manifest_dir = Path::new(CURRENT_DIR);
    let config = CompileConfig::load(manifest_dir).expect("compile_config.toml is readable TOML");
    // Rerun this script if the compile configuration changes (e.g. a contract name is added).
    println!("cargo:rerun-if-changed={}/compile_config.toml", CURRENT_DIR);

    // Exposes which Foundry profile this build actually selected (see
    // select_foundry_profile in build_utils_impl.rs), so tests can tell whether golden
    // values captured from a --release build are meaningful to compare against for the
    // current build (see genesis_contract_bytecode_matches_expected_hashes).
    println!(
        "cargo:rustc-env=SUPRA_CONTRACTS_FOUNDRY_PROFILE={}",
        if std::env::var("PROFILE").as_deref() == Ok("release") {
            "production"
        } else {
            "default"
        }
    );

    let mut contracts_bytecode = BTreeMap::new();
    compile_and_load_contracts(
        &config.contracts_dapp_path(manifest_dir),
        config.contract_names(),
        &mut contracts_bytecode,
        &[],
    )
    .expect("the Supra contracts compile and their bytecode is readable");

    dump_bytecodes(contracts_bytecode, "supra_contracts_bytecode")
        .expect("the compiled bytecode is written to OUT_DIR");
}
