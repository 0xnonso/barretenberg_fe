// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeTest} from "./helpers/FeTest.sol";
import {HonkVerifier, Errors, MODULUS, Q} from "../../reference/solidity/generated/ArithmeticVerifier.sol";

interface IFeVerifier {
    function verify(bytes calldata proof, bytes32[] calldata inputs) external view returns (bool);
}

contract FeVerifierTest is FeTest {
    IFeVerifier private fe;
    HonkVerifier private referenceVerifier;

    function setUp() public {
        fe = IFeVerifier(deployFe("out/corpus/arithmetic/fe.bin"));
        referenceVerifier = new HonkVerifier();
    }

    function testCorrectProofAccepted() public view {
        (bytes memory proof, bytes32[] memory inputs) = loadFixture("arithmetic");
        assertTrue(fe.verify(proof, inputs));
        assertTrue(referenceVerifier.verify(proof, inputs));
    }

    function testRuntimeFitsEip170() public view {
        assertLe(address(fe).code.length, 24576, "Fe runtime exceeds EIP-170");
    }

    function testEveryProofWordMutationRejects() public view {
        (bytes memory proof, bytes32[] memory inputs) = loadFixture("arithmetic");
        for (uint256 i; i < 142; ++i) {
            uint256 bound = i < 8
                ? uint256(1) << (i % 2 == 0 ? 136 : 120)
                : ((i < 28 || (i >= 117 && i < 129) || i >= 138) ? Q : MODULUS);
            uint256 old;
            assembly { old := mload(add(add(proof, 32), mul(i, 32))) }
            uint256 value = addmod(old, 1, bound);
            assembly { mstore(add(add(proof, 32), mul(i, 32)), value) }
            bothReject(proof, inputs);
            assembly { mstore(add(add(proof, 32), mul(i, 32)), old) }
        }
    }

    function testMalformedInputsReject() public view {
        (bytes memory proof, bytes32[] memory inputs) = loadFixture("arithmetic");
        inputs[0] = bytes32(uint256(13));
        bothReject(proof, inputs);
        inputs[0] = bytes32(MODULUS);
        bothReject(proof, inputs);
        bothReject(proof, new bytes32[](0));
        bothReject(proof, new bytes32[](2));
        inputs[0] = bytes32(uint256(12));
        bothReject(new bytes(4543), inputs);
        bothReject(bytes.concat(proof, hex"00"), inputs);
    }

    function testPrecompileFailuresReject() public {
        (bytes memory proof, bytes32[] memory inputs) = loadFixture("arithmetic");
        for (uint160 precompile = 5; precompile <= 8; ++precompile) {
            vm.mockCallRevert(address(precompile), bytes(""), hex"");
            sameRevert(
                proof,
                inputs,
                abi.encodeWithSelector(precompile == 5 ? bytes4(0xf8d61709) : Errors.ShpleminiFailed.selector)
            );
            vm.clearMockedCalls();
        }
    }

    function testSuccessfulPairingCallRequiresTrue() public {
        (bytes memory proof, bytes32[] memory inputs) = loadFixture("arithmetic");
        uint256[4] memory responses = [uint256(0), 1, 2, type(uint256).max];
        for (uint256 i; i < responses.length; ++i) {
            vm.mockCall(address(8), bytes(""), abi.encode(responses[i]));
            (bool ok, bytes memory output) =
                address(fe).staticcall{gas: 10_000_000}(abi.encodeCall(fe.verify, (proof, inputs)));
            if (responses[i] == 1) {
                assertTrue(ok, "true pairing rejected");
                assertTrue(abi.decode(output, (bool)), "true pairing rejected");
            } else {
                assertFalse(ok, "false or malformed pairing accepted");
                sameRevert(
                    proof,
                    inputs,
                    responses[i] == 0 ? abi.encodeWithSelector(Errors.ShpleminiFailed.selector) : bytes("")
                );
            }
            vm.clearMockedCalls();
        }
    }

    function testLibraConsistencyErrorMatchesSolidity() public {
        (bytes memory proof, bytes32[] memory inputs) = loadFixture("arithmetic");
        uint256 value;
        assembly { value := mload(add(add(proof, 32), mul(134, 32))) }
        value = addmod(value, 1, MODULUS);
        assembly { mstore(add(add(proof, 32), mul(134, 32)), value) }
        sameRevert(proof, inputs, abi.encodeWithSelector(Errors.ConsistencyCheckFailed.selector));
    }

    function testInvalidOpeningWithValidCurvePointMatchesSolidityError() public {
        (bytes memory proof, bytes32[] memory inputs) = loadFixture("arithmetic");
        // Negation stays on the curve, so both implementations reach the error handler.
        uint256 y;
        assembly { y := mload(add(add(proof, 32), mul(139, 32))) }
        uint256 negated = Q - y;
        assembly { mstore(add(add(proof, 32), mul(139, 32)), negated) }
        sameRevert(proof, inputs, abi.encodeWithSelector(Errors.ShpleminiFailed.selector));
    }

    function testRevertPayloadsAndValidationOrderMatchSolidity() public {
        (bytes memory proof, bytes32[] memory inputs) = loadFixture("arithmetic");
        // Proof validation precedes input count/range checks, even if both are wrong.
        sameRevert(
            new bytes(0),
            new bytes32[](0),
            abi.encodeWithSelector(Errors.ProofLengthWrongWithLogN.selector, uint256(5), uint256(0), uint256(4544))
        );
        sameRevert(
            bytes.concat(proof, hex"00"),
            inputs,
            abi.encodeWithSelector(Errors.ProofLengthWrongWithLogN.selector, uint256(5), uint256(4545), uint256(4544))
        );
        sameRevert(proof, new bytes32[](0), abi.encodeWithSelector(Errors.PublicInputsLengthWrong.selector));
        inputs[0] = bytes32(MODULUS);
        sameRevert(proof, inputs, abi.encodeWithSelector(Errors.ValueGeFieldOrder.selector));
        // Every decoder position: limb errors take precedence over scalar errors.
        for (uint256 i; i < 142; ++i) {
            bool coordinate = (i >= 8 && i < 28) || (i >= 117 && i < 129) || i >= 138;
            uint256 badWord = i < 8 ? type(uint256).max : coordinate ? Q : MODULUS;
            bytes4 selector = i < 8
                ? Errors.ValueGeLimbMax.selector
                : coordinate ? Errors.ValueGeGroupOrder.selector : Errors.ValueGeFieldOrder.selector;
            uint256 old;
            assembly {
                old := mload(add(add(proof, 32), mul(i, 32)))
                mstore(add(add(proof, 32), mul(i, 32)), badWord)
            }
            sameRevert(proof, new bytes32[](0), abi.encodeWithSelector(selector));
            assembly { mstore(add(add(proof, 32), mul(i, 32)), old) }
        }
        inputs[0] = bytes32(uint256(13));
        sameRevert(proof, inputs, abi.encodeWithSelector(Errors.SumcheckFailed.selector));
    }

    function sameRevert(bytes memory proof, bytes32[] memory inputs, bytes memory expected) private {
        vm.expectRevert(expected);
        fe.verify{gas: 10_000_000}(proof, inputs);
        vm.expectRevert(expected);
        referenceVerifier.verify{gas: 10_000_000}(proof, inputs);
    }

    function bothReject(bytes memory proof, bytes32[] memory inputs) private view {
        (bool ok, bytes memory output) =
            address(fe).staticcall{gas: 10_000_000}(abi.encodeCall(fe.verify, (proof, inputs)));
        assertTrue(!ok || !abi.decode(output, (bool)), "Fe accepted invalid proof");
        (ok, output) = address(referenceVerifier).staticcall{gas: 10_000_000}(
            abi.encodeCall(referenceVerifier.verify, (proof, inputs))
        );
        assertTrue(!ok || !abi.decode(output, (bool)), "reference accepted invalid proof");
    }
}
