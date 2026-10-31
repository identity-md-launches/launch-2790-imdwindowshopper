// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDwindowshopper} from "../src/IMDwindowshopper.sol";

/// @dev Deploys through CREATE2 so a test can try to mint a second time at the same address.
contract Create2Probe {
    function deploy(bytes32 salt) external returns (IMDwindowshopper) {
        return new IMDwindowshopper{salt: salt}();
    }
}

/// @dev Refuses every call, so a token that touched a recipient could not deliver to this one.
contract HostileRecipient {
    fallback() external payable {
        revert("recipient was called");
    }
}

/// @dev Inputs the accepted suite does not reach: the zero address as caller and as `from`, the order
/// in which checks fail, malformed calldata, the boundary of the infinite allowance, the absence of
/// events and storage writes, and the contract's whole external surface as compiled.
contract IMDwindowshopperEdgesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 private constant MAX = type(uint256).max;
    uint256 private constant EIP170_LIMIT = 24_576;

    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");

    // OpenZeppelin ERC20 storage layout. test_storageLayoutMatchesTheSlotsTheseTestsWatch pins it.
    uint256 private constant BALANCES_SLOT = 0;
    uint256 private constant ALLOWANCES_SLOT = 1;
    uint256 private constant TOTAL_SUPPLY_SLOT = 2;

    IMDwindowshopper private token;
    address private alice;
    address private bob;
    address private spender;

    function setUp() public {
        token = new IMDwindowshopper();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
    }

    // ---------------------------------------------------------------- deployment

    function test_metadataIsExactlyTheBriefsAsciiBytes() public view {
        assertEq(bytes(token.name()), hex"494d4477696e646f7773686f70706572");
        assertEq(bytes(token.symbol()), hex"575757");
    }

    function test_constructorMintsToTheCallerNotTheTransactionOrigin() public {
        vm.prank(alice, bob);
        IMDwindowshopper fresh = new IMDwindowshopper();
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(bob), 0);
    }

    function test_constructorRejectsNativeValue() public {
        vm.deal(address(this), 1 ether);
        bytes memory code = type(IMDwindowshopper).creationCode;
        address withValue;
        address withoutValue;
        assembly ("memory-safe") {
            withValue := create(1, add(code, 32), mload(code))
            withoutValue := create(0, add(code, 32), mload(code))
        }
        assertEq(withValue, address(0));
        assertTrue(withoutValue != address(0), "control deployment failed");
        assertEq(address(this).balance, 1 ether);
    }

    function test_constructorRevertsWhenTheDeployerIsTheZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(address(0));
        new IMDwindowshopper();
    }

    function test_sameCreate2SaltCannotMintASecondTime() public {
        Create2Probe factory = new Create2Probe();
        bytes32 salt = keccak256("one launch");
        IMDwindowshopper launched = factory.deploy(salt);

        vm.expectRevert();
        factory.deploy(salt);

        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
    }

    function test_separateDeploymentsShareNoState() public {
        IMDwindowshopper other = new IMDwindowshopper();
        assertTrue(address(other) != address(token));
        assertTrue(token.transfer(alice, 1 ether));
        assertTrue(token.approve(spender, 1 ether));
        assertEq(other.balanceOf(alice), 0);
        assertEq(other.balanceOf(address(this)), SUPPLY);
        assertEq(other.allowance(address(this), spender), 0);
    }

    function test_runtimeFitsEip170() public view {
        assertLe(address(token).code.length, EIP170_LIMIT);
    }

    // ---------------------------------------------------------------- transfer

    function test_transferOfTheMaximumAmountReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, MAX)
        );
        token.transfer(alice, MAX);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferOneMoreThanTheWholeSupplyReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_selfTransferOverBalanceRevertsAndDoesNotInflate() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(address(this), SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_transferFromTheZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(alice, 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_receiverIsCheckedBeforeBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 1);
    }

    function test_transferDeliversToARecipientThatRefusesEveryCall() public {
        HostileRecipient recipient = new HostileRecipient();
        assertTrue(token.transfer(address(recipient), 1 ether));
        assertEq(token.balanceOf(address(recipient)), 1 ether);

        vm.prank(address(recipient));
        assertTrue(token.transfer(alice, 1 ether));
        assertEq(token.balanceOf(alice), 1 ether);
    }

    /// @dev The README's warning, made exact: nothing can take tokens out of the token's own balance.
    function test_tokensSentToTheTokenItselfStayCountedAndNoCallerCanRemoveThem() public {
        assertTrue(token.transfer(address(token), 7 ether));
        assertEq(token.balanceOf(address(token)), 7 ether);
        assertEq(token.totalSupply(), SUPPLY);

        address[3] memory callers = [address(this), alice, address(token)];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, callers[i], 0, 1));
            vm.prank(callers[i]);
            token.transferFrom(address(token), alice, 1);
        }
        assertEq(token.balanceOf(address(token)), 7 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transfersAreIndependentOfTimeBlockAndChain() public {
        assertTrue(token.transfer(alice, 1 ether));
        vm.warp(type(uint40).max);
        vm.roll(type(uint40).max);
        vm.chainId(8453);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1 ether));
        assertEq(token.balanceOf(bob), 1 ether);
    }

    // ---------------------------------------------------------------- allowance boundaries

    function test_holderMustApproveItselfToUseTransferFrom() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);

        assertTrue(token.approve(address(this), 2));
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), address(this)), 1);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_ownerSpenderAndRecipientMayAllBeTheSameAccount() public {
        assertTrue(token.approve(address(this), 3 ether));
        assertTrue(token.transferFrom(address(this), address(this), 2 ether));
        assertEq(token.allowance(address(this), address(this)), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_oneBelowTheMaximumAllowanceIsFinite() public {
        assertTrue(token.approve(spender, MAX - 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), MAX - 2);
    }

    function test_infiniteAllowanceSurvivesARejectedSpendAndCanBeRevoked() public {
        assertTrue(token.approve(spender, MAX));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, MAX)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, MAX);
        assertEq(token.allowance(address(this), spender), MAX);

        assertTrue(token.approve(spender, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
    }

    function test_allowanceIsCheckedBeforeBalance() public {
        assertTrue(token.transfer(alice, 1));
        vm.prank(alice);
        assertTrue(token.approve(spender, 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1, 2));
        vm.prank(spender);
        token.transferFrom(alice, bob, 2);
    }

    function test_allowanceIsCheckedBeforeReceiver() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 1);
    }

    function test_zeroValueSpendToTheZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 0);
    }

    function test_zeroValueSpendKeepsAnExistingAllowance() public {
        assertTrue(token.approve(spender, 5));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 0));
        assertEq(token.allowance(address(this), spender), 5);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_spendingFromTheZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 1);
    }

    function test_zeroAddressCannotApproveOrSpend() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(spender, 1);

        // The approver is checked first when both ends are zero.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(address(0), 1);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(address(0));
        token.transferFrom(address(this), alice, 0);
    }

    function test_allowanceFollowsTheOwnerNotTheTokens() public {
        assertTrue(token.approve(spender, 1 ether));
        assertTrue(token.transfer(alice, 1 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(address(this), spender), 1 ether);
    }

    function test_allowanceOutlivesAnEmptiedBalance() public {
        assertTrue(token.transfer(alice, 2 ether));
        vm.prank(alice);
        assertTrue(token.approve(spender, 2 ether));
        vm.prank(alice);
        assertTrue(token.transfer(bob, 2 ether));
        assertEq(token.allowance(alice, spender), 2 ether);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);

        vm.prank(bob);
        assertTrue(token.transfer(alice, 2 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 2 ether));
        assertEq(token.allowance(alice, spender), 0);
    }

    /// @dev What the README warns about: `approve` overwrites without looking at what was spent, so a
    /// spender that moves between the holder's two approvals uses both.
    function test_replacingAnAllowanceDoesNotAccountForWhatWasAlreadySpent() public {
        assertTrue(token.approve(spender, 5 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 5 ether));
        assertTrue(token.approve(spender, 3 ether));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 3 ether));
        assertEq(token.balanceOf(alice), 8 ether);
        assertEq(token.allowance(address(this), spender), 0);
    }

    // ---------------------------------------------------------------- ABI behaviour

    function test_writesReturnExactlyOneAbiEncodedTrue() public {
        (bool approved, bytes memory approveData) = address(token).call(abi.encodeCall(token.approve, (spender, 2)));
        assertTrue(approved);
        assertEq(approveData, abi.encode(true));

        (bool moved, bytes memory transferData) = address(token).call(abi.encodeCall(token.transfer, (alice, 1)));
        assertTrue(moved);
        assertEq(transferData, abi.encode(true));

        vm.prank(spender);
        (bool spent, bytes memory spendData) =
            address(token).call(abi.encodeCall(token.transferFrom, (address(this), alice, 1)));
        assertTrue(spent);
        assertEq(spendData, abi.encode(true));
    }

    function test_truncatedCalldataIsRejected() public {
        bytes32 to = bytes32(uint256(uint160(alice)));
        bytes[3] memory calls = [
            abi.encodePacked(token.transfer.selector, to, uint248(1)),
            abi.encodePacked(token.approve.selector, to, uint248(1)),
            abi.encodePacked(token.transferFrom.selector, bytes32(uint256(uint160(address(this)))), to, uint248(1))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "a short amount was padded");
        }
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), alice), 0);
    }

    function test_addressArgumentsWithDirtyHighBitsAreRejected() public {
        bytes32 dirty = bytes32(uint256(uint160(alice)) | (uint256(1) << 160));
        (bool moved,) = address(token).call(abi.encodePacked(token.transfer.selector, dirty, uint256(1)));
        assertFalse(moved);
        (bool approved,) = address(token).call(abi.encodePacked(token.approve.selector, dirty, uint256(1)));
        assertFalse(approved);
        assertEq(token.balanceOf(alice), 0);

        // The same call with clean bits goes through, so the two above failed on the bits alone.
        bytes32 clean = bytes32(uint256(uint160(alice)));
        (bool control,) = address(token).call(abi.encodePacked(token.transfer.selector, clean, uint256(1)));
        assertTrue(control);
    }

    function test_everyFunctionRefusesNativeValue() public {
        vm.deal(address(this), 11 ether);
        bytes[11] memory calls = [
            abi.encodeCall(token.name, ()),
            abi.encodeCall(token.symbol, ()),
            abi.encodeCall(token.decimals, ()),
            abi.encodeCall(token.totalSupply, ()),
            abi.encodeCall(token.INITIAL_SUPPLY, ()),
            abi.encodeCall(token.balanceOf, (alice)),
            abi.encodeCall(token.allowance, (alice, bob)),
            abi.encodeCall(token.transfer, (alice, 1)),
            abi.encodeCall(token.approve, (spender, 1)),
            abi.encodeCall(token.transferFrom, (address(this), alice, 0)),
            bytes("")
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call{value: 1 ether}(calls[i]);
            assertFalse(ok);
        }
        assertEq(address(token).balance, 0);
        assertEq(address(this).balance, 11 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------- events

    function test_transferEmitsOneLogAndNothingElse() public {
        vm.recordLogs();
        assertTrue(token.transfer(alice, 1));
        _assertSoleLog(TRANSFER_TOPIC, address(this), alice, 1);
    }

    function test_selfTransferEmitsOneLog() public {
        vm.recordLogs();
        assertTrue(token.transfer(address(this), 1));
        _assertSoleLog(TRANSFER_TOPIC, address(this), address(this), 1);
    }

    function test_approveEmitsOneLogEvenWhenTheValueIsUnchanged() public {
        assertTrue(token.approve(spender, 9));
        vm.recordLogs();
        assertTrue(token.approve(spender, 9));
        _assertSoleLog(APPROVAL_TOPIC, address(this), spender, 9);
    }

    function test_finiteSpendEmitsTransferButNoApproval() public {
        assertTrue(token.approve(spender, 9));
        vm.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 4));
        _assertSoleLog(TRANSFER_TOPIC, address(this), alice, 4);
    }

    function test_infiniteSpendEmitsTransferButNoApproval() public {
        assertTrue(token.approve(spender, MAX));
        vm.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 4));
        _assertSoleLog(TRANSFER_TOPIC, address(this), alice, 4);
    }

    function test_rejectedCallsEmitNothing() public {
        vm.recordLogs();
        (bool overBalance,) = address(token).call(abi.encodeCall(token.transfer, (alice, SUPPLY + 1)));
        (bool toZero,) = address(token).call(abi.encodeCall(token.transfer, (address(0), 1)));
        (bool overAllowance,) = address(token).call(abi.encodeCall(token.transferFrom, (alice, bob, 1)));
        (bool zeroSpender,) = address(token).call(abi.encodeCall(token.approve, (address(0), 1)));
        assertFalse(overBalance || toZero || overAllowance || zeroSpender);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ---------------------------------------------------------------- storage frame

    function test_storageLayoutMatchesTheSlotsTheseTestsWatch() public {
        assertTrue(token.approve(spender, 3));
        assertEq(uint256(vm.load(address(token), _balanceSlot(address(this)))), SUPPLY);
        assertEq(uint256(vm.load(address(token), _allowanceSlot(address(this), spender))), 3);
        assertEq(uint256(vm.load(address(token), bytes32(TOTAL_SUPPLY_SLOT))), SUPPLY);
    }

    function test_transferWritesOnlyTheTwoBalances() public {
        vm.record();
        assertTrue(token.transfer(alice, 1));
        (, bytes32[] memory writes) = vm.accesses(address(token));
        bytes32[] memory allowed = new bytes32[](2);
        allowed[0] = _balanceSlot(address(this));
        allowed[1] = _balanceSlot(alice);
        _assertWritesAreExactly(writes, allowed);
    }

    function test_approveWritesOnlyTheAllowance() public {
        vm.record();
        assertTrue(token.approve(spender, 1));
        (, bytes32[] memory writes) = vm.accesses(address(token));
        bytes32[] memory allowed = new bytes32[](1);
        allowed[0] = _allowanceSlot(address(this), spender);
        _assertWritesAreExactly(writes, allowed);
    }

    function test_finiteSpendWritesTheBalancesAndTheAllowance() public {
        assertTrue(token.approve(spender, 2));
        vm.record();
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        (, bytes32[] memory writes) = vm.accesses(address(token));
        bytes32[] memory allowed = new bytes32[](3);
        allowed[0] = _balanceSlot(address(this));
        allowed[1] = _balanceSlot(alice);
        allowed[2] = _allowanceSlot(address(this), spender);
        _assertWritesAreExactly(writes, allowed);
    }

    function test_infiniteSpendLeavesTheAllowanceSlotUnwritten() public {
        assertTrue(token.approve(spender, MAX));
        vm.record();
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        (, bytes32[] memory writes) = vm.accesses(address(token));
        bytes32[] memory allowed = new bytes32[](2);
        allowed[0] = _balanceSlot(address(this));
        allowed[1] = _balanceSlot(alice);
        _assertWritesAreExactly(writes, allowed);
    }

    // ---------------------------------------------------------------- compiled surface

    /// @dev Every 4-byte constant in reachable code is one of the ten functions, one of the errors or
    /// the compiler's panic, and the only constants compared with EQ are selectors, so one with a
    /// leading zero byte cannot hide in a shorter PUSH. A hidden mint or rescue function has nowhere
    /// to be: the list in the accepted suite only rejects names someone thought of.
    function test_compiledDispatcherHoldsOnlyTheDocumentedSurface() public view {
        bytes4[10] memory functions = [
            token.name.selector,
            token.symbol.selector,
            token.decimals.selector,
            token.totalSupply.selector,
            token.INITIAL_SUPPLY.selector,
            token.balanceOf.selector,
            token.allowance.selector,
            token.transfer.selector,
            token.approve.selector,
            token.transferFrom.selector
        ];
        bytes4[7] memory others = [
            IERC20Errors.ERC20InsufficientBalance.selector,
            IERC20Errors.ERC20InvalidSender.selector,
            IERC20Errors.ERC20InvalidReceiver.selector,
            IERC20Errors.ERC20InsufficientAllowance.selector,
            IERC20Errors.ERC20InvalidApprover.selector,
            IERC20Errors.ERC20InvalidSpender.selector,
            bytes4(0x4e487b71) // Panic(uint256)
        ];

        bytes memory runtime = address(token).code;
        uint256 seenFunctions;
        bool reachable = true;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (reachable && op >= 0x60 && op <= 0x63) {
                uint256 width = op - 0x5F;
                uint32 value;
                for (uint256 k = 1; k <= width; ++k) {
                    value = (value << 8) | uint8(runtime[i + k]);
                }
                bool compared = uint8(runtime[i + width + 1]) == 0x14; // EQ
                assertTrue(width == 4 || !compared, "the dispatcher compares a selector shorter than four bytes");
                if (width == 4) {
                    bool known;
                    for (uint256 j; j < functions.length; ++j) {
                        if (_oddPart(bytes4(value)) == _oddPart(functions[j])) {
                            known = true;
                            seenFunctions |= uint256(1) << j;
                        }
                    }
                    for (uint256 j; j < others.length; ++j) {
                        if (_oddPart(bytes4(value)) == _oddPart(others[j])) known = true;
                    }
                    assertTrue(known, "the runtime holds a selector outside the documented surface");
                }
            }
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (_terminates(op)) reachable = false;
        }
        // The scan saw the whole dispatcher, or the list above means nothing.
        assertEq(seenFunctions, (uint256(1) << functions.length) - 1, "a documented selector was not found");
    }

    /// @dev Pure bookkeeping needs none of these. Their absence is what makes the contract free of
    /// reentrancy, of time or chain dependent rules, and of any way to reach another contract.
    function test_compiledCodeHasNoExternalInteractionOrEnvironmentRead() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        bool reachable = true;
        uint256 storageWrites;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (reachable) {
                assertFalse(_isForbidden(op), vm.toString(abi.encodePacked(op)));
                if (op == 0x55) ++storageWrites;
            }
            if (_terminates(op)) reachable = false;
        }
        assertGt(storageWrites, 0, "the scan did not reach the transfer path");
    }

    // ---------------------------------------------------------------- helpers

    function _assertSoleLog(bytes32 topic, address first, address second, uint256 value) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], topic);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(first))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(second))));
        assertEq(abi.decode(logs[0].data, (uint256)), value);
    }

    function _assertWritesAreExactly(bytes32[] memory writes, bytes32[] memory allowed) private pure {
        uint256 seen;
        for (uint256 i; i < writes.length; ++i) {
            bool known;
            for (uint256 j; j < allowed.length; ++j) {
                if (writes[i] == allowed[j]) {
                    known = true;
                    seen |= uint256(1) << j;
                }
            }
            assertTrue(known, "wrote a slot outside the operation's parties");
        }
        assertEq(seen, (uint256(1) << allowed.length) - 1, "a slot the operation owes was not written");
    }

    function _balanceSlot(address account) private pure returns (bytes32) {
        return keccak256(abi.encode(account, BALANCES_SLOT));
    }

    function _allowanceSlot(address owner, address approved) private pure returns (bytes32) {
        return keccak256(abi.encode(approved, keccak256(abi.encode(owner, ALLOWANCES_SLOT))));
    }

    /// @dev The optimizer stores a constant with trailing zero bits as a smaller PUSH4 and a shift, so
    /// the error 0xe450d38c appears as 0x391434e3. Both reduce to the same odd number.
    function _oddPart(bytes4 constant4) private pure returns (uint32 odd) {
        odd = uint32(constant4);
        while (odd != 0 && odd & 1 == 0) {
            odd >>= 1;
        }
    }

    function _terminates(uint8 op) private pure returns (bool) {
        return op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF;
    }

    function _isForbidden(uint8 op) private pure returns (bool) {
        return op == 0x31 // BALANCE
            || op == 0x32 // ORIGIN
            || op == 0x3A // GASPRICE
            || op == 0x3B // EXTCODESIZE
            || op == 0x3C // EXTCODECOPY
            || op == 0x3F // EXTCODEHASH
            || (op >= 0x40 && op <= 0x4A) // block and chain context, BLOCKHASH to BLOBBASEFEE
            || op == 0x5C // TLOAD
            || op == 0x5D // TSTORE
            || op == 0xF0 // CREATE
            || op == 0xF1 // CALL
            || op == 0xF2 // CALLCODE
            || op == 0xF4 // DELEGATECALL
            || op == 0xF5 // CREATE2
            || op == 0xFA // STATICCALL
            || op == 0xFF; // SELFDESTRUCT
    }
}
