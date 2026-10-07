// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {BlockMeta} from "../src/BlockMeta.sol";
import {MultiSignatureWallet} from "../src/MultiSignatureWallet.sol";
import {MultisigBeacon} from "../src/MultisigBeacon.sol";
import {IBlockMeta} from "../src/interfaces/IBlockMeta.sol";
import {ICoreFacet} from "../src/interfaces/ICoreFacet.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IRegistryFacet} from "../src/interfaces/IRegistryFacet.sol";
import {IConfigFacet} from "../src/interfaces/IConfigFacet.sol";
import {Counter} from "./Counter.sol";
import {
    InitializeCycleMonitoring,
    AuthorizeAccount,
    EnableDisableAutomation,
    ExecuteTxn
} from "../script/GovActions.s.sol";

// The scripts read their inputs from environment variables in setUp(). vm.setEnv changes the
// environment of the whole test process, and forge runs test functions in parallel, so tests
// that each set different values could read one another's. The harnesses below set the scripts'
// inputs directly instead, and a single test (test_setUpReadsTheDocumentedEnvironmentNames) is
// the only one that touches the environment.

contract InitializeCycleMonitoringHarness is InitializeCycleMonitoring {
    function configure(address payable _wallet, address _blockMeta, address _registry, uint64 _gasLimit) external {
        multisigWalletAddr = _wallet;
        blockMetadata = _blockMeta;
        registry = _registry;
        selector = ICoreFacet.monitorCycleEnd.selector;
        selectorGasLimit = _gasLimit;
        timeout = 1 hours;
    }

    function inputs() external view returns (address, address, address, bytes4, uint64, uint64) {
        return (multisigWalletAddr, blockMetadata, registry, selector, selectorGasLimit, timeout);
    }
}

contract AuthorizeAccountHarness is AuthorizeAccount {
    function configure(address payable _wallet, address _registry, address _account) external {
        multisigWalletAddr = _wallet;
        automationRegistry = _registry;
        account = _account;
        timeout = 1 hours;
    }

    function inputs() external view returns (address, address, address, uint64) {
        return (multisigWalletAddr, automationRegistry, account, timeout);
    }
}

contract EnableDisableAutomationHarness is EnableDisableAutomation {
    function configure(address payable _wallet, address _registry, bool _enable) external {
        multisigWalletAddr = _wallet;
        automationRegistry = _registry;
        timeout = 1 hours;
        enable = _enable;
    }

    function inputs() external view returns (address, address, uint64, bool) {
        return (multisigWalletAddr, automationRegistry, timeout, enable);
    }
}

contract ExecuteTxnHarness is ExecuteTxn {
    function configure(address payable _wallet, uint256 _txIndex, bytes32 _contentHash) external {
        multisigWalletAddr = _wallet;
        txIndex = _txIndex;
        contentHash = _contentHash;
    }
}

/// @dev Owned by the wallet like a real BlockMeta, but getExecutionIndex reverts with an error
/// other than SelectorNotRegistered, as a contract that is not a BlockMeta, or a failing call,
/// would.
contract UnexpectedRevertBlockMeta {
    error UnexpectedFailure(uint256 code);

    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function getExecutionIndex(address, bytes4) external pure returns (uint256) {
        revert UnexpectedFailure(42);
    }
}

