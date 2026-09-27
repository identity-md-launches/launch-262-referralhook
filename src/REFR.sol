// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply launch token. Its deployer receives the entire supply once.
contract REFR is ERC20 {
    constructor() ERC20("Referral", "REFR") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
