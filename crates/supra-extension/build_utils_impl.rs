use anyhow::Result;
use foundry_compilers::utils;
use foundry_config::Config;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

// Shared build-time utility implementations.
//
// This file is `include!`-d into both `build.rs` (build script) and
// `src/build_utils.rs` (library, behind the `build-utils` feature) so that
// the logic lives in exactly one place while being reachable from both contexts.

/// Configuration for which Solidity contracts to compile, loaded from `compile_config.toml`.
#[derive(Serialize, Deserialize, Debug)]
pub struct CompileConfig {
    /// Path to the foundry project, relative to the crate's manifest directory.
    dapp_path: PathBuf,
    /// Names of contracts whose bytecode should be extracted after compilation.
    contract_names: Vec<String>,
}

impl CompileConfig {
    /// Load configuration from `compile_config.toml` located in `manifest_dir`.
    ///
    /// `manifest_dir` is typically `env!("CARGO_MANIFEST_DIR")` when called from a
    /// build script, and can be sourced from any directory when called from tests or
    /// other tooling.
    pub fn load(manifest_dir: &Path) -> Result<CompileConfig> {
        let path = manifest_dir.join("compile_config.toml");
        toml::from_str::<CompileConfig>(&std::fs::read_to_string(path)?)
            .map_err(|e| e.into())
            .inspect_err(|e| println!("Error: {}", e))
    }

    /// Resolve and canonicalize the foundry project directory relative to `manifest_dir`.
    pub fn contracts_dapp_path(&self, manifest_dir: &Path) -> PathBuf {
        utils::canonicalize(manifest_dir.join(&self.dapp_path))
            .expect("failed to canonicalize dapp path")
    }

    /// Names of contracts to compile and embed.
    pub fn contract_names(&self) -> &[String] {
        &self.contract_names
    }
}

/// Compile all Solidity contracts in the foundry project rooted at `path`.
///
/// Emits `cargo:rerun-if-changed` for every Solidity source file discovered by
/// the project, and sets `cargo:rustc-env=COMPILED_CONTRACTS_DIR` to the
/// artifacts directory so downstream code can locate the compiled output.
///
/// Returns the path to the compiled artifacts directory.
pub fn compile_contracts(path: &impl AsRef<Path>) -> Result<PathBuf> {
    let foundry_config = Config::load_with_root(path.as_ref())?.sanitized();
    let _ = foundry_config.install_lib_dir();
    let project = foundry_config.project()?;

    let output = project.compile()?;
    let _ = output.succeeded();
    // Instruct Cargo to re-run this build script whenever a Solidity source changes.
    project.rerun_if_sources_changed();

    let artifacts_dir = project.paths.artifacts.clone();
    println!(
        "cargo:rustc-env=COMPILED_CONTRACTS_DIR={}",
        artifacts_dir.display()
    );

    Ok(artifacts_dir)
}

/// Populate `bytecodes` with the compiled deployment bytecode for each contract in
/// `contract_names`, reading Foundry's default artifact layout under `artifacts_path`:
/// `<artifacts_path>/<ContractName>.sol/<ContractName>.json`.
///
/// Returns an error if any artifact is missing, its bytecode field is empty, or a
/// contract name appears more than once.
pub fn load_contracts_bytecode(
    contract_names: &[String],
    artifacts_path: &Path,
    bytecodes: &mut BTreeMap<String, Vec<u8>>,
) -> Result<()> {
    for contract_name in contract_names {
        let path = artifacts_path
            .join(format!("{contract_name}.sol"))
            .join(format!("{contract_name}.json"));

        if !path.exists() {
            return Err(anyhow::anyhow!(
                "Failed to find contract artifact at: {}",
                path.display()
            ));
        }

        let file = std::fs::File::open(&path)?;
        let buf_reader = std::io::BufReader::new(file);
        let contract: foundry_compilers::artifacts::ContractBytecode =
            serde_json::from_reader(buf_reader)?;

        let bytecode: Vec<u8> = contract
            .bytecode
            .and_then(|b| b.bytes().cloned())
            .map(|b| b.to_vec())
            .filter(|b| !b.is_empty())
            .ok_or_else(|| {
                anyhow::anyhow!("Failed to load bytecode for contract: {contract_name}")
            })?;

        let inserted = bytecodes.insert(contract_name.to_string(), bytecode);
        // Two contracts with the same name in the same artifacts tree is a configuration
        // error — the second would silently overwrite the first if we allowed it.
        if inserted.is_some() {
            return Err(anyhow::anyhow!(
                "Duplicate contract name: {contract_name} in {artifacts_path:?} path"
            ));
        }
    }
    Ok(())
}

/// Serialize `bytecodes` with bincode and write the result to
/// `$OUT_DIR/<bin_file_name>.bin`.
///
/// Also emits `cargo:rustc-env=CONTRACTS_DUMPED=1` so that the library crate can
/// assert at compile time that the build step ran successfully.
///
/// `OUT_DIR` is set by Cargo when executing build scripts; calling this function
/// outside a build script context will return an error.
pub fn dump_bytecodes(bytecodes: BTreeMap<String, Vec<u8>>, bin_file_name: &str) -> Result<()> {
    let out_dir = std::env::var("OUT_DIR")?;
    let out_path = Path::new(&out_dir)
        .join(bin_file_name)
        .with_extension("bin");

    std::fs::write(
        &out_path,
        bincode::serde::encode_to_vec(&bytecodes, bincode::config::standard())
            .expect("Successful serialization"),
    )
    .expect("Failed to write bytecodes to file");

    println!("cargo:rustc-env=CONTRACTS_DUMPED=1");
    Ok(())
}