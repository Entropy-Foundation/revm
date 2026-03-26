//! Prepares supra-extension by compiling smart-contracts and building rust bindings

use anyhow::Result;
use foundry_compilers::artifacts::Remapping;
use foundry_compilers::multi::MultiCompilerSettings;
use foundry_compilers::solc::SolcSettings;
use foundry_compilers::{utils, Project, ProjectPathsConfig};
use serde::{Deserialize, Serialize};
use std::env;
use std::path::Path;
use std::path::PathBuf;

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
    dapp_relative_path: PathBuf,
    solc_settings: SolcSettings,
    #[serde(default)]
    remappings: Vec<(String, String)>,
}

impl CompileConfig {
    fn load() -> Result<CompileConfig> {
        let path = Path::new(CURRENT_DIR).join("compile_config.toml");
        toml::from_str::<CompileConfig>(&std::fs::read_to_string(path)?)
            .map_err(|e| e.into())
            .inspect_err(|e| println!("Error: {}", e))
    }

    fn dapp_path(&self) -> PathBuf {
        utils::canonicalize(Path::new(CURRENT_DIR).join(&self.dapp_relative_path))
            .expect("failed to canonicalize dapp path")
    }

    fn remappings(&self) -> Vec<Remapping> {
        self.remappings
            .iter()
            .map(|(name, rel_path)| Remapping {
                context: None,
                name: name.clone(),
                path: self
                    .dapp_path()
                    .join(rel_path)
                    .to_string_lossy()
                    .into_owned(),
            })
            .collect()
    }

    fn to_multi_compiler_settings(self) -> MultiCompilerSettings {
        let mut settings = MultiCompilerSettings::default();
        settings.solc = self.solc_settings;
        settings
    }
}

fn compile_contracts() -> Result<()> {
    let config = CompileConfig::load()?;

    let mut paths = ProjectPathsConfig::dapptools(&config.dapp_path())?;
    for (idx, value) in config.remappings().into_iter().enumerate() {
        paths.remappings.insert(idx, value)
    }

    let project = Project::builder()
        .paths(paths)
        .settings(config.to_multi_compiler_settings())
        .build(Default::default())?;
    let output = project.compile()?;
    let _ = output.succeeded();
    // Tell Cargo that if a source file changes, to rerun this build script.
    project.rerun_if_sources_changed();
    println!("cargo:rerun-if-changed={}/compile_config.toml", CURRENT_DIR);
    println!(
        "cargo:rustc-env=COMPILED_CONTRACTS_DIR={}",
        project.paths.artifacts.display()
    );

    Ok(())
}

fn main() {
    rebuild_rust_bindings();
    compile_contracts()
        .inspect_err(|e| panic!("{e:?}"))
        .unwrap()
}
