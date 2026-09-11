// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Minimal target used to exercise the different shapes of revert data that
///      'executeTransaction' must forward byte-for-byte through 'ExecutionFailed'.
contract RevertingTarget {
    error BigError(bytes blob, uint256 tag);

    function revertWithString(string calldata reason) external pure {
        revert(reason);
    }

    function revertWithDynamicError(bytes calldata blob, uint256 tag) external pure {
        revert BigError(blob, tag);
    }

    function revertWithNoData() external pure {
        assembly ("memory-safe") {
            revert(0, 0)
        }
    }
}

/// @dev Minimal contract whose constructor always reverts with a known custom error, used to
///      exercise 'deployContract' forwarding the constructor's failure data through
///      'ContractCreationFailed'.
contract RevertingConstructor {
    error ConstructorBlew(uint256 code);

    constructor(uint256 code) {
        revert ConstructorBlew(code);
    }
}
