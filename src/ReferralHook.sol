// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Permissionless 20 bps native-ETH referrals, backed by PoolManager ERC-6909 claims.
/// @dev No token binding or administration. Every pool with native ETH as currency0 is supported.
contract ReferralHook is IUnlockCallback {
    using SafeCast for int256;

    error OnlyPoolManager();
    error PartialFill();

    event Referred(address indexed referrer, PoolId indexed poolId, uint256 ethLeg, uint256 reward);
    event Claimed(address indexed referrer, uint256 amount);

    uint256 public constant FEE_BPS = 20;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    IPoolManager public immutable poolManager;

    // ETH debts are fungible across pools; claim() redeems the caller's complete aggregate debt.
    mapping(address referrer => uint256) public balanceOf;
    mapping(address referrer => uint256) public referredVolume;
    mapping(address referrer => uint256) public referralCount;

    struct PoolReferral {
        uint256 volume;
        uint256 count;
        uint256 earned;
    }

    /// @notice Lifetime statistics for a referrer in a particular pool (earned is not claimable).
    mapping(PoolId poolId => mapping(address referrer => PoolReferral)) public poolReferrals;

    constructor(IPoolManager manager) {
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @dev Positive specified delta: reduces an exact-in buy's pool input, or increases
    /// an exact-out sell's pool output. The caller's specified ETH amount remains unchanged.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!key.currency0.isAddressZero() || !_ethSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }
        address referrer = _referrer(hookData);
        if (referrer == address(0)) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);

        uint256 ethLeg = _abs(params.amountSpecified);
        uint256 reward = _fee(ethLeg);
        int128 delta = int256(reward).toInt128();
        _credit(key.toId(), referrer, ethLeg, reward);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(delta, 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        if (!key.currency0.isAddressZero()) return (IHooks.afterSwap.selector, 0);

        address referrer = _referrer(hookData);
        bool ethSpecified = _ethSpecified(params);
        uint256 beforeFee = ethSpecified && referrer != address(0) ? _fee(_abs(params.amountSpecified)) : 0;

        // afterSwap receives the pool delta BEFORE hook fees. The adjusted specified amount
        // must be filled exactly, even when there is no referrer. A revert rolls back minting.
        int256 specifiedDelta = ethSpecified ? int256(delta.amount0()) : int256(delta.amount1());
        if (specifiedDelta - int256(beforeFee) != params.amountSpecified) revert PartialFill();

        if (ethSpecified || referrer == address(0)) return (IHooks.afterSwap.selector, 0);
        uint256 ethLeg = _abs(int256(delta.amount0()));
        uint256 reward = _fee(ethLeg);
        _credit(key.toId(), referrer, ethLeg, reward);
        return (IHooks.afterSwap.selector, int256(reward).toInt128());
    }

    /// @notice Pay the caller their entire accrued ETH balance. An empty claim is a no-op.
    /// @dev Must start while the manager is locked; a failed unlock or payout rolls back all effects.
    function claim() external returns (uint256 amount) {
        amount = balanceOf[msg.sender];
        if (amount == 0) return 0;
        balanceOf[msg.sender] = 0;
        poolManager.unlock(abi.encode(msg.sender, amount));
        emit Claimed(msg.sender, amount);
    }

    /// @dev PoolManager only calls the unlock initiator. Claims are burned before paying ETH
    /// directly to the referrer; the hook never holds ETH and never pays during swap callbacks.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address referrer, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), referrer, amount);
        return "";
    }

    function _credit(PoolId id, address referrer, uint256 ethLeg, uint256 reward) private {
        balanceOf[referrer] += reward;
        referredVolume[referrer] += ethLeg;
        referralCount[referrer]++;
        PoolReferral storage stats = poolReferrals[id][referrer];
        stats.volume += ethLeg;
        stats.count++;
        stats.earned += reward;
        if (reward != 0) poolManager.mint(address(this), 0, reward);
        emit Referred(referrer, id, ethLeg, reward);
    }

    function _referrer(bytes calldata data) private view returns (address referrer) {
        if (data.length != 32) return address(0);
        // Noncanonical ABI words are invalid referral data, not a reason to block a swap.
        if (uint256(bytes32(data)) > type(uint160).max) return address(0);
        referrer = abi.decode(data, (address));
        // tx.origin is ONLY a weak self-referral exclusion, never authorization.
        if (referrer == tx.origin || referrer == address(this) || referrer == address(poolManager)) {
            return address(0);
        }
    }

    function _ethSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _fee(uint256 ethLeg) private pure returns (uint256) {
        // Exactly floor(ethLeg * 20 / 10_000), without intermediate multiplication overflow.
        return ethLeg / (BPS_DENOMINATOR / FEE_BPS);
    }

    function _abs(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }
}
