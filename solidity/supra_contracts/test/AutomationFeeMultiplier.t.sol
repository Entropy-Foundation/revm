// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {InitParams} from "../src/libraries/DiamondTypes.sol";
import {Deployment, LibDiamondUtils} from "../src/libraries/LibDiamondUtils.sol";
import {ERC20Supra} from "../src/ERC20Supra.sol";

/// @notice Tests for calculateAutomationFeeMultiplierForCommittedOccupancy.
///
/// Configuration under test (exactly as specified by the user):
///   registryMaxGasCap          = 300_000_000  (= 300 * 1_000_000)
///   congestionThresholdPct     = 75            (75 %)
///   congestionExponent         = 6
///   congestionBaseFeeWeiPerSec = 1_714_530_600_000
///   automationBaseFeeWeiPerSec = 1_714_530_600_000  (= CONGESTION_BASE_FEE)
///
/// ─── Formula (LibAccounting.calculateAutomationCongestionFee) ────────────────
///
///   DECIMAL               = 1e8
///   thresholdUsageScaled  = (totalGas * DECIMAL * 100) / maxGas
///   thresholdPctScaled    = threshold * DECIMAL
///
///   if usage <= thresholdPctScaled      → congestion fee = 0  (short-circuit)
///   if congestionBaseFee == 0           → congestion fee = 0  (short-circuit)
///   if threshold == 100                 → congestion fee = 0  (short-circuit)
///
///   surplus       = min(usage, 100*DECIMAL) − thresholdPctScaled
///   surplusScaled = surplus / 100
///   expResult     = ((1 + surplusScaled) ^ exponent)  −  1   [fixed-point, DECIMAL=1e8]
///   congestionFee = (congestionBaseFee * expResult) / DECIMAL
///
///   totalMultiplier = congestionFee + automationBaseFeeWeiPerSec
///
/// ─── Derivation for the 100 % occupancy case ─────────────────────────────────
///
///   thresholdUsageScaled = (300_000_000 × 1e8 × 100) / 300_000_000 = 1e10
///   thresholdPctScaled   = 75 × 1e8 = 7_500_000_000
///   surplus              = 1e10 − 7.5e9 = 2_500_000_000
///   surplusScaled        = 25_000_000   (= 0.25 in fixed-point)
///
///   calculateExponentiation(25_000_000, 6):
///     base   = 1e8 + 25_000_000 = 125_000_000  (represents 1.25)
///     result = 1e8
///
///     iter 1 (exponent=6, bit=0): skip; base = (1.25²)×1e8 = 156_250_000
///     iter 2 (exponent=3, bit=1): result = 156_250_000;
///                                  base  = (1.5625²)×1e8 = 244_140_625
///     iter 3 (exponent=1, bit=1): result = (156_250_000 × 244_140_625) / 1e8
///                                        = 38_146_972_656_250_000 / 1e8
///                                        = 381_469_726  (floor; exact: 381_469_726.5625)
///     return 381_469_726 − 1e8 = 281_469_726
///     (exact: 1.25^6 − 1 = 2.814697265625 → ×1e8 = 281_469_726.5625 → truncated)
///
///   congestionFee = (1_714_530_600_000 × 281_469_726) / 1e8
///                 = 482_588_458_200_615_600_000 / 1e8
///                 = 4_825_884_582_006  (floor; remainder 15_600_000)
///   totalMultiplier = 4_825_884_582_006 + 1_714_530_600_000 = 6_540_415_182_006
///
/// ─── Derivation for the 76 % occupancy case ──────────────────────────────────
///
///   thresholdUsageScaled = 76 × 1e8 = 7_600_000_000
///   surplus              = 100_000_000 ; surplusScaled = 1_000_000 (= 0.01)
///
///   calculateExponentiation(1_000_000, 6):
///     base = 101_000_000
///     iter 1 (bit=0): base   = (1.01²)×1e8 = 102_010_000
///     iter 2 (bit=1): result = 102_010_000;
///                      base  = (102_010_000²)/1e8 = 104_060_401
///     iter 3 (bit=1): result = (102_010_000 × 104_060_401) / 1e8
///                            = 10_615_201_506_010_000 / 1e8
///                            = 106_152_015  (floor)
///     return 6_152_015   (exact: 1.01^6−1 ≈ 0.06152015, ×1e8 = 6_152_015.06…)
///
///   congestionFee = (1_714_530_600_000 × 6_152_015) / 1e8
///                 = 10_547_817_969_159_000_000 / 1e8
///                 = 105_478_179_691  (floor; remainder 59_000_000)
///   totalMultiplier = 105_478_179_691 + 1_714_530_600_000 = 1_820_008_779_691
contract AutomationFeeMultiplierTest is Test {

    // ── User-specified config ──────────────────────────────────────────────
    uint128 constant REGISTRY_MAX_GAS       = 300_000_000;          // 300 * 1_000_000
    uint8   constant CONGESTION_THRESHOLD  = 75;
    uint8   constant CONGESTION_EXPONENT   = 6;
    uint128 constant CONGESTION_BASE_FEE   = 1_714_530_600_000;   // derived from 0.00000000000017145306 ETH/s at 18 decimals
    uint128 constant AUTOMATION_BASE_FEE   = 1_714_530_600_000;   // = CONGESTION_BASE_FEE

    // ── Pre-computed expected values (congestionFee + AUTOMATION_BASE_FEE; see file header) ──
    uint128 constant EXPECTED_FEE_100_PCT = 6_540_415_182_006;   // 4_825_884_582_006 + 1_714_530_600_000
    uint128 constant EXPECTED_FEE_76_PCT  = 1_820_008_779_691;   // 105_478_179_691   + 1_714_530_600_000

    // ── Addresses / contracts ──────────────────────────────────────────────
    address admin   = address(0xA11CE);
    address bridge  = address(0xBEEF);
    ERC20Supra erc20Supra;
    address testDiamond;

    // ── TX-hash precompile required by BaseDiamondTest infra ──────────────
    address constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000053555001;

    // ══════════════════════════════════════════════════════════════════════════
    //                              Setup
    // ══════════════════════════════════════════════════════════════════════════

    function setUp() public {
        // Mock the TX-hash precompile so Diamond deployment doesn't revert.
        vm.mockCall(
            TX_HASH_PRECOMPILE,
            bytes(""),
            abi.encode(keccak256("txHash"))
        );

        // Deploy ERC20Supra (the Diamond requires a valid contract address).
        vm.startPrank(admin);
        address[] memory authorized = new address[](1);
        authorized[0] = bridge;
        ERC20Supra impl = new ERC20Supra();
        bytes memory initData = abi.encodeCall(ERC20Supra.initialize, (admin, authorized));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        erc20Supra = ERC20Supra(address(proxy));
        vm.stopPrank();

        // Deploy the diamond with the user-specified config.
        testDiamond = _deployDiamond(AUTOMATION_BASE_FEE);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //                              Helpers
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Deploys a fresh diamond whose active config contains the user-specified
    ///      congestion parameters plus the provided automationBaseFeeWeiPerSec.
    function _deployDiamond(uint128 automationBaseFee) internal returns (address) {
        InitParams memory p = LibDiamondUtils.defaultInitParams();
        p.registryMaxGasCap            = REGISTRY_MAX_GAS;
        p.sysRegistryMaxGasCap         = REGISTRY_MAX_GAS;
        p.congestionThresholdPercentage = CONGESTION_THRESHOLD;
        p.congestionExponent            = CONGESTION_EXPONENT;
        p.congestionBaseFeeWeiPerSec    = CONGESTION_BASE_FEE;
        p.automationBaseFeeWeiPerSec    = automationBaseFee;

        vm.startPrank(admin);
        Deployment memory d = LibDiamondUtils.deploy(admin, address(erc20Supra), p);
        vm.stopPrank();
        return d.diamond;
    }

    /// @dev Wraps the function under test.
    function _calc(address diamond, uint128 committedGas) internal view returns (uint128) {
        return IRegistryFacet(diamond)
            .calculateAutomationFeeMultiplierForCommittedOccupancy(committedGas);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //                            Tests
    // ══════════════════════════════════════════════════════════════════════════

    // ── Zero occupancy ────────────────────────────────────────────────────────

    /// @dev 0 % usage is far below the 75 % threshold → no congestion fee.
    ///      Only automationBaseFee is returned (1_714_530_600_000).
    function testFeeMultiplier_ZeroOccupancy() public view {
        assertEq(_calc(testDiamond, 0), AUTOMATION_BASE_FEE,
            "zero occupancy: multiplier must equal automation base fee only");
    }

    // ── Below threshold: 74 % ─────────────────────────────────────────────────

    /// @dev 74 % usage (222_000_000) is strictly below the 75 % threshold.
    ///      thresholdUsageScaled = 7_400_000_000 ≤ 7_500_000_000 → no congestion.
    function testFeeMultiplier_BelowThreshold_74Pct() public view {
        // Use integer arithmetic to avoid any rounding artefact in the input.
        uint128 gas74 = uint128((74 * uint256(REGISTRY_MAX_GAS)) / 100); // 222_000_000
        assertEq(_calc(testDiamond, gas74), AUTOMATION_BASE_FEE,
            "74% occupancy: only automation base fee (no congestion)");
    }

    // ── Exactly at threshold: 75 % ────────────────────────────────────────────

    /// @dev The guard condition is `≤`, so at exactly the threshold value the
    ///      congestion fee is still zero.
    ///      thresholdUsageScaled = 7_500_000_000 == thresholdPctScaled → no congestion.
    function testFeeMultiplier_AtThreshold_75Pct() public view {
        uint128 gas75 = uint128((75 * uint256(REGISTRY_MAX_GAS)) / 100); // 225_000_000
        assertEq(_calc(testDiamond, gas75), AUTOMATION_BASE_FEE,
            "75% occupancy (at threshold): no congestion fee");
    }

    // ── Just above threshold: 76 % ────────────────────────────────────────────

    /// @dev 76 % usage triggers a small but non-zero congestion fee.
    ///      Expected total = congestionFee(76%) + automationBaseFee
    ///                     = 105_478_179_691 + 1_714_530_600_000 = 1_820_008_779_691.
    function testFeeMultiplier_JustAboveThreshold_76Pct() public view {
        uint128 gas76 = uint128((76 * uint256(REGISTRY_MAX_GAS)) / 100); // 228_000_000
        uint128 result = _calc(testDiamond, gas76);

        assertEq(result, EXPECTED_FEE_76_PCT,
            "76% occupancy: unexpected congestion fee value");
        assertGt(result, 0,
            "76% occupancy: fee must be strictly positive");
        assertLt(result, EXPECTED_FEE_100_PCT,
            "76% occupancy: fee must be less than 100% fee");
    }

    // ── Primary case: 100 % occupancy (totalCommittedMaxGas = registryMaxGas) ──

    /// @dev Full-registry occupancy with the exact user-supplied parameters.
    ///      Expected total = congestionFee(100%) + automationBaseFee
    ///                     = 4_825_884_582_006 + 1_714_530_600_000 = 6_540_415_182_006.
    function testFeeMultiplier_FullOccupancy_100Pct() public view {
        // totalCommittedMaxGas = 300 * 1_000_000 = registryMaxGas
        uint128 result = _calc(testDiamond, REGISTRY_MAX_GAS);
        assertEq(result, EXPECTED_FEE_100_PCT,
            "100% occupancy: unexpected congestion fee value");
    }

    // ── Over-committed: totalGas > registryMaxGas ─────────────────────────────

    /// @dev The surplus is capped at (100 % − threshold) when totalGas > maxGas,
    ///      so the fee at 200 % commitment equals the fee at 100 % commitment.
    ///
    ///      thresholdUsageScaled at 200% = 20_000_000_000 > 100 * DECIMAL
    ///      → surplus capped at (1e10 − 7.5e9) = 2_500_000_000  (same as 100%)
    function testFeeMultiplier_OverCommitted_200Pct() public view {
        uint128 gas200pct = 2 * REGISTRY_MAX_GAS; // 600_000_000
        assertEq(_calc(testDiamond, gas200pct), EXPECTED_FEE_100_PCT,
            "200% over-commitment: fee must be capped at the 100% level");
    }

    // ── Monotonicity ──────────────────────────────────────────────────────────

    /// @dev The congestion multiplier must be non-decreasing as committed gas grows
    ///      (all other config held constant).
    function testFeeMultiplier_MonotonicallyNonDecreasing() public view {
        uint128 fee74  = _calc(testDiamond, uint128((74 * uint256(REGISTRY_MAX_GAS)) / 100));
        uint128 fee75  = _calc(testDiamond, uint128((75 * uint256(REGISTRY_MAX_GAS)) / 100));
        uint128 fee76  = _calc(testDiamond, uint128((76 * uint256(REGISTRY_MAX_GAS)) / 100));
        uint128 fee90  = _calc(testDiamond, uint128((90 * uint256(REGISTRY_MAX_GAS)) / 100));
        uint128 fee100 = _calc(testDiamond, REGISTRY_MAX_GAS);

        assertLe(fee74,  fee75,  "74% <= 75%");
        assertLe(fee75,  fee76,  "75% <= 76%");
        assertLe(fee76,  fee90,  "76% <= 90%");
        assertLe(fee90,  fee100, "90% <= 100%");
    }

    // ── Fee decomposition: baseFee is present at every occupancy level ────────

    /// @dev Verifies that automationBaseFeeWeiPerSec (= 1_714_530_600_000) is always
    ///      present in the result regardless of congestion state.
    ///
    ///      Below threshold: result == AUTOMATION_BASE_FEE   (no congestion component)
    ///      Above threshold: result == congestionFee + AUTOMATION_BASE_FEE
    ///
    ///      The gap between any two occupancy levels must equal the gap between their
    ///      pure congestion fees (the base fee cancels out in the difference).
    function testFeeMultiplier_BaseFeeAlwaysPresent() public view {
        uint128 gas74  = uint128((74 * uint256(REGISTRY_MAX_GAS)) / 100);
        uint128 gas100 = REGISTRY_MAX_GAS;

        uint128 resultBelow = _calc(testDiamond, gas74);
        uint128 resultFull  = _calc(testDiamond, gas100);

        // Below threshold: only the base fee, no congestion.
        assertEq(resultBelow, AUTOMATION_BASE_FEE,
            "below threshold: result must equal automation base fee only");

        // At full occupancy: total = congestionFee(100%) + baseFee = 6_540_415_182_006.
        assertEq(resultFull, EXPECTED_FEE_100_PCT,
            "100% occupancy: result must equal congestionFee + automationBaseFee");

        // The difference isolates the pure congestion component (baseFee cancels out).
        uint128 congestionOnly = resultFull - resultBelow; // 4_825_884_582_006
        assertEq(congestionOnly, 4_825_884_582_006,
            "fee delta must equal the congestion-only component");
    }

    // ── Threshold = 100 % (short-circuit guard) ───────────────────────────────

    /// @dev When congestionThresholdPercentage = 100 the implementation immediately
    ///      returns 0 for the congestion portion (guard: `if (threshold == 100) return 0`).
    ///      Even at full occupancy, only the automation base fee is returned.
    function testFeeMultiplier_ThresholdAt100_NoCongestionEver() public {
        InitParams memory p = LibDiamondUtils.defaultInitParams();
        p.registryMaxGasCap            = REGISTRY_MAX_GAS;
        p.sysRegistryMaxGasCap         = REGISTRY_MAX_GAS;
        p.congestionThresholdPercentage = 100;          // short-circuit active
        p.congestionExponent            = CONGESTION_EXPONENT;
        p.congestionBaseFeeWeiPerSec    = CONGESTION_BASE_FEE;
        p.automationBaseFeeWeiPerSec    = 0;

        vm.startPrank(admin);
        Deployment memory d = LibDiamondUtils.deploy(admin, address(erc20Supra), p);
        vm.stopPrank();

        assertEq(_calc(d.diamond, REGISTRY_MAX_GAS), 0,
            "threshold=100%: no congestion fee even at full occupancy");
    }

    // ── Zero congestion base fee (congestion pricing disabled) ────────────────

    /// @dev When congestionBaseFeeWeiPerSec = 0 the implementation immediately
    ///      returns 0 for the congestion portion (guard: `if (baseFee == 0) return 0`).
    function testFeeMultiplier_ZeroCongestionBaseFee_NoCongestionEver() public {
        InitParams memory p = LibDiamondUtils.defaultInitParams();
        p.registryMaxGasCap            = REGISTRY_MAX_GAS;
        p.sysRegistryMaxGasCap         = REGISTRY_MAX_GAS;
        p.congestionThresholdPercentage = CONGESTION_THRESHOLD;
        p.congestionExponent            = CONGESTION_EXPONENT;
        p.congestionBaseFeeWeiPerSec    = 0;            // disabled
        p.automationBaseFeeWeiPerSec    = 0;

        vm.startPrank(admin);
        Deployment memory d = LibDiamondUtils.deploy(admin, address(erc20Supra), p);
        vm.stopPrank();

        assertEq(_calc(d.diamond, REGISTRY_MAX_GAS), 0,
            "congestionBaseFee=0: no congestion fee at any occupancy");
    }
}
