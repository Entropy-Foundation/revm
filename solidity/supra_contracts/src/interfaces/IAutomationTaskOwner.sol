// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC165} from "./IERC165.sol";

// ERC-165 identifier of `IAutomationTaskOwner`: a fixed value rather than
// `type(IAutomationTaskOwner).interfaceId`, which is zero for an interface that declares no
// functions of its own.
bytes4 constant AUTOMATION_TASK_OWNER_INTERFACE_ID = bytes4(keccak256("IAutomationTaskOwner"));

/// @notice Declared by a contract that may own SupraEVM automation tasks (#4469).
/// @dev The AutomationRegistry accepts a caller of `register` or `registerSystemTask` whose code
///      is neither empty nor an EIP-7702 delegation designation only if the caller reports,
///      through ERC-165, that it supports `IERC165` and `AUTOMATION_TASK_OWNER_INTERFACE_ID` and
///      does not support `0xffffffff`. A caller without code, including a contract registering
///      from its constructor, and an EIP-7702 delegated account are accepted without the check.
///      `supportsInterface` must therefore return `true` for `type(IERC165).interfaceId` as well
///      as for `AUTOMATION_TASK_OWNER_INTERFACE_ID`.
///
///      A task runs with its owner as the transaction sender, and the registry calls nothing on
///      the owner after registration. Declaring the interface states that the contract meets
///      these obligations, which the registry cannot check:
///      - Only accounts the contract trusts can make it call `register` or `registerSystemTask`.
///        Every task it registers runs in its name, and passes every check other contracts make
///        on its address, until the task ends.
///      - It has functions, restricted in the same way, that call `cancelTasks` and `stopTasks`
///        (`cancelSystemTasks` and `stopSystemTasks` for system tasks). Only the owner can end a
///        task; otherwise only the registry owner can remove it, through `removeTasks`.
///      - It can withdraw the WSUPRA refunded to it when a task is cancelled, stopped or removed.
///      - For user tasks, it holds WSUPRA and approves the registry for the registration and
///        cycle fees, and holds native SUPRA for each execution's gas and any value the task
///        sends.
///
///      `AutomationTaskOwnerBase` implements `supportsInterface` and the registry calls as
///      internal functions, leaving the access control to the contract that inherits it.
interface IAutomationTaskOwner is IERC165 {}