contract GovActionsTest is Test {
    uint64 constant GAS_CAP = 16_777_216;
    uint64 constant CALLABLE_CAP = (GAS_CAP * 63) / 64;
    uint64 constant SELECTOR_GAS_LIMIT = 9_000_000;

    MultiSignatureWallet wallet;
    BlockMeta blockMeta;
    // Stands in for the automation registry. BlockMeta.register only requires the target to have
    // code; the registry views the action scripts read (owner, isAutomationEnabled,
    // isAuthorizedSubmitter) are mocked per test.
    address registry;
    address secondOwner = address(0xB0B);

    function setUp() public {
        // The scripts broadcast without naming a sender, which signs as forge-std's
        // DEFAULT_SENDER, so it is one of the wallet's owners here. Two confirmations are
        // required: the submission counts as the submitter's, and secondOwner adds the other.
        address[] memory owners = new address[](2);
        owners[0] = DEFAULT_SENDER;
        owners[1] = secondOwner;

        MultisigBeacon beacon = new MultisigBeacon(address(new MultiSignatureWallet()), address(this));
        BeaconProxy walletProxy =
            new BeaconProxy(address(beacon), abi.encodeCall(MultiSignatureWallet.initialize, (owners, 2)));
        wallet = MultiSignatureWallet(payable(walletProxy));

        // Owned by the wallet, as genesis deploys it.
        ERC1967Proxy blockMetaProxy = new ERC1967Proxy(
            address(new BlockMeta()), abi.encodeCall(BlockMeta.initialize, (address(wallet), GAS_CAP))
        );
        blockMeta = BlockMeta(address(blockMetaProxy));

        registry = address(new Counter());
        // Owned by the wallet, as genesis deploys the registry Diamond. A test that needs another
        // owner mocks it again; the latest mock for the same call wins.
        vm.mockCall(registry, abi.encodeCall(IERC173.owner, ()), abi.encode(address(wallet)));
    }

    function cycleMonitoring(uint64 gasLimit) internal returns (InitializeCycleMonitoringHarness script) {
        script = new InitializeCycleMonitoringHarness();
        script.configure(payable(address(wallet)), address(blockMeta), registry, gasLimit);
    }

    function registrationData(uint64 gasLimit) internal view returns (bytes memory) {
        return abi.encodeCall(IBlockMeta.register, (registry, ICoreFacet.monitorCycleEnd.selector, gasLimit));
    }

    /// @dev Registers an entry directly as the wallet, the way an earlier governance action would
    /// have, so a test can start from a BlockMeta that already has entries.
    function registerAsWallet(address target, bytes4 selector, uint64 gasLimit) internal {
        vm.prank(address(wallet));
        blockMeta.register(target, selector, gasLimit);
    }

    function test_submitsTheRegistrationToTheWallet() public {
        cycleMonitoring(SELECTOR_GAS_LIMIT).run();

        assertEq(wallet.txCount(), 1);
        (address to, uint256 value, uint24 confirmations,, bytes memory data) = wallet.getTransaction(0);
        assertEq(to, address(blockMeta));
        assertEq(value, 0);
        assertEq(confirmations, 1, "submission is the submitter's confirmation");
        assertEq(data, registrationData(SELECTOR_GAS_LIMIT));
        assertEq(
            wallet.getTransactionContentHash(0),
            wallet.hashTransactionContent(address(blockMeta), 0, registrationData(SELECTOR_GAS_LIMIT))
        );
    }

    /// @dev Submit with the script, confirm as the second owner, execute with ExecuteTxn: the
    /// sequence submit_governance_action.sh runs. The entry is registered at the requested limit.
    function test_submittedRegistrationExecutesThroughTheWallet() public {
        cycleMonitoring(SELECTOR_GAS_LIMIT).run();
        bytes32 contentHash = wallet.getTransactionContentHash(0);

        vm.prank(secondOwner);
        wallet.confirmTransaction(0, contentHash);

        ExecuteTxnHarness execute = new ExecuteTxnHarness();
        execute.configure(payable(address(wallet)), 0, contentHash);
        execute.run();

        assertEq(blockMeta.getExecutionGasLimit(registry, ICoreFacet.monitorCycleEnd.selector), SELECTOR_GAS_LIMIT);
        assertEq(blockMeta.totalGasAllocated(), SELECTOR_GAS_LIMIT);
        (address[] memory targets, bytes4[] memory selectors) = blockMeta.getExecutions();
        assertEq(targets.length, 1);
        assertEq(targets[0], registry);
        assertEq(selectors[0], ICoreFacet.monitorCycleEnd.selector);
    }

    function test_acceptsALimitEqualToTheCallableShare() public {
        cycleMonitoring(CALLABLE_CAP).run();
        assertEq(wallet.txCount(), 1);
    }

    function test_refusesALimitAboveTheCallableShare() public {
        InitializeCycleMonitoringHarness script = cycleMonitoring(CALLABLE_CAP + 1);
        vm.expectRevert(bytes("SelectorGasLimit exceeds the callable share of the block prologue gas cap"));
        script.run();
        assertEq(wallet.txCount(), 0);
    }

    /// @dev The bound covers every registered entry, not only this one: a limit that fits the cap
    /// on its own is refused when other entries already hold part of it.
    function test_refusesALimitThatOtherEntriesLeaveNoRoomFor() public {
        registerAsWallet(registry, Counter.increment.selector, CALLABLE_CAP - SELECTOR_GAS_LIMIT + 1);

        InitializeCycleMonitoringHarness script = cycleMonitoring(SELECTOR_GAS_LIMIT);
        vm.expectRevert(bytes("SelectorGasLimit exceeds the callable share of the block prologue gas cap"));
        script.run();
        assertEq(wallet.txCount(), 0);
    }

    function test_acceptsALimitThatFitsBesideOtherEntries() public {
        registerAsWallet(registry, Counter.increment.selector, CALLABLE_CAP - SELECTOR_GAS_LIMIT);

        cycleMonitoring(SELECTOR_GAS_LIMIT).run();
        assertEq(wallet.txCount(), 1);
    }

    function test_refusesWhenMonitorCycleEndIsAlreadyRegistered() public {
        registerAsWallet(registry, ICoreFacet.monitorCycleEnd.selector, SELECTOR_GAS_LIMIT);

        InitializeCycleMonitoringHarness script = cycleMonitoring(SELECTOR_GAS_LIMIT);
        vm.expectRevert(bytes("monitorCycleEnd is already registered in BlockMetadata"));
        script.run();
        assertEq(wallet.txCount(), 0);
    }

    function test_refusesAZeroLimit() public {
        InitializeCycleMonitoringHarness script = cycleMonitoring(0);
        vm.expectRevert(bytes("SelectorGasLimit must be greater than zero"));
        script.run();
    }

    function test_refusesARegistryAddressWithoutCode() public {
        InitializeCycleMonitoringHarness script = new InitializeCycleMonitoringHarness();
        script.configure(payable(address(wallet)), address(blockMeta), address(0xDEAD), SELECTOR_GAS_LIMIT);
        vm.expectRevert(bytes("AutomationRegistry has no code at the given address"));
        script.run();
    }

    /// @dev A getExecutionIndex revert other than SelectorNotRegistered is passed through
    /// unchanged, not read as "not registered" (which would go on to submit) nor as "already
    /// registered".
    function test_passesThroughARevertThatIsNotSelectorNotRegistered() public {
        UnexpectedRevertBlockMeta stub = new UnexpectedRevertBlockMeta(address(wallet));
        InitializeCycleMonitoringHarness script = new InitializeCycleMonitoringHarness();
        script.configure(payable(address(wallet)), address(stub), registry, SELECTOR_GAS_LIMIT);

        vm.expectRevert(abi.encodeWithSelector(UnexpectedRevertBlockMeta.UnexpectedFailure.selector, 42));
        script.run();
        assertEq(wallet.txCount(), 0);
    }

    /// @dev BlockMeta.register is owner-only: a BlockMeta the wallet does not own would refuse the
    /// registration at execution.
    function test_refusesABlockMetaTheWalletDoesNotOwn() public {
        ERC1967Proxy otherProxy =
            new ERC1967Proxy(address(new BlockMeta()), abi.encodeCall(BlockMeta.initialize, (address(this), GAS_CAP)));
        InitializeCycleMonitoringHarness script = new InitializeCycleMonitoringHarness();
        script.configure(payable(address(wallet)), address(otherProxy), registry, SELECTOR_GAS_LIMIT);

        vm.expectRevert(bytes("BlockMetadata is not owned by FoundationWallet"));
        script.run();
        assertEq(wallet.txCount(), 0);
    }

    function test_refusesABlockMetaAddressWithoutCode() public {
        InitializeCycleMonitoringHarness script = new InitializeCycleMonitoringHarness();
        script.configure(payable(address(wallet)), address(0xDEAD), registry, SELECTOR_GAS_LIMIT);
        vm.expectRevert(bytes("BlockMetadata has no code at the given address"));
        script.run();
    }

    function authorizeAccount(address account) internal returns (AuthorizeAccountHarness script) {
        script = new AuthorizeAccountHarness();
        script.configure(payable(address(wallet)), registry, account);
    }

    function test_authorizationIsSubmittedForANewAccount() public {
        address account = address(0xACC);
        vm.mockCall(registry, abi.encodeCall(IRegistryFacet.isAuthorizedSubmitter, (account)), abi.encode(false));

        authorizeAccount(account).run();

        (address to,,,, bytes memory data) = wallet.getTransaction(0);
        assertEq(to, registry);
        assertEq(data, abi.encodeCall(IConfigFacet.grantAuthorization, (account)));
    }

    /// @dev grantAuthorization reverts with AddressAlreadyExists for an authorized account.
    function test_refusesToAuthorizeAnAlreadyAuthorizedAccount() public {
        address account = address(0xACC);
        vm.mockCall(registry, abi.encodeCall(IRegistryFacet.isAuthorizedSubmitter, (account)), abi.encode(true));

        AuthorizeAccountHarness script = authorizeAccount(account);
        vm.expectRevert(bytes("AccountToAuthorize is already authorized"));
        script.run();
        assertEq(wallet.txCount(), 0);
    }

    function test_refusesToAuthorizeTheZeroAddress() public {
        AuthorizeAccountHarness script = authorizeAccount(address(0));
        vm.expectRevert(bytes("AccountToAuthorize must not be the zero address"));
        script.run();
    }

    function test_refusesToAuthorizeOnARegistryTheWalletDoesNotOwn() public {
        vm.mockCall(registry, abi.encodeCall(IERC173.owner, ()), abi.encode(address(this)));

        AuthorizeAccountHarness script = authorizeAccount(address(0xACC));
        vm.expectRevert(bytes("AutomationRegistry is not owned by FoundationWallet"));
        script.run();
        assertEq(wallet.txCount(), 0);
    }

    function test_enableIsSubmittedWhenAutomationIsDisabled() public {
        vm.mockCall(registry, abi.encodeCall(ICoreFacet.isAutomationEnabled, ()), abi.encode(false));
        EnableDisableAutomationHarness script = new EnableDisableAutomationHarness();
        script.configure(payable(address(wallet)), registry, true);

        script.run();

        (address to,,,, bytes memory data) = wallet.getTransaction(0);
        assertEq(to, registry);
        assertEq(data, abi.encodeCall(ICoreFacet.enableAutomation, ()));
    }

    function test_disableIsSubmittedWhenAutomationIsEnabled() public {
        vm.mockCall(registry, abi.encodeCall(ICoreFacet.isAutomationEnabled, ()), abi.encode(true));
        EnableDisableAutomationHarness script = new EnableDisableAutomationHarness();
        script.configure(payable(address(wallet)), registry, false);

        script.run();

        (,,,, bytes memory data) = wallet.getTransaction(0);
        assertEq(data, abi.encodeCall(ICoreFacet.disableAutomation, ()));
    }

    function test_refusesToEnableOnARegistryTheWalletDoesNotOwn() public {
        vm.mockCall(registry, abi.encodeCall(IERC173.owner, ()), abi.encode(address(this)));
        vm.mockCall(registry, abi.encodeCall(ICoreFacet.isAutomationEnabled, ()), abi.encode(false));
        EnableDisableAutomationHarness script = new EnableDisableAutomationHarness();
        script.configure(payable(address(wallet)), registry, true);

        vm.expectRevert(bytes("AutomationRegistry is not owned by FoundationWallet"));
        script.run();
        assertEq(wallet.txCount(), 0);
    }

    function test_refusesToRequestTheStateAutomationIsAlreadyIn() public {
        vm.mockCall(registry, abi.encodeCall(ICoreFacet.isAutomationEnabled, ()), abi.encode(true));
        EnableDisableAutomationHarness script = new EnableDisableAutomationHarness();
        script.configure(payable(address(wallet)), registry, true);

        vm.expectRevert(bytes("Automation is already in the requested state"));
        script.run();
        assertEq(wallet.txCount(), 0);
    }

    /// @dev The only test that sets environment variables (see the note at the top of this file).
    /// The names are the keys of the on-chain EvmContractsDetails resource plus the action inputs,
    /// and are what submit_governance_action.sh and the README document.
    function test_setUpReadsTheDocumentedEnvironmentNames() public {
        vm.setEnv("FoundationWallet", vm.toString(address(wallet)));
        vm.setEnv("BlockMetadata", vm.toString(address(blockMeta)));
        vm.setEnv("AutomationRegistry", vm.toString(registry));
        vm.setEnv("SelectorGasLimit", "9000000");
        vm.setEnv("Timeout", "360");
        vm.setEnv("EnableAutomation", "true");
        vm.setEnv("AccountToAuthorize", vm.toString(address(0xACC)));

        InitializeCycleMonitoringHarness monitoring = new InitializeCycleMonitoringHarness();
        monitoring.setUp();
        (address w, address bm, address reg, bytes4 sel, uint64 gasLimit, uint64 timeout) = monitoring.inputs();
        assertEq(w, address(wallet));
        assertEq(bm, address(blockMeta));
        assertEq(reg, registry);
        assertEq(sel, bytes4(keccak256("monitorCycleEnd()")));
        assertEq(gasLimit, 9_000_000);
        assertEq(timeout, 360);

        EnableDisableAutomationHarness automation = new EnableDisableAutomationHarness();
        automation.setUp();
        (address w2, address reg2, uint64 timeout2, bool enable) = automation.inputs();
        assertEq(w2, address(wallet));
        assertEq(reg2, registry);
        assertEq(timeout2, 360);
        assertTrue(enable);

        AuthorizeAccountHarness authorization = new AuthorizeAccountHarness();
        authorization.setUp();
        (address w3, address reg3, address account, uint64 timeout3) = authorization.inputs();
        assertEq(w3, address(wallet));
        assertEq(reg3, registry);
        assertEq(account, address(0xACC));
        assertEq(timeout3, 360);
    }
}
