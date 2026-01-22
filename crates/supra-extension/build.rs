//! Prepares supra-extension by compiling smart-contracts and building rust bindings

use foundry_compilers::artifacts::{Optimizer, Remapping, Settings};
use foundry_compilers::multi::MultiCompilerSettings;
use foundry_compilers::solc::SolcSettings;
use foundry_compilers::{Project, ProjectPathsConfig};
use std::env;
use std::path::Path;
use std::path::PathBuf;
use anyhow::Result;

fn rebuild_rust_bindings() {
    // 1. Tell Cargo to rerun the script if the contracts directory changes
    let cargo_dir = PathBuf::from(
        env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR environment variable not set"),
    );
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

    //// Determine the output directory for the generated bindings
    //use clap::Parser;
    //use forge::cmd::bind::BindArgs;
    //let contracts_relative_path = PathBuf::from("../../solidity/supra_contracts");
    //let contracts_build_config =
    //    cargo_dir.join(contracts_relative_path.join(PathBuf::from("foundry.toml")));
    //let contract_names = "SupraContracts";

    //let bindings_path = cargo_dir
    //    .join(PathBuf::from("src"))
    //    .join(PathBuf::from("supra_contract_bindings"));

    //// Ensure the output directory exists
    //std::fs::create_dir_all(bindings_path.as_path()).expect("Failed to create bindings directory");
    //let command_inputs = format!(
    //    "bind --bindings-path {} --overwrite --module --select {} --alloy --config-path {}",
    //    bindings_path.display(),
    //    contract_names,
    //    contracts_build_config.display()
    //);
    //let parsed_inputs = shlex::split(&command_inputs).expect("Failed to parse command string");
    //let bind_cmd: BindArgs =
    //    BindArgs::try_parse_from(parsed_inputs).expect("Failed to parse command arguments");
    //bind_cmd.run().expect("Failed to execute bind command");
}

const CONTRACTS_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../solidity/supra_contracts/"
);
fn compile_contracts() -> Result<()> {
    let path = foundry_compilers::utils::canonicalize(Path::new(CONTRACTS_PATH))?;
    let mut settings = Settings::default();
    settings.via_ir = Some(true);
    settings.optimizer = Optimizer {
        enabled: Some(true),
        runs: Some(200),
        details: None,
    };
    let mut multi_compiler_settings = MultiCompilerSettings::default();
    let mut solc_settings = SolcSettings::default();
    solc_settings.settings = settings;
    multi_compiler_settings.solc = solc_settings;

    // configure the project with all its paths, solc, cache etc.
    // @openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
    let remappings = Remapping {
        context: None,
        name: "@openzeppelin/contracts/".to_string(),
        path: path
            .join("lib/openzeppelin-contracts/contracts/").as_os_str().to_string_lossy().to_string()
    };
    let mut paths = ProjectPathsConfig::dapptools(&path)?;
    paths.remappings.insert(0, remappings);
    let project = Project::builder()
        .paths(paths)
        .settings(multi_compiler_settings)
        .build(Default::default())?;
    let output = project.compile().unwrap();
    let _ = output.succeeded();
    // Tell Cargo that if a source file changes, to rerun this build script.
    project.rerun_if_sources_changed();
    Ok(())
}

fn main() {
    rebuild_rust_bindings();
    compile_contracts().inspect_err(|e|{
        panic!("{e:?}")
    }).unwrap()
}
