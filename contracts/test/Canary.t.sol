// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { BaitToken } from "../BaitToken.sol";
import { EscapeVault } from "../EscapeVault.sol";
import { CanaryWatcher } from "../CanaryWatcher.sol";
import { IReactive } from "../lib/reactive-lib/src/interfaces/IReactive.sol";
import { IPayable } from "../lib/reactive-lib/src/interfaces/IPayable.sol";
import { ISystemContract } from "../lib/reactive-lib/src/interfaces/ISystemContract.sol";

/// Minimal stand-in for the Reactive system contract (0x8888...8888) and the destination callback proxy.
contract MockSystem {
    uint256 public subscriptions;
    ISystemContract.CallbackConfiguration_V_1_0[] internal queue;

    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptions++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        queue.push(config_);
    }

    function callbacks() external view returns (uint256) {
        return queue.length;
    }

    function callback(uint256 i) external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return queue[i];
    }
}

contract CanaryTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant BASE = 84532; // Base Sepolia
    uint256 constant UNICHAIN = 1301; // Unichain Sepolia
    address constant PROXY = address(0xCA11BAC);
    address constant CANARY = address(0xCA9A21);
    address constant COLD = address(0xC01D);
    address constant THIEF = address(0xBAD);
    address constant SHOP = address(0x5109);
    uint64 constant DELAY = 10 minutes;

    MockSystem sys;
    CanaryWatcher watcher;
    BaitToken bait;
    BaitToken savings;
    EscapeVault vault;
    bytes32 key;

    function setUp() public {
        MockSystem impl = new MockSystem();
        vm.etch(SYSTEM, address(impl).code);
        sys = MockSystem(payable(SYSTEM));

        watcher = new CanaryWatcher();
        bait = new BaitToken(CANARY, 5 ether);
        vault = new EscapeVault{ value: 10 ether }(IPayable(payable(PROXY)), address(watcher), COLD, DELAY);
        savings = new BaitToken(address(vault), 250 ether);
        vault.trackToken(address(savings));

        key = watcher.arm(BASE, address(bait), CANARY);
        watcher.protect(key, BASE, address(vault));
        vm.warp(1_800_000_000);
    }

    function _log(uint256 topic0, address from, address to, uint256 amount)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: BASE,
            contractAddress: address(bait),
            topic0: topic0,
            topic1: uint256(uint160(from)),
            topic2: uint256(uint160(to)),
            topic3: 0,
            data: abi.encode(amount),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _react(IReactive.LogRecord memory log_) internal {
        vm.prank(SYSTEM);
        watcher.react(log_);
    }

    /// Delivers a queued callback the way the callback proxy does: the Reactive Network overwrites the first
    /// argument with the address of the reactive contract that requested it.
    function _deliver(uint256 i) internal returns (bool ok) {
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = sys.callback(i);
        bytes memory payload = cb.payload;
        bytes32 sender = bytes32(uint256(uint160(address(watcher))));
        assembly {
            mstore(add(payload, 36), sender)
        }
        vm.prank(PROXY);
        (ok,) = cb.recipient.call(payload);
    }

    function test_armSubscribesToTransferAndApprovalOnce() public {
        assertEq(sys.subscriptions(), 2);
        watcher.arm(BASE, address(bait), CANARY);
        assertEq(sys.subscriptions(), 2);
    }

    function test_baitMovedEvacuatesEthAndTokensToColdWallet() public {
        _react(_log(watcher.TRANSFER_TOPIC(), CANARY, THIEF, 5 ether));
        assertEq(sys.callbacks(), 1);
        assertEq(sys.callback(0).chainId, BASE);
        assertEq(sys.callback(0).recipient, address(vault));

        assertTrue(_deliver(0));
        assertTrue(vault.evacuated());
        assertEq(COLD.balance, 10 ether);
        assertEq(address(vault).balance, 0);
        assertEq(savings.balanceOf(COLD), 250 ether);
        assertTrue(watcher.tripped(key));
    }

    function test_approvalByCanaryAlsoTrips() public {
        _react(_log(watcher.APPROVAL_TOPIC(), CANARY, THIEF, type(uint256).max));
        assertEq(sys.callbacks(), 1);
    }

    function test_transfersFromOtherAddressesAreIgnored() public {
        _react(_log(watcher.TRANSFER_TOPIC(), THIEF, CANARY, 1 ether)); // someone sends the canary more bait
        _react(_log(uint256(keccak256("Other(address)")), CANARY, THIEF, 1));
        assertEq(sys.callbacks(), 0);
        assertFalse(watcher.tripped(key));
    }

    function test_tripsOnlyOnceUntilReset() public {
        _react(_log(watcher.TRANSFER_TOPIC(), CANARY, THIEF, 1 ether));
        _react(_log(watcher.TRANSFER_TOPIC(), CANARY, THIEF, 1 ether));
        assertEq(sys.callbacks(), 1);

        watcher.reset(key);
        _react(_log(watcher.TRANSFER_TOPIC(), CANARY, THIEF, 1 ether));
        assertEq(sys.callbacks(), 2);
    }

    function test_oneCanaryProtectsVaultsOnSeveralChains() public {
        EscapeVault other = new EscapeVault{ value: 3 ether }(IPayable(payable(PROXY)), address(watcher), COLD, DELAY);
        watcher.protect(key, UNICHAIN, address(other));

        _react(_log(watcher.TRANSFER_TOPIC(), CANARY, THIEF, 5 ether));
        assertEq(sys.callbacks(), 2);
        assertEq(sys.callback(1).chainId, UNICHAIN);
        assertEq(sys.callback(1).recipient, address(other));
        assertTrue(_deliver(0));
        assertTrue(_deliver(1));
        assertEq(COLD.balance, 13 ether);
    }

    function test_onlyTheWatcherThroughTheProxyCanEvacuate() public {
        vm.expectRevert();
        vault.evacuate(address(watcher), CANARY, BASE); // not the callback proxy

        vm.prank(PROXY);
        vm.expectRevert();
        vault.evacuate(THIEF, CANARY, BASE); // proxy, but another reactive contract asked
        assertFalse(vault.evacuated());
    }

    function test_onlySystemCanReact() public {
        IReactive.LogRecord memory log_ = _log(watcher.TRANSFER_TOPIC(), CANARY, THIEF, 1 ether);
        vm.expectRevert();
        watcher.react(log_);
    }

    function test_ownerSpendsThroughTheTimeLock() public {
        vault.requestWithdraw(SHOP, 1 ether);
        vm.expectRevert(EscapeVault.NotReady.selector);
        vault.executeWithdraw();

        vm.warp(block.timestamp + DELAY);
        vault.executeWithdraw();
        assertEq(SHOP.balance, 1 ether);
    }

    function test_thiefWithTheOwnerKeyLosesTheRace() public {
        // The thief holds the seed: they queue a withdrawal with the owner key and sweep the bait.
        vault.requestWithdraw(THIEF, 10 ether);
        _react(_log(watcher.TRANSFER_TOPIC(), CANARY, THIEF, 5 ether));
        assertTrue(_deliver(0));

        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(EscapeVault.NothingPending.selector);
        vault.executeWithdraw();
        vm.expectRevert(EscapeVault.AlreadyEvacuated.selector);
        vault.requestWithdraw(THIEF, 1);
        assertEq(THIEF.balance, 0);
        assertEq(COLD.balance, 10 ether);
    }

    function test_strangersCannotConfigure() public {
        vm.startPrank(THIEF);
        vm.expectRevert(CanaryWatcher.NotOwner.selector);
        watcher.protect(key, BASE, THIEF);
        vm.expectRevert(CanaryWatcher.NotOwner.selector);
        watcher.reset(key);
        vm.expectRevert(EscapeVault.NotOwner.selector);
        vault.requestWithdraw(THIEF, 1 ether);
        vm.expectRevert(EscapeVault.NotOwner.selector);
        vault.rearm();
        vm.stopPrank();
    }

    function test_rearmAfterRotatingKeys() public {
        _react(_log(watcher.TRANSFER_TOPIC(), CANARY, THIEF, 5 ether));
        assertTrue(_deliver(0));
        vault.rearm();
        assertFalse(vault.evacuated());
        vm.deal(address(vault), 2 ether);
        vault.requestWithdraw(SHOP, 1 ether);
        vm.warp(block.timestamp + DELAY);
        vault.executeWithdraw();
        assertEq(SHOP.balance, 1 ether);
    }
}
