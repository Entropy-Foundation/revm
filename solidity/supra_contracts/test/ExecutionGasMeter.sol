// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Measures the execution gas of one call it makes, before refunds.
/// @dev The gas benchmarks (CycleTransitionGas.t.sol, MonitorCycleEndGas.t.sol) etch it at
///      LibUtils.VM_SIGNER and call it as its own isolated transaction
///      (BaseDiamondTest.meteredVmSignerCall), so that the measured call sees the registry state
///      earlier transactions committed, and comes from VM_SIGNER as monitorCycleEnd and
///      processTasks require. A transaction's gas used, which a test sees for an isolated call,
///      has its refunds subtracted, up to a fifth of the gas (EIP-3529), while a gas limit has to
///      cover the gas spent before them; storage clears earn large refunds, so a call measured
///      that way reads up to a fifth low.
contract ExecutionGasMeter {
    /// @return gasUsed Gas the call used, refunds not subtracted.
    function measure(address _target, bytes calldata _data) external returns (uint256 gasUsed) {
        uint256 before = gasleft();
        (bool ok, bytes memory returned) = _target.call(_data);
        gasUsed = before - gasleft();
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returned, 32), mload(returned))
            }
        }
    }
}
