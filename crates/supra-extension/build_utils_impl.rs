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

/// `FOUNDRY_*`/`DAPP_*` environment variables that Foundry reads and that can change
/// compiled bytecode. Watched here (via `cargo:rerun-if-env-changed`) even for the
/// ones this build script manages itself, so the build cache still invalidates when
/// they change.
const FOUNDRY_WATCHED_ENV_VARS: &[&str] = &[
    "FOUNDRY_PROFILE",
    "FOUNDRY_CONFIG",
    "FOUNDRY_SRC",
    "FOUNDRY_OUT",
    "FOUNDRY_LIBS",
    "FOUNDRY_REMAPPINGS",
    "FOUNDRY_OPTIMIZER",
    "FOUNDRY_OPTIMIZER_RUNS",
    "FOUNDRY_VIA_IR",
    "FOUNDRY_BYTECODE_HASH",
    "FOUNDRY_CBOR_METADATA",
    "FOUNDRY_EVM_VERSION",
    "FOUNDRY_SOLC_VERSION",
    "FOUNDRY_SOLC",
    "DAPP_SRC",
    "DAPP_LIBS",
    "DAPP_REMAPPINGS",
];

/// Guard against ambient `FOUNDRY_WATCHED_ENV_VARS` silently changing compiled
/// Solidity bytecode. Foundry merges any such variable over `foundry.toml`
/// (last-wins).
///
/// Emits `cargo:rerun-if-env-changed` for each variable in `FOUNDRY_WATCHED_ENV_VARS`,
/// then fails the build if any of them is set and isn't listed in `allowed_env`. A
/// caller that deliberately sets one of these variables itself (to select a Foundry
/// profile, for instance) must pass its name there rather than have it silently
/// excluded here. Other `FOUNDRY_*`/`DAPP_*` variables Foundry reads are not checked,
/// so this only rejects variables actually in the list above.
fn guard_ambient_foundry_env(allowed_env: &[&str]) -> Result<()> {
    for var in FOUNDRY_WATCHED_ENV_VARS {
        println!("cargo:rerun-if-env-changed={var}");
    }
    println!("cargo:rerun-if-env-changed=PROFILE");

    let offending: Vec<String> = std::env::vars()
        .map(|(key, _)| key)
        .filter(|key| FOUNDRY_WATCHED_ENV_VARS.contains(&key.as_str()))
        .filter(|key| !allowed_env.contains(&key.as_str()))
        .collect();

    if !offending.is_empty() {
        return Err(anyhow::anyhow!(
            "Ambient environment variable(s) {} would silently change the compiled \
             Solidity bytecode embedded into this binary, and therefore every \
             CREATE2 genesis contract address derived from it. Unset them before \
             building.",
            offending.join(", ")
        ));
    }
    Ok(())
}

/// Explicitly select the Foundry profile to compile with, based on Cargo's own build
/// profile rather than leaving profile selection to an ambient `FOUNDRY_PROFILE`.
/// Release builds — the ones whose genesis bytecode actually ships — compile under
/// `[profile.production]`; everything else compiles under `[profile.default]`.
fn select_foundry_profile() {
    let profile = match std::env::var("PROFILE").as_deref() {
        Ok("release") => "production",
        _ => "default",
    };
    std::env::set_var("FOUNDRY_PROFILE", profile);
}

