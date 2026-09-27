// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {ReferralHook} from "../src/ReferralHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract ClaimReceiver {
    ReferralHook public immutable hook;
    IPoolManager public immutable manager;
    PoolKey private key;
    bool public reject;
    bool public reenter;
    bool public swapOnReceive;
    bool public nestedClaimSucceeded;
    uint256 public reentrantPayment;
    uint256 public balanceAtReceive;
    uint256 public claimsAtReceive;

    constructor(ReferralHook hook_, PoolKey memory key_) {
        hook = hook_;
        manager = hook_.poolManager();
        key = key_;
    }

    function configure(bool reject_, bool reenter_, bool swapOnReceive_) external {
        reject = reject_;
        reenter = reenter_;
        swapOnReceive = swapOnReceive_;
    }

    function claim() external returns (uint256) {
        return hook.claim();
    }

    function claimWhileUnlocked() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        hook.claim();
        return "";
    }

    receive() external payable {
        require(!reject, "reject ETH");
        balanceAtReceive = hook.balanceOf(address(this));
        claimsAtReceive = manager.balanceOf(address(hook), 0);
        if (reenter) reentrantPayment = hook.claim();
        if (swapOnReceive) {
            // Reenter the actual manager while the claim unlock is active. No router unlock.
            BalanceDelta delta = manager.swap(
                key,
                SwapParams(true, -int256(msg.value / 2), TickMath.MIN_SQRT_PRICE + 1),
                abi.encode(address(this))
            );
            manager.sync(key.currency0);
            manager.settle{value: uint256(-int256(delta.amount0()))}();
            manager.take(key.currency1, address(this), uint256(int256(delta.amount1())));
            try hook.claim() returns (uint256) {
                nestedClaimSucceeded = true;
            } catch {}
        }
    }
}

contract ClaimsTest is Fixture {
    event Claimed(address indexed referrer, uint256 amount);

    function test_claimPaysExactlyOnceAndEmitsEvent() public {
        _swap(true, -0.01 ether, abi.encode(REFERRER));
        uint256 balance = hook.balanceOf(REFERRER);
        uint256 ethBefore = REFERRER.balance;
        uint256 managerBefore = address(manager).balance;
        vm.expectEmit(true, false, false, true, address(hook));
        emit Claimed(REFERRER, balance);
        vm.prank(REFERRER);
        assertEq(hook.claim(), balance);
        assertEq(REFERRER.balance, ethBefore + balance);
        assertEq(address(manager).balance, managerBefore - balance);
        assertEq(hook.balanceOf(REFERRER), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        vm.prank(REFERRER);
        assertEq(hook.claim(), 0);
        assertEq(REFERRER.balance, ethBefore + balance);
        assertEq(hook.referredVolume(REFERRER), 0.01 ether);
        assertEq(hook.referralCount(REFERRER), 1);
    }

    function test_cannotClaimSomeoneElsesDebt() public {
        _swap(true, -0.01 ether, abi.encode(REFERRER));
        uint256 owed = hook.balanceOf(REFERRER);
        assertEq(hook.claim(), 0);
        assertEq(hook.balanceOf(REFERRER), owed);
        assertEq(manager.balanceOf(address(hook), 0), owed);
    }

    function test_rejectingReceiverOnlyBlocksItsOwnClaimAndCanRetry() public {
        ClaimReceiver receiver = new ClaimReceiver(hook, key);
        receiver.configure(true, false, false);
        // Swaps never call the receiver, so both first buy and later swaps succeed.
        _swap(true, -0.01 ether, abi.encode(address(receiver)));
        _swap(true, -0.01 ether, abi.encode(REFERRER));
        uint256 badDebt = hook.balanceOf(address(receiver));
        uint256 goodDebt = hook.balanceOf(REFERRER);
        vm.expectRevert();
        receiver.claim();
        assertEq(hook.balanceOf(address(receiver)), badDebt);
        assertEq(manager.balanceOf(address(hook), 0), badDebt + goodDebt);
        vm.prank(REFERRER);
        hook.claim();
        assertEq(manager.balanceOf(address(hook), 0), badDebt);
        assertEq(REFERRER.balance, goodDebt);
        receiver.configure(false, false, false);
        receiver.claim();
        assertEq(address(receiver).balance, badDebt);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_reentrantClaimSeesZeroBalanceAndBurnedClaims() public {
        ClaimReceiver receiver = new ClaimReceiver(hook, key);
        receiver.configure(false, true, false);
        _swap(true, -0.01 ether, abi.encode(address(receiver)));
        uint256 owed = hook.balanceOf(address(receiver));
        receiver.claim();
        assertEq(address(receiver).balance, owed);
        assertEq(receiver.reentrantPayment(), 0);
        assertEq(receiver.balanceAtReceive(), 0);
        assertEq(receiver.claimsAtReceive(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_nestedSwapDuringClaimCreatesOnlyBackedNewDebt() public {
        ClaimReceiver receiver = new ClaimReceiver(hook, key);
        receiver.configure(false, true, true);
        _swap(true, -0.01 ether, abi.encode(address(receiver)));
        uint256 oldDebt = hook.balanceOf(address(receiver));
        receiver.claim();
        uint256 newDebt = (oldDebt / 2) / 500;
        assertEq(receiver.balanceAtReceive(), 0);
        assertEq(receiver.claimsAtReceive(), 0);
        assertEq(receiver.reentrantPayment(), 0);
        assertFalse(receiver.nestedClaimSucceeded());
        assertEq(hook.balanceOf(address(receiver)), newDebt);
        assertEq(manager.balanceOf(address(hook), 0), newDebt);
        assertEq(hook.referralCount(address(receiver)), 2);
        receiver.configure(false, false, false);
        receiver.claim();
        assertEq(address(receiver).balance, oldDebt - oldDebt / 2 + newDebt);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_claimDuringExistingUnlockRevertsWithoutLosingDebt() public {
        ClaimReceiver receiver = new ClaimReceiver(hook, key);
        _swap(true, -0.01 ether, abi.encode(address(receiver)));
        uint256 owed = hook.balanceOf(address(receiver));
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        receiver.claimWhileUnlocked();
        assertEq(hook.balanceOf(address(receiver)), owed);
        assertEq(manager.balanceOf(address(hook), 0), owed);
        receiver.claim();
        assertEq(address(receiver).balance, owed);
    }

    function testFuzz_manyReferrersAndInterleavedClaims(uint96[8] memory sizes) public {
        uint256 total;
        for (uint256 i; i < sizes.length; ++i) {
            uint256 size = bound(sizes[i], 1, 0.01 ether);
            address referrer = address(uint160(0x10000 + i));
            _swap(true, -int256(size), abi.encode(referrer));
            total += size / 500;
            assertEq(manager.balanceOf(address(hook), 0), total);
            if (i % 2 == 0) {
                vm.prank(referrer);
                uint256 paid = hook.claim();
                assertEq(paid, size / 500);
                total -= paid;
                assertEq(manager.balanceOf(address(hook), 0), total);
            }
        }
        for (uint256 i; i < sizes.length; ++i) {
            address referrer = address(uint160(0x10000 + i));
            vm.prank(referrer);
            total -= hook.claim();
            assertEq(manager.balanceOf(address(hook), 0), total);
        }
        assertEq(total, 0);
    }
}
