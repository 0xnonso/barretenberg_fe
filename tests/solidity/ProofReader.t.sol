// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SolidityReaderReference} from "./helpers/SolidityReaderReference.sol";
import {FeTest} from "./helpers/FeTest.sol";

import {MODULUS, Q} from "../../reference/solidity/generated/ArithmeticVerifier.sol";

interface IReaderProbe {
    // kind: 0=raw, 1=Fr, 2=Fq, 3=G1. code: 0=ok, 1=short, 2=Fr, 3=Fq.
    function read(bytes calldata data, uint256 start, uint256 kind)
        external
        pure
        returns (uint256 code, uint256 first, uint256 second, uint256 position, uint256 remaining);
}

contract ProofReaderTest is FeTest {
    IReaderProbe private fe;
    SolidityReaderReference private referenceReader;

    function setUp() public {
        fe = IReaderProbe(deployProbe("ReaderProbe"));
        referenceReader = new SolidityReaderReference();
    }

    function testBigEndianAndUnalignedWords() public view {
        uint256 distinctive = 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20;
        bytes memory data = abi.encodePacked(distinctive, type(uint256).max, uint256(0));
        for (uint256 start; start <= 64; ++start) {
            assertMatches(data, start, 0);
        }
        (, uint256 word,,,) = fe.read(data, 0, 0);
        assertEq(word, distinctive, "wrong byte order");
        (, word,,,) = fe.read(data, 32, 0);
        assertEq(word, type(uint256).max, "raw word reduced");
    }

    function testEveryShortWidthAndExactBoundary() public view {
        for (uint256 len; len <= 65; ++len) {
            bytes memory data = new bytes(len);
            for (uint256 kind; kind < 4; ++kind) {
                assertMatches(data, 0, kind);
                assertMatches(data, 1, kind);
                assertMatches(data, len, kind);
            }
        }
    }

    function testScalarAndCoordinateBoundaries() public view {
        uint256[7] memory words = [uint256(0), 1, MODULUS - 1, MODULUS, Q - 1, Q, type(uint256).max];
        for (uint256 i; i < words.length; ++i) {
            bytes memory data = abi.encode(words[i]);
            for (uint256 kind; kind < 3; ++kind) {
                assertMatches(data, 0, kind);
            }
        }
        (uint256 code,,,,) = fe.read(abi.encode(MODULUS), 0, 1);
        assertEq(code, 2, "noncanonical scalar must not reduce to zero");
        (code,,,,) = fe.read(abi.encode(MODULUS), 0, 2);
        assertEq(code, 0, "scalar modulus is a valid coordinate");
    }

    function testPointsCheckBothCoordinatesAndPermitIdentityAndOffCurve() public view {
        uint256[5] memory words = [uint256(0), 1, Q - 1, Q, type(uint256).max];
        for (uint256 i; i < words.length; ++i) {
            for (uint256 j; j < words.length; ++j) {
                assertMatches(abi.encode(words[i], words[j]), 0, 3);
            }
        }
        (uint256 code,,,,) = fe.read(abi.encode(uint256(1), uint256(1)), 0, 3);
        assertEq(code, 0, "reader must not claim curve validation");
    }

    function testInvalidPointAtNonzeroCursorDoesNotConsumePartOfPoint() public view {
        bytes memory data = abi.encode(uint256(7), uint256(1), Q);
        assertMatches(data, 32, 3);
        (uint256 code,,, uint256 position, uint256 remaining) = fe.read(data, 32, 3);
        assertEq(code, 3, "partial point consumed");
        assertEq(position, 32, "partial point consumed");
        assertEq(remaining, 64, "partial point consumed");
    }

    function testOversizedCursorCannotWrapIntoPayload() public view {
        bytes memory data = abi.encode(uint256(7));
        uint256[4] memory offsets = [uint256(33), type(uint256).max, type(uint256).max - 31, uint256(1) << 255];
        for (uint256 i; i < offsets.length; ++i) {
            for (uint256 kind; kind < 4; ++kind) {
                assertMatches(data, offsets[i], kind);
            }
        }
    }

    function testAllFixtureWordsAndSelectedTypedSectionsMatchSolidity() public view {
        bytes memory proof = vm.readFileBinary("fixtures/arithmetic/artifacts/proof");
        assertEq(proof.length, 4544);
        for (uint256 offset; offset < proof.length; offset += 32) {
            assertMatches(proof, offset, 0);
        }
        // ZKTranscript.loadProof: eight accumulator limbs, then ten G1 points.
        for (uint256 offset = 256; offset < 896; offset += 64) {
            assertMatches(proof, offset, 3);
        }
        // Libra sum and the first sumcheck round's nine scalar evaluations.
        for (uint256 offset = 896; offset < 1216; offset += 32) {
            assertMatches(proof, offset, 1);
        }
    }

    function testFuzzRawWordsAndUnalignedOffsets(uint256 a, uint256 b, uint256 c, uint8 offset) public view {
        assertMatches(abi.encode(a, b, c), uint256(offset) % 97, 0);
    }

    function testFuzzFieldAndPointAcceptance(uint256 x, uint256 y, uint8 prefix) public view {
        bytes memory padding = new bytes(uint256(prefix) % 8);
        bytes memory data = abi.encodePacked(padding, x, y);
        for (uint256 kind = 1; kind < 4; ++kind) {
            assertMatches(data, padding.length, kind);
        }
        assertMatches(abi.encode(x % Q, y % Q), 0, 3);
    }

    function testFuzzTruncationAndCursor(bytes memory data, uint256 start, uint8 kind) public view {
        // Bound work, retaining arbitrary bytes/lengths and huge offsets.
        if (data.length > 160) {
            return;
        }
        assertMatches(data, start, uint256(kind) % 4);
        assertMatches(data, start % (data.length + 1), uint256(kind) % 4);
    }

    function assertMatches(bytes memory data, uint256 start, uint256 kind) private view {
        (uint256 code, uint256 first, uint256 second, uint256 position, uint256 remaining) = fe.read(data, start, kind);
        (bool ok, bytes memory output) =
            address(referenceReader).staticcall(abi.encodeCall(referenceReader.read, (data, start, kind)));
        assertEq((code == 0), ok, "Fe/Solidity acceptance differs");
        if (ok) {
            (uint256 expectedFirst, uint256 expectedSecond) = abi.decode(output, (uint256, uint256));
            assertEq(first, expectedFirst, "decoded values differ");
            assertEq(second, expectedSecond, "decoded values differ");
            assertEq(position, start + (kind == 3 ? 64 : 32), "wrong cursor advance");
        } else {
            assertEq(first, 0, "failure leaked partial values");
            assertEq(second, 0, "failure leaked partial values");
            assertEq(position, (start <= data.length ? start : 0), "failed read advanced cursor");
            if (start > data.length || data.length - start < (kind == 3 ? 64 : 32)) {
                assertEq(code, 1, "expected bounds error");
            } else {
                assertEq(code, (kind == 1 ? 2 : 3), "expected canonicality error");
            }
        }
        assertLe(position, data.length, "reader invariant broken");
        assertEq(remaining, data.length - position, "reader invariant broken");
    }
}
