// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";
import {IERC20Supra} from "../src/interfaces/IERC20Supra.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";

contract ERC20SupraTest is Test {
    ERC20Supra token;

    address owner = address(0x123);
    address alice = address(0x456);
    address bob   = address(0x789);
    address bridge = address(0xabc);
    address erc20SupraHandlerAddr;
    address newAuthorized = address(0xdef);

    function setUp() public {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 50 ether);
        vm.deal(owner, 10 ether);

        erc20SupraHandlerAddr = vm.computeCreateAddress(owner, 3);
        address[] memory authorizedAddresses = new address[](2);
        authorizedAddresses[0] = bridge;
        authorizedAddresses[1] = erc20SupraHandlerAddr;

        vm.startPrank(owner);
        ERC20Supra impl = new ERC20Supra();
        bytes memory initData = abi.encodeCall(ERC20Supra.initialize, (owner, authorizedAddresses));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = ERC20Supra(address(proxy));
        vm.stopPrank();
    }

    /// @dev Test to ensure all state variables are initialized correctly.
    function testDeployment() public view {
        assertEq(token.owner(), owner);
        assertEq(token.name(), "ERC20Supra");
        assertEq(token.symbol(), "SUPRA");
        assertEq(token.decimals(), 18);

        assertTrue(token.authorizedAddresses(bridge));
        assertTrue(token.authorizedAddresses(erc20SupraHandlerAddr));
    }

    /// @dev Test to ensure initialization reverts with invalid owner address.
    function testInitializeRevertsWithInvalidOwner() public {
        address[] memory authorizedAddresses = new address[](2);
        authorizedAddresses[0] = bridge;
        authorizedAddresses[1] = erc20SupraHandlerAddr;

        vm.startPrank(owner);
        ERC20Supra impl = new ERC20Supra();
        bytes memory initData = abi.encodeCall(ERC20Supra.initialize, (address(0), authorizedAddresses));
        
        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(impl), initData);
        vm.stopPrank();
    }

    /// @dev Test to ensure initialization reverts with invalid address in array.
    function testInitializeRevertsWithInvalidAddress() public {
        address[] memory authorizedAddresses = new address[](2);
        authorizedAddresses[0] = bridge;
        authorizedAddresses[1] = address(0);  // Invalid address

        vm.startPrank(owner);
        ERC20Supra impl = new ERC20Supra();
        bytes memory initData = abi.encodeCall(ERC20Supra.initialize, (owner, authorizedAddresses));
        
        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);
        new ERC1967Proxy(address(impl), initData);
        vm.stopPrank();
    }


    /// @dev Test to ensure initialization ignores duplicate addresses and succeeds.
    function testInitializeIgnoresDuplicateAddress() public {
        address[] memory authorizedAddresses = new address[](3);
        authorizedAddresses[0] = bridge;
        authorizedAddresses[1] = erc20SupraHandlerAddr;
        authorizedAddresses[2] = bridge;  // Duplicate address

        vm.startPrank(owner);
        ERC20Supra impl = new ERC20Supra();
        bytes memory initData = abi.encodeCall(ERC20Supra.initialize, (owner, authorizedAddresses));
        
        vm.expectEmit(true, false, false, false);
        emit IERC20Supra.InitializedAuthorizedAddresses(authorizedAddresses);

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        ERC20Supra erc20Supra = ERC20Supra(address(proxy));

        vm.stopPrank();

        assertTrue(erc20Supra.authorizedAddresses(bridge));
        assertTrue(erc20Supra.authorizedAddresses(erc20SupraHandlerAddr));
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'mint' :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'mint' works correctly when called by authorized address.
    function testMintByAuthorizedAddress() public {
        vm.prank(bridge);
        token.mint(alice, 100);

        assertEq(token.balanceOf(alice), 100);
    }

    /// @dev Test to ensure 'mint' reverts if called by an unauthorized caller.
    function testMintRevertsIfUnauthorizedCaller() public {
        vm.expectRevert(IERC20Supra.UnauthorizedCaller.selector);

        vm.prank(alice);
        token.mint(alice, 100);
    }

    // ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: Tests related to 'burn' :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    /// @dev Test to ensure 'burn' works correctly when called by authorized address.
    function testBurnByAuthorizedAddress() public {
        vm.prank(bridge);
        token.mint(alice, 100);
        assertEq(token.balanceOf(alice), 100);

        vm.prank(bridge);
        token.burn(alice, 50);

        assertEq(token.balanceOf(alice), 50);
    }

    /// @dev Test to ensure 'burn' reverts if called by an unauthorized caller.
    function testBurnRevertsIfUnauthorizedCaller() public {
        vm.expectRevert(IERC20Supra.UnauthorizedCaller.selector);

        vm.prank(alice);
        token.burn(alice, 10);
    }

    /// @dev Test to ensure adding authorized address works.
    function testAddAuthorizedAddress() public {
        vm.prank(owner);
        token.addAuthorizedAddress(newAuthorized);
        
        assertTrue(token.authorizedAddresses(newAuthorized));
    }

    /// @dev Test to ensure 'AuthorizedAddressAdded' event is emitted correctly.
    function testAddAuthorizedAddressEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IERC20Supra.AuthorizedAddressAdded(newAuthorized, owner);
        
        vm.prank(owner);
        token.addAuthorizedAddress(newAuthorized);
    }

    /// @dev Test to ensure adding authorized address reverts if not owner.
    function testAddAuthorizedAddressRevertsIfNotOwner() public {   
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));

        vm.prank(alice);
        token.addAuthorizedAddress(newAuthorized);
    }

    /// @dev Test to ensure adding invalid address reverts.
    function testAddAuthorizedAddressRevertsIfInvalidAddress() public {
        vm.expectRevert(LibUtils.AddressCannotBeZero.selector);

        vm.prank(owner);
        token.addAuthorizedAddress(address(0));
    }

    /// @dev Test to ensure adding already authorized address reverts.
    function testAddAuthorizedAddressRevertsIfAlreadyAuthorized() public {
        vm.expectRevert(IERC20Supra.AddressAlreadyAuthorized.selector);

        vm.prank(owner);
        token.addAuthorizedAddress(bridge);
    }

    /// @dev Test to ensure removing authorized address works.
    function testRemoveAuthorizedAddress() public {
        vm.prank(owner);

        token.removeAuthorizedAddress(bridge);
        assertFalse(token.authorizedAddresses(bridge));
    }

    /// @dev Test to ensure 'AuthorizedAddressRemoved' event is emitted correctly.
    function testRemoveAuthorizedAddressEmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IERC20Supra.AuthorizedAddressRemoved(bridge, owner);
        
        vm.prank(owner);
        token.removeAuthorizedAddress(bridge);
    }

    /// @dev Test to ensure removing authorized address reverts if not owner.
    function testRemoveAuthorizedAddressRevertsIfNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        
        vm.prank(alice);
        token.removeAuthorizedAddress(bridge);
    }

    /// @dev Test to ensure removing non-authorized address reverts.
    function testRemoveAuthorizedAddressRevertsIfNotAuthorized() public {
        vm.prank(owner);

        vm.expectRevert(IERC20Supra.AddressNotAuthorized.selector);
        token.removeAuthorizedAddress(address(0x123));
    }
}