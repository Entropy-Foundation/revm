// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ISupraRandomness} from "../interfaces/ISupraRandomness.sol";

/// @title Convenience helpers over {ISupraRandomness}.
/// @notice Mirrors the helpers `supra_framework::randomness` offers on the Move side, so a
/// contract does not have to reduce raw bytes to a range by hand.
///
/// @dev **These helpers carry no safety semantics.** Every guarantee comes from the precompile's
/// own rules, and every requirement it places on a consumer applies unchanged to code that goes
/// through this library. The two requirements the VM cannot enforce, repeated from
/// {ISupraRandomness-next}:
///
/// > After reading randomness, no external call you make may be able to revert your frame. Either
/// > catch the failure of every such call, or finalise the outcome in a different transaction from
/// > the one that makes the call. A callee controlled by the transaction sender can otherwise
/// > revert the transaction after observing the outcome. Persisting the outcome to storage first
/// > does not help: a revert unwinds the frame, storage writes included.
///
/// > After a read, the gas you spend must not depend on the value in a way that makes an outcome
/// > the sender would reject the more expensive one. The sender chooses the transaction's gas
/// > limit, and running out of gas unwinds the frame just as a revert does, so a limit set to the
/// > cheap branch's cost completes only the outcomes that fit it. This needs no external call, so
/// > a contract that never calls out is exposed too.
///
/// Recording the outcome and settling in a later transaction satisfies both.
///
/// A transaction that reads and then fails is charged its whole gas limit, except an automation
/// task's predicate, which is executed free of charge. See {ISupraRandomness-next} for what
/// protects a predicate's action instead.
///
/// {seedAt} carries a different obligation, which applies to every kind of transaction: the value
/// is public, so anyone can compute what your contract will derive from it. A design that settles
/// against a seed must commit before that seed exists, and must not let the party an outcome is
/// bad for decide whether the settlement happens. See {ISupraRandomness-seedAt}.
library LibRandomness {
    /// @notice The randomness precompile. Frozen.
    ISupraRandomness internal constant RANDOMNESS = ISupraRandomness(0x0000000000000000000000000000000053555003);

    /// @notice How many blocks back {seedAt} will serve. Matches `BLOCKHASH`'s window.
    uint64 internal constant SEED_WINDOW = 256;

    /// @notice Thrown when the range passed to a `*Range` helper is empty or inverted.
    error EmptyRange(uint256 minIncl, uint256 maxExcl);

    /// @notice 32 fresh random bytes.
    function value() internal returns (bytes32) {
        return RANDOMNESS.next();
    }

    /// @notice A fresh `uint256`.
    function u256() internal returns (uint256) {
        return uint256(RANDOMNESS.next());
    }

    /// @notice A fresh `uint64`.
    function u64() internal returns (uint64) {
        return uint64(uint256(RANDOMNESS.next()));
    }

    /// @notice `n` fresh random bytes.
    /// @dev One read per 32 bytes, and each read costs gas, so this is linear in `n`.
    function bytesN(uint256 n) internal returns (bytes memory out) {
        out = new bytes(n);
        uint256 written = 0;
        while (written < n) {
            bytes32 word = RANDOMNESS.next();
            uint256 chunk = n - written < 32 ? n - written : 32;
            for (uint256 i = 0; i < chunk; i++) {
                out[written + i] = word[i];
            }
            written += chunk;
        }
    }

    /// @notice A number in `[minIncl, maxExcl)`.
    ///
    /// @dev The distribution is not perfectly uniform: it is a modular reduction of a 256-bit
    /// sample, so the bias is negligible for any range a contract would use. If you need exact
    /// uniformity, sample {u256} and reject. This matches what `randomness.move`'s `u64_range` and
    /// `u256_range` do, so a contract ported between the two VMs behaves the same way.
    function u256Range(uint256 minIncl, uint256 maxExcl) internal returns (uint256) {
        if (maxExcl <= minIncl) revert EmptyRange(minIncl, maxExcl);
        uint256 range = maxExcl - minIncl;
        return minIncl + (u256() % range);
    }

    /// @notice A number in `[minIncl, maxExcl)`. See {u256Range} on uniformity.
    function u64Range(uint64 minIncl, uint64 maxExcl) internal returns (uint64) {
        return uint64(u256Range(minIncl, maxExcl));
    }

    /// @notice A uniformly random permutation of `[0, 1, ..., n - 1]`, or an empty array for
    /// `n == 0`.
    ///
    /// @dev A Fisher-Yates shuffle, as `randomness.move`'s `permutation` is. It makes `n - 1`
    /// reads, each of which costs gas, so `n` should be small and bounded by the caller.
    function permutation(uint64 n) internal returns (uint64[] memory values) {
        values = new uint64[](n);
        if (n == 0) return values;
        for (uint64 i = 0; i < n; i++) {
            values[i] = i;
        }
        // Walk down, swapping each position with a uniformly chosen one at or below it.
        for (uint64 i = n - 1; i > 0; i--) {
            uint64 j = u64Range(0, i + 1);
            (values[i], values[j]) = (values[j], values[i]);
        }
    }

    /// @notice The seed of the committed block at `height`.
    /// @dev Reverts unless `height` is in `[block.number - 256, block.number - 1]`; the block being
    /// executed is not served. Use {value} for the current block's randomness.
    function seedAt(uint64 height) internal view returns (bytes32) {
        return RANDOMNESS.seedAt(height);
    }

    /// @notice Whether `height` is one {seedAt} will serve, so a caller can check before spending
    /// gas on a revert.
    function isServable(uint64 height) internal view returns (bool) {
        if (block.number == 0) return false;
        uint64 newest = uint64(block.number) - 1;
        uint64 oldest = block.number > SEED_WINDOW ? uint64(block.number) - SEED_WINDOW : 0;
        return height <= newest && height >= oldest;
    }
}
