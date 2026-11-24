# Changelog

Project versions are recorded in `fe.toml` and released as matching `vX.Y.Z`
Git tags. Upstream Barretenberg and compiler versions are pinned separately in
`toolchain.lock.json`.

## [Unreleased]

## [0.1.0] - 2026-11-24

- Initial Fe verifier for Barretenberg 6.0.0 UltraHonk ZK/Keccak proofs.
- Standalone verifier generation from a compiled Noir circuit or verification key.
- Circuit-independent verifier runtime with an immutable key and deployed relation library.
- Fe unit tests, compile-fail checks, stage probes and Forge differential tests over nine proof fixtures.
- Reproducible toolchain and benchmark reporting against the pinned Solidity reference.
- Version and source-revision comments in generated verifiers.
