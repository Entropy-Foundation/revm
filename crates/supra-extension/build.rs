use std::env;
use std::path::PathBuf;

use clap::Parser;
use forge::cmd::bind::BindArgs;

fn main() {
    // 1. Tell Cargo to rerun the script if the contracts directory changes
    let cargo_dir = PathBuf::from(
        env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR environment variable not set"),
    );
    println!(
        "cargo:rerun-if-changed={}/../../solidity/supra_contracts/src/SupraContractsBindings.sol",
        cargo_dir.display()
    );

    // Determine the output directory for the generated bindings

    let contracts_relative_path = PathBuf::from("../../solidity/supra_contracts");
    let contracts_build_config =
        cargo_dir.join(contracts_relative_path.join(PathBuf::from("foundry.toml")));
    let contract_names = "SupraContracts";

    let bindings_path = cargo_dir
        .join(PathBuf::from("src"))
        .join(PathBuf::from("supra_contract_bindings"));

    // Ensure the output directory exists
    std::fs::create_dir_all(bindings_path.as_path()).expect("Failed to create bindings directory");
    let command_inputs = format!(
        "bind --bindings-path {} --overwrite --module --select {} --alloy --config-path {}",
        bindings_path.display(),
        contract_names,
        contracts_build_config.display()
    );
    let parsed_inputs = shlex::split(&command_inputs).expect("Failed to parse command string");
    let bind_cmd: BindArgs =
        BindArgs::try_parse_from(parsed_inputs).expect("Failed to parse command arguments");
    bind_cmd.run().expect("Failed to execute bind command");
}
