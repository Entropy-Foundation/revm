//! Prepares supra-extension by compiling smart-contracts and building rust bindings

use anyhow::Result;
use bincode;
use foundry_compilers::utils;
use foundry_config::Config;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::env;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

const CURRENT_DIR: &str = env!("CARGO_MANIFEST_DIR");

fn rebuild_rust_bindings() {
    // 1. Tell Cargo to rerun the script if the contracts directory changes
    let cargo_dir = PathBuf::from(CURRENT_DIR);
    println!(
        "cargo:rerun-if-changed={}/../../solidity/supra_contracts/src/SupraContractsBindings.sol",
        cargo_dir.display()
    );

    // smr-moonshot referencing this version of the REVM has dependency conflicts caused by syn library used by forge.
    // So unless the issue is fixed, rust bindings on updates of the SupraContractsBindings.sol will be regenerated manually
    // and committed. This code should remain commented out otherwise
    // To do it:
    // - uncomment below code
    // - uncomment build dependencies in Cargo.toml file of this project
    // - uncomment forge library reference in top level Cargo.toml file
    // - build the project

    // // Determine the output directory for the generated bindings
    // use clap::Parser;
    // use forge::cmd::bind::BindArgs;
    // let contracts_relative_path = PathBuf::from("../../solidity/supra_contracts");
    // let contracts_build_config =
    //    cargo_dir.join(contracts_relative_path.join(PathBuf::from("foundry.toml")));
    // let contract_names = "SupraContracts";
    //
    // let bindings_path = cargo_dir
    //    .join(PathBuf::from("src"))
    //    .join(PathBuf::from("supra_contract_bindings"));
    //
    // // Ensure the output directory exists
    // std::fs::create_dir_all(bindings_path.as_path()).expect("Failed to create bindings directory");
    // let command_inputs = format!(
    //    "bind --bindings-path {} --overwrite --module --select {} --alloy --config-path {}",
    //    bindings_path.display(),
    //    contract_names,
    //    contracts_build_config.display()
    // );
    // let parsed_inputs = shlex::split(&command_inputs).expect("Failed to parse command string");
    // let bind_cmd: BindArgs =
    //    BindArgs::try_parse_from(parsed_inputs).expect("Failed to parse command arguments");
    // bind_cmd.run().expect("Failed to execute bind command");
}

#[derive(Serialize, Deserialize, Debug)]
struct CompileConfig {
    /// Supra contracts relative path
    supra_dapp_path: PathBuf,
    /// Supra nova dapp repository
    supra_nova_repo: String,
    /// Supra nova dapp tag to reference to
    supra_nova_tag: String,
    /// Supra nova dapp relative path in repo
    supra_nova_dapp_path: String,
}

impl CompileConfig {
    fn load() -> Result<CompileConfig> {
        let path = Path::new(CURRENT_DIR).join("compile_config.toml");
        toml::from_str::<CompileConfig>(&std::fs::read_to_string(path)?)
            .map_err(|e| e.into())
            .inspect_err(|e| println!("Error: {}", e))
    }

    fn supra_contracts_dapp_path(&self) -> PathBuf {
        utils::canonicalize(Path::new(CURRENT_DIR).join(&self.supra_dapp_path))
            .expect("failed to canonicalize dapp path")
    }

    fn supra_nova_dapp_path(&self) -> Result<PathBuf> {
        self.checkout_supra_nova_repo()
            .map(|path| path.join(self.supra_nova_dapp_path.clone()))
    }

    fn checkout_supra_nova_repo(&self) -> Result<PathBuf> {
        let out_dir = env::var("OUT_DIR")?;
        let repo_dir = Path::new(&out_dir).join("supranova-contracts");

        if repo_dir.exists() {
            // Check whether the already-cloned repo is at the right tag.
            let output = Command::new("git")
                .args(["describe", "--tags", "--exact-match"])
                .current_dir(&repo_dir)
                .output()?;
            let current_tag = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if current_tag == self.supra_nova_tag {
                return Ok(repo_dir);
            }
            // Wrong tag – remove and re-clone.
            std::fs::remove_dir_all(&repo_dir)?;
        }

        let status = Command::new("git")
            .env(
                "GIT_SSH_COMMAND",
                "ssh -o BatchMode=yes -o StrictHostKeyChecking=no",
            )
            .args([
                "clone",
                "--recurse-submodules",
                "--branch",
                self.supra_nova_tag.as_str(),
                "--depth",
                "1",
                self.supra_nova_repo.as_str(),
                repo_dir
                    .to_str()
                    .ok_or_else(|| anyhow::anyhow!("non-UTF-8 OUT_DIR path"))?,
            ])
            .status()?;

        if !status.success() {
            return Err(anyhow::anyhow!(
                "Failed to clone {} at tag {}",
                self.supra_nova_repo,
                self.supra_nova_tag
            ));
        }

        Ok(repo_dir)
    }
}

