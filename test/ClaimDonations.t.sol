// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Anyone can mint backed claims to any recipient; ERC-6909 has no receiver acceptance hook.
contract ClaimDonor {
    IPoolManager private immutable manager;
    address private immutable recipient;

    constructor(IPoolManager manager_, address recipient_) {
        manager = manager_;
        recipient = recipient_;
    }

    function donate() external payable {
        manager.unlock(abi.encode(msg.value));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        uint256 amount = abi.decode(data, (uint256));
        manager.mint(recipient, 0, amount);
        manager.sync(Currency.wrap(address(0)));
        manager.settle{value: amount}();
        return "";
    }
}

contract ClaimDonationsTest is Fixture {
    function test_unsolicitedClaimsCreateSurplusAndDoNotBlockClaims() public {
        _swap(true, -0.01 ether, abi.encode(REFERRER));
        uint256 owed = hook.balanceOf(REFERRER);
        ClaimDonor donor = new ClaimDonor(manager, address(hook));
        donor.donate{value: 1 ether}();
        assertEq(hook.balanceOf(REFERRER), owed);
        assertEq(manager.balanceOf(address(hook), 0), owed + 1 ether);
        vm.prank(REFERRER);
        assertEq(hook.claim(), owed);
        assertEq(manager.balanceOf(address(hook), 0), 1 ether);
        assertEq(hook.balanceOf(REFERRER), 0);
    }
}
