# Local verification evidence

These are contributor-run checks, not independent review or deployment approval.

- Compiler: `0.8.26+commit.8a97fa7a` (version-pinned in `foundry.toml`).
- Foundry: `forge 1.7.1`, build commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`.
- `forge build`: passed.
- `forge test`: 28 passed, 0 failed, 0 skipped across five suites.
- `forge fmt --check`: passed.
- `forge test --fuzz-runs 1000 --no-match-contract ReferralInvariantTest`: 27 passed;
  each of the three fuzz properties ran 1,000 cases.
- Stateful invariant: 128 runs × 64 actions = 8,192 actions, zero reverts.
- `forge clean`, then `forge build --offline` and `forge test --offline`: passed,
  including all 28 tests, demonstrating compilation without a dependency download.
- `python3 scripts/check_artifacts.py`: ABI exports and all vendor checksums match.
- Runtime size: REFR 1,722 bytes; ReferralHook 4,446 bytes. Both runtime opcode
  scans passed the protected checks' DELEGATECALL/CALLCODE/SELFDESTRUCT exclusions.

Source SHA-256 values at verification:

| File | SHA-256 |
| --- | --- |
| `src/REFR.sol` | `45865d54cc7bc9df9ff89bccee11fc169ccac4b2cc3e72117c8194520ae8bfc1` |
| `src/ReferralHook.sol` | `cd8b01d37a978b6a96e47cd76b6768dd8eaded9e402aa932d4d11c88f5233dff` |
| `foundry.toml` | `d4e7b9a59f5a2608feec2c9b7b1047de4719ec945d006e4a61037bf401543a65` |

The provided protected suites were read as acceptance definitions; they are not
vendored, edited or counted as executed here. Local tests reproduce their relevant
token, permission, access and opcode assertions without reading environment values.
The implementation task's live Sepolia fork rehearsal and independent review have
not been represented as completed. The later manifest must reconcile the explicit
price and seed assumptions in the README.

The equality invariant covers swaps and claims. The separate donation test proves
why arbitrary external ERC-6909 donations change equality into a surplus relation:
fund donor → donor unlocks manager → mint ID 0 to hook → donor settles native ETH →
existing referrer claims normally → unsolicited claims remain. No balance deficit
or payout failure is introduced by this sequence. See the README for this explicit
limitation of the unconditional invariant wording.
