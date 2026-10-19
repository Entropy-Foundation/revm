// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC165} from "./IERC165.sol";

// ERC-165 identifier of `IAutomationTaskOwner`: a fixed value rather than
// `type(IAutomationTaskOwner).interfaceId`, which is zero for an interface that declares no
// functions of its own.
bytes4 constant AUTOMATION_TASK_OWNER_INTERFACE_ID = bytes4(keccak256("IAutomationTaskOwner"));

/// @notice Declared by a contract that may own SupraEVM automation tasks (#4469).
/// @dev The AutomationRegistry accepts a contract as the caller of `register` or
///      `registerSystemTask` only if the contract reports, through ERC-165, that it supports
///      `IERC165` and `AUTOMATION_TASK_OWNER_INTERFACE_ID` and does not support `0xffffffff`.
///      A task runs with its owner as the transaction sender, so declaring the interface states
///      that the contract is built to have calls made in its name by the tasks it registers, and
///      to cancel or stop them.
interface IAutomationTaskOwner is IERC165 {}
