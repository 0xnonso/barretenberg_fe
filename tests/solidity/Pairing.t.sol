// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SolidityPairingReference} from "./helpers/SolidityPairingReference.sol";
import {FeTest} from "./helpers/FeTest.sol";

import {MODULUS, Q} from "../../reference/solidity/generated/ArithmeticVerifier.sol";

interface IPairingProbe {
    function check(uint256[12] calldata words) external view returns (uint256 code, bool result);
}

contract PairingTest is FeTest {
    IPairingProbe private fe;
    SolidityPairingReference private referencePairing;

    function setUp() public {
        fe = IPairingProbe(deployProbe("PairingProbe"));
        referencePairing = new SolidityPairingReference();
    }

    function testKnownTrueAndFalseEquations() public view {
        uint256[12] memory words = generatorPairs();
        words[7] = Q - 2;
        assertEquation(words, true); // e(G,H) * e(-G,H) = 1
        words[7] = 2;
        assertEquation(words, false); // e(G,H)^2 != 1
    }

    function testIdentityInEitherGroup() public view {
        uint256[12] memory words = generatorPairs();
        words[0] = 0;
        words[1] = 0;
        for (uint256 i = 8; i < 12; ++i) {
            words[i] = 0;
        }
        assertEquation(words, true);
        words = generatorPairs();
        words[6] = 0;
        words[7] = 0;
        assertEquation(words, false); // One identity term must not bypass the other.
        uint256[12] memory allIdentity;
        assertEquation(allIdentity, true);
    }

    function testExactEncodingAndPinnedSrsHelperAgreement() public {
        uint256[12] memory words = pinnedPairs();
        // Nonidentical G1/G2 terms detect offset and component-order mistakes.
        words[7] = Q - 2;
        vm.expectCall(address(8), abi.encode(words));
        (uint256 code, bool result) = fe.check(words);
        assertEq(code, 0);
        vm.expectCall(address(8), abi.encode(words));
        assertEq(result, referencePairing.pinned(words[0], words[1], words[6], words[7]));
        assertFalse(result);
        words[0] = 0;
        words[1] = 0;
        words[6] = 0;
        words[7] = 0;
        (code, result) = fe.check(words);
        assertEq(code, 0);
        assertTrue(result);
        assertTrue(referencePairing.pinned(0, 0, 0, 0));
        words[0] = 1;
        words[1] = 2;
        (code, result) = fe.check(words);
        assertEq(code, 0);
        assertFalse(result);
        assertFalse(referencePairing.pinned(1, 2, 0, 0));
    }

    function testFuzzPairingBilinearity(uint256 a, uint256 b) public view {
        a %= MODULUS;
        b %= MODULUS;
        uint256[12] memory words = generatorPairs();
        (words[0], words[1]) = referencePairing.multiple(a);
        (words[6], words[7]) = referencePairing.multiple(b);
        assertEquation(words, addmod(a, b, MODULUS) == 0);
        words[6] = words[0];
        words[7] = words[1] == 0 ? 0 : Q - words[1];
        assertEquation(words, true);
    }

    function testSwappedG2ComponentsAndOffCurveG2Fail() public view {
        for (uint256 term; term < 2; ++term) {
            uint256 offset = term * 6;
            uint256[12] memory words = generatorPairs();
            (words[offset + 2], words[offset + 3]) = (words[offset + 3], words[offset + 2]);
            assertCallFailure(words);
            words = generatorPairs();
            (words[offset + 4], words[offset + 5]) = (words[offset + 5], words[offset + 4]);
            assertCallFailure(words);
            words = generatorPairs();
            for (uint256 i = 2; i < 6; ++i) {
                words[offset + i] = 1;
            }
            assertCallFailure(words);
        }
    }

    function testInvalidG1RejectedBeforePairing() public view {
        for (uint256 term; term < 2; ++term) {
            uint256[12] memory words = generatorPairs();
            words[term * 6 + 1] = 1;
            (uint256 code, bool result) = fe.check(words);
            assertEq(code, 1, "invalid G1 lost");
            assertFalse(result, "invalid G1 lost");
            (code, result) = referencePairing.check{gas: 1_000_000}(words);
            assertEq(code, 7, "reference accepted invalid G1");
            assertFalse(result, "reference accepted invalid G1");
        }
    }

    function testNoncanonicalComponentsReject() public view {
        for (uint256 i; i < 12; ++i) {
            uint256[12] memory words = generatorPairs();
            words[i] = Q;
            (bool ok,) = address(fe).staticcall{gas: 100_000}(abi.encodeCall(fe.check, (words)));
            assertFalse(ok, "accepted coordinate modulus");
            words[i] = type(uint256).max;
            (ok,) = address(fe).staticcall{gas: 100_000}(abi.encodeCall(fe.check, (words)));
            assertFalse(ok, "accepted oversized coordinate");
        }
    }

    function testCallFailureIsDistinctFromSuccessfulFalse() public {
        uint256[12] memory words = generatorPairs();
        (uint256 code, bool result) = fe.check(words);
        assertEq(code, 0);
        assertFalse(result);
        vm.mockCallRevert(address(8), bytes(""), hex"deadbeef");
        (code, result) = fe.check(words);
        assertEq(code, 7);
        assertFalse(result);
        uint256[12] memory identity;
        (code, result) = fe.check(identity);
        assertEq(code, 7, "identity bypassed call failure");
        assertFalse(result, "identity bypassed call failure");
        // The pinned helper folds call failure into false; the library preserves it.
        assertFalse(referencePairing.pinned(0, 0, 0, 0));
        vm.clearMockedCalls();
    }

    function testStrictBooleanOutput() public {
        uint256[12] memory words = generatorPairs();
        uint256[4] memory outputs = [uint256(0), 1, 2, type(uint256).max];
        for (uint256 i; i < outputs.length; ++i) {
            vm.mockCall(address(8), bytes(""), abi.encode(outputs[i]));
            (uint256 code, bool result) = fe.check(words);
            if (outputs[i] < 2) {
                assertEq(code, 0);
                assertEq(result, (outputs[i] == 1));
            } else {
                assertEq(code, 8);
                assertFalse(result);
                (bool ok,) = address(referencePairing).staticcall(abi.encodeCall(referencePairing.check, (words)));
                assertFalse(ok, "Solidity accepted non-boolean output");
            }
            vm.clearMockedCalls();
        }
    }

    function testRejectsWrongReturnLengths() public {
        uint256[12] memory words = generatorPairs();
        uint256[5] memory sizes = [uint256(0), 1, 31, 33, 64];
        for (uint256 i; i < sizes.length; ++i) {
            vm.mockCall(address(8), bytes(""), new bytes(sizes[i]));
            (uint256 code, bool result) = fe.check(words);
            assertEq(code, 9);
            assertFalse(result);
            vm.clearMockedCalls();
        }
        vm.mockCall(address(8), bytes(""), abi.encode(uint256(1), type(uint256).max));
        (uint256 extraCode, bool extraResult) = fe.check(words);
        assertEq(extraCode, 9, "valid prefix hid excess data");
        assertFalse(extraResult, "valid prefix hid excess data");
        vm.clearMockedCalls();
    }

    function generatorPairs() private pure returns (uint256[12] memory words) {
        for (uint256 offset; offset < 12; offset += 6) {
            words[offset] = 1;
            words[offset + 1] = 2;
            words[offset + 2] = 0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2;
            words[offset + 3] = 0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed;
            words[offset + 4] = 0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b;
            words[offset + 5] = 0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa;
        }
    }

    function pinnedPairs() private pure returns (uint256[12] memory words) {
        words = generatorPairs();
        // Pinned utils.sol second G2 point. Fixed in the verifier, never caller-selected.
        words[8] = 0x260e01b251f6f1c7e7ff4e580791dee8ea51d87a358e038b4efe30fac09383c1;
        words[9] = 0x0118c4d5b837bcc2bc89b5b398b5974e9f5944073b32078b7e231fec938883b0;
        words[10] = 0x04fc6369f7110fe3d25156c1bb9a72859cf2a04641f99ba4ee413c80da6a5fe4;
        words[11] = 0x22febda3c0c0632a56475b4214e5615e11e6dd3f96e6cea2854a87d4dacc5e55;
    }

    function assertEquation(uint256[12] memory words, bool expected) private view {
        (uint256 code, bool result) = fe.check(words);
        assertEq(code, 0, "Fe pairing equation differs");
        assertEq(result, expected, "Fe pairing equation differs");
        (code, result) = referencePairing.check(words);
        assertEq(code, 0, "reference pairing equation differs");
        assertEq(result, expected, "reference pairing equation differs");
    }

    function assertCallFailure(uint256[12] memory words) private view {
        // Invalid precompile input consumes forwarded gas. Leave enough EIP-150
        // reserve for the Fe adapter to report its typed error.
        (uint256 code, bool result) = fe.check{gas: 1_000_000}(words);
        assertEq(code, 7, "invalid G2 did not fail the call");
        assertFalse(result, "invalid G2 did not fail the call");
        (code, result) = referencePairing.check{gas: 1_000_000}(words);
        assertEq(code, 7, "reference accepted invalid G2");
        assertFalse(result, "reference accepted invalid G2");
    }
}
