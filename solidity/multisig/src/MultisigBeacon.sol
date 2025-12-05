// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {UpgradeableBeacon} from "../lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";

/**
 * @title MultisigBeacon
 * @dev A beacon that stores the implementation address for multisig proxies.
 *      Admin can upgrade the implementation to a new version.
 */
contract MultisigBeacon is UpgradeableBeacon {
    /**
     * @dev Constructor to initialize the addresses for implementation and initial owner.
     * @param _implementation Address of the initial multisig implementation contract.
     */
    constructor(address _implementation) UpgradeableBeacon(_implementation, msg.sender) {}
}
