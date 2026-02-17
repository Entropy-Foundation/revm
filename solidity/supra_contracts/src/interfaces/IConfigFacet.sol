// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Config} from "../libraries/LibAppStorage.sol";

interface IConfigFacet {
    // Custom errors
    error AddressAlreadyExists();
    error AddressCannotBeZero();
    error AddressDoesNotExist();
    error AlreadyDisabled();
    error AlreadyEnabled();
    error InvalidAmount();
    error InsufficientBalance();
    error RequestExceedsLockedBalance();
    error TransferFailed();
    error UnacceptableRegistryMaxGasCap();    
    error UnacceptableSysRegistryMaxGasCap();

    // View functions
    function erc20Supra() external view returns (address);
    function getConfig() external view returns (Config memory);
    function getConfigBuffer() external view returns (Config memory);
    function getVmSigner() external view returns (address);
    function isRegistrationEnabled() external view returns (bool);
}
