#!/usr/bin/env python3
"""Offline verification of generated ABI exports and vendored source integrity."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
for contract in ("REFR", "ReferralHook"):
    artifact = json.loads((root / "out" / f"{contract}.sol" / f"{contract}.json").read_text())
    exported = json.loads((root / "docs" / "abi" / f"{contract}.json").read_text())
    assert artifact["abi"] == exported, f"stale ABI: {contract}"

for dependency in json.loads((root / "docs" / "dependencies.json").read_text()):
    for path, expected in dependency["files"].items():
        actual = hashlib.sha256((root / path).read_bytes()).hexdigest()
        assert actual == expected, f"modified dependency: {path}"
print("ABI exports and vendored source checksums match")
