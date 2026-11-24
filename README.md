# barretenberg_fe

Fe verifier for Barretenberg 6.0.0 UltraHonk ZK/Keccak proofs on the EVM.
Exposes `verify(bytes proof, bytes32[] publicInputs)`.

## Versioning

The project version lives in [fe.toml](fe.toml); release notes live in
[CHANGELOG.md](CHANGELOG.md). Releases use annotated Git tags matching that
version, starting with `v0.1.0`.

During `0.x` development, increment the patch for compatible fixes and the minor
for features or breaking changes. At `1.0.0`, the public contract ABI, supported
proof/key formats and generator CLI become the compatibility boundary for
[Semantic Versioning](https://semver.org/).

For a release, update `fe.toml`, add a dated changelog entry, then:

```sh
make version-check TAG=v0.1.0  # substitute the new version
make test
git add fe.toml CHANGELOG.md
git commit -m "Release v0.1.0"
git tag -a v0.1.0 -m "barretenberg_fe v0.1.0"
git push --atomic origin main v0.1.0
```

Commit implementation changes before the release commit. Published tags stay
fixed. The test-only probe package has its own internal version; it is not a
separate release. Upstream tool versions remain pinned in `toolchain.lock.json`.

`make version` prints the project version and Git revision. Generated verifiers
include both as comments; local changes add `-dirty`, and source archives or
checkouts without a commit report `unknown`. These comments do not change the
contract ABI or runtime.

## Generate a verifier

The pinned toolchain supports Apple Silicon macOS. The scripts require Python 3.11 or later.

```sh
make setup
make verifier CIRCUIT=target/circuit.json OUT=UltraHonkVerifier.fe
.tools/bin/fe build --standalone UltraHonkVerifier.fe -O 2 --emit bytecode
```

For an existing key, use `make verifier VK=out/vk OUT=UltraHonkVerifier.fe`.
Supply the binary key with its matching `vk_hash`, or use `vk.json`, from the
same trusted `bb write_vk --verifier_target evm` run.

## Design

One compiled verifier code body serves all supported circuits; each deployment
stores its own immutable key and creates a `RelationsLib`. Keys require
`4 <= log_n <= 25` and `application_inputs + 8 < 2^log_n`.

Fraction-based sumcheck and batched inversions reduce MODEXP calls to four
(5,396 gas under Cancun), versus Solidity's `12 * log_n + 263` calls
(434,578–677,398 gas across these fixtures). Both pay 113,000 gas for the final
pairing. These are implementation optimizations that Solidity could also use.

## Test

```sh
make test     # builds artifacts, then runs every correctness check
make bench    # rebuilds and reports size, deployment and verification gas
make fmt      # Fe, Solidity tests and Python formatting
make clean    # generated test output and caches
```

`make test` runs Fe unit and compile-fail tests, generator/reference checks,
native proof verification and Forge differential/mutation tests over nine
fixtures. Invalid proofs must revert; error bytes are compared when Solidity
returns a payload. Files in `tests/compile_fail/` are intentionally invalid.

For a focused run, including required Fe builds:

```sh
make test-solidity FORGE_ARGS='--match-contract CurveTest -vv'
```

## Benchmarks

Verified 2026-11-24 using the [pinned toolchain](toolchain.lock.json): Fe 26.6.0
(`-O 2`), Solidity 0.8.30 (optimizer runs 1, no via-IR), Forge 1.4.4,
**Cancun**, matching the pinned Aztec v6 benchmark configuration.

Uses [Aztec's benchmark method](https://github.com/AztecProtocol/aztec-packages/blob/0219f11d8133970df3974fe5ae65e006bf8c193a/barretenberg/sol/bootstrap.sh):
the Forge JSON gas report's median for `verify(bytes,bytes32[])`, with one valid
call per verifier and fixture. These are this repository's nine saved fixtures;
the Solidity baseline comes from `bb write_solidity_verifier`.

| Verification call | log_n | Inputs | Fe gas | Solidity gas | Saved |
|---|---:|---:|---:|---:|---:|
| no_public | 5 | 0 | 556,381 | 1,787,049 | 69% |
| arithmetic | 5 | 1 | 556,929 | 1,788,477 | 69% |
| range_hash | 12 | 2 | 751,130 | 2,216,915 | 66% |
| merkle_batch | 15 | 4 | 815,687 | 2,403,394 | 66% |
| curve_lookup | 16 | 1 | 873,340 | 2,460,444 | 65% |
| sha256_large | 19 | 8 | 925,417 | 2,654,509 | 65% |
| ecdsa_commitment | 19 | 1 | 952,116 | 2,644,576 | 64% |
| recursive | 20 | 1 | 952,254 | 2,725,043 | 65% |
| ecdsa_batch | 19 | 544 | 1,238,151 | 3,415,629 | 64% |

| Deployed size (bytes) | Fe | Solidity |
|---|---:|---:|
| Verifier, including immutables | 15,703 | 16,858–17,701 |
| Libraries combined | 6,870 | 14,219 |
| Total | 22,573 | 31,077–31,920 |

Deployment estimates across the fixtures: **4.96–4.99M gas** for Fe in one
transaction; **6.88–7.06M** for Solidity with two fresh libraries (three
transactions), or **3.70–3.88M** when reusing its libraries.

The [harness](tests/solidity/Corpus.t.sol) installs each verifier's exact runtime
at an ABI-known address so Forge can report both; bytecode equality is checked.
Deployment estimates combine measured CREATE gas with transaction base and
calldata costs. These are benchmark results, not transaction receipts.

Run `make bench` to reproduce. Results are saved as `name`/`value`/`unit` entries
in `out/bench/verifier.bench.json`, alongside raw reports and toolchain metadata.
Use `python3 scripts/bench.py --no-build --profile` for precompile counts after building.
