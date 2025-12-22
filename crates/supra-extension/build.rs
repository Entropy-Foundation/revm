use std::process::Command;
use std::env;
use std::path::PathBuf;

fn main() {
    // 1. Tell Cargo to rerun the script if the contracts directory changes
    // println!("cargo:rerun-if-changed=solidity/supra_contracts/");

    // Determine the output directory for the generated bindings
    let cargo_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("OUT_DIR environment variable not set"));

    let contracts_relative_path = PathBuf::from("../../solidity/supra_contracts");
    let contracts_build_config = cargo_dir.join(contracts_relative_path.join(PathBuf::from("foundry.toml")));
    let contract_names = "SupraContracts";

    let bindings_path = cargo_dir
        .join(PathBuf::from("src"))
        .join(PathBuf::from("supra_contract_bindings"));

    // Ensure the output directory exists
    std::fs::create_dir_all(bindings_path.as_path()).expect("Failed to create bindings directory");

    // 2. Build the contracts using forge build
    // This step ensures the contract artifacts are up-to-date
    let build_output = Command::new("forge")
        .arg("build")
        .arg("--config-path")
        .arg(contracts_build_config.display().to_string())
        .status()
        .expect("Failed to execute forge build. Is foundry installed and in PATH?");

    if !build_output.success() {
        panic!("forge build failed: {:?}", build_output);
    }

    // 3. Generate the bindings using forge bind
    let bind_output = Command::new("forge")
        .arg("bind")
        .arg("--bindings-path")
        .arg(&bindings_path)
        .arg("--module") // Generate as a module (lib.rs file inside the path)
        .arg("--overwrite") // Overwrite existing files
        .arg("--select")
        .arg(contract_names)
        .arg("--alloy")
        .status()
        .expect("Failed to execute forge bind. Is foundry installed and in PATH?");

    if !bind_output.success() {
        panic!("forge bind failed");
    }
}
