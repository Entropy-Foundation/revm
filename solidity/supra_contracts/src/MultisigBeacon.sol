// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title MultisigBeacon
 * @dev A beacon that stores the implementation address for multisig proxies.
 *      Admin can upgrade the implementation to a new version.
 *
 *      Uses two-step ownership transfer (Ownable2Step): transferOwnership only designates a
 *      pending owner, who must separately call acceptOwnership to complete the transfer, so the
 *      current owner keeps control of the beacon until that happens. renounceOwnership is
 *      disabled entirely, since giving up ownership here would leave upgradeTo permanently
 *      unreachable.
 */
contract MultisigBeacon is UpgradeableBeacon, Ownable2Step {
    /// @notice Thrown by renounceOwnership, which is always disabled on this contract.
    error OwnershipRenunciationDisabled();

    /**
     * @dev Constructor to initialize the addresses for implementation and initial owner.
     * @param _implementation Address of the initial multisig implementation contract.
     * @param _owner Address of the Beacon owner.
     */
    constructor(address _implementation, address _owner) UpgradeableBeacon(_implementation, _owner) {}

    /// @dev Resolves the Ownable/Ownable2Step diamond by forwarding to the two-step implementation.
    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) {
        Ownable2Step.transferOwnership(newOwner);
    }

    /// @dev Resolves the Ownable/Ownable2Step diamond by forwarding to the two-step implementation.
    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }

    /// @dev Always reverts - see contract-level NatSpec for why renouncing is disabled.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenunciationDisabled();
    }
}
