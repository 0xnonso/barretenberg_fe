// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SolidityInversionProbe} from "./helpers/SolidityInversionProbe.sol";
import {FeTest} from "./helpers/FeTest.sol";

import {MODULUS} from "../../reference/solidity/generated/ArithmeticVerifier.sol";

interface IInversionProbe {
    function invert(uint256 a) external view returns (uint256);
    function divide(uint256 a, uint256 b) external view returns (uint256);
    function pow(uint256 a, uint256 exponent) external view returns (uint256);
    function tryInvert(uint256 a) external view returns (uint256 errorCode, uint256 value);
    function tryDivide(uint256 a, uint256 b) external view returns (uint256 errorCode, uint256 value);
    function tryPow(uint256 a, uint256 exponent) external view returns (uint256 errorCode, uint256 value);
}

contract FieldInversionTest is FeTest {
    IInversionProbe private fe;
    SolidityInversionProbe private referenceProbe;

    function setUp() public {
        fe = IInversionProbe(deployProbe("FieldProbe"));
        referenceProbe = new SolidityInversionProbe();
    }

    function testInverseBoundaryVectors() public view {
        uint256[6] memory values = [uint256(1), 2, 3, MODULUS - 1, MODULUS - 2, uint256(1) << 128];
        for (uint256 i; i < values.length; ++i) {
            uint256 inverse = fe.invert(values[i]);
            assertEq(inverse, referenceProbe.invert(values[i]), "inverse differs");
            assertLt(inverse, MODULUS);
            assertEq(mulmod(values[i], inverse, MODULUS), 1);
        }
        assertEq(fe.invert(2), (MODULUS + 1) / 2);
        assertEq(fe.divide(0, 2), 0);
        assertEq(fe.divide(7, 7), 1);
    }

    function testFuzzInverseAndDivision(uint256 a, uint256 seed) public view {
        a %= MODULUS;
        uint256 b = seed % (MODULUS - 1) + 1;
        uint256 inverse = fe.invert(b);
        assertEq(inverse, referenceProbe.invert(b));
        assertEq(mulmod(b, inverse, MODULUS), 1);
        uint256 quotient = fe.divide(a, b);
        assertEq(quotient, referenceProbe.divide(a, b));
        assertLt(quotient, MODULUS);
        assertEq(mulmod(quotient, b, MODULUS), a);
    }

    function testFuzzPowerMatchesReference(uint256 a, uint8 bit) public view {
        a %= MODULUS;
        uint256 exponent = uint256(1) << bit;
        uint256 result = fe.pow(a, exponent);
        assertEq(result, referenceProbe.pow(a, exponent), "power differs");
        assertLt(result, MODULUS);
    }

    function testPowerBoundaryVectors() public view {
        uint256[4] memory bases = [uint256(0), 1, 2, MODULUS - 1];
        uint256[4] memory exponents = [uint256(1), 2, 256, uint256(1) << 255];
        for (uint256 i; i < bases.length; ++i) {
            for (uint256 j; j < exponents.length; ++j) {
                assertEq(fe.pow(bases[i], exponents[j]), referenceProbe.pow(bases[i], exponents[j]));
            }
        }
        assertEq(fe.pow(2, 4), 16);
    }

    function testZeroInverseAndDivisionRejectLikeReference() public view {
        bothReject(abi.encodeCall(fe.invert, (0)));
        bothReject(abi.encodeCall(fe.divide, (1, 0)));
        bothReject(abi.encodeCall(fe.divide, (0, 0)));
        (uint256 code, uint256 value) = fe.tryInvert(0);
        assertEq(code, 1);
        assertEq(value, 0);
        (code, value) = fe.tryDivide(3, 0);
        assertEq(code, 1);
        assertEq(value, 0);
    }

    function testUnsupportedExponentsRejectLikeReference() public view {
        uint256[5] memory values = [uint256(0), 3, 6, MODULUS - 2, type(uint256).max];
        for (uint256 i; i < values.length; ++i) {
            bothReject(abi.encodeCall(fe.pow, (2, values[i])));
            (uint256 code, uint256 value) = fe.tryPow(2, values[i]);
            assertEq(code, 2);
            assertEq(value, 0);
        }
    }

    function testNoncanonicalBasesAndDivisorsReject() public view {
        bothReject(abi.encodeCall(fe.invert, (MODULUS)));
        bothReject(abi.encodeCall(fe.divide, (MODULUS, 1)));
        bothReject(abi.encodeCall(fe.divide, (1, MODULUS)));
        bothReject(abi.encodeCall(fe.pow, (type(uint256).max, 2)));
    }

    function testExactModexpInputEncoding() public {
        // Three length words, then base/exponent/modulus, all big-endian 32-byte words.
        vm.expectCall(address(5), payload(2, MODULUS - 2));
        assertEq(fe.invert(2), (MODULUS + 1) / 2);
        vm.expectCall(address(5), payload(3, 256));
        assertEq(fe.pow(3, 256), referenceProbe.pow(3, 256));
    }

    function testCallFailurePropagatesThroughEveryOperation() public {
        vm.mockCallRevert(address(5), bytes(""), hex"deadbeef");
        (uint256 code, uint256 value) = fe.tryInvert(2);
        assertEq(code, 3, "invert swallowed call failure");
        assertEq(value, 0, "invert swallowed call failure");
        (code, value) = fe.tryDivide(7, 2);
        assertEq(code, 3, "divide swallowed call failure");
        assertEq(value, 0, "divide swallowed call failure");
        (code, value) = fe.tryPow(2, 4);
        assertEq(code, 3, "pow swallowed call failure");
        assertEq(value, 0, "pow swallowed call failure");
        feRejects(abi.encodeCall(fe.invert, (2)));
        feRejects(abi.encodeCall(fe.divide, (7, 2)));
        feRejects(abi.encodeCall(fe.pow, (2, 4)));
        vm.clearMockedCalls();
        assertEq(fe.invert(2), (MODULUS + 1) / 2);
    }

    function testRejectsWrongReturnLengths() public {
        uint256[5] memory sizes = [uint256(0), 1, 31, 33, 64];
        for (uint256 i; i < sizes.length; ++i) {
            vm.mockCall(address(5), bytes(""), new bytes(sizes[i]));
            (uint256 code, uint256 value) = fe.tryInvert(2);
            assertEq(code, 4);
            assertEq(value, 0);
            (code, value) = fe.tryDivide(7, 2);
            assertEq(code, 4);
            assertEq(value, 0);
            (code, value) = fe.tryPow(2, 4);
            assertEq(code, 4);
            assertEq(value, 0);
            vm.clearMockedCalls();
        }
        uint256 inverse = (MODULUS + 1) / 2;
        vm.mockCall(address(5), bytes(""), abi.encode(inverse, type(uint256).max));
        (uint256 extraCode,) = fe.tryInvert(2);
        assertEq(extraCode, 4, "valid prefix hid excess data");
        vm.clearMockedCalls();
        vm.mockCall(address(5), bytes(""), abi.encode(inverse));
        assertEq(fe.invert(2), inverse);
        vm.clearMockedCalls();
    }

    function testNoncanonicalReturnWordCannotBecomeScalar() public {
        uint256[3] memory values = [MODULUS, MODULUS + 1, type(uint256).max];
        for (uint256 i; i < values.length; ++i) {
            vm.mockCall(address(5), bytes(""), abi.encode(values[i]));
            (uint256 code, uint256 value) = fe.tryInvert(2);
            assertEq(code, 5);
            assertEq(value, 0);
            (code, value) = fe.tryDivide(7, 2);
            assertEq(code, 5);
            assertEq(value, 0);
            (code, value) = fe.tryPow(2, 4);
            assertEq(code, 5);
            assertEq(value, 0);
            feRejects(abi.encodeCall(fe.invert, (2)));
            vm.clearMockedCalls();
        }
    }

    function testEarlyDomainErrorsRemainDistinctFromCallFailure() public {
        vm.mockCallRevert(address(5), bytes(""), hex"deadbeef");
        (uint256 code,) = fe.tryInvert(0);
        assertEq(code, 1);
        (code,) = fe.tryDivide(0, 0);
        assertEq(code, 1);
        (code,) = fe.tryPow(2, 0);
        assertEq(code, 2);
        (code,) = fe.tryPow(2, 3);
        assertEq(code, 2);
        vm.clearMockedCalls();
    }

    function payload(uint256 base, uint256 exponent) private pure returns (bytes memory) {
        return abi.encode(uint256(32), uint256(32), uint256(32), base, exponent, MODULUS);
    }

    function bothReject(bytes memory data) private view {
        feRejects(data);
        (bool ok,) = address(referenceProbe).staticcall{gas: 100_000}(data);
        assertFalse(ok, "Solidity accepted invalid domain");
    }

    function feRejects(bytes memory data) private view {
        uint256 before = gasleft();
        (bool ok,) = address(fe).staticcall{gas: 100_000}(data);
        assertFalse(ok, "Fe accepted invalid operation");
        assertLt(before - gasleft(), 90_000, "rejection exhausted call gas");
    }
}
