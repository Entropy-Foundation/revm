// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {ERC20SupraHandler} from "../src/ERC20SupraHandler.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {Deployment, InitParams, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";

abstract contract BaseDiamondTest is Test {
    ERC20Supra erc20Supra;                      // ERC20Supra contract
    ERC20SupraHandler erc20SupraHandler;        // ERC20SupraHandler contract
    address diamondAddr;                        // Diamond address

    InitParams defaultParams;                   // Default initialization parameters
    Deployment deployment;                      // Struct containing deployed contract addresses

    /// @dev Address of the transaction hash precompile.
    address constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;

    address admin = address(0xA11CE);
    address alice = address(0x123);
    address bob = address(0x456);
    address bridge = address(0x789);
    address erc20SupraHandlerAddr;

    /// @dev Sets up initial state for testing.
    /// @dev Sets balance of 'alice' to 100 ether.
    /// @dev Deploys all the contracts and initializes the Diamond with required parameters. 
    function setUp() public {
        vm.deal(alice, 100 ether);

        erc20SupraHandlerAddr = vm.computeCreateAddress(admin, 3);
        erc20Supra = ERC20Supra(deployErc20Supra(bridge, erc20SupraHandlerAddr));

        vm.startPrank(admin);
        ERC20SupraHandler impl = new ERC20SupraHandler();
        bytes memory initData = abi.encodeCall(ERC20SupraHandler.initialize, (admin, address(erc20Supra)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        erc20SupraHandler = ERC20SupraHandler(payable(address(proxy)));
        
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

    /// @dev Helper function to deploy ERC20Supra contract.
    function deployErc20Supra(address _bridge, address _erc20SupraHandlerAddr) internal returns (address) {
        vm.startPrank(admin);
        ERC20Supra impl = new ERC20Supra();
        
        address[] memory authorizedAddresses = new address[](2);
        authorizedAddresses[0] = _bridge;
        authorizedAddresses[1] = _erc20SupraHandlerAddr;
        
        bytes memory initData = abi.encodeCall(ERC20Supra.initialize, (admin, authorizedAddresses));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vm.stopPrank();

        return address(proxy);
    }

    /// @dev Helper function to register a UST.
    function registerUst() internal {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(erc20SupraHandler), abi.encodeCall(ERC20SupraHandler.withdraw, 100)); 
        bytes memory predicate = createPredicate(diamondAddr);
        
        vm.startPrank(alice);
        erc20SupraHandler.deposit{value: 100 ether}();
        erc20Supra.approve(diamondAddr, type(uint256).max);

        IRegistryFacet(diamondAddr).register(
            payload,
            predicate,
            uint64(block.timestamp + 1250),
            uint128(100_000),
            uint128(4 gwei),
            uint128(60.1 ether),
            2,
            auxData
        );
        vm.stopPrank();
    }
    
    /// @dev Helper function to return payload.
    /// @param _value Value to be sent along with the transaction.
    /// @param _target Address of the destination smart contract.
    /// @param _callData Calldata to be sent along with the transaction.
    function createPayload(uint128 _value, address _target, bytes memory _callData) internal pure returns (bytes memory) {
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

        bytes memory payload = abi.encode(_value, _target, _callData, accessList);

        return payload;   
    }

    /// @notice Helper function to create a predicate
    /// @param _target Address of the contract to call
    function createPredicate(address _target) internal pure returns (bytes memory) {
        // Creates a predicate that checks if registration is enabled
        bytes memory callData = abi.encodeCall(IConfigFacet.isRegistrationEnabled, ());
        return abi.encode(_target, callData);
    }
}
