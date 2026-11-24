// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ArithmeticStagesReference} from "./helpers/ArithmeticStagesReference.sol";
import {FeTest} from "./helpers/FeTest.sol";
import {
    Honk,
    HonkVerificationKey,
    N,
    LOG_N,
    NUMBER_OF_PUBLIC_INPUTS,
    VK_HASH,
    ZKTranscriptLib,
    ZKTranscript,
    Fr,
    MODULUS,
    Q
} from "../../reference/solidity/generated/ArithmeticVerifier.sol";

interface IProtocolProbe {
    function hash(uint256[3] calldata words) external pure returns (uint256, uint256, uint256, uint256);
    function decode(bytes calldata data) external pure returns (uint256[142] memory);
    function key() external pure returns (uint256[60] memory);
}

interface ITranscriptProbe {
    function transcript(bytes calldata data, bytes32[] calldata inputs) external pure returns (uint256[49] memory);
}

interface ISumcheckProbe {
    function check(bytes calldata data, bytes32[] calldata inputs) external view returns (bool);
    function rounds(bytes calldata data, bytes32[] calldata inputs) external view returns (uint256, uint256);
}

interface IArithmeticStagesProbe {
    function delta(uint256[11] calldata words) external view returns (uint256);
    function interpolate(uint256[9] calldata values, uint256 u) external view returns (uint256);
}

