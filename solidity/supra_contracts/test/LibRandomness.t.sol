// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ISupraRandomness} from "../src/interfaces/ISupraRandomness.sol";
import {LibRandomness} from "../src/libraries/LibRandomness.sol";

/// Stands in for the randomness precompile, which Forge's EVM does not have.
contract MockRandomness {
    function next() external pure returns (bytes32) {
        return bytes32(uint256(7));
    }
}

contract GuardedReader {
    function read(uint256 minGasAfterRead) external returns (bytes32) {
        return LibRandomness.valueWithGasLeft(minGasAfterRead);
    }
}

contract LibRandomnessTest is Test {
    GuardedReader internal reader;

    function setUp() public {
        vm.etch(address(LibRandomness.RANDOMNESS), address(new MockRandomness()).code);
        reader = new GuardedReader();
    }

    function test_valueWithGasLeft_reads_when_enough_gas_remains() public {
        vm.expectCall(address(LibRandomness.RANDOMNESS), abi.encodeCall(ISupraRandomness.next, ()), 1);
        assertEq(reader.read(50_000), bytes32(uint256(7)));
    }

    function test_valueWithGasLeft_reverts_without_reading_when_gas_is_short() public {
        vm.expectCall(address(LibRandomness.RANDOMNESS), abi.encodeCall(ISupraRandomness.next, ()), 0);
        try reader.read{gas: 100_000}(1_000_000) {
            fail();
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), LibRandomness.InsufficientGasForRead.selector);
        }
    }
}
