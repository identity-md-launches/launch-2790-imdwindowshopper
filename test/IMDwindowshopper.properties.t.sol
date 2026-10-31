// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDwindowshopper} from "../src/IMDwindowshopper.sol";

/// @dev Performs the launch's token flows in one call, as `launchCustom` does in one transaction:
/// deploy, forward the swarm's share, seed the pool, forward the remainder. Each leg is measured from
/// the balances it should have moved, the way a launch notices a flow that arrives short.
contract LaunchFlowProbe {
    error ArrivedShort(address recipient, uint256 expected, uint256 actual);

    function launch(bytes32 salt, address distributor, address pool, address remainder, uint256 poolBps)
        external
        returns (IMDwindowshopper token)
    {
        token = new IMDwindowshopper{salt: salt}();
        uint256 supply = token.totalSupply();
        uint256 swarm = supply / 10;
        uint256 seeded = supply * poolBps / 10_000;
        _forward(token, distributor, swarm);
        _forward(token, pool, seeded);
        _forward(token, remainder, supply - swarm - seeded);
    }

    function _forward(IMDwindowshopper token, address to, uint256 amount) private {
        uint256 before = token.balanceOf(to);
        require(token.transfer(to, amount));
        uint256 actual = token.balanceOf(to) - before;
        if (actual != amount) revert ArrivedShort(to, amount, actual);
    }
}

