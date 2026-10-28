// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {Deployment, InitParams, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {LibUtils} from "../src/libraries/LibUtils.sol";
import {EvmGasConfigMock} from "./EvmGasConfigMock.sol";
import {RecordSizingParameters} from "../src/libraries/LibAppStorage.sol";

abstract contract BaseDiamondTest is Test {
    WrappedSupra wsupra;                             // WrappedSupra contract
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
        vm.deal(alice, 500 ether);

        vm.startPrank(admin);
        wsupra = new WrappedSupra();

        defaultParams = LibDiamondUtils.defaultInitParams();
        deployment = LibDiamondUtils.deploy(admin, address(wsupra), defaultParams);
        diamondAddr = deployment.diamond;

        IConfigFacet(diamondAddr).grantAuthorization(bob);

        vm.stopPrank();

        vm.mockCall(
            TX_HASH_PRECOMPILE,
            bytes(""),
            abi.encode(keccak256("txHash"))
        );

        // Registration reads the chain's per-transaction gas cap and minimum gas price from the
        // EVM gas config precompile, which Forge's EVM does not have.
        EvmGasConfigMock.mockDefaults(vm);
    }

    /// @dev Helper function to register a UST.
    /// @param _diamond The address of the diamond.
    /// @param _duration The duration of the UST.
    function registerUst(address _diamond, uint64 _duration) internal {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100));
        bytes memory predicate = createPredicate(_diamond);

        vm.startPrank(alice);
        wsupra.deposit{value: 100 ether}();
        wsupra.approve(_diamond, type(uint256).max);

        IRegistryFacet(_diamond).register(
            payload,                                // payload
            predicate,                              // predicate
            uint64(block.timestamp + _duration),    // expiryTime
            uint128(100_000),                       // maxGasAmount
            uint128(4 gwei),                        // gasPriceCap
            uint128(60.1 ether),                    // automationFeeCapForCycle
            2,                                      // priority
            auxData                                 // aux data
        );
        vm.stopPrank();
    }

    /// @dev Helper function to register a GST.
    /// @param _diamond The address of the diamond.
    /// @param _duration The duration of the GST.
    function registerGst(address _diamond, uint64 _duration) internal {
        bytes[] memory auxData;
        bytes memory payload = createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100));
        bytes memory predicate = createPredicate(_diamond);

        vm.prank(bob);
        IRegistryFacet(_diamond).registerSystemTask(
            payload,                                // payload
            predicate,                              // predicate
            uint64(block.timestamp + _duration),    // expiryTime
            uint128(100_000),                       // maxGasAmount
            2,                                      // priority
            auxData                                 // aux data
        );
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

    /// @dev A payload of exactly `_totalLength` bytes, filled with non-zero bytes so every slot
    ///      it occupies in storage is non-zero (a zero-filled one would store and clear almost
    ///      for free). Registration only decodes the payload and length-checks its call data.
    ///      With an empty access list abi.encode(uint128, address, bytes, AccessListEntry[]) is
    ///      192 bytes plus the call data padded to 32; RegistrationGas.t.sol builds its cap-size
    ///      payloads the same way. Shared by CycleTransitionGas.t.sol and RecordSizing.t.sol.
    function payloadOfExactLength(uint256 _totalLength) internal view returns (bytes memory) {
        require(_totalLength % 32 == 0 && _totalLength > 192 + 32, "payload length");
        LibCommon.AccessListEntry[] memory emptyAccessList;
        bytes memory callData = abi.encodePacked(wsupra.withdraw.selector, nonZeroBytes(_totalLength - 192 - 4));
        return abi.encode(uint128(0), address(wsupra), callData, emptyAccessList);
    }

    /// @dev A predicate of exactly `_totalLength` bytes. Registration executes the predicate
    ///      with a staticcall, so its call data stays a valid call: isRegistrationEnabled()
    ///      takes no arguments and ignores the trailing bytes. abi.encode(address, bytes) is
    ///      96 bytes plus the call data padded to 32.
    function predicateOfExactLength(address _diamond, uint256 _totalLength) internal pure returns (bytes memory) {
        require(_totalLength % 32 == 0 && _totalLength > 96 + 32, "predicate length");
        bytes memory callData = abi.encodePacked(
            IConfigFacet.isRegistrationEnabled.selector, nonZeroBytes(_totalLength - 96 - 4)
        );
        return abi.encode(_diamond, callData);
    }

    /// @dev Returns `_length` bytes of 0xab.
    function nonZeroBytes(uint256 _length) internal pure returns (bytes memory out) {
        out = new bytes(_length);
        for (uint256 i = 0; i < _length; i++) {
            out[i] = 0xab;
        }
    }

    /// @notice Helper function to create a predicate
    /// @param _target Address of the contract to call
    function createPredicate(address _target) internal pure returns (bytes memory) {
        // Creates a predicate that checks if registration is enabled
        bytes memory callData = abi.encodeCall(IConfigFacet.isRegistrationEnabled, ());
        return abi.encode(_target, callData);
    }

    /// @dev Helper to warp past the current cycle, end it, and process the given tasks.
    function processCycleTransition(address _diamond, uint64[] memory _taskIndexes) internal {
        (uint64 indexBefore, uint64 startTimeBefore, uint64 durationBefore, ) = ICoreFacet(_diamond).getCycleInfo();
        vm.warp(startTimeBefore + durationBefore);

        vm.startPrank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(_diamond).monitorCycleEnd();

        (uint64 indexAfter, , , LibCommon.CycleState stateAfter) = ICoreFacet(_diamond).getCycleInfo();
        assertEq(indexAfter, indexBefore);
        assertEq(uint8(stateAfter), uint8(LibCommon.CycleState.FINISHED));

        vm.expectEmit(_diamond);
        emit ICoreFacet.ActiveTasks(indexBefore + 1, _taskIndexes);

        ICoreFacet(_diamond).processTasks(indexBefore + 1, _taskIndexes);
        vm.stopPrank();
    }

    /// @dev Buffers `_diamond`'s record sizing `maxCapacity` raised to `_maxCapacity` as the owner,
    ///      keeping the task-support percentage in force. updateConfigBuffer refuses a capacity
    ///      above the `maxCapacity` in force after the next cycle boundary
    ///      (Entropy-Foundation/smr-moonshot#4755); tests that buffer a larger capacity for reasons
    ///      unrelated to record sizing declare it first, as an operator would after re-running the
    ///      benchmark at that size. Both buffers apply at the same boundary.
    function raiseRecordMaxCapacity(address _diamond, uint32 _maxCapacity) internal {
        RecordSizingParameters memory parameters = IConfigFacet(_diamond).getRecordSizingParameters();
        parameters.maxCapacity = _maxCapacity;
        vm.prank(admin);
        IConfigFacet(_diamond).updateRecordSizingParameters(parameters);
    }

    /// @dev Warps to the end of `_diamond`'s current cycle and calls monitorCycleEnd as the VM
    /// signer, which moves a STARTED registry to FINISHED. Returns the index of the cycle that
    /// ended; processTasks for the transition takes `index + 1`.
    function endCycleAsVmSigner(address _diamond) internal returns (uint64 index) {
        uint64 startTime;
        uint64 duration;
        (index, startTime, duration, ) = ICoreFacet(_diamond).getCycleInfo();
        vm.warp(startTime + duration);
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(_diamond).monitorCycleEnd();
    }

    /// @dev Calls processTasks on `_diamond` as the VM signer and returns only the logs that call
    /// emitted, the way an indexer reads one transaction's receipt.
    function processTasksRecordingLogs(address _diamond, uint64 _cycleIndex, uint64[] memory _taskIndexes)
        internal
        returns (Vm.Log[] memory logs)
    {
        vm.recordLogs();
        vm.prank(LibUtils.VM_SIGNER, LibUtils.VM_SIGNER);
        ICoreFacet(_diamond).processTasks(_cycleIndex, _taskIndexes);
        logs = vm.getRecordedLogs();
    }

    /// @dev Asserts that two uint64 arrays have the same length and elements, in order. forge-std's
    /// assertEq has array overloads for uint256[] but not for uint64[], the type of the registry's
    /// task-id lists. The message names the first differing position.
    function assertEqUint64Array(uint64[] memory _left, uint64[] memory _right, string memory _err) internal pure {
        assertEq(_left.length, _right.length, string.concat(_err, ": length"));
        for (uint256 i; i < _left.length; i++) {
            assertEq(_left[i], _right[i], string.concat(_err, ": element ", vm.toString(i)));
        }
    }

    /// @dev Returns the one log `_emitter` emitted with `_topic0`, and fails unless there is
    /// exactly one. Tests use it to read a log the way an indexer reads `eth_getLogs` output:
    /// select by emitter and topic0, then decode `data` with the event's ABI.
    function findLog(Vm.Log[] memory _logs, address _emitter, bytes32 _topic0)
        internal
        pure
        returns (Vm.Log memory found)
    {
        uint256 matches;
        for (uint256 i; i < _logs.length; i++) {
            // A log with no topics is anonymous and cannot carry the event's topic0.
            if (_logs[i].emitter != _emitter || _logs[i].topics.length == 0 || _logs[i].topics[0] != _topic0) {
                continue;
            }
            found = _logs[i];
            matches++;
        }
        // Zero matches means the event was not emitted; more than one means the caller's
        // selection is ambiguous. Both make a decode assertion meaningless, so fail here.
        require(matches == 1, "findLog: expected exactly one matching log");
    }

    /// @dev Helper function to deploy a custom AutomationRegistry with:
    /// - taskCapacity and sysTaskCapacity set to 2
    /// - automation and congestion base fees set to 0
    function deployCustomRegistry() internal returns (address) {
        InitParams memory initParams = InitParams({
            taskDurationCapSecs: 3600 * 24 * 7,
            registryMaxGasCap: 20_000_000,
            automationBaseFeeWeiPerSec: 0,
            flatRegistrationFeeWei: 1 ether,
            congestionThresholdPercentage: 50,
            congestionBaseFeeWeiPerSec: 0,
            congestionExponent: 6,
            maxCongestionExponent: 6,
            taskCapacity: 2,
            cycleDurationSecs: 1200,
            sysTaskDurationCapSecs: 3600 * 24 * 180,
            sysRegistryMaxGasCap: 20_000_000,
            sysTaskCapacity: 2,
            registrationEnabled: true,
            automationEnabled: true
        });
        
        vm.startPrank(admin);
        Deployment memory customDeployment = LibDiamondUtils.deploy(admin, address(wsupra), initParams);
        address diamond = customDeployment.diamond;
        IConfigFacet(diamond).grantAuthorization(bob);
        vm.stopPrank();

        return diamond;
    }
}

/// @dev Mock ERC20 that returns `false` on transfer/transferFrom to test TransferFailed revert paths.
contract FailingERC20 {
    function balanceOf(address) external pure returns (uint256) { return 100 ether; }
    function transfer(address, uint256) external pure returns (bool) { return false; }
    function transferFrom(address, address, uint256) external pure returns (bool) { return false; }
}
