// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MultisigBeacon
 * @dev A beacon that stores the implementation address for multisig proxies.
 *      Admin can upgrade the implementation to a new version.
 *
 *      Uses two-step ownership transfer (Ownable2Step): transferOwnership only designates a
 *      pending owner, who must separately call acceptOwnership to complete the transfer, so the
 *      current owner keeps control of the beacon until that happens.
 */
contract MultisigBeacon is IBeacon, Ownable2Step {
    address private _implementation;

    /**
     * @dev The `implementation` of the beacon is invalid.
     */
    error BeaconInvalidImplementation(address implementation);

    /**
     * @dev Emitted when the implementation returned by the beacon is changed.
     */
    event Upgraded(address indexed implementation);

    /**
     * @dev Constructor to initialize the addresses for implementation and initial owner.
     * @param _implementationAddress Address of the initial multisig implementation contract.
     * @param _owner Address of the Beacon owner.
     */
    constructor(address _implementationAddress, address _owner) Ownable(_owner) {
        _setImplementation(_implementationAddress);
    }

    /**
     * @dev Returns the current implementation address.
     */
    function implementation() public view virtual returns (address) {
        return _implementation;
    }

    /**
     * @dev Upgrades the beacon to a new implementation.
     *
     * Emits an {Upgraded} event.
     *
     * Requirements:
     *
     * - msg.sender must be the owner of the contract.
     * - `newImplementation` must be a contract.
     */
    function upgradeTo(address newImplementation) public virtual onlyOwner {
        _setImplementation(newImplementation);
    }

    /**
     * @dev Sets the implementation contract address for this beacon
     *
     * Requirements:
     *
     * - `newImplementation` must be a contract.
     */
    function _setImplementation(address newImplementation) private {
        if (newImplementation.code.length == 0) {
            revert BeaconInvalidImplementation(newImplementation);
        }
        _implementation = newImplementation;
        emit Upgraded(newImplementation);
    }
}
