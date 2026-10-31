// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDwindowshopper} from "../src/IMDwindowshopper.sol";

/// @dev An actor that holds tokens but refuses every call, so a token that touched a holder would fail.
contract RefusingHolder {
    fallback() external payable {
        revert("holder was called");
    }
}

/// @dev Drives the token with bounded inputs from several actors, successes and rejections alike, and
/// keeps two ledgers that never read a balance back: one applied from what each operation should do,
/// one replayed from the logs the token actually emitted. Recipients are open-ended, so unlike the
/// accepted handler's four actors the set of holders can grow to any address, the token itself included.
contract LedgerHandler is Test {
    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 private constant MAX = type(uint256).max;
    uint256 private constant ACTORS = 5;

    IMDwindowshopper public token;
    address[ACTORS] public actors;
    address[] public holders;
    mapping(address => bool) private isHolder;

    mapping(address => uint256) public modelBalance;
    mapping(address => mapping(address => uint256)) public modelAllowance;
    mapping(address => uint256) public eventBalance;
    uint256 public eventSupply;

    uint256 public moves;
    uint256 public approvals;
    uint256 public rejections;
    uint256 public callsRefused;

    /// @dev Deploys the token here, so the event ledger starts from the real constructor mint and not
    /// from an assumption about it, then spreads the supply so every actor has something to spend.
    constructor() {
        actors[0] = makeAddr("first holder");
        actors[1] = makeAddr("second holder");
        actors[2] = makeAddr("third holder");
        actors[3] = makeAddr("fourth holder");
        actors[4] = address(new RefusingHolder());
        for (uint256 i; i < ACTORS; ++i) {
            _track(actors[i]);
        }
        _track(address(this));

        vm.recordLogs();
        token = new IMDwindowshopper();
        assertEq(_replay(), 1);
        modelBalance[address(this)] = SUPPLY;

        uint256 share = SUPPLY / ACTORS;
        for (uint256 i; i < ACTORS; ++i) {
            vm.recordLogs();
            assertTrue(token.transfer(actors[i], share));
            assertEq(_replay(), 1);
            _applyMove(address(this), actors[i], share);
        }
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    // ---------------------------------------------------------------- operations that must succeed

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), _within(rawAmount, modelBalance[from]));
    }

    function transferToAnyone(uint256 fromSeed, address to, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        if (to == address(0)) to = address(1);
        _track(to);
        _transfer(from, to, _within(rawAmount, modelBalance[from]));
    }

    function transferToTheToken(uint256 fromSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        _track(address(token));
        _transfer(from, address(token), _within(rawAmount, modelBalance[from]));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _anyAllowance(rawAmount);

        vm.recordLogs();
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(_replay(), 1, "approve must emit exactly one Approval");

        modelAllowance[owner][spender] = amount;
        ++approvals;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 approved = modelAllowance[owner][spender];
        uint256 held = modelBalance[owner];
        uint256 amount = _within(rawAmount, held < approved ? held : approved);

        vm.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        assertEq(_replay(), 1, "a spend must emit one Transfer and no Approval");

        if (approved != MAX) modelAllowance[owner][spender] = approved - amount;
        _applyMove(owner, to, amount);
        ++moves;
    }

    // ---------------------------------------------------------------- operations that must fail

    function rejectTransferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = _actor(fromSeed);
        uint256 held = modelBalance[from];
        uint256 amount = _above(rawAmount, held);
        _expectRejected(
            from,
            abi.encodeCall(token.transfer, (_actor(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount)
        );
    }

    function rejectTransferToZero(uint256 fromSeed, uint256 rawAmount) external {
        _expectRejected(
            _actor(fromSeed),
            abi.encodeCall(token.transfer, (address(0), rawAmount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    /// @dev Reachable with a balance that would cover it: the existing handler's rejected spend always
    /// exceeds the balance and so never tests the allowance alone.
    function rejectSpendOverAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 approved = modelAllowance[owner][spender];
        if (approved == MAX) return;
        uint256 amount = _above(rawAmount, approved);
        _expectRejected(
            spender,
            abi.encodeCall(token.transferFrom, (owner, _actor(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
    }

    function rejectSpendOverBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 approved = modelAllowance[owner][spender];
        uint256 held = modelBalance[owner];
        if (approved <= held) return;
        uint256 amount = bound(rawAmount, held + 1, approved);
        _expectRejected(
            spender,
            abi.encodeCall(token.transferFrom, (owner, _actor(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount)
        );
    }

    function rejectSpendToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 approved = modelAllowance[owner][spender];
        uint256 held = modelBalance[owner];
        _expectRejected(
            spender,
            abi.encodeCall(
                token.transferFrom, (owner, address(0), _within(rawAmount, held < approved ? held : approved))
            ),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function rejectApproveZero(uint256 ownerSeed, uint256 rawAmount) external {
        _expectRejected(
            _actor(ownerSeed),
            abi.encodeCall(token.approve, (address(0), rawAmount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
    }

    function rejectPullFromTheToken(uint256 callerSeed, uint256 toSeed, uint256 rawAmount) external {
        address caller = _actor(callerSeed);
        uint256 amount = bound(rawAmount, 1, MAX);
        _expectRejected(
            caller,
            abi.encodeCall(token.transferFrom, (address(token), _actor(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, caller, 0, amount)
        );
    }

    /// @dev A selector outside the ABI, or the ABI with value attached. Neither may do anything.
    function refuseUnknownCall(uint256 callerSeed, bytes4 selector, bytes calldata args, uint256 rawValue) external {
        address caller = _actor(callerSeed);
        if (_isAbi(selector)) selector = bytes4(keccak256(abi.encode(selector)));
        uint256 value = bound(rawValue, 0, 1 ether);
        vm.deal(caller, value);
        vm.recordLogs();
        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}(abi.encodePacked(selector, args));
        assertFalse(ok, "the token answered a call outside its ABI");
        assertEq(vm.getRecordedLogs().length, 0, "a refused call emitted a log");
        ++callsRefused;
    }

    function refuseEther(uint256 callerSeed, uint256 rawValue) external {
        address caller = _actor(callerSeed);
        uint256 value = bound(rawValue, 1, 1 ether);
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted ether");
        ++callsRefused;
    }

    // ---------------------------------------------------------------- internals

    function _transfer(address from, address to, uint256 amount) private {
        vm.recordLogs();
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        assertEq(_replay(), 1, "a transfer must emit exactly one Transfer");
        _applyMove(from, to, amount);
        ++moves;
    }

    function _expectRejected(address caller, bytes memory data, bytes memory expected) private {
        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory returned) = address(token).call(data);
        assertFalse(ok, "a call that must fail succeeded");
        assertEq(returned, expected, "failed for the wrong reason");
        assertEq(vm.getRecordedLogs().length, 0, "a rejected call emitted a log");
        ++rejections;
    }

    function _applyMove(address from, address to, uint256 amount) private {
        modelBalance[from] -= amount;
        modelBalance[to] += amount;
    }

    function _replay() private returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        count = logs.length;
        for (uint256 i; i < count; ++i) {
            assertEq(logs[i].emitter, address(token));
            if (logs[i].topics[0] == APPROVAL_TOPIC) continue;
            assertEq(logs[i].topics[0], TRANSFER_TOPIC);
            address from = address(uint160(uint256(logs[i].topics[1])));
            address to = address(uint160(uint256(logs[i].topics[2])));
            uint256 value = abi.decode(logs[i].data, (uint256));
            if (from == address(0)) eventSupply += value;
            else eventBalance[from] -= value;
            if (to == address(0)) eventSupply -= value;
            else eventBalance[to] += value;
        }
    }

    function _track(address account) private {
        if (isHolder[account]) return;
        isHolder[account] = true;
        holders.push(account);
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % ACTORS];
    }

    /// @dev An amount in [0, ceiling], hitting 0, 1 and the ceiling far more often than chance would.
    function _within(uint256 raw, uint256 ceiling) private pure returns (uint256) {
        uint256 pick = raw % 8;
        if (pick == 0 || ceiling == 0) return 0;
        if (pick == 1) return 1;
        if (pick == 2) return ceiling;
        if (pick == 3) return ceiling - 1;
        return bound(raw, 0, ceiling);
    }

    /// @dev An amount above `floor`, hitting one wei over and the maximum far more often than chance would.
    function _above(uint256 raw, uint256 floor) private pure returns (uint256) {
        uint256 pick = raw % 4;
        if (pick == 0) return floor + 1;
        if (pick == 1) return MAX;
        return bound(raw, floor + 1, MAX);
    }

    /// @dev Allowances around the two boundaries that matter: the supply and the infinite marker.
    function _anyAllowance(uint256 raw) private pure returns (uint256) {
        uint256 pick = raw % 8;
        if (pick == 0) return 0;
        if (pick == 1) return 1;
        if (pick == 2) return SUPPLY;
        if (pick == 3) return SUPPLY + 1;
        if (pick == 4) return MAX - 1;
        if (pick == 5) return MAX;
        return bound(raw, 0, SUPPLY);
    }

    function _isAbi(bytes4 selector) private view returns (bool) {
        return selector == token.name.selector || selector == token.symbol.selector
            || selector == token.decimals.selector || selector == token.totalSupply.selector
            || selector == token.INITIAL_SUPPLY.selector || selector == token.balanceOf.selector
            || selector == token.allowance.selector || selector == token.transfer.selector
            || selector == token.approve.selector || selector == token.transferFrom.selector;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract IMDwindowshopperLedgerInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 private constant ACTORS = 5;

    IMDwindowshopper private token;
    LedgerHandler private handler;

    function setUp() public {
        handler = new LedgerHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = LedgerHandler.transfer.selector;
        selectors[1] = LedgerHandler.transferToAnyone.selector;
        selectors[2] = LedgerHandler.transferToTheToken.selector;
        selectors[3] = LedgerHandler.approve.selector;
        selectors[4] = LedgerHandler.transferFrom.selector;
        selectors[5] = LedgerHandler.rejectTransferOverBalance.selector;
        selectors[6] = LedgerHandler.rejectTransferToZero.selector;
        selectors[7] = LedgerHandler.rejectSpendOverAllowance.selector;
        selectors[8] = LedgerHandler.rejectSpendOverBalance.selector;
        selectors[9] = LedgerHandler.rejectSpendToZero.selector;
        selectors[10] = LedgerHandler.rejectApproveZero.selector;
        selectors[11] = LedgerHandler.rejectPullFromTheToken.selector;
        selectors[12] = LedgerHandler.refuseUnknownCall.selector;
        selectors[13] = LedgerHandler.refuseEther.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// GL-01: the supply is the brief's number, whatever has happened.
    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    /// GL-02: everyone who was ever sent anything accounts for every token, none created or lost.
    function invariant_everyHolderSumsToTheSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.holderCount(); ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, SUPPLY);
    }

    /// GL-03: each balance is what the operations should have left there.
    function invariant_balancesMatchTheOperationLedger() public view {
        for (uint256 i; i < handler.holderCount(); ++i) {
            address holder = handler.holders(i);
            assertEq(token.balanceOf(holder), handler.modelBalance(holder));
        }
    }

    /// GL-04: an indexer replaying Transfer logs arrives at the same balances the contract reports.
    function invariant_transferLogsReconstructEveryBalance() public view {
        assertEq(handler.eventSupply(), token.totalSupply());
        for (uint256 i; i < handler.holderCount(); ++i) {
            address holder = handler.holders(i);
            assertEq(token.balanceOf(holder), handler.eventBalance(holder));
        }
    }

    /// GL-05: an allowance moves only by its owner's approval or by a spend, and the maximum never moves.
    function invariant_allowancesMatchTheOperationLedger() public view {
        for (uint256 i; i < ACTORS; ++i) {
            for (uint256 j; j < ACTORS; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.modelAllowance(owner, spender));
            }
        }
    }

    /// GL-06: the zero address can neither hold, grant nor receive anything.
    function invariant_zeroAddressStaysEmpty() public view {
        assertEq(token.balanceOf(address(0)), 0);
        for (uint256 i; i < ACTORS; ++i) {
            assertEq(token.allowance(address(0), handler.actors(i)), 0);
            assertEq(token.allowance(handler.actors(i), address(0)), 0);
        }
    }

    /// GL-07: the token itself grants nobody anything, so what it holds stays where it is.
    function invariant_tokenContractGrantsNoAllowance() public view {
        for (uint256 i; i < ACTORS; ++i) {
            assertEq(token.allowance(address(token), handler.actors(i)), 0);
        }
    }

    /// GL-08: nothing a caller does rewrites what the token says it is.
    function invariant_metadataNeverChanges() public view {
        assertEq(keccak256(bytes(token.name())), keccak256("IMDwindowshopper"));
        assertEq(keccak256(bytes(token.symbol())), keccak256("WWW"));
        assertEq(token.decimals(), 18);
    }

    /// GL-09: the token never takes ether, with or without a call attached.
    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0);
    }

    /// A sequence that did nothing would pass every invariant above.
    function afterInvariant() public view {
        assertGt(handler.moves() + handler.approvals(), 0, "the sequence changed no state");
        assertGt(handler.rejections() + handler.callsRefused(), 0, "the sequence tried nothing that must fail");
    }

    /// @dev Every path of the handler, once, in an order that makes each reachable, so the invariants
    /// above cannot be passing over a branch that never runs. Raw amounts are `_within`'s and
    /// `_anyAllowance`'s picks: 1 is one wei, 2 is the supply, 5 is the infinite allowance.
    function test_everyHandlerPathIsReachableAndChecked() public {
        handler.transfer(0, 1, 1);
        handler.transferToAnyone(0, address(0xABCD), 1);
        handler.transferToAnyone(0, address(0), 1);
        handler.transferToTheToken(0, 1);
        handler.approve(1, 2, 2);
        handler.transferFrom(1, 2, 3, 1);
        handler.approve(3, 2, 5);
        handler.transferFrom(3, 2, 1, 1);
        assertEq(handler.moves(), 6);
        assertEq(handler.approvals(), 2);

        handler.rejectTransferOverBalance(0, 1, 0);
        handler.rejectTransferToZero(0, 1);
        handler.rejectSpendOverAllowance(1, 2, 3, 0);
        handler.rejectSpendToZero(1, 2, 0);
        handler.rejectApproveZero(0, 1);
        handler.rejectPullFromTheToken(0, 1, 1);
        assertEq(handler.rejections(), 6);

        // An allowance of the whole supply over a fifth of it, finite and infinite.
        handler.approve(2, 3, 2);
        handler.rejectSpendOverBalance(2, 3, 1, 0);
        handler.rejectSpendOverBalance(3, 2, 1, 0);
        assertEq(handler.rejections(), 8);

        // The maximum cannot be exceeded, so this one has nothing to try.
        handler.rejectSpendOverAllowance(3, 2, 1, 0);
        assertEq(handler.rejections(), 8);

        handler.refuseUnknownCall(0, 0xdeadbeef, hex"01", 0);
        handler.refuseUnknownCall(0, token.transfer.selector, "", 1);
        handler.refuseEther(0, 1);
        assertEq(handler.callsRefused(), 3);

        invariant_supplyNeverChanges();
        invariant_everyHolderSumsToTheSupply();
        invariant_balancesMatchTheOperationLedger();
        invariant_transferLogsReconstructEveryBalance();
        invariant_allowancesMatchTheOperationLedger();
        invariant_zeroAddressStaysEmpty();
        invariant_tokenContractGrantsNoAllowance();
        invariant_metadataNeverChanges();
        invariant_tokenHoldsNoEther();
        assertGt(token.balanceOf(address(token)), 0, "the locked path moved nothing");
        assertGt(handler.holderCount(), ACTORS + 1, "no stranger was added to the holder set");
    }
}
