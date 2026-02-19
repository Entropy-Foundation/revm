// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {Deployment, InitParams, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";

abstract contract BaseDiamondTest is Test {
    ERC20Supra erc20Supra;                      // ERC20Supra contract
    address diamondAddr;                        // Diamond address

    InitParams defaultParams;                   // Default initialization parameters
    Deployment deployment;                      // Struct containing deployed contract addresses

    /// @dev Address of the transaction hash precompile.
    address constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;

    address admin = address(0xA11CE);
    address alice = address(0x123);
    address bob = address(0x456);

    /// @dev Sets up initial state for testing.
    /// @dev Sets balance of 'alice' to 100 ether.
    /// @dev Deploys all the contracts and initializes the Diamond with required parameters. 
    function setUp() public {
        vm.deal(alice, 100 ether);

        vm.startPrank(admin);
        erc20Supra = new ERC20Supra(admin);

        defaultParams = LibDiamondUtils.defaultInitParams();
        deployment = LibDiamondUtils.deploy(admin);
        LibDiamondUtils.executeCut(LibUtils.VM_SIGNER, address(erc20Supra), defaultParams, deployment);
        diamondAddr = deployment.diamond;

        IConfigFacet(diamondAddr).grantAuthorization(bob);

        vm.stopPrank();

        vm.mockCall(
            TX_HASH_PRECOMPILE,
            bytes(""),
            abi.encode(keccak256("txHash"))
        );
    }

    /// @dev Helper function to register a UST.
    function registerUST() internal {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20Supra)); 
        
        vm.startPrank(alice);
        erc20Supra.nativeToErc20Supra{value: 5 ether}();
        erc20Supra.approve(diamondAddr, type(uint256).max);

        IRegistryFacet(diamondAddr).register(
            payload,
            uint64(block.timestamp + 2250),
            uint128(1_000_000),
            uint128(10 gwei),
            uint128(0.5 ether),
            2,
            auxData
        );
        vm.stopPrank();
    }
    
    /// @dev Helper function to return payload.
    /// @param _value Value to be sent along with the transaction.
    /// @param _target Address of the destination smart contract.
    function createPayload(uint128 _value, address _target) internal pure returns (bytes memory) {
        LibCommon.AccessListEntry[] memory accessList = new LibCommon.AccessListEntry[](2);
        
        bytes32[] memory keys = new bytes32[](2); 
        keys[0] = bytes32(uint256(0));
        keys[1] = bytes32(uint256(1));

        accessList[0] = LibCommon.AccessListEntry({
            addr: address(0x1111),
            storageKeys: keys
        });

        accessList[1] = LibCommon.AccessListEntry({
            addr: address(0x2222),
            storageKeys: keys
        });

        bytes memory callData = abi.encodeCall(ERC20Supra.erc20SupraToNative, 100);
        bytes memory payload = abi.encode(_value, _target, callData, accessList);

        return payload;   
    }
}
