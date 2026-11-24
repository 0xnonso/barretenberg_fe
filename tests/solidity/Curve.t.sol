// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SolidityCurveReference} from "./helpers/SolidityCurveReference.sol";
import {FeTest} from "./helpers/FeTest.sol";

import {MODULUS, Q} from "../../reference/solidity/generated/ArithmeticVerifier.sol";

interface ICurveProbe {
    function add(uint256 x1, uint256 y1, uint256 x2, uint256 y2) external view returns (uint256, uint256);
    function mul(uint256 x, uint256 y, uint256 scalar) external view returns (uint256, uint256);
    function negate(uint256 x, uint256 y) external pure returns (uint256, uint256);
    function validate(uint256 x, uint256 y) external pure returns (uint256, uint256);
    function tryAdd(uint256 x1, uint256 y1, uint256 x2, uint256 y2) external view returns (uint256, uint256, uint256);
    function tryMul(uint256 x, uint256 y, uint256 scalar) external view returns (uint256, uint256, uint256);
    function tryValidate(uint256 x, uint256 y) external pure returns (uint256, uint256, uint256);
}

contract CurveTest is FeTest {
    ICurveProbe private fe;
    SolidityCurveReference private referenceCurve;

    function setUp() public {
        fe = ICurveProbe(deployProbe("CurveProbe"));
        referenceCurve = new SolidityCurveReference();
    }

    function testIndependentDoubleGeneratorVector() public view {
        (uint256 x, uint256 y) = fe.add(1, 2, 1, 2);
        assertEq(x, 1368015179489954701390400359078579693043519447331113978918064868415326638035);
        assertEq(y, 9918110051302171585080402603319702774565515993150576347155970296011118125764);
        (uint256 mx, uint256 my) = fe.mul(1, 2, 2);
        assertEq(x, mx);
        assertEq(y, my);
    }

    function testScalarBoundariesAndIdentity() public view {
        uint256[7] memory scalars = [uint256(0), 1, 2, MODULUS - 1, MODULUS - 2, uint256(1) << 128, uint256(1) << 253];
        for (uint256 i; i < scalars.length; ++i) {
            assertSame(abi.encodeCall(fe.mul, (1, 2, scalars[i])));
            assertSame(abi.encodeCall(fe.mul, (0, 0, scalars[i])));
        }
        assertSame(abi.encodeCall(fe.add, (0, 0, 0, 0)));
        assertSame(abi.encodeCall(fe.add, (1, 2, 0, 0)));
        assertSame(abi.encodeCall(fe.add, (0, 0, 1, 2)));
        assertSame(abi.encodeCall(fe.add, (1, 2, 1, Q - 2)));
        assertSame(abi.encodeCall(fe.negate, (0, 0)));
        assertSame(abi.encodeCall(fe.negate, (1, 2)));
        (uint256 x, uint256 y) = fe.mul(1, 2, MODULUS - 1);
        assertEq(x, 1);
        assertEq(y, Q - 2);
        (x, y) = fe.add(1, 2, 1, Q - 2);
        assertEq(x, 0);
        assertEq(y, 0);
    }

    function testFuzzValidGroupOperations(uint256 a, uint256 b) public view {
        a %= MODULUS;
        b %= MODULUS;
        // Generate points independently with pinned Solidity, then exercise Fe.
        (uint256 px, uint256 py) = referenceCurve.mul(1, 2, a);
        (uint256 qx, uint256 qy) = referenceCurve.mul(1, 2, b);
        assertSame(abi.encodeCall(fe.add, (px, py, qx, qy)));
        assertSame(abi.encodeCall(fe.mul, (px, py, b)));
        assertSame(abi.encodeCall(fe.negate, (px, py)));
        assertSame(abi.encodeCall(fe.validate, (px, py)));
        (uint256 x, uint256 y) = fe.add(px, py, qx, qy);
        (uint256 expectedX, uint256 expectedY) = referenceCurve.mul(1, 2, addmod(a, b, MODULUS));
        assertEq(x, expectedX, "linearity differs");
        assertEq(y, expectedY, "linearity differs");
        (x, y) = fe.negate(px, py);
        (x, y) = fe.negate(x, y);
        assertEq(x, px, "double negation differs");
        assertEq(y, py, "double negation differs");
    }

    function testFuzzCanonicalPointValidation(uint256 x, uint256 y) public view {
        x %= Q;
        y %= Q;
        (uint256 code, uint256 outX, uint256 outY) = fe.tryValidate(x, y);
        (bool ok,) = address(referenceCurve).staticcall{gas: 100_000}(abi.encodeCall(referenceCurve.validate, (x, y)));
        assertEq((code == 0), ok, "membership differs from EVM");
        if (ok) {
            assertEq(outX, x);
            assertEq(outY, y);
        } else {
            assertEq(code, 1);
            assertEq(outX, 0);
            assertEq(outY, 0);
        }
    }

    function testInvalidPointsRejectEvenWithZeroScalarOrIdentityOtherOperand() public view {
        uint256[2][5] memory invalid = [
            [uint256(1), uint256(1)],
            [uint256(0), uint256(1)],
            [uint256(1), uint256(0)],
            [uint256(0), uint256(2)],
            [Q - 1, uint256(2)]
        ];
        for (uint256 i; i < invalid.length; ++i) {
            uint256 x = invalid[i][0];
            uint256 y = invalid[i][1];
            bothReject(abi.encodeCall(fe.validate, (x, y)));
            bothReject(abi.encodeCall(fe.mul, (x, y, 0)));
            bothReject(abi.encodeCall(fe.add, (x, y, 0, 0)));
            bothReject(abi.encodeCall(fe.add, (0, 0, x, y)));
            feRejects(abi.encodeCall(fe.negate, (x, y)));
            // Solidity negateInplace is unchecked. Our negate requires a G1 first.
            (uint256 code,,) = fe.tryMul(x, y, 0);
            assertEq(code, 1);
        }
    }

    function testNoncanonicalCoordinatesAndScalarsReject() public view {
        uint256[3] memory badCoordinates = [Q, Q + 1, type(uint256).max];
        for (uint256 i; i < badCoordinates.length; ++i) {
            uint256 bad = badCoordinates[i];
            bothReject(abi.encodeCall(fe.add, (bad, 2, 1, 2)));
            bothReject(abi.encodeCall(fe.add, (1, 2, 1, bad)));
            bothReject(abi.encodeCall(fe.mul, (1, bad, 0)));
            bothReject(abi.encodeCall(fe.validate, (bad, 2)));
            feRejects(abi.encodeCall(fe.negate, (1, bad)));
        }
        bothReject(abi.encodeCall(fe.mul, (1, 2, MODULUS)));
        bothReject(abi.encodeCall(fe.mul, (0, 0, type(uint256).max)));
    }

    function testExactPrecompileInputEncoding() public {
        vm.expectCall(address(6), abi.encode(uint256(1), uint256(2), uint256(1), Q - 2));
        (uint256 x, uint256 y) = fe.add(1, 2, 1, Q - 2);
        assertEq(x, 0);
        assertEq(y, 0);
        vm.expectCall(address(7), abi.encode(uint256(1), uint256(2), MODULUS - 1));
        (x, y) = fe.mul(1, 2, MODULUS - 1);
        assertEq(x, 1);
        assertEq(y, Q - 2);
    }

    function testCallFailuresAreDistinctAndNeverIdentitySuccess() public {
        vm.mockCallRevert(address(6), bytes(""), hex"deadbeef");
        vm.mockCallRevert(address(7), bytes(""), hex"deadbeef");
        assertErrors(2, 3);
        (uint256 code,,) = fe.tryAdd(0, 0, 0, 0);
        assertEq(code, 2);
        (code,,) = fe.tryMul(1, 2, 0);
        assertEq(code, 3);
        (code,,) = fe.tryMul(0, 0, 0);
        assertEq(code, 3);
        feRejects(abi.encodeCall(fe.add, (1, 2, 1, 2)));
        feRejects(abi.encodeCall(fe.mul, (1, 2, 2)));
        vm.clearMockedCalls();
        assertSame(abi.encodeCall(fe.mul, (1, 2, 2)));
    }

    function testInvalidInputRemainsDistinctFromCallFailure() public {
        vm.mockCallRevert(address(6), bytes(""), hex"deadbeef");
        vm.mockCallRevert(address(7), bytes(""), hex"deadbeef");
        (uint256 code,,) = fe.tryAdd(1, 1, 0, 0);
        assertEq(code, 1);
        (code,,) = fe.tryAdd(0, 0, 1, 1);
        assertEq(code, 1);
        (code,,) = fe.tryMul(1, 1, 0);
        assertEq(code, 1);
        (uint256 x, uint256 y) = fe.negate(1, 2);
        assertEq(x, 1, "negation must not call a precompile");
        assertEq(y, Q - 2, "negation must not call a precompile");
        vm.clearMockedCalls();
    }

    function testRejectsWrongReturnLengths() public {
        uint256[6] memory sizes = [uint256(0), 1, 32, 63, 65, 96];
        for (uint256 i; i < sizes.length; ++i) {
            mockBoth(new bytes(sizes[i]));
            assertErrors(4, 4);
            vm.clearMockedCalls();
        }
        mockBoth(abi.encode(uint256(1), uint256(2), type(uint256).max));
        assertErrors(4, 4);
        vm.clearMockedCalls();
        mockBoth(abi.encode(uint256(1), uint256(2)));
        (uint256 code, uint256 x, uint256 y) = fe.tryAdd(1, 2, 1, 2);
        assertEq(code, 0);
        assertEq(x, 1);
        assertEq(y, 2);
        (code, x, y) = fe.tryMul(1, 2, 2);
        assertEq(code, 0);
        assertEq(x, 1);
        assertEq(y, 2);
        vm.clearMockedCalls();
    }

    function testFixtureCommitmentsMatchReference() public view {
        bytes memory proof = vm.readFileBinary("fixtures/arithmetic/artifacts/proof");
        assertEq(proof.length, 4544);
        for (uint256 offset = 256; offset < 896; offset += 64) {
            uint256 x;
            uint256 y;
            assembly {
                x := mload(add(add(proof, 32), offset))
                y := mload(add(add(proof, 64), offset))
            }
            assertSame(abi.encodeCall(fe.validate, (x, y)));
            assertSame(abi.encodeCall(fe.add, (x, y, x, y)));
            assertSame(abi.encodeCall(fe.mul, (x, y, 2)));
            assertSame(abi.encodeCall(fe.negate, (x, y)));
        }
    }

    function mockBoth(bytes memory output) private {
        vm.mockCall(address(6), bytes(""), output);
        vm.mockCall(address(7), bytes(""), output);
    }

    function assertErrors(uint256 addError, uint256 mulError) private view {
        (uint256 code, uint256 x, uint256 y) = fe.tryAdd(1, 2, 1, 2);
        assertEq(code, addError, "add error lost");
        assertEq(x, 0, "add error lost");
        assertEq(y, 0, "add error lost");
        (code, x, y) = fe.tryMul(1, 2, 2);
        assertEq(code, mulError, "mul error lost");
        assertEq(x, 0, "mul error lost");
        assertEq(y, 0, "mul error lost");
    }

    function assertSame(bytes memory data) private view {
        (bool ok, bytes memory output) = address(fe).staticcall(data);
        (bool referenceOk, bytes memory expected) = address(referenceCurve).staticcall(data);
        assertTrue(ok, "valid operation rejected");
        assertTrue(referenceOk, "valid operation rejected");
        assertEq(output, expected, "Fe/Solidity curve result differs");
    }

    function bothReject(bytes memory data) private view {
        feRejects(data);
        (bool ok,) = address(referenceCurve).staticcall{gas: 100_000}(data);
        assertFalse(ok, "Solidity accepted invalid input");
    }

    function feRejects(bytes memory data) private view {
        uint256 before = gasleft();
        (bool ok, bytes memory output) = address(fe).staticcall{gas: 100_000}(data);
        assertFalse(ok, "Fe did not explicitly revert");
        assertEq(output.length, 0, "Fe did not explicitly revert");
        assertLt(before - gasleft(), 90_000, "Fe rejection exhausted gas");
    }
}
