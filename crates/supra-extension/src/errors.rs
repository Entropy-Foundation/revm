//! Errors reported in scope of supra-extension module.

use thiserror::Error;

/// Supra-extension error.
#[derive(Error, Debug)]
pub enum SupraExtensionError {
    /// Reported when transaction builder misses mandatory value to build final transaction.
    #[error("Missing mandatory value: {0}::{1}")]
    MissingBuilderValue(String, String),

    /// Reported on failure of automation task inner payload decode.
    #[error("Failed to decode payload: {0}")]
    PayloadDecode(#[from] alloy_sol_types::Error),

    /// Reported on failure of task state conversion to counterpart in native layer.
    #[error("Invalid automation task state value: {0}, expected [0(PENDING), 1(ACTIVE), 2(CANCELLED)]")]
    InvalidAutomationTaskStateValue(u8),

    /// Reported on failure of task state conversion to counterpart in native layer.
    #[error("Invalid automation task type value: {0}, expected [0(UST), 1(GST)]")]
    InvalidAutomationTaskTypeValue(u8),

    /// Reported when automated transaction builder is attempted to be built for inactive task.
    #[error("Attempt to create automated transaction builder for non-active task")]
    InvalidAutomationTaskStateForBuilder,
    /// Reported when automated transaction builder is attempted to be built for inactive task.
    #[error("AutomationRecordBuilder.RemoveTasks: Task indexes count mismatches with reasons.")]
    InvalidAutomationRecordBuilderForTaskRemoval,
}

/// Extracts value of the optional value or reports [`SupraExtensionError::MissingBuilderValue`].
#[macro_export]
macro_rules! value_or_error {
    ($tpy:ty, $name:literal, $value:expr) => {
        match $value {
            Some(v) => v,
            None => {
                return Err($crate::errors::SupraExtensionError::MissingBuilderValue(
                    std::any::type_name::<$tpy>().to_string(),
                    $name.to_string(),
                ));
            }
        }
    };
}
