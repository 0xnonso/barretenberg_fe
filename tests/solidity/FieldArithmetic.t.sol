// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeTest} from "./helpers/FeTest.sol";

// Actual pinned Barretenberg definitions, already in our generated reference.
import {Fr as ReferenceFr, FrLib, MODULUS} from "../../reference/solidity/generated/ArithmeticVerifier.sol";

interface IFieldProbe {
    function calculate(uint256 a, uint256 b)
        external
        pure
        returns (uint256 sum, uint256 difference, uint256 product, uint256 negative, bool equal);
}

contract FieldArithmeticTest is FeTest {
    IFieldProbe private fe;

    function setUp() public {
        fe = IFieldProbe(deployProbe("FieldProbe"));
    }

    function testBoundaryCrossProductMatchesBarretenberg() public view {
        uint256[8] memory values =
            [uint256(0), 1, 2, MODULUS - 1, MODULUS - 2, uint256(1) << 128, uint256(1) << 200, MODULUS / 2];
        for (uint256 i; i < values.length; ++i) {
            for (uint256 j; j < values.length; ++j) {
                assertMatches(values[i], values[j]);
            }
        }
    }

    function testFuzzArithmeticMatchesBarretenberg(uint256 a, uint256 b) public view {
        assertMatches(a % MODULUS, b % MODULUS);
    }

    function testProductUsesBitsBeyondU256() public view {
        uint256 a = uint256(1) << 128;
        (,, uint256 product,,) = fe.calculate(a, a);
        // Independently computed with Python arbitrary-precision integers.
        assertEq(product, 6350874878119819312338956282401532410528162663560392320966563075034087161851);
        uint256 truncated;
        unchecked {
            truncated = a * a;
        }
        assertEq(truncated, 0, "truncation test ineffective");
        assertNotEq(product, truncated % MODULUS, "truncation test ineffective");
        (,, product,,) = fe.calculate(MODULUS - 1, MODULUS - 1);
        assertEq(product, 1);
    }

    function testZeroNegationIsCanonical() public view {
        (,,, uint256 negative,) = fe.calculate(0, 0);
        assertEq(negative, 0);
        // Reference uses r internally for -0. Fe's private Fr invariant forbids it.
        assertEq(ReferenceFr.unwrap(FrLib.neg(ReferenceFr.wrap(0))), MODULUS);
    }

    function testRejectsNoncanonicalOperands() public view {
        uint256[4] memory invalid = [
            MODULUS,
            MODULUS + 1,
            uint256(21888242871839275222246405745257275088696311157297823662689037894645226208583),
            type(uint256).max
        ];
        for (uint256 i; i < invalid.length; ++i) {
            uint256 before = gasleft();
            (bool left, bytes memory leftError) =
                address(fe).staticcall{gas: 100_000}(abi.encodeCall(fe.calculate, (invalid[i], 1)));
            (bool right, bytes memory rightError) =
                address(fe).staticcall{gas: 100_000}(abi.encodeCall(fe.calculate, (1, invalid[i])));
            assertFalse(left, "out-of-field operand accepted");
            assertFalse(right, "out-of-field operand accepted");
            assertLt(before - gasleft(), 50_000, "rejection consumed forwarded gas");
            assertEq(leftError.length, 0, "expected explicit empty revert");
            assertEq(rightError.length, 0, "expected explicit empty revert");
        }
    }

    function testFuzzFieldLaws(uint256 a, uint256 b, uint256 c) public view {
        a %= MODULUS;
        b %= MODULUS;
        c %= MODULUS;
        (uint256 sum,, uint256 ab, uint256 negA,) = fe.calculate(a, b);
        (, uint256 recovered,,,) = fe.calculate(sum, b);
        assertEq(recovered, a, "addition/subtraction inverse");
        (uint256 zero,,,,) = fe.calculate(a, negA);
        assertEq(zero, 0, "additive inverse");
        (,,, uint256 doubleNeg,) = fe.calculate(negA, 0);
        assertEq(doubleNeg, a, "double negation");
        (uint256 bc,,,,) = fe.calculate(b, c);
        (,, uint256 lhs,,) = fe.calculate(a, bc);
        (,, uint256 ac,,) = fe.calculate(a, c);
        (uint256 rhs,,,,) = fe.calculate(ab, ac);
        assertEq(lhs, rhs, "distributivity");
    }

    function assertMatches(uint256 a, uint256 b) private view {
        (uint256 sum, uint256 difference, uint256 product, uint256 negative, bool equal) = fe.calculate(a, b);
        ReferenceFr x = FrLib.from(a);
        ReferenceFr y = FrLib.from(b);
        assertEq(sum, ReferenceFr.unwrap(x + y), "addition differs");
        assertEq(difference, ReferenceFr.unwrap(x - y), "subtraction differs");
        assertEq(product, ReferenceFr.unwrap(x * y), "multiplication differs");
        assertEq(negative, ReferenceFr.unwrap(FrLib.neg(x)) % MODULUS, "negation differs modulo r");
        assertEq(equal, (x == y), "equality differs");
        assertLt(sum, MODULUS, "result is not canonical");
        assertLt(difference, MODULUS, "result is not canonical");
        assertLt(product, MODULUS, "result is not canonical");
        assertLt(negative, MODULUS, "result is not canonical");
    }
}
