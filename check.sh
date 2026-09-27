#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
forge fmt --check
forge build
forge test
forge test --fuzz-runs 1000 --no-match-contract ReferralInvariantTest
python3 scripts/check_artifacts.py