fn compile_contracts(path: &impl AsRef<Path>) -> Result<PathBuf> {
    let foundry_config = Config::load_with_root(path.as_ref())?.sanitized();
    let _ = foundry_config.install_lib_dir();
    let project = foundry_config.project()?;

    let output = project.compile()?;
    let _ = output.succeeded();
    // Tell Cargo that if a source file changes, to rerun this build script.
    project.rerun_if_sources_changed();
    println!("cargo:rerun-if-changed={}/compile_config.toml", CURRENT_DIR);

    let artifacts_dir = project.paths.artifacts.clone();
    println!(
        "cargo:rustc-env=COMPILED_CONTRACTS_DIR={}",
        artifacts_dir.display()
    );

    Ok(artifacts_dir)
}

fn load_supra_contracts_bytecode(
    artifacts_path: &Path,
    bytecodes: &mut BTreeMap<String, Vec<u8>>,
) -> Result<()> {
    // Contract names to load
    let contract_names = [
        "MultiSignatureWallet",
        "MultisigBeacon",
        "BeaconProxy",
        "ERC20Supra",
        "ERC20SupraHandler",
        "BlockMeta",
        "ERC1967Proxy",
        "DiamondCutFacet",
        "Diamond",
        "DiamondLoupeFacet",
        "OwnershipFacet",
        "ConfigFacet",
        "RegistryFacet",
        "CoreFacet",
        "DiamondInit",
    ];
    load_contracts_bytecode(&contract_names, artifacts_path, bytecodes)
}

fn load_supra_nova_contracts_bytecode(
    artifacts_path: &Path,
    bytecodes: &mut BTreeMap<String, Vec<u8>>,
) -> Result<()> {
    // Contract names to load
    let contract_names = [
        "WrappedToken",             // Impl
        "WrappedTokenFactory",      // Beacon
        "WrappedTokenFactoryProxy", // Beacon Proxy
        "TokenVault",
        "TokenVaultProxy",
        "Hypernova",
        "HypernovaProxy",
        "FeeOperator",
        "FeeOperatorProxy",
        "TokenBridge",
        "TokenBridgeProxy",
    ];
    load_contracts_bytecode(&contract_names, artifacts_path, bytecodes)
}

fn load_contracts_bytecode(
    contract_names: &[&'static str],
    artifacts_path: &Path,
    bytecodes: &mut BTreeMap<String, Vec<u8>>,
) -> Result<()> {
    // Load each contract's bytecode
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
        if inserted.is_some() {
            return Err(anyhow::anyhow!(
                "Duplicate contract name: {contract_name} in {artifacts_path:?} path"
            ));
        }
    }
    Ok(())
}

fn dump_bytecodes(bytecodes: BTreeMap<String, Vec<u8>>, bin_file_name: &str) -> Result<()> {
    // Dump the combined contract bytecodes to be loaded at compile to by generator.
    let out_dir = env::var("OUT_DIR")?;
    let out_path = Path::new(&out_dir)
        .join(bin_file_name)
        .with_extension("bin");

    std::fs::write(
        &out_path,
        bincode::serde::encode_to_vec(&bytecodes, bincode::config::standard())
            .expect("Successful serializationA"),
    )
    .expect("Failed to write bytecodes to file");

    println!("cargo:rustc-env=CONTRACTS_DUMPED=1");
    Ok(())
}

fn main() {
    rebuild_rust_bindings();

    let config = CompileConfig::load().expect("Config should always be valid");
    let supra_contracts_artifacts = compile_contracts(&config.supra_contracts_dapp_path())
        .expect("Successful supra contracts compilation");
    let supra_nova_artifacts = compile_contracts(
        &config
            .supra_nova_dapp_path()
            .expect("Successful supra nova dapp path resolve"),
    )
    .expect("Successful supra nova contracts compilation");
    let mut contracts_bytecode = BTreeMap::new();
    load_supra_contracts_bytecode(&supra_contracts_artifacts, &mut contracts_bytecode)
        .expect("Supra contracts loaded successfully");
    load_supra_nova_contracts_bytecode(&supra_nova_artifacts, &mut contracts_bytecode)
        .expect("Supra nova contracts loaded successfully");
    dump_bytecodes(contracts_bytecode, "supra_contracts_bytecode")
        .expect("Bytecodes dumped successfully");
}
