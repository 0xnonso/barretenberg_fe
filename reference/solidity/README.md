# Solidity reference

`honk/` contains the seven readable upstream Honk Solidity files at Aztec release v6.0.0, commit `0219f11d8133970df3974fe5ae65e006bf8c193a`. Upstream SPDX/copyright notices are preserved. See `LICENSE.upstream` for the upstream license.

`generated/ArithmeticVerifier.sol` is emitted by that same release binary from the arithmetic fixture VK. It contains the fixed circuit values and flattened verifier implementation. Local cleanup removes redundant and stale comments from both reference trees; executable tokens are unchanged. Regeneration restores the upstream comments.

`tests/solidity/ArithmeticVerifier.t.sol` exercises the reference in Foundry; `tests/solidity/helpers/OpeningReference.sol` exposes its intermediate opening terms. Neither has been modified to imitate the Fe implementation.

`scripts/check_reference.py` checks the opening calculation in both source forms
and the instrumented adapter. Probe builds and tests reject executable drift;
the adapter only omits the separately tested Libra assertion and final pairing.
