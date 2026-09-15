// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ISupraBlockTimestamp} from "../interfaces/ISupraBlockTimestamp.sol";

/// @title Convenience helper over {ISupraBlockTimestamp}.
/// @notice Holds the precompile's frozen address so a contract does not have to spell it out, and
/// wraps the single read.
///
/// @dev The helper adds no semantics of its own. The value is the certified block's timestamp in
/// microseconds since the Unix epoch, identical for every transaction in the block, and
/// `microseconds() / 1_000_000` equals `block.timestamp`. No caller rule applies to the read. See
/// {ISupraBlockTimestamp} for the errors it can revert with.
library LibBlockTimestamp {
    /// @notice The block timestamp precompile. Frozen.
    ISupraBlockTimestamp internal constant BLOCK_TIMESTAMP =
        ISupraBlockTimestamp(0x0000000000000000000000000000000053555004);

    /// @notice The block's timestamp in microseconds since the Unix epoch.
    function microseconds() internal view returns (uint64) {
        return BLOCK_TIMESTAMP.microseconds();
    }
}
