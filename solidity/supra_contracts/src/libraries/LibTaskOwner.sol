// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {AUTOMATION_TASK_OWNER_INTERFACE_ID} from "../interfaces/IAutomationTaskOwner.sol";
import {IRegistryFacet} from "../interfaces/IRegistryFacet.sol";

/// @notice The rule for which accounts may own automation tasks (#4469), in one place for every
/// site that applies it: the registry when a task is registered (`LibRegistry`), the registry
/// owner's `grantAuthorization` (`ConfigFacet`), and the governance driver's pre-submission check
/// (`script/GovActions.s.sol`). All functions are internal, so each site compiles its own copy of
/// the same code and none of them depends on another contract at run time.
library LibTaskOwner {
    /// @notice Length of an EIP-7702 delegation designation, `0xef0100 || address`.
    uint256 internal constant DELEGATION_DESIGNATION_LENGTH = 23;

    /// @notice Whether `_account` may own automation tasks: it has no code, its code is an EIP-7702
    /// delegation designation, or it declares `IAutomationTaskOwner` through ERC-165. A contract
    /// calling from its constructor has no code yet and is accepted.
    function isAccepted(address _account) internal view returns (bool) {
        // EXTCODESIZE first: the code is copied only when its size is that of a designation.
        uint256 size = _account.code.length;
        if (size == 0 || (size == DELEGATION_DESIGNATION_LENGTH && isDelegationDesignation(_account.code))) {
            return true;
        }
        return ERC165Checker.supportsInterface(_account, AUTOMATION_TASK_OWNER_INTERFACE_ID);
    }

    /// @notice Reverts with `UnsupportedTaskOwner(_account)` unless `isAccepted(_account)`.
    function requireAccepted(address _account) internal view {
        if (!isAccepted(_account)) revert IRegistryFacet.UnsupportedTaskOwner(_account);
    }

    /// @notice Whether `_code` is an EIP-7702 delegation designation, `0xef0100 || address`.
    function isDelegationDesignation(bytes memory _code) internal pure returns (bool) {
        return _code.length == DELEGATION_DESIGNATION_LENGTH && _code[0] == 0xef && _code[1] == 0x01 && _code[2] == 0x00;
    }
}