/// Compile all Solidity contracts in the foundry project rooted at `path`.
///
/// Emits `cargo:rerun-if-changed` for every Solidity source file discovered by the
/// project, for the project's `lib/` directories and `foundry.toml`/`remappings.txt`,
/// and sets `cargo:rustc-env=COMPILED_CONTRACTS_DIR` to the artifacts directory so
/// downstream code can locate the compiled output.
///
/// Fails the build if an ambient `FOUNDRY_*`/`DAPP_*` environment variable is set
/// that isn't in `allowed_env` — see `guard_ambient_foundry_env`. The Foundry profile
/// used is always `FOUNDRY_PROFILE`, selected by `select_foundry_profile`, so callers
/// never need to (and must not) allowlist `FOUNDRY_PROFILE` themselves.
///
/// Returns the path to the compiled artifacts directory.
pub fn compile_contracts(path: &impl AsRef<Path>, allowed_env: &[&str]) -> Result<PathBuf> {
    let mut allowed = vec!["FOUNDRY_PROFILE"];
    allowed.extend_from_slice(allowed_env);
    guard_ambient_foundry_env(&allowed)?;
    select_foundry_profile();

    let foundry_config = Config::load_with_root(path.as_ref())?.sanitized();
    let _ = foundry_config.install_lib_dir();
    let project = foundry_config.project()?;

    let output = project.compile()?;
    // `has_compiler_errors` honours the project's severity filter and ignored error
    // codes, so warnings do not fail the build. `Display` renders the compiler's own
    // diagnostics, filtered the same way.
    if output.has_compiler_errors() {
        return Err(anyhow::anyhow!(
            "Solidity compilation failed for the project at {}:\n{output}",
            path.as_ref().display()
        ));
    }
    // Instruct Cargo to re-run this build script whenever a Solidity source changes.
    project.rerun_if_sources_changed();
    // `rerun_if_sources_changed` above only watches `src/`; also watch `lib/` and
    // `foundry.toml`/`remappings.txt` below (Entropy-Foundation/smr-moonshot#3473).
    for library in &project.paths.libraries {
        println!("cargo:rerun-if-changed={}", library.display());
    }
    println!(
        "cargo:rerun-if-changed={}",
        project.paths.root.join("foundry.toml").display()
    );
    // Cargo accepts a rerun-if-changed path that doesn't exist yet and treats its
    // later appearance as a change, so this is unconditional.
    println!(
        "cargo:rerun-if-changed={}",
        project.paths.root.join("remappings.txt").display()
    );

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
    // Two contracts with the same name would silently overwrite each other, which is a
    // configuration error rather than a damaged artifact. It is checked before any file
    // is read so that every later error in this function means the artifacts themselves
    // are unusable, and are therefore worth recompiling.
    for (index, contract_name) in contract_names.iter().enumerate() {
        if contract_names[..index].contains(contract_name) || bytecodes.contains_key(contract_name)
        {
            return Err(anyhow::anyhow!(
                "Duplicate contract name: {contract_name} in {artifacts_path:?} path"
            ));
        }
    }

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
            serde_json::from_reader(buf_reader).map_err(|e| {
                anyhow::anyhow!(
                    "Failed to parse contract artifact at {}: {e}",
                    path.display()
                )
            })?;

        let bytecode: Vec<u8> = contract
            .bytecode
            .and_then(|b| b.bytes().cloned())
            .map(|b| b.to_vec())
            .filter(|b| !b.is_empty())
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "Failed to load bytecode for contract {contract_name} from {}",
                    path.display()
                )
            })?;

        bytecodes.insert(contract_name.to_string(), bytecode);
    }
    Ok(())
}

/// Compile the Solidity project rooted at `path` and populate `bytecodes` with the
/// deployment bytecode of each contract in `contract_names`.
///
/// An artifact that is missing, empty, unparsable or devoid of deployment bytecode is
/// treated as damaged rather than fatal: the compiled output and the compiler cache are
/// discarded and the project is compiled once more before the error is reported. The
/// cache must go with the artifacts, because the compiler considers unchanged sources
/// already built and would otherwise leave the damaged output in place.
///
/// This matters because these artifacts live in Cargo's git checkout directory, outside
/// any workspace and beyond the reach of CI cleanup steps: a build interrupted mid-write
/// leaves a truncated artifact that every later build on that machine would read, and a
/// build script cannot be re-run by hand to clear it.
///
/// Returns the path to the compiled artifacts directory.
pub fn compile_and_load_contracts(
    path: &impl AsRef<Path>,
    contract_names: &[String],
    bytecodes: &mut BTreeMap<String, Vec<u8>>,
    allowed_env: &[&str],
) -> Result<PathBuf> {
    let artifacts_dir = compile_contracts(path, allowed_env)?;
    let first_attempt = match load_contracts_bytecode(contract_names, &artifacts_dir, bytecodes) {
        Ok(()) => return Ok(artifacts_dir),
        Err(e) => e,
    };

    println!(
        "cargo:warning=Discarding the compiled Solidity output at {} and recompiling, because it \
         could not be read: {first_attempt:#}",
        artifacts_dir.display()
    );
    // A failed load may have inserted bytecodes for the contracts it did reach.
    for contract_name in contract_names {
        bytecodes.remove(contract_name);
    }
    discard_compiled_output(path)?;

    let artifacts_dir = compile_contracts(path, allowed_env)?;
    load_contracts_bytecode(contract_names, &artifacts_dir, bytecodes).map_err(|e| {
        anyhow::anyhow!(
            "Recompiling the Solidity project at {} did not produce readable artifacts. \
             Before recompiling: {first_attempt:#}. After recompiling: {e:#}",
            path.as_ref().display()
        )
    })?;

    Ok(artifacts_dir)
}

/// Delete the compiled artifacts and the compiler cache of the Solidity project rooted
/// at `path`, so that the next compilation rebuilds every source from scratch.
///
/// Does not re-run `guard_ambient_foundry_env`/`select_foundry_profile`: this is only
/// called from `compile_and_load_contracts`'s retry path, immediately before another
/// `compile_contracts` call that already does both, and `FOUNDRY_PROFILE` set by the
/// first `compile_contracts` call persists in the process for this one to see.
fn discard_compiled_output(path: &impl AsRef<Path>) -> Result<()> {
    let foundry_config = Config::load_with_root(path.as_ref())?.sanitized();
    let project = foundry_config.project()?;
    project.cleanup()?;
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
            .expect("the bytecode map is serializable"),
    )
    .expect("the serialized bytecode is written to OUT_DIR");

    println!("cargo:rustc-env=CONTRACTS_DUMPED=1");
    Ok(())
}