/// @dev Properties that constrain the token without recomputing it: inverses, path independence,
/// idempotence, what is left over after a spend, and who a call may not touch. Addresses and amounts
/// are shaped by `bound` and `_elsewhere` rather than discarded.
/// forge-config: default.fuzz.runs = 1000
contract IMDwindowshopperPropertiesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 private constant MAX = type(uint256).max;

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

    function testFuzz_transferThenReturnRestoresBothBalances(address to, uint256 rawAmount) public {
        to = _elsewhere(to);
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.transfer(to, amount));
        vm.prank(to);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(to), 0);
    }

    function testFuzz_splittingATransferReachesTheSameState(address to, uint256 rawWhole, uint256 rawPart) public {
        to = _elsewhere(to);
        uint256 whole = bound(rawWhole, 0, SUPPLY);
        uint256 part = bound(rawPart, 0, whole);

        uint256 start = vm.snapshotState();
        assertTrue(token.transfer(to, whole));
        uint256 senderOnce = token.balanceOf(address(this));
        uint256 recipientOnce = token.balanceOf(to);

        vm.revertToState(start);
        assertTrue(token.transfer(to, part));
        assertTrue(token.transfer(to, whole - part));
        assertEq(token.balanceOf(address(this)), senderOnce);
        assertEq(token.balanceOf(to), recipientOnce);
    }

    function testFuzz_splittingASpendReachesTheSameState(uint256 rawApproved, uint256 rawWhole, uint256 rawPart)
        public
    {
        uint256 approved = bound(rawApproved, 0, SUPPLY);
        uint256 whole = bound(rawWhole, 0, approved);
        uint256 part = bound(rawPart, 0, whole);
        assertTrue(token.approve(spender, approved));

        uint256 start = vm.snapshotState();
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, whole));
        uint256 allowanceOnce = token.allowance(address(this), spender);
        uint256 recipientOnce = token.balanceOf(alice);

        vm.revertToState(start);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, part));
        assertTrue(token.transferFrom(address(this), alice, whole - part));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), allowanceOnce);
        assertEq(token.balanceOf(alice), recipientOnce);
    }

    function testFuzz_lastApprovalWinsAndRepeatingItChangesNothing(uint256 first, uint256 last) public {
        assertTrue(token.approve(spender, first));
        assertTrue(token.approve(spender, last));
        assertEq(token.allowance(address(this), spender), last);
        assertTrue(token.approve(spender, last));
        assertEq(token.allowance(address(this), spender), last);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    /// @dev Pulls that fit succeed and pulls that do not revert, in any order. What arrived plus what
    /// is still allowed is what was granted, however the spender cut it up.
    function testFuzz_repeatedPullsNeverExceedTheGrant(uint256 rawGrant, uint256[8] calldata rawPulls) public {
        uint256 grant = bound(rawGrant, 0, SUPPLY - 1);
        assertTrue(token.approve(spender, grant));

        for (uint256 i; i < rawPulls.length; ++i) {
            uint256 left = token.allowance(address(this), spender);
            uint256 pull = bound(rawPulls[i], 0, left + 1);
            vm.prank(spender);
            (bool ok, bytes memory returned) = _spend(address(this), alice, pull);
            assertEq(ok, pull <= left);
            if (!ok) {
                assertEq(
                    returned,
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, left, pull)
                );
            }
            assertEq(token.balanceOf(alice) + token.allowance(address(this), spender), grant);
        }
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice), SUPPLY);
    }

    function testFuzz_infiniteAllowanceIsNeverConsumed(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        assertTrue(token.approve(spender, MAX));
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertTrue(token.transferFrom(address(this), alice, SUPPLY - amount));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), MAX);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    /// @dev Here the allowance is enough and the balance is not, the case the accepted fuzz tests do
    /// not reach, finite and infinite alike. The allowance must survive the failure.
    function testFuzz_spendOverBalanceRevertsWhateverTheAllowance(uint256 rawBalance, uint256 rawAmount, bool infinite)
        public
    {
        uint256 balance = bound(rawBalance, 0, SUPPLY);
        uint256 amount = bound(rawAmount, balance + 1, MAX);
        uint256 approved = infinite ? MAX : amount;
        assertTrue(token.transfer(alice, balance));
        vm.prank(alice);
        assertTrue(token.approve(spender, approved));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), approved);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Owner, spender and recipient drawn from three addresses, so they coincide about as often
    /// as not. No aliasing may create or lose a token, and the allowance moves by the amount or not at all.
    function testFuzz_aliasedPartiesConserveTokens(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 rawApproved,
        uint256 rawAmount
    ) public {
        address[3] memory parties = [alice, bob, spender];
        address owner = parties[ownerSeed % 3];
        address operator = parties[spenderSeed % 3];
        address to = parties[toSeed % 3];
        uint256 approved = bound(rawApproved, 0, SUPPLY);
        uint256 amount = bound(rawAmount, 0, approved);

        assertTrue(token.transfer(owner, SUPPLY));
        vm.prank(owner);
        assertTrue(token.approve(operator, approved));
        vm.prank(operator);
        assertTrue(token.transferFrom(owner, to, amount));

        assertEq(token.allowance(owner, operator), approved - amount);
        assertEq(token.balanceOf(to), owner == to ? SUPPLY : amount);
        assertEq(token.balanceOf(owner), owner == to ? SUPPLY : SUPPLY - amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(spender), SUPPLY);
    }

    function testFuzz_callsLeaveThirdPartiesUntouched(address bystander, uint256 rawAmount, uint256 rawHeld) public {
        bystander = _elsewhere(bystander);
        if (bystander == alice || bystander == bob || bystander == spender) bystander = address(token);
        uint256 amount = bound(rawAmount, 0, SUPPLY / 4);
        uint256 held = bound(rawHeld, 0, SUPPLY / 4);

        assertTrue(token.transfer(bystander, held));
        vm.prank(bystander);
        assertTrue(token.approve(spender, 77));
        assertTrue(token.approve(spender, amount));

        assertTrue(token.transfer(alice, amount / 2));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, amount));
        vm.prank(alice);
        assertTrue(token.approve(bob, amount));

        assertEq(token.balanceOf(bystander), held);
        assertEq(token.allowance(bystander, spender), 77);
        assertEq(token.allowance(bystander, alice), 0);
    }

    /// @dev The accepted suite tries seventeen names. This tries any selector that is not in the ABI,
    /// from any caller, with any arguments.
    function testFuzz_callsOutsideTheAbiFailAndChangeNothing(address caller, bytes4 rawSelector, bytes calldata args)
        public
    {
        assertTrue(token.transfer(alice, 10 ether));
        assertTrue(token.approve(spender, 3 ether));
        bytes4 selector = _isAbi(rawSelector) ? bytes4(keccak256(abi.encode(rawSelector))) : rawSelector;

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));

        assertFalse(ok, "the token answered a selector outside its ABI");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.allowance(address(this), spender), 3 ether);
    }

    function testFuzz_aHolderCanLeaveWithEverythingAtAnyTime(address holder, uint256 rawAmount, uint40 when) public {
        holder = _elsewhere(holder);
        uint256 amount = bound(rawAmount, 1, SUPPLY);
        assertTrue(token.transfer(holder, amount));
        vm.warp(when);
        address to = holder == bob ? alice : bob;
        vm.prank(holder);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(to), amount);
    }

    /// @dev The whole launch in one transaction, over every pool share the requester's ninety percent
    /// allows, including none and all of it.
    function testFuzz_launchFlowsArriveWhole(uint256 rawPoolBps, bytes32 salt) public {
        uint256 poolBps = bound(rawPoolBps, 0, 9_000);
        address distributor = makeAddr("distributor");
        address pool = makeAddr("poolManager");
        address remainder = makeAddr("remainder");
        LaunchFlowProbe probe = new LaunchFlowProbe();

        IMDwindowshopper launched = probe.launch(salt, distributor, pool, remainder, poolBps);

        assertEq(launched.balanceOf(address(probe)), 0);
        assertEq(launched.balanceOf(distributor), SUPPLY / 10);
        assertEq(launched.balanceOf(pool), SUPPLY * poolBps / 10_000);
        assertEq(launched.balanceOf(remainder), SUPPLY * (9_000 - poolBps) / 10_000);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    /// @dev Equal claims against the distributor pay every claimant in full and strand only the
    /// remainder of the division, which is the distributor's rounding and not the token's.
    function testFuzz_distributorClaimsPayInFull(uint256 rawClaimants) public {
        uint256 claimants = bound(rawClaimants, 1, 64);
        address distributor = makeAddr("distributor");
        uint256 swarm = SUPPLY / 10;
        assertTrue(token.transfer(distributor, swarm));

        uint256 share = swarm / claimants;
        for (uint256 i; i < claimants; ++i) {
            address claimant = address(uint160(0x10000 + i));
            vm.prank(distributor);
            assertTrue(token.transfer(claimant, share));
            assertEq(token.balanceOf(claimant), share);
        }
        assertLt(token.balanceOf(distributor), claimants);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _spend(address from, address to, uint256 amount) private returns (bool, bytes memory) {
        return address(token).call(abi.encodeCall(token.transferFrom, (from, to, amount)));
    }

    /// @dev A valid counterparty that is neither this contract nor the zero address.
    function _elsewhere(address account) private view returns (address) {
        if (account == address(0) || account == address(this)) return alice;
        return account;
    }

    function _isAbi(bytes4 selector) private view returns (bool) {
        return selector == token.name.selector || selector == token.symbol.selector
            || selector == token.decimals.selector || selector == token.totalSupply.selector
            || selector == token.INITIAL_SUPPLY.selector || selector == token.balanceOf.selector
            || selector == token.allowance.selector || selector == token.transfer.selector
            || selector == token.approve.selector || selector == token.transferFrom.selector;
    }
}
