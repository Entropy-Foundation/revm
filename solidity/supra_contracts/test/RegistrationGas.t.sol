// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {BaseDiamondTest} from "./BaseDiamondTest.t.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {LibCommon} from "../src/libraries/LibCommon.sol";
import {WrappedSupra} from "../src/WrappedSupra.sol";

/// @notice Gas benchmark for registering a single automation task, as a user task through
///         `register` and as a system task through `registerSystemTask`.
///
///         Each scenario registers one task of a given payload/predicate size into a fresh
///         registry (the first task, which also initialises the registry's and the owner's
///         bookkeeping) and then a second task of the same size (the steady state). The size
///         sweep runs from the fixture task used throughout the test suite up to the
///         DataLengthCaps configured by DiamondInit (payload 4096 bytes, predicate 2048 bytes,
///         no auxData); the cap row reads the caps from the registry, so it follows any change
///         to the defaults.
///
///         How the figures are produced:
///         - Before every measured call the Diamond, each facet and WrappedSupra are marked cold
///           (`vm.cool`), so storage and account access is charged as in a transaction that
///           touches the registry for the first time. Without it Foundry keeps the access list
///           of earlier calls in the same test, which undercounts every SLOAD and SSTORE.
///         - `execution` is the measured call frame (`vm.lastCallGas`).
///         - `tx total` adds what a transaction pays around that frame under the Prague rules
///           that foundry.toml selects: 21000 intrinsic gas, 4 gas per calldata token
///           (zero byte = 1 token, non-zero byte = 4 tokens), the refund capped at a fifth of
///           the gas used (EIP-3529), and the EIP-7623 floor of 21000 + 10 gas per token.
///         - `TaskRegistered log` is the LOG opcode's charge for that event: 375, plus 375 per
///           topic, plus 8 per byte of data. With taskMetadata in the log data (#4285) it grows
///           with the payload and predicate; memory expansion for the encoding is not included.
///
///         Payload and predicate filler bytes are non-zero. A zero byte stores into a fresh slot
///         almost for free and costs a quarter of a non-zero byte in calldata, so zero-filled
///         inputs would understate both storage and calldata cost.
///
///         Run with: forge test --match-contract RegistrationGasTest -vv
contract RegistrationGasTest is BaseDiamondTest {
    /// @dev EIP-7825 per-transaction gas cap (`TX_GAS_LIMIT_CAP`, crates/primitives/src/eip7825.rs).
    ///      A registration at the DataLengthCaps must fit under it, or a task of that size could
    ///      not be registered at all.
    uint256 constant TX_GAS_LIMIT_CAP = 16_777_216;

    /// @dev Prague transaction cost constants (EIP-2028, EIP-3529, EIP-7623).
    uint256 constant TX_BASE_GAS = 21_000;
    uint256 constant STANDARD_GAS_PER_TOKEN = 4;
    uint256 constant FLOOR_GAS_PER_TOKEN = 10;
    uint256 constant MAX_REFUND_QUOTIENT = 5;

    /// @dev LOG opcode charges (Yellow Paper G_log, G_logtopic, G_logdata).
    uint256 constant LOG_BASE_GAS = 375;
    uint256 constant LOG_TOPIC_GAS = 375;
    uint256 constant LOG_DATA_GAS_PER_BYTE = 8;

    /// @dev Encoded-length overhead of the payload and predicate builders below; see their NatSpec.
    uint256 constant PAYLOAD_ENCODING_OVERHEAD = 192;
    uint256 constant PREDICATE_ENCODING_OVERHEAD = 96;

    /// @dev Non-zero filler byte for payload and predicate call data.
    bytes1 constant FILLER = 0xab;

    /// @dev One measured registration.
    struct Measurement {
        uint256 execution;
        uint256 calldataBytes;
        uint256 txTotal;
        uint256 logDataBytes;
        uint256 logGas;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Input builders
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Returns `_length` non-zero bytes.
    function _filler(uint256 _length) internal pure returns (bytes memory out) {
        out = new bytes(_length);
        for (uint256 i; i < _length; i++) {
            out[i] = FILLER;
        }
    }

    /// @dev A payload of exactly `_totalLength` bytes. Registration only decodes the payload and
    ///      length-checks its call data, so the call data is the WrappedSupra.withdraw selector
    ///      followed by filler. With an empty access list abi.encode(uint128, address, bytes,
    ///      AccessListEntry[]) is 192 bytes plus the call data padded to 32, so `_totalLength`
    ///      must be 32-aligned and leave room for at least the 4-byte selector.
    function _payloadOfLength(uint256 _totalLength) internal view returns (bytes memory) {
        require(_totalLength % 32 == 0 && _totalLength > PAYLOAD_ENCODING_OVERHEAD, "payload length");
        LibCommon.AccessListEntry[] memory emptyAccessList;
        bytes memory callData = abi.encodePacked(
            WrappedSupra.withdraw.selector, _filler(_totalLength - PAYLOAD_ENCODING_OVERHEAD - 4)
        );
        return abi.encode(uint128(0), address(wsupra), callData, emptyAccessList);
    }

    /// @dev A predicate of exactly `_totalLength` bytes. Registration executes the predicate with a
    ///      staticcall, so its call data stays a valid call: isRegistrationEnabled() takes no
    ///      arguments and ignores the trailing filler. abi.encode(address, bytes) is 96 bytes plus
    ///      the call data padded to 32, so `_totalLength` must be 32-aligned.
    function _predicateOfLength(uint256 _totalLength) internal view returns (bytes memory) {
        require(_totalLength % 32 == 0 && _totalLength > PREDICATE_ENCODING_OVERHEAD, "predicate length");
        bytes memory callData = abi.encodePacked(
            IConfigFacet.isRegistrationEnabled.selector, _filler(_totalLength - PREDICATE_ENCODING_OVERHEAD - 4)
        );
        return abi.encode(diamondAddr, callData);
    }

    // ────────────────────────────────────────────────────────────────────────
    // Measurement
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Marks the registry's accounts and storage cold, as at the start of a transaction.
    ///      The Diamond delegates to its facets, so each facet's code account is cooled as well.
    function _coolRegistry() internal {
        vm.cool(diamondAddr);
        vm.cool(address(wsupra));
        address[] memory facets = IDiamondLoupe(diamondAddr).facetAddresses();
        for (uint256 i; i < facets.length; i++) {
            vm.cool(facets[i]);
        }
    }

    /// @dev Gas a transaction with `_calldata` pays for an execution frame that used `_execution`
    ///      gas and accrued `_refund`: the standard cost less the capped refund, but never less than
    ///      the EIP-7623 calldata floor.
    function _txTotal(bytes memory _calldata, uint256 _execution, int256 _refund) internal pure returns (uint256) {
        uint256 tokens;
        for (uint256 i; i < _calldata.length; i++) {
            tokens += _calldata[i] == 0 ? 1 : 4;
        }
        uint256 standard = TX_BASE_GAS + STANDARD_GAS_PER_TOKEN * tokens + _execution;
        // A negative refund cannot occur for a completed frame; treat it as none. The cast only
        // runs on a positive int256, which uint256 represents exactly.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 refund = _refund > 0 ? uint256(_refund) : 0;
        uint256 maxRefund = standard / MAX_REFUND_QUOTIENT;
        uint256 charged = standard - (refund < maxRefund ? refund : maxRefund);
        uint256 floor = TX_BASE_GAS + FLOOR_GAS_PER_TOKEN * tokens;
        return charged > floor ? charged : floor;
    }

    /// @dev Completes `_m` from the last call's gas record and the one `_topic0` log it emitted.
    function _complete(Measurement memory _m, bytes memory _calldata, bytes32 _topic0) internal {
        Vm.Gas memory gas = vm.lastCallGas();
        // Read the gas record before any further call, since every call overwrites it.
        _m.execution = gas.gasTotalUsed;
        _m.calldataBytes = _calldata.length;
        _m.txTotal = _txTotal(_calldata, gas.gasTotalUsed, gas.gasRefunded);

        Vm.Log memory log = findLog(vm.getRecordedLogs(), diamondAddr, _topic0);
        _m.logDataBytes = log.data.length;
        _m.logGas = LOG_BASE_GAS + LOG_TOPIC_GAS * log.topics.length + LOG_DATA_GAS_PER_BYTE * log.data.length;
    }

    /// @dev Registers one UST as alice with the given inputs and measures it.
    function _measureUst(bytes memory _payload, bytes memory _predicate) internal returns (Measurement memory m) {
        bytes[] memory auxData;
        uint64 expiry = uint64(block.timestamp + 1250);
        bytes memory callData = abi.encodeCall(
            IRegistryFacet.register,
            (_payload, _predicate, expiry, uint128(100_000), uint128(4 gwei), uint128(60.1 ether), 0, auxData)
        );

        _coolRegistry();
        vm.recordLogs();
        vm.prank(alice);
        IRegistryFacet(diamondAddr).register(
            _payload, _predicate, expiry, uint128(100_000), uint128(4 gwei), uint128(60.1 ether), 0, auxData
        );
        _complete(m, callData, IRegistryFacet.TaskRegistered.selector);
    }

    /// @dev Registers one GST as bob, an authorized submitter, with the given inputs and measures it.
    function _measureGst(bytes memory _payload, bytes memory _predicate) internal returns (Measurement memory m) {
        bytes[] memory auxData;
        uint64 expiry = uint64(block.timestamp + 1250);
        bytes memory callData = abi.encodeCall(
            IRegistryFacet.registerSystemTask, (_payload, _predicate, expiry, uint128(100_000), 0, auxData)
        );

        _coolRegistry();
        vm.recordLogs();
        vm.prank(bob);
        IRegistryFacet(diamondAddr).registerSystemTask(_payload, _predicate, expiry, uint128(100_000), 0, auxData);
        _complete(m, callData, IRegistryFacet.SystemTaskRegistered.selector);
    }

    /// @dev Funds alice for the two UST registrations a scenario makes: each takes a 1 ether flat
    ///      fee and a 60.1 ether deposit. BaseDiamondTest deals alice 500 ether.
    function _fundAlice() internal {
        vm.startPrank(alice);
        wsupra.deposit{value: 200 ether}();
        wsupra.approve(diamondAddr, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Logs one measurement as a labelled line.
    function _log(string memory _scenario, string memory _which, Measurement memory _m) internal pure {
        console.log(string.concat(_scenario, " | ", _which));
        console.log("    execution               :", _m.execution);
        console.log("    calldata bytes          :", _m.calldataBytes);
        console.log("    tx total                :", _m.txTotal);
        console.log("    event log data bytes    :", _m.logDataBytes);
        console.log("    event LOG opcode gas    :", _m.logGas);
    }

    /// @dev Measures a first and a second UST registration of the given inputs and checks that
    ///      both fit under the per-transaction gas cap.
    function _runUst(string memory _scenario, bytes memory _payload, bytes memory _predicate) internal {
        _fundAlice();
        Measurement memory first = _measureUst(_payload, _predicate);
        Measurement memory second = _measureUst(_payload, _predicate);
        console.log(
            string.concat(_scenario, " | payload bytes / predicate bytes:"), _payload.length, _predicate.length
        );
        _log(_scenario, "first task in registry", first);
        _log(_scenario, "second task, same owner", second);
        assertLt(first.txTotal, TX_GAS_LIMIT_CAP, "first registration fits the transaction gas cap");
        assertLt(second.txTotal, TX_GAS_LIMIT_CAP, "second registration fits the transaction gas cap");
    }

    /// @dev GST counterpart of _runUst.
    function _runGst(string memory _scenario, bytes memory _payload, bytes memory _predicate) internal {
        Measurement memory first = _measureGst(_payload, _predicate);
        Measurement memory second = _measureGst(_payload, _predicate);
        console.log(
            string.concat(_scenario, " | payload bytes / predicate bytes:"), _payload.length, _predicate.length
        );
        _log(_scenario, "first task in registry", first);
        _log(_scenario, "second task, same owner", second);
        assertLt(first.txTotal, TX_GAS_LIMIT_CAP, "first registration fits the transaction gas cap");
        assertLt(second.txTotal, TX_GAS_LIMIT_CAP, "second registration fits the transaction gas cap");
    }

    /// @dev The configured payload and predicate caps. ConfigFacet keeps both multiples of 32
    ///      (LibCommon.validateDataLengthCaps), the grid the builders below require.
    function _capLengths() internal view returns (uint256 payloadLength, uint256 predicateLength) {
        (uint16 maxPayload, uint16 maxPredicate,,) = IConfigFacet(diamondAddr).getDataLengthCaps();
        payloadLength = maxPayload;
        predicateLength = maxPredicate;
    }

    /// @dev `_cap / _divisor` rounded down to a multiple of 32. A word-aligned cap divided by 2 or 4
    ///      is not always word-aligned (2,016 / 4 = 504), and the builders require it to be.
    function _fractionOfCap(uint256 _cap, uint256 _divisor) internal pure returns (uint256) {
        uint256 length = _cap / _divisor;
        return length - (length % 32);
    }

    // ────────────────────────────────────────────────────────────────────────
    // UST (register)
    // ────────────────────────────────────────────────────────────────────────

    /// @dev The fixture task used across the suite: a WrappedSupra.withdraw call with a two-entry
    ///      access list, and an isRegistrationEnabled predicate.
    function testRegistrationGas_Ust_Fixture() public {
        _runUst(
            "UST fixture",
            createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)),
            createPredicate(diamondAddr)
        );
    }

    /// @dev A quarter of the default caps.
    function testRegistrationGas_Ust_QuarterCaps() public {
        (uint256 payloadLength, uint256 predicateLength) = _capLengths();
        _runUst(
            "UST 1/4 caps",
            _payloadOfLength(_fractionOfCap(payloadLength, 4)),
            _predicateOfLength(_fractionOfCap(predicateLength, 4))
        );
    }

    /// @dev Half of the default caps.
    function testRegistrationGas_Ust_HalfCaps() public {
        (uint256 payloadLength, uint256 predicateLength) = _capLengths();
        _runUst(
            "UST 1/2 caps",
            _payloadOfLength(_fractionOfCap(payloadLength, 2)),
            _predicateOfLength(_fractionOfCap(predicateLength, 2))
        );
    }

    /// @dev The largest payload and predicate the default caps admit.
    function testRegistrationGas_Ust_AtCaps() public {
        (uint256 payloadLength, uint256 predicateLength) = _capLengths();
        _runUst("UST at caps", _payloadOfLength(payloadLength), _predicateOfLength(predicateLength));
    }

    // ────────────────────────────────────────────────────────────────────────
    // GST (registerSystemTask)
    // ────────────────────────────────────────────────────────────────────────

    /// @dev The fixture task, registered as a system task. A GST pays no fee or deposit.
    function testRegistrationGas_Gst_Fixture() public {
        _runGst(
            "GST fixture",
            createPayload(0, address(wsupra), abi.encodeCall(WrappedSupra.withdraw, 100)),
            createPredicate(diamondAddr)
        );
    }

    /// @dev The largest system task the default caps admit.
    function testRegistrationGas_Gst_AtCaps() public {
        (uint256 payloadLength, uint256 predicateLength) = _capLengths();
        _runGst("GST at caps", _payloadOfLength(payloadLength), _predicateOfLength(predicateLength));
    }
}
