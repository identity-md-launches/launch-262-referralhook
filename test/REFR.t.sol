// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {REFR} from "../src/REFR.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract REFRTest is Test {
    REFR private token;
    address private constant ALICE = address(0xa11ce);
    address private constant BOB = address(0xb0b);

    function setUp() public {
        token = new REFR();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "Referral");
        assertEq(token.symbol(), "REFR");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transfersConserveSupply(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_allowanceSpentAndInfiniteAllowancePreserved() public {
        token.approve(ALICE, 100);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 40);
        assertEq(token.allowance(address(this), ALICE), 60);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 60, 61)
        );
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 61);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 40);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        assertEq(token.balanceOf(BOB), 80);
    }

    function test_badTransfersRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_noAdminOrMintSelectorsEvenForDeployer() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool success,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, 1 ether));
            assertFalse(success);
        }
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
