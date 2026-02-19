// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;


contract TxHashPrecompile {
    fallback(bytes calldata input) external returns (bytes memory) {
        bytes32 output = keccak256("txn_hash");
        return abi.encode( output);
    }
}
