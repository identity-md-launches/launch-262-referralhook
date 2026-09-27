// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {HookMiner} from "./helpers/HookMiner.sol";
import {REFR} from "../src/REFR.sol";
import {ReferralHook} from "../src/ReferralHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

contract ReferralHookTest is Fixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    bytes32 private constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant REFERRED_EVENT = keccak256("Referred(address,bytes32,uint256,uint256)");

    function test_launchAndFirstBuyIntoEthlessPool() public {
        assertEq(address(manager).balance, 0);
        assertEq(address(hook).balance, 0);
        assertLe(token.balanceOf(address(manager)), factory.SEED_AMOUNT());
        assertGt(token.balanceOf(address(manager)), factory.SEED_AMOUNT() - 1 ether);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, factory.initialPrice());
        _assertTrade(true, -0.01 ether);
        assertEq(address(manager).balance, 0.01 ether);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0.00002 ether);
    }

    function test_allFourModesHonorAmountsAndFee() public {
        _bootstrap();
        _assertTrade(true, -0.01 ether);
        _assertTrade(true, 1_000_000 ether);
        _assertTrade(false, -1_000_000 ether);
        _assertTrade(false, 0.001 ether);
        assertEq(hook.referralCount(REFERRER), 4);
    }

    function test_firstExactOutputBuyIntoEthlessPool() public {
        assertEq(address(manager).balance, 0);
        _assertTrade(true, 1_000_000 ether);
        assertGt(hook.balanceOf(REFERRER), 0);
    }

    function test_extremeSpecifiedEthAmountsRevertWithoutCredit() public {
        vm.expectRevert();
        router.swap{value: 1 ether}(
            key,
            SwapParams(true, type(int256).min, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(REFERRER)
        );
        vm.expectRevert();
        router.swap(
            key,
            SwapParams(false, type(int256).max, TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(REFERRER)
        );
        assertEq(hook.balanceOf(REFERRER), 0);
        assertEq(hook.referralCount(REFERRER), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function testFuzz_allFourModes(uint128 ethAmount, uint128 tokenAmount) public {
        _bootstrap();
        uint256 ethSize = bound(ethAmount, 1, 0.01 ether);
        uint256 tokenSize = bound(tokenAmount, 1, 1_000_000 ether);
        _assertTrade(true, -int256(ethSize));
        _assertTrade(true, int256(tokenSize));
        _assertTrade(false, -int256(tokenSize));
        _assertTrade(false, int256(ethSize));
    }

    function test_dustAndRoundingBoundaries() public {
        _bootstrap();
        uint256[5] memory sizes = [uint256(1), 499, 500, 501, 999];
        for (uint256 i; i < sizes.length; ++i) {
            _assertTrade(true, -int256(sizes[i]));
            _assertTrade(false, int256(sizes[i]));
        }
        // At this price these token amounts move less than 500 wei of ETH.
        uint256 beforeBalance = hook.balanceOf(REFERRER);
        _assertTrade(true, 1);
        _assertTrade(false, -1);
        assertEq(hook.balanceOf(REFERRER), beforeBalance);
        assertEq(hook.referralCount(REFERRER), 12);
    }

    function test_invalidReferrersAndMalformedDataPayNothingInAllModes() public {
        _bootstrap();
        bytes[9] memory invalid = [
            bytes(""),
            abi.encode(address(0)),
            abi.encode(TRADER),
            abi.encode(address(hook)),
            abi.encode(address(manager)),
            bytes(hex"1234"),
            abi.encode(REFERRER, REFERRER),
            abi.encode(type(uint256).max),
            new bytes(31)
        ];
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode < 2;
            int256 amount = mode == 0
                ? -int256(0.001 ether)
                : mode == 1 ? int256(1000 ether) : mode == 2 ? -int256(1000 ether) : int256(0.001 ether);
            uint256 snapshot = vm.snapshotState();
            BalanceDelta baseline = _swap(buy, amount, "");
            assertTrue(vm.revertToState(snapshot));
            for (uint256 i; i < invalid.length; ++i) {
                snapshot = vm.snapshotState();
                vm.recordLogs();
                BalanceDelta actual = _swap(buy, amount, invalid[i]);
                Vm.Log[] memory logs = vm.getRecordedLogs();
                assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(baseline));
                assertEq(manager.balanceOf(address(hook), 0), 0);
                assertEq(hook.balanceOf(REFERRER), 0);
                assertEq(hook.referralCount(REFERRER), 0);
                for (uint256 j; j < logs.length; ++j) {
                    assertNotEq(logs[j].emitter, address(hook));
                }
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_permissionsAndMinedAddress() public view {
        Hooks.Permissions memory expected;
        expected.beforeSwap = true;
        expected.afterSwap = true;
        expected.beforeSwapReturnDelta = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(uint160(address(hook)) & 0x3fff, 0x00cc);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_constructorRejectsWrongPermissionBits() public {
        bytes32 hash = keccak256(abi.encodePacked(type(ReferralHook).creationCode, abi.encode(manager)));
        bytes32 salt;
        address predicted;
        do {
            salt = bytes32(uint256(salt) + 1);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash))))
            );
        } while (uint160(predicted) & 0x3fff == 0x00cc);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new ReferralHook{salt: salt}(manager);
    }

    function test_allImplementedCallbacksRejectDirectCalls() public {
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(ReferralHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, abi.encode(REFERRER));
        vm.expectRevert(ReferralHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), abi.encode(REFERRER));
        vm.expectRevert(ReferralHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(address(this), 1 ether));
    }

    function test_partialFillRevertsAndRollsBackEveryModeWithOrWithoutReferral() public {
        _bootstrap();
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode < 2;
            int256 amount = mode == 0
                ? -int256(0.05 ether)
                : mode == 1
                    ? int256(1_000_000 ether)
                    : mode == 2 ? -int256(1_000_000 ether) : int256(0.01 ether);
            for (uint256 referred; referred < 2; ++referred) {
                (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
                vm.expectRevert(
                    abi.encodeWithSelector(
                        CustomRevert.WrappedError.selector,
                        address(hook),
                        IHooks.afterSwap.selector,
                        abi.encodeWithSelector(ReferralHook.PartialFill.selector),
                        abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                    )
                );
                router.swap{value: buy ? 1 ether : 0}(
                    key,
                    SwapParams(buy, amount, buy ? price - 1 : price + 1),
                    PoolSwapTest.TestSettings(false, false),
                    referred == 0 ? bytes("") : abi.encode(REFERRER)
                );
                (uint160 afterPrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
                assertEq(afterPrice, price);
                assertEq(hook.balanceOf(REFERRER), 0);
                assertEq(hook.referralCount(REFERRER), 0);
                assertEq(manager.balanceOf(address(hook), 0), 0);
            }
        }
    }

    function test_nonNativePoolHasNoHookEffects() public {
        REFR a = new REFR();
        REFR b = new REFR();
        (REFR first, REFR second) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory other = PoolKey(
            Currency.wrap(address(first)), Currency.wrap(address(second)), 3000, 60, IHooks(address(hook))
        );
        manager.initialize(other, uint160(1 << 96));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        first.approve(address(lp), type(uint256).max);
        second.approve(address(lp), type(uint256).max);
        first.approve(address(router), type(uint256).max);
        second.approve(address(router), type(uint256).max);
        lp.modifyLiquidity(other, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)), "");
        for (uint256 mode; mode < 4; ++mode) {
            bool buy = mode < 2;
            int256 amount = mode % 2 == 0 ? -int256(1 ether) : int256(1 ether);
            _swapKey(other, buy, amount, abi.encode(REFERRER));
        }
        assertEq(hook.balanceOf(REFERRER), 0);
        assertEq(hook.referralCount(REFERRER), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        (uint256 volume, uint256 count, uint256 earned) = hook.poolReferrals(other.toId(), REFERRER);
        assertEq(volume + count + earned, 0);
        // Even a partial fill in an unsupported pool has no hook restriction.
        router.swap(
            other,
            SwapParams(true, -100 ether, uint160(1 << 96) - 1e24),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(REFERRER)
        );
    }

    function test_multiplePoolsKeepIndependentStatisticsAndAggregateClaims() public {
        _assertTrade(true, -0.01 ether);
        REFR second = new REFR();
        second.transfer(address(factory), factory.SEED_AMOUNT());
        PoolKey memory other = key;
        other.currency1 = Currency.wrap(address(second));
        factory.seed(other, factory.SEED_AMOUNT());
        _swapKey(other, true, -0.02 ether, abi.encode(REFERRER));
        (uint256 volume, uint256 count, uint256 earned) = hook.poolReferrals(key.toId(), REFERRER);
        assertEq(volume, 0.01 ether);
        assertEq(count, 1);
        assertEq(earned, 0.00002 ether);
        (volume, count, earned) = hook.poolReferrals(other.toId(), REFERRER);
        assertEq(volume, 0.02 ether);
        assertEq(count, 1);
        assertEq(earned, 0.00004 ether);
        assertEq(hook.balanceOf(REFERRER), 0.00006 ether);
        assertEq(hook.referredVolume(REFERRER), 0.03 ether);
        vm.prank(REFERRER);
        hook.claim();
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_runtimeHasNoEscapeHatches() public view {
        _scan(address(hook).code);
        _scan(address(token).code);
    }

    function _scan(bytes memory code) private pure {
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            }
        }
    }

    struct TradeLog {
        int128 pool0;
        int128 pool1;
        uint256 leg;
        uint256 reward;
    }

    function _assertTrade(bool buy, int256 amount) private {
        uint256 balanceBefore = hook.balanceOf(REFERRER);
        uint256 volumeBefore = hook.referredVolume(REFERRER);
        uint256 traderEth = address(this).balance;
        uint256 traderTokens = token.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta actual = _swap(buy, amount, abi.encode(REFERRER));
        TradeLog memory info = _readTradeLogs();
        bool ethSpecified = buy == (amount < 0);
        uint256 expectedLeg = _abs(ethSpecified ? amount : int256(info.pool0));
        assertEq(info.leg, expectedLeg);
        assertEq(info.reward, expectedLeg * 20 / 10_000);
        assertEq(int256(actual.amount0()), int256(info.pool0) - int256(info.reward));
        assertEq(actual.amount1(), info.pool1);
        assertEq(ethSpecified ? int256(actual.amount0()) : int256(actual.amount1()), amount);
        assertEq(int256(address(this).balance) - int256(traderEth), int256(actual.amount0()));
        assertEq(int256(token.balanceOf(address(this))) - int256(traderTokens), int256(actual.amount1()));
        assertEq(hook.balanceOf(REFERRER), balanceBefore + info.reward);
        assertEq(hook.referredVolume(REFERRER), volumeBefore + info.leg);
        assertEq(manager.balanceOf(address(hook), 0), hook.balanceOf(REFERRER));
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), key.currency0), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(router), key.currency0), 0);
        assertFalse(IPoolManager(address(manager)).isUnlocked());
    }

    function _readTradeLogs() private returns (TradeLog memory info) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swaps;
        uint256 referrals;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                (info.pool0, info.pool1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                swaps++;
            }
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == REFERRED_EVENT) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(REFERRER))));
                assertEq(logs[i].topics[2], PoolId.unwrap(key.toId()));
                (info.leg, info.reward) = abi.decode(logs[i].data, (uint256, uint256));
                referrals++;
            }
        }
        assertEq(swaps, 1);
        assertEq(referrals, 1);
    }

    function _abs(int256 value) private pure returns (uint256) {
        return uint256(value < 0 ? -value : value);
    }
}
