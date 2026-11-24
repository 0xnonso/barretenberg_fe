// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MsmReference} from "./helpers/MsmReference.sol";
import {FeTest} from "./helpers/FeTest.sol";
import {
    Errors,
    Honk,
    Fr,
    MODULUS,
    Q,
    ecMul,
    mulWithSeperator,
    generateRecursionSeparator
} from "../../reference/solidity/generated/ArithmeticVerifier.sol";

interface IAccumulatorProbe {
    function combine(uint256[4] calldata base, uint256[8] calldata limbs) external view returns (uint256[5] memory);
    function msm(uint256[141] calldata words) external view returns (uint256, uint256);
    function pair(uint256[4] calldata points) external view returns (bool);
}

contract AccumulatorTest is FeTest {
    IAccumulatorProbe private fe;
    MsmReference private refMsm;

    function setUp() public {
        fe = IAccumulatorProbe(deployProbe("AccumulatorProbe"));
        refMsm = new MsmReference();
    }

    function testFuzzNondefaultAccumulator(uint256 seed) public view {
        Honk.G1Point memory a = point(seed);
        Honk.G1Point memory b = point(uint256(keccak256(abi.encode(seed))));
        Honk.G1Point memory c = point(uint256(keccak256(abi.encode(seed, uint256(1)))));
        Honk.G1Point memory d = point(uint256(keccak256(abi.encode(seed, uint256(2)))));
        uint256[8] memory limbs = encode(c, d);
        Fr[8] memory fields;
        for (uint256 i; i < 8; ++i) {
            fields[i] = Fr.wrap(limbs[i]);
        }
        Fr separator = generateRecursionSeparator(fields, a, b);
        uint256[5] memory actual = fe.combine([a.x, a.y, b.x, b.y], limbs);
        a = mulWithSeperator(a, c, separator);
        b = mulWithSeperator(b, d, separator);
        assertEq(abi.encode(actual), abi.encode([a.x, a.y, b.x, b.y, Fr.unwrap(separator)]));
    }

    function testDefaultAccumulator() public view {
        uint256[8] memory zero;
        uint256[5] memory actual = fe.combine([uint256(1), 2, 0, 0], zero);
        assertEq(actual[0], 1);
        assertEq(actual[1], 2);
        assertEq(actual[2], 0);
        assertEq(actual[3], 0);
    }

    function testBadAccumulatorEncodingsReject() public view {
        uint256[4] memory base = [uint256(1), 2, 1, 2];
        uint256[8] memory limbs = encode(Honk.G1Point(1, 2), Honk.G1Point(1, 2));
        for (uint256 i; i < 8; ++i) {
            uint256 old = limbs[i];
            limbs[i] = uint256(1) << (i % 2 == 0 ? 136 : 120);
            rejects(base, limbs);
            limbs[i] = old;
        }
        limbs[0] = 0; // mixed infinity
        limbs[1] = 0;
        limbs[2] = 0;
        limbs[3] = 0;
        rejects(base, limbs);
        limbs[0] = 1; // off curve
        limbs[2] = 3;
        rejects(base, limbs);
        limbs[0] = Q & ((1 << 136) - 1); // noncanonical
        limbs[1] = Q >> 136;
        rejects(base, limbs);
    }

    function testAccumulatorErrorPayloadAndPrecedence() public {
        uint256[8] memory limbs = encode(Honk.G1Point(0, 0), Honk.G1Point(1, 2));
        sameAccumulatorError(limbs, Errors.PointAtInfinity.selector);
        // A later noncanonical coordinate must win over an earlier identity.
        limbs = encode(Honk.G1Point(0, 0), Honk.G1Point(Q, 2));
        sameAccumulatorError(limbs, Errors.ValueGeGroupOrder.selector);
        // Identity rejection precedes an earlier off-curve point's precompile failure.
        limbs = encode(Honk.G1Point(1, 3), Honk.G1Point(0, 0));
        sameAccumulatorError(limbs, Errors.PointAtInfinity.selector);
    }

    function sameAccumulatorError(uint256[8] memory limbs, bytes4 selector) private {
        uint256[4] memory base = [uint256(1), 2, 1, 2];
        vm.expectRevert(selector);
        fe.combine(base, limbs);
        vm.expectRevert(selector);
        refMsm.accumulator(limbs);
    }

    function testFuzzMsm(uint256 seed) public view {
        uint256[141] memory words;
        for (uint256 i; i < 47; ++i) {
            if (i % 7 != 0) {
                words[3 * i] = 1;
                words[3 * i + 1] = 2;
            }
            if (i % 5 != 0) {
                words[3 * i + 2] = uint256(keccak256(abi.encode(seed, i))) % MODULUS;
            }
        }
        (uint256 x, uint256 y) = fe.msm(words);
        (uint256 rx, uint256 ry) = refMsm.msm(words);
        assertEq(x, rx);
        assertEq(y, ry);
    }

    function testMsmInvalidPointWithZeroScalarRejects() public view {
        uint256[141] memory words;
        words[0] = 1;
        words[1] = 3;
        (bool ok,) = address(fe).staticcall{gas: 2_000_000}(abi.encodeCall(fe.msm, (words)));
        assertFalse(ok);
        (ok,) = address(refMsm).staticcall{gas: 2_000_000}(abi.encodeCall(refMsm.msm, (words)));
        assertFalse(ok);
    }

    function testFinalPairingIdentityAndChangedPoint() public view {
        assertTrue(fe.pair([uint256(0), 0, 0, 0]));
        assertFalse(fe.pair([uint256(1), 2, 0, 0]));
    }

    function rejects(uint256[4] memory base, uint256[8] memory limbs) private view {
        (bool ok,) = address(fe).staticcall(abi.encodeCall(fe.combine, (base, limbs)));
        assertFalse(ok);
    }

    function point(uint256 seed) private view returns (Honk.G1Point memory) {
        return ecMul(Fr.wrap(seed % (MODULUS - 1) + 1), Honk.G1Point(1, 2));
    }

    function encode(Honk.G1Point memory a, Honk.G1Point memory b) private pure returns (uint256[8] memory limbs) {
        uint256[4] memory coords = [a.x, a.y, b.x, b.y];
        for (uint256 i; i < 4; ++i) {
            limbs[2 * i] = coords[i] & ((1 << 136) - 1);
            limbs[2 * i + 1] = coords[i] >> 136;
        }
    }
}
