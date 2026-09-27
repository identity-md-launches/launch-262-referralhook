// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {REFR} from "../src/REFR.sol";
import {ReferralHook} from "../src/ReferralHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract ReferralHandler is Test {
    ReferralHook public immutable hook;
    PoolSwapTest private immutable router;
    IPoolManager public immutable manager;
    PoolKey[2] private keys;
    address[4] public referrers = [address(0x10001), address(0x10002), address(0x10003), address(0x10004)];
    uint256[4] public earned;
    uint256[4] public paid;
    uint256[4] public volume;
    uint256[4] public count;
    uint256[4][2] public poolEarned;
    uint256[4][2] public poolVolume;
    uint256[4][2] public poolCount;
    uint256 public totalEarned;
    uint256 public totalPaid;
    uint256 public swapCalls;

    constructor(ReferralHook hook_, PoolSwapTest router_, PoolKey memory a, PoolKey memory b) {
        hook = hook_;
        router = router_;
        manager = hook_.poolManager();
        keys[0] = a;
        keys[1] = b;
        REFR(Currency.unwrap(a.currency1)).approve(address(router), type(uint256).max);
        REFR(Currency.unwrap(b.currency1)).approve(address(router), type(uint256).max);
    }

    function swap(uint256 poolSeed, uint256 sizeSeed, uint256 modeSeed, uint256 referralSeed) external {
        uint256 poolIndex = poolSeed % 2;
        uint256 mode = modeSeed % 4;
        bool buy = mode < 2;
        bool exactInput = mode % 2 == 0;
        bool ethSpecified = buy == exactInput;
        uint256 size = bound(sizeSeed, 1, ethSpecified ? 0.0001 ether : 1000 ether);
        int256 amount = exactInput ? -int256(size) : int256(size);
        // Modes 0..3 are tracked referrers. Modes 4..9 are invalid referral data.
        uint256 ref = referralSeed % 10;
        bytes memory data = ref < 4
            ? abi.encode(referrers[ref])
            : ref == 4
                ? bytes("")
                : ref == 5
                    ? abi.encode(address(0))
                    : ref == 6
                        ? abi.encode(address(hook))
                        : ref == 7
                            ? abi.encode(address(manager))
                            : ref == 8 ? abi.encode(address(0x7777)) : abi.encode(type(uint256).max);
        vm.recordLogs();
        vm.prank(address(this), address(0x7777));
        BalanceDelta delta = router.swap{value: buy ? 1 ether : 0}(
            keys[poolIndex],
            SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            data
        );
        assertEq(ethSpecified ? int256(delta.amount0()) : int256(delta.amount1()), amount);
        uint256 ethLeg = ethSpecified ? size : _poolEthLeg(vm.getRecordedLogs());
        if (ref < 4) {
            uint256 reward = ethLeg * 20 / 10_000;
            earned[ref] += reward;
            volume[ref] += ethLeg;
            count[ref]++;
            poolEarned[poolIndex][ref] += reward;
            poolVolume[poolIndex][ref] += ethLeg;
            poolCount[poolIndex][ref]++;
            totalEarned += reward;
        }
        swapCalls++;
    }

    function claim(uint256 refSeed) public {
        uint256 ref = refSeed % 4;
        uint256 beforeEth = referrers[ref].balance;
        vm.prank(referrers[ref]);
        uint256 amount = hook.claim();
        assertEq(amount, earned[ref] - paid[ref]);
        assertEq(referrers[ref].balance - beforeEth, amount);
        paid[ref] += amount;
        totalPaid += amount;
    }

    function _poolEthLeg(Vm.Log[] memory logs) private view returns (uint256) {
        bytes32 signature = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == signature) {
                (int128 amount0,,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return uint256(amount0 < 0 ? -int256(amount0) : int256(amount0));
            }
        }
        revert("missing manager swap event");
    }

    receive() external payable {}
}

contract ReferralInvariantTest is Fixture {
    using TransientStateLibrary for IPoolManager;
    ReferralHandler private handler;
    PoolKey private secondKey;

    function setUp() public override {
        super.setUp();
        _bootstrap();
        REFR second = new REFR();
        second.transfer(address(factory), factory.SEED_AMOUNT());
        secondKey = key;
        secondKey.currency1 = Currency.wrap(address(second));
        factory.seed(secondKey, factory.SEED_AMOUNT());
        _swapKey(secondKey, true, -0.2 ether, "");
        handler = new ReferralHandler(hook, router, key, secondKey);
        token.transfer(address(handler), 50_000_000 ether);
        second.transfer(address(handler), 50_000_000 ether);
        vm.deal(address(handler), 1000 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = ReferralHandler.swap.selector;
        selectors[1] = ReferralHandler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_sumOfBalancesEqualsEthClaims() public view {
        uint256 totalOwed;
        for (uint256 i; i < 4; ++i) {
            address ref = handler.referrers(i);
            uint256 owed = hook.balanceOf(ref);
            assertEq(owed, handler.earned(i) - handler.paid(i));
            assertEq(hook.referredVolume(ref), handler.volume(i));
            assertEq(hook.referralCount(ref), handler.count(i));
            totalOwed += owed;
            for (uint256 pool; pool < 2; ++pool) {
                (uint256 volume, uint256 count, uint256 earned) =
                    hook.poolReferrals(pool == 0 ? key.toId() : secondKey.toId(), ref);
                assertEq(volume, handler.poolVolume(pool, i));
                assertEq(count, handler.poolCount(pool, i));
                assertEq(earned, handler.poolEarned(pool, i));
            }
        }
        assertEq(totalOwed, manager.balanceOf(address(hook), 0));
        assertEq(totalOwed, handler.totalEarned() - handler.totalPaid());
        assertGe(address(manager).balance, totalOwed);
        assertEq(address(hook).balance, 0);
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0);
        assertFalse(IPoolManager(address(manager)).isUnlocked());
    }

    function afterInvariant() public {
        for (uint256 i; i < 4; ++i) {
            handler.claim(i);
        }
        assertEq(handler.totalEarned(), handler.totalPaid());
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }
}
