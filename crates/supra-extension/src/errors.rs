use std::any::type_name;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum SupraExtensionError {

    #[error("{0}")]
    MissingBuilderValue(String, String),

    #[error("{0}")]
    AlloyDecode(#[from]alloy_sol_types::Error)

}

#[macro_export]
macro_rules! value_or_error {
    ($tpy:ty, $name:literal, $value:expr) => {
        match $value {
            Some(v) => v,
            None => {
                return Err($crate::errors::SupraExtensionError::MissingBuilderValue(std::any::type_name::<$tpy>().to_string(), $name.to_string()));
            }
        }
    };
}