contract ProtocolTest is FeTest {
    IProtocolProbe private fe;
    ITranscriptProbe private transcriptFe;
    IArithmeticStagesProbe private arithmeticFe;
    ISumcheckProbe private sumcheckFe;
    ISumcheckProbe private roundsFe;
    ArithmeticStagesReference private arithmeticReference;

    function setUp() public {
        fe = IProtocolProbe(deployProbe("ProtocolProbe"));
        transcriptFe = ITranscriptProbe(deployProbe("TranscriptProbe"));
        arithmeticFe = IArithmeticStagesProbe(deployProbe("ArithmeticStagesProbe"));
        arithmeticReference = new ArithmeticStagesReference();
        sumcheckFe = ISumcheckProbe(deployProbe("SumcheckProbe"));
        roundsFe = ISumcheckProbe(deployProbe("RoundsProbe"));
    }

    function testFixtureSumcheckAndRoundTargets() public view {
        (bytes memory data, bytes32[] memory inputs) = loadFixture("arithmetic");
        assertTrue(sumcheckFe.check(data, inputs));
        assertTrue(arithmeticReference.sumcheck(data, inputs));
        (uint256 target, uint256 gate) = roundsFe.rounds(data, inputs);
        (uint256 refTarget, uint256 refGate) = arithmeticReference.rounds(data, inputs);
        assertEq(target, refTarget);
        assertEq(gate, refGate);
    }

    function testSumcheckMutationsMatchReference() public view {
        bytes memory data = vm.readFileBinary("fixtures/arithmetic/artifacts/proof");
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(uint256(13));
        assertFalse(sumcheckFe.check(data, inputs));
        inputs[0] = bytes32(uint256(12));
        for (uint256 i; i < 47; ++i) {
            uint256 index = i < 5 ? 29 + 9 * i : 74 + i - 5;
            uint256 offset = 32 * index;
            uint256 old;
            assembly { old := mload(add(add(data, 32), offset)) }
            uint256 changed = addmod(old, 1, MODULUS);
            assembly { mstore(add(add(data, 32), offset), changed) }
            bool accepted = sumcheckFe.check(data, inputs);
            (bool ok, bytes memory output) =
                address(arithmeticReference).staticcall(abi.encodeCall(arithmeticReference.sumcheck, (data, inputs)));
            assertEq(accepted, (ok && abi.decode(output, (bool))), "mutated sumcheck differs");
            if (i < 5) {
                assertFalse(accepted, "changed round accepted");
            }
            // Some terminal values, including the masking slot, are constrained
            // by opening authentication rather than this standalone relation check.
            assembly { mstore(add(add(data, 32), offset), old) }
        }
    }

    function testFuzzPublicInputDelta(uint256[11] memory words) public view {
        for (uint256 i; i < words.length; ++i) {
            words[i] %= MODULUS;
        }
        (bool ok, bytes memory output) = address(arithmeticFe).staticcall(abi.encodeCall(arithmeticFe.delta, (words)));
        (bool refOk, bytes memory expected) =
            address(arithmeticReference).staticcall(abi.encodeCall(arithmeticReference.delta, (words)));
        assertEq(ok, refOk);
        if (ok) {
            assertEq(output, expected);
        }
    }

    function testPublicDeltaZeroNumeratorAndDenominator() public view {
        uint256[11] memory words;
        words[9] = 1;
        words[10] = 6;
        (bool ok,) = address(arithmeticFe).staticcall(abi.encodeCall(arithmeticFe.delta, (words)));
        assertFalse(ok);
        (ok,) = address(arithmeticReference).staticcall(abi.encodeCall(arithmeticReference.delta, (words)));
        assertFalse(ok);
        words[10] = MODULUS - ((1 << 28) + 5);
        assertEq(arithmeticFe.delta(words), 0);
        assertEq(arithmeticReference.delta(words), 0);
    }

    function testFuzzInterpolation(uint256[9] memory values, uint256 u) public view {
        for (uint256 i; i < 9; ++i) {
            values[i] %= MODULUS;
        }
        u = 9 + u % (MODULUS - 9);
        assertEq(arithmeticFe.interpolate(values, u), arithmeticReference.interpolate(values, u));
    }

    function testInterpolationKnownPolynomialAndDomainRejection() public view {
        uint256[9] memory values;
        for (uint256 i; i < 9; ++i) {
            values[i] = i * i + 3 * i + 7;
        }
        assertEq(arithmeticFe.interpolate(values, 11), 161);
        for (uint256 u; u < 9; ++u) {
            (bool ok,) = address(arithmeticFe).staticcall(abi.encodeCall(arithmeticFe.interpolate, (values, u)));
            assertFalse(ok);
            (ok,) =
                address(arithmeticReference).staticcall(abi.encodeCall(arithmeticReference.interpolate, (values, u)));
            assertFalse(ok);
        }
    }

    function testFixtureTranscriptEveryChallenge() public view {
        (bytes memory data, bytes32[] memory inputs) = loadFixture("arithmetic");
        assertTranscript(data, inputs);
    }

    function testFuzzTranscriptEveryChallenge(uint256 seed, uint256 input) public view {
        bytes memory data = new bytes(4544);
        for (uint256 i; i < 142; ++i) {
            uint256 word = uint256(keccak256(abi.encode(seed, i))) % limit(i);
            assembly { mstore(add(add(data, 32), mul(i, 32)), word) }
        }
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(input % MODULUS);
        assertTranscript(data, inputs);
    }

    function testTranscriptRejectsNoncanonicalAndWrongCountInputs() public view {
        bytes memory data = new bytes(4544);
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(MODULUS);
        (bool ok,) = address(transcriptFe).staticcall(abi.encodeCall(transcriptFe.transcript, (data, inputs)));
        assertFalse(ok);
        (ok,) = address(transcriptFe).staticcall(abi.encodeCall(transcriptFe.transcript, (data, new bytes32[](0))));
        assertFalse(ok);
        (ok,) = address(transcriptFe).staticcall(abi.encodeCall(transcriptFe.transcript, (data, new bytes32[](2))));
        assertFalse(ok);
    }

    function assertTranscript(bytes memory data, bytes32[] memory inputs) private view {
        assertEq(
            abi.encode(transcriptFe.transcript(data, inputs)),
            abi.encode(this.transcriptReference(data, inputs)),
            "transcript challenge differs"
        );
    }

    function transcriptReference(bytes calldata data, bytes32[] calldata inputs)
        external
        pure
        returns (uint256[49] memory words)
    {
        Honk.ZKProof memory p = ZKTranscriptLib.loadProof(data, LOG_N);
        ZKTranscript memory t = ZKTranscriptLib.generateTranscript(p, inputs, VK_HASH, NUMBER_OF_PUBLIC_INPUTS, LOG_N);
        words[0] = Fr.unwrap(t.relationParameters.eta);
        words[1] = Fr.unwrap(t.relationParameters.romLogupGamma);
        words[2] = Fr.unwrap(t.relationParameters.beta);
        words[3] = Fr.unwrap(t.relationParameters.gamma);
        for (uint256 i; i < 30; ++i) {
            words[4 + i] = Fr.unwrap(t.alphas[i]);
        }
        for (uint256 i; i < LOG_N; ++i) {
            words[34 + i] = Fr.unwrap(t.gateChallenges[i]);
        }
        words[39] = Fr.unwrap(t.libraChallenge);
        for (uint256 i; i < LOG_N; ++i) {
            words[40 + i] = Fr.unwrap(t.sumCheckUChallenges[i]);
        }
        words[45] = Fr.unwrap(t.rho);
        words[46] = Fr.unwrap(t.geminiR);
        words[47] = Fr.unwrap(t.shplonkNu);
        words[48] = Fr.unwrap(t.shplonkZ);
    }

    function testFuzzExactWordHashing(uint256 a, uint256 b, uint256 c) public view {
        (uint256 empty, uint256 single, uint256 triple, uint256 reduced) = fe.hash([a, b, c]);
        assertEq(empty, uint256(keccak256(hex"")));
        assertEq(single, uint256(keccak256(abi.encodePacked(a))));
        assertEq(triple, uint256(keccak256(abi.encodePacked(a, b, c))));
        assertEq(reduced, triple % MODULUS);
    }

    function testHashLeadingZerosAndOrder() public view {
        this.testFuzzExactWordHashing(0, 1, type(uint256).max);
        (,, uint256 left,) = fe.hash([uint256(0), 1, 2]);
        (,, uint256 right,) = fe.hash([uint256(0), 2, 1]);
        assertNotEq(left, right);
    }

    function testEveryDecodedFixtureField() public view {
        bytes memory data = vm.readFileBinary("fixtures/arithmetic/artifacts/proof");
        assertDecoded(data);
    }

    function testFuzzCanonicalDecodedFields(uint256 seed) public view {
        bytes memory data = new bytes(4544);
        for (uint256 i; i < 142; ++i) {
            uint256 word = uint256(keccak256(abi.encode(seed, i))) % limit(i);
            assembly { mstore(add(add(data, 32), mul(i, 32)), word) }
        }
        assertDecoded(data);
    }

    function testDecoderRejectsTruncatedAndExtendedPayloads() public view {
        uint256[6] memory sizes = [uint256(0), 31, 256, 4512, 4543, 4545];
        for (uint256 i; i < sizes.length; ++i) {
            (bool ok,) = address(fe).staticcall(abi.encodeCall(fe.decode, (new bytes(sizes[i]))));
            assertFalse(ok, "bad proof size accepted");
        }
    }

    function testEveryEncodingBoundary() public view {
        bytes memory data = new bytes(4544);
        for (uint256 i; i < 142; ++i) {
            uint256 bound = limit(i);
            assembly { mstore(add(add(data, 32), mul(i, 32)), sub(bound, 1)) }
            assertDecoded(data); // The maximum legal value is preserved, not reduced.
            assembly { mstore(add(add(data, 32), mul(i, 32)), bound) }
            (bool ok,) = address(fe).staticcall(abi.encodeCall(fe.decode, (data)));
            assertFalse(ok, "noncanonical word accepted");
            (ok,) = address(this).staticcall(abi.encodeCall(this.decodeReference, (data)));
            assertFalse(ok, "reference accepted boundary");
            assembly { mstore(add(add(data, 32), mul(i, 32)), 0) }
        }
    }

    function limit(uint256 i) private pure returns (uint256) {
        if (i < 8) {
            return uint256(1) << (i % 2 == 0 ? 136 : 120);
        }
        if ((i >= 8 && i < 28) || (i >= 117 && i < 129) || i >= 138) {
            return Q;
        }
        return MODULUS;
    }

    function assertDecoded(bytes memory data) private view {
        assertEq(abi.encode(fe.decode(data)), abi.encode(this.decodeReference(data)), "named decoded fields differ");
    }

    function decodeReference(bytes calldata data) external pure returns (uint256[142] memory words) {
        Honk.ZKProof memory p = ZKTranscriptLib.loadProof(data, LOG_N);
        uint256 at;
        for (uint256 i; i < 8; ++i) {
            words[at++] = Fr.unwrap(p.pairingPointObject[i]);
        }
        Honk.G1Point[12] memory commitments = [
            p.w1,
            p.w2,
            p.w3,
            p.w4,
            p.zPerm,
            p.lookupReadCounts,
            p.lookupReadTags,
            p.lookupInverses,
            p.geminiMaskingPoly,
            p.libraCommitments[0],
            p.libraCommitments[1],
            p.libraCommitments[2]
        ];
        for (uint256 i; i < 12; ++i) {
            words[at++] = commitments[i].x;
            words[at++] = commitments[i].y;
        }
        words[at++] = Fr.unwrap(p.libraSum);
        for (uint256 i; i < LOG_N; ++i) {
            for (uint256 k; k < 9; ++k) {
                words[at++] = Fr.unwrap(p.sumcheckUnivariates[i][k]);
            }
        }
        for (uint256 i; i < 42; ++i) {
            words[at++] = Fr.unwrap(p.sumcheckEvaluations[i]);
        }
        words[at++] = Fr.unwrap(p.libraEvaluation);
        for (uint256 i; i < LOG_N - 1; ++i) {
            words[at++] = p.geminiFoldComms[i].x;
            words[at++] = p.geminiFoldComms[i].y;
        }
        for (uint256 i; i < LOG_N; ++i) {
            words[at++] = Fr.unwrap(p.geminiAEvaluations[i]);
        }
        for (uint256 i; i < 4; ++i) {
            words[at++] = Fr.unwrap(p.libraPolyEvals[i]);
        }
        words[at++] = p.shplonkQ.x;
        words[at++] = p.shplonkQ.y;
        words[at++] = p.kzgQuotient.x;
        words[at++] = p.kzgQuotient.y;
        assertEq(at, 142);
    }

    function testEveryVerificationKeyValue() public view {
        uint256[60] memory words = fe.key();
        assertEq(words[0], N);
        assertEq(words[1], LOG_N);
        assertEq(words[2], NUMBER_OF_PUBLIC_INPUTS);
        assertEq(words[3], VK_HASH);
        Honk.VerificationKey memory vk = HonkVerificationKey.loadVerificationKey();
        Honk.G1Point[28] memory points = [
            vk.s1,
            vk.s2,
            vk.s3,
            vk.s4,
            vk.id1,
            vk.id2,
            vk.id3,
            vk.id4,
            vk.lagrangeFirst,
            vk.lagrangeLast,
            vk.qLookup,
            vk.t1,
            vk.t2,
            vk.t3,
            vk.t4,
            vk.qm,
            vk.qr,
            vk.qo,
            vk.qc,
            vk.ql,
            vk.q4,
            vk.qArith,
            vk.qDeltaRange,
            vk.qElliptic,
            vk.qMemory,
            vk.qNnf,
            vk.qPoseidon2External,
            vk.qPoseidon2Internal
        ];
        for (uint256 i; i < 28; ++i) {
            assertEq(words[4 + 2 * i], points[i].x, "VK coordinate differs");
            assertEq(words[5 + 2 * i], points[i].y, "VK coordinate differs");
        }
        assertEq(N, uint256(1) << LOG_N);
        assertGe(LOG_N, 1);
        assertLe(LOG_N, 25);
        assertGe(NUMBER_OF_PUBLIC_INPUTS, 8);
        assertEq(vm.readFileBinary("fixtures/arithmetic/artifacts/proof").length, 32 * (82 + 12 * LOG_N));
    }
}
