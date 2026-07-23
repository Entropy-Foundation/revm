// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// Helper library used by Supra contracts
library LibUtils {

    // Custom errors
    error AddressCannotBeEOA();
    error AddressCannotBeZero();
    error CallerNotVmSigner();
    
    // Address of the VM Signer: SUP0
    address constant VM_SIGNER = address(0x53555000);
    
    /// @dev Returns a boolean indicating whether the given address is a contract or not.
    /// @param _addr The address to be checked.
    /// @return A boolean indicating whether the given address is a contract or not.
    function isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    /// @notice Validates a contract address.
    function validateContractAddress(address _contractAddr) internal view {
        if (_contractAddr == address(0)) { revert AddressCannotBeZero(); }
        if (!isContract(_contractAddr)) { revert AddressCannotBeEOA(); }
    }

    /// @notice Validates an address.
    function validateAddress(address _addr) internal pure {
        if (_addr == address(0)) { revert AddressCannotBeZero(); }
    }

    /// @notice Checks if an address is VM Signer, reverts if it is not.
    /// @param _addr Address to check.
    function enforceIsVmSigner(address _addr) internal pure {
        if (_addr != VM_SIGNER) revert CallerNotVmSigner();
    }

    /// @notice Checks if an address is a reserved address. 
    /// @param _addr Address to check.
    /// @return bool If it is a reserved address.
    function isReservedAddress(address _addr) internal pure returns (bool) {
        uint160 addr = uint160(_addr);
        return addr >= uint160(VM_SIGNER) && addr <= uint160(0x535550FF);
    }

    /// @notice Converts a uint256 storage array to a uint64 memory array.
    /// @param arr The storage array to convert.
    /// @return result The values as a uint64 array.
    function uint256ArrayToUint64Array(uint256[] storage arr) internal view returns (uint64[] memory result) {
        uint256 length = arr.length;
        result = new uint64[](length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = uint64(arr[i]);
        }
    }
}
