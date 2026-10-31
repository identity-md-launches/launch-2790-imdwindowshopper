// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDwindowshopper} from "../src/IMDwindowshopper.sol";

/// @dev All tokens stay within four test actors. An independent ledger models every operation,
/// including rejected spends and finite/infinite allowances, without querying token balances.
contract TokenHandler is Test {
    IMDwindowshopper public immutable token;
    address[4] public actors;
    uint256[4] public balances;
    uint256[4][4] public allowances;

    constructor(IMDwindowshopper token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("invariant actor", i)))));
        }
        balances[0] = 1_000_000_000 * 10 ** 18;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        uint256 from = fromSeed % actors.length;
        uint256 to = toSeed % actors.length;
        uint256 amount = bound(rawAmount, 0, balances[from]);
        balances[from] -= amount;
        balances[to] += amount;
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount, bool unlimited) external {
        uint256 owner = ownerSeed % actors.length;
        uint256 spender = spenderSeed % actors.length;
        uint256 amount = unlimited ? type(uint256).max : bound(rawAmount, 0, 1_000_000_000 * 10 ** 18);
        allowances[owner][spender] = amount;
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount) external {
        uint256 owner = ownerSeed % actors.length;
        uint256 spender = spenderSeed % actors.length;
        uint256 to = toSeed % actors.length;
        uint256 approved = allowances[owner][spender];
        uint256 maximum = balances[owner] < approved ? balances[owner] : approved;
        uint256 amount = bound(rawAmount, 0, maximum);
        if (approved != type(uint256).max) allowances[owner][spender] -= amount;
        balances[owner] -= amount;
        balances[to] += amount;
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[owner], actors[to], amount));
    }

    function rejectedSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        uint256 owner = ownerSeed % actors.length;
        uint256 spender = spenderSeed % actors.length;
        uint256 to = toSeed % actors.length;
        // Always exceeds balance, regardless of whether allowance would permit it.
        uint256 amount = balances[owner] + 1;
        vm.prank(actors[spender]);
        (bool success,) = address(token).call(abi.encodeCall(token.transferFrom, (actors[owner], actors[to], amount)));
        assertFalse(success, "spending more than a holder owns must fail");
    }
}

contract IMDwindowshopperInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    IMDwindowshopper private token;
    TokenHandler private handler;

    function setUp() public {
        token = new IMDwindowshopper();
        handler = new TokenHandler(token);
        assertTrue(token.transfer(handler.actors(0), SUPPLY));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        selectors[3] = TokenHandler.rejectedSpend.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyIsFixedAndAllTokensAreAccountedFor() public view {
        assertEq(token.totalSupply(), SUPPLY);
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function invariant_balancesAndAllowancesMatchModel() public view {
        for (uint256 i; i < 4; ++i) {
            assertEq(token.balanceOf(handler.actors(i)), handler.balances(i));
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(handler.actors(i), handler.actors(j)), handler.allowances(i, j));
            }
        }
    }
}
