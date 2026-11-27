// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { IERC173 } from "../interfaces/IERC173.sol";
import { IOwnable2Step } from "../interfaces/IOwnable2Step.sol";
import { IFacetSelectors } from "../interfaces/IFacetSelectors.sol";

/**
 * Ownership of the automation registry Diamond (Entropy-Foundation/smr-moonshot#4975).
 *  - The owner is the only account that can call 'diamondCut', the ConfigFacet setters, fee withdrawal and the
 *    owner-only registry operations, so the Diamond must always have an owner that can act.
 *  - Transfer is two-step, as on BlockMeta and MultisigBeacon: 'transferOwnership' only nominates a pending owner,
 *    who must call 'acceptOwnership' to complete it. The current owner keeps full control until then and can
 *    replace the nomination, or cancel it with 'transferOwnership(address(0))'.
 *  - A nomination does not expire; it is cleared when it is accepted, replaced or cancelled.
 *  - Renouncing is not supported: the owner is never the zero address.
 *  - A diamondCut Remove action naming a selector of this facet or 'diamondCut' reverts
 *    (LibDiamond.removeFunctions). A Replace action for them is accepted; verifying that the new facet
 *    implements them correctly is the owner's responsibility.
 */
contract OwnershipFacet is IERC173, IOwnable2Step, IFacetSelectors {

    /// @inheritdoc IERC173
    /// @dev Owner-only. Records the nominee; ownership itself does not change here.
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setPendingOwner(_newOwner);
    }

    /// @inheritdoc IOwnable2Step
    /// @dev Only the account the owner nominated can call this; that account is non-zero and can
    ///      send transactions, so the new owner can act.
    function acceptOwnership() external override {
        LibDiamond.enforceIsPendingOwner();
        // setContractOwner also clears the pending nomination, so it cannot be accepted twice.
        LibDiamond.setContractOwner(msg.sender);
    }

    /// @inheritdoc IERC173
    function owner() external override view returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }

    /// @inheritdoc IOwnable2Step
    function pendingOwner() external override view returns (address pendingOwner_) {
        pendingOwner_ = LibDiamond.pendingOwner();
    }

    /// @notice Selectors this facet serves through the Diamond.
    /// @dev Must list every external function except getSelectors() itself;
    ///      script/check_facet_selectors.sh cross-checks it against the compiled ABI.
    function getSelectors() external pure override returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = OwnershipFacet.owner.selector;
        s[1] = OwnershipFacet.transferOwnership.selector;
        s[2] = OwnershipFacet.pendingOwner.selector;
        s[3] = OwnershipFacet.acceptOwnership.selector;
    }
}
