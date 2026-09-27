// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {REFR} from "../../src/REFR.sol";
import {ReferralHook} from "../../src/ReferralHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LaunchFactory} from "./LaunchFactory.sol";
import {HookMiner} from "./HookMiner.sol";

abstract contract Fixture is Test {
    REFR internal token;
    ReferralHook internal hook;
    PoolManager internal manager;
    PoolSwapTest internal router;
    LaunchFactory internal factory;
    PoolKey internal key;
    address internal constant REFERRER = address(0x1234);
    address internal constant TRADER = address(0x5678);

    function setUp() public virtual {
        vm.deal(address(this), 10_000 ether);
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        factory = new LaunchFactory(manager);
        (bytes32 salt, address predicted) = HookMiner.find(address(factory), manager);
        (token, hook, key) = factory.launch(salt);
        assertEq(address(hook), predicted);
        token.approve(address(router), type(uint256).max);
    }

    function _swap(bool buy, int256 amount, bytes memory data) internal returns (BalanceDelta) {
        return _swapKey(key, buy, amount, data);
    }

    function _swapKey(PoolKey memory pool, bool buy, int256 amount, bytes memory data)
        internal
        returns (BalanceDelta)
    {
        vm.prank(address(this), TRADER);
        return router.swap{value: buy ? 10 ether : 0}(
            pool,
            SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            data
        );
    }

    function _bootstrap() internal {
        _swap(true, -0.2 ether, "");
    }

    receive() external payable {}
}
