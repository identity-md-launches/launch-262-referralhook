// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {REFR} from "../../src/REFR.sol";
import {ReferralHook} from "../../src/ReferralHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @dev Local rehearsal of the supplied factory lifecycle, not production deployment tooling.
contract LaunchFactory is IUnlockCallback {
    IPoolManager public immutable manager;
    int24 public constant TICK_LOWER = -887220;
    int24 public constant TICK_UPPER = 207240;
    uint256 public constant SEED_AMOUNT = 800_000_000 ether;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function initialPrice() public pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(TICK_UPPER);
    }

    function launch(bytes32 salt) external returns (REFR token, ReferralHook hook, PoolKey memory key) {
        token = new REFR();
        require(token.balanceOf(address(this)) == token.totalSupply(), "factory must receive all supply");
        hook = new ReferralHook{salt: salt}(manager);
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook))
        );
        seed(key, SEED_AMOUNT);
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }

    /// @dev Test helper may seed additional pools after receiving their tokens.
    function seed(PoolKey memory key, uint256 amount) public {
        manager.initialize(key, initialPrice());
        uint256 liquidity =
            FullMath.mulDiv(amount, 1 << 96, initialPrice() - TickMath.getSqrtPriceAtTick(TICK_LOWER));
        manager.unlock(abi.encode(key, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, uint256 liquidity) = abi.decode(data, (PoolKey, uint256));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, int256(liquidity), bytes32(0)), ""
        );
        require(delta.amount0() == 0, "seed must be token only");
        manager.sync(key.currency1);
        REFR(Currency.unwrap(key.currency1)).transfer(address(manager), uint256(-int256(delta.amount1())));
        manager.settle();
        return "";
    }
}
