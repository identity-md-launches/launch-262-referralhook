// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReferralHook} from "../../src/ReferralHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

library HookMiner {
    uint160 internal constant FLAGS = 0x00cc;
    uint160 internal constant MASK = 0x3fff;

    function find(address deployer, IPoolManager manager)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes32 hash = keccak256(abi.encodePacked(type(ReferralHook).creationCode, abi.encode(manager)));
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, hash)))));
            if (uint160(predicted) & MASK == FLAGS) return (salt, predicted);
        }
        revert("no hook salt in search window");
    }
}
