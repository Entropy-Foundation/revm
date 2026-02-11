use std::env;
use std::path::PathBuf;


fn main() {
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
