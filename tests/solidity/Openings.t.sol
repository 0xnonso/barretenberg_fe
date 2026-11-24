// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeTest} from "./helpers/FeTest.sol";
import {OpeningReference} from "./helpers/OpeningReference.sol";
import {
    Errors,
    Honk,
    Fr,
    MODULUS,
    Q,
    ZKTranscript,
    ZKTranscriptLib,
    LOG_N,
    VK_HASH,
    NUMBER_OF_PUBLIC_INPUTS
} from "../../reference/solidity/generated/ArithmeticVerifier.sol";

interface IOpeningProbe {
    function terms(bytes calldata data, bytes32[] calldata inputs) external view returns (uint256[141] memory);
}

interface IGeminiProbe {
    function fold(uint256[5] calldata u, uint256 batched, uint256[5] calldata negative, uint256 r)
        external
        view
        returns (uint256[5] memory, uint256[5] memory);
}

interface ILibraProbe {
    function libra(uint256[4] calldata evaluations, uint256 r, uint256[5] calldata u, uint256 claimed)
        external
        view
        returns (bool);
}

contract OpeningsTest is FeTest {
    IOpeningProbe private opening;
    IGeminiProbe private gemini;
    ILibraProbe private libra;
    OpeningReference private referenceOpening;

    function setUp() public {
        opening = IOpeningProbe(deployProbe("OpeningProbe"));
        gemini = IGeminiProbe(deployProbe("GeminiProbe"));
        libra = ILibraProbe(deployProbe("LibraProbe"));
        referenceOpening = new OpeningReference();
    }

    function testFixtureEveryOpeningTerm() public view {
        (bytes memory data, bytes32[] memory inputs) = loadFixture("arithmetic");
        assertEq(
            abi.encode(opening.terms(data, inputs)),
            abi.encode(referenceOpening.terms(data, inputs)),
            "opening term differs"
        );
    }

    function testFuzzEveryOpeningTerm(uint256 seed) public view {
        bytes memory data = new bytes(4544);
        for (uint256 i; i < 142; ++i) {
            uint256 bound = i < 8
                ? uint256(1) << (i % 2 == 0 ? 136 : 120)
                : ((i < 28 || (i >= 117 && i < 129) || i >= 138) ? Q : MODULUS);
            uint256 value = uint256(keccak256(abi.encode(seed, i))) % bound;
            assembly { mstore(add(add(data, 32), mul(i, 32)), value) }
        }
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(seed % MODULUS);
        assertEq(
            abi.encode(opening.terms(data, inputs)),
            abi.encode(referenceOpening.terms(data, inputs)),
            "random opening term differs"
        );
    }

    function testFuzzGeminiFolds(uint256[5] memory u, uint256 batched, uint256[5] memory negative, uint256 r)
        public
        view
    {
        for (uint256 i; i < 5; ++i) {
            u[i] %= MODULUS;
            negative[i] %= MODULUS;
        }
        batched %= MODULUS;
        r %= MODULUS;
        (bool ok, bytes memory output) =
            address(gemini).staticcall(abi.encodeCall(gemini.fold, (u, batched, negative, r)));
        (bool refOk, bytes memory expected) =
            address(referenceOpening).staticcall(abi.encodeCall(referenceOpening.fold, (u, batched, negative, r)));
        assertEq(ok, refOk);
        if (ok) {
            assertEq(output, expected, "Gemini folds differ");
        }
    }

    function testGeminiZeroDenominatorRejects() public {
        uint256[5] memory zero;
        vm.expectRevert(Errors.InvertOfZero.selector);
        gemini.fold(zero, 0, zero, 0);
        vm.expectRevert(Errors.InvertOfZero.selector);
        referenceOpening.fold(zero, 0, zero, 0);
    }

    function testFixtureLibraConsistencyAndMutations() public view {
        (bytes memory data, bytes32[] memory inputs) = loadFixture("arithmetic");
        (uint256[4] memory evaluations, uint256 r, uint256[5] memory u, uint256 claimed) =
            this.libraInputs(data, inputs);
        assertTrue(libra.libra(evaluations, r, u, claimed));
        assertTrue(referenceOpening.libra(evaluations, r, u, claimed));
        for (uint256 i; i < 4; ++i) {
            uint256 old = evaluations[i];
            evaluations[i] = addmod(old, 1, MODULUS);
            assertFalse(libra.libra(evaluations, r, u, claimed));
            assertFalse(referenceOpening.libra(evaluations, r, u, claimed));
            evaluations[i] = old;
        }
    }

    function testFuzzLibraConsistency(uint256[4] memory evaluations, uint256 r, uint256[5] memory u, uint256 claimed)
        public
        view
    {
        for (uint256 i; i < 4; ++i) {
            evaluations[i] %= MODULUS;
        }
        for (uint256 i; i < 5; ++i) {
            u[i] %= MODULUS;
        }
        r %= MODULUS;
        claimed %= MODULUS;
        (bool ok, bytes memory output) =
            address(libra).staticcall(abi.encodeCall(libra.libra, (evaluations, r, u, claimed)));
        (bool refOk, bytes memory expected) =
            address(referenceOpening).staticcall(abi.encodeCall(referenceOpening.libra, (evaluations, r, u, claimed)));
        assertEq(ok, refOk);
        if (ok) {
            assertEq(output, expected);
        }
    }

    function testLibraSubgroupAndZeroPolynomial() public {
        uint256[4] memory evaluations;
        uint256[5] memory u;
        uint256[2] memory roots =
            [uint256(1), uint256(0x07b0c561a6148404f086204a9f36ffb0617942546750f230c893619174a57a76)];
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert(Errors.GeminiChallengeInSubgroup.selector);
            libra.libra(evaluations, roots[i], u, 0);
            vm.expectRevert(Errors.GeminiChallengeInSubgroup.selector);
            referenceOpening.libra(evaluations, roots[i], u, 0);
        }
        assertTrue(libra.libra(evaluations, 0, u, 0));
        assertTrue(referenceOpening.libra(evaluations, 0, u, 0));
        assertTrue(libra.libra(evaluations, 2, u, 0));
        assertTrue(referenceOpening.libra(evaluations, 2, u, 0));
    }

    function libraInputs(bytes calldata data, bytes32[] calldata inputs)
        external
        pure
        returns (uint256[4] memory evaluations, uint256 r, uint256[5] memory u, uint256 claimed)
    {
        Honk.ZKProof memory p = ZKTranscriptLib.loadProof(data, LOG_N);
        ZKTranscript memory t = ZKTranscriptLib.generateTranscript(p, inputs, VK_HASH, NUMBER_OF_PUBLIC_INPUTS, LOG_N);
        for (uint256 i; i < 4; ++i) {
            evaluations[i] = Fr.unwrap(p.libraPolyEvals[i]);
        }
        for (uint256 i; i < 5; ++i) {
            u[i] = Fr.unwrap(t.sumCheckUChallenges[i]);
        }
        r = Fr.unwrap(t.geminiR);
        claimed = Fr.unwrap(p.libraEvaluation);
    }
}
