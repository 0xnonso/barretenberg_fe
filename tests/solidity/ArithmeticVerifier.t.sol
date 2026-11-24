// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeTest} from "./helpers/FeTest.sol";

import {HonkVerifier, Errors, LOG_N} from "../../reference/solidity/generated/ArithmeticVerifier.sol";

contract ArithmeticVerifierTest is FeTest {
    HonkVerifier private verifier;

    function setUp() public {
        verifier = new HonkVerifier();
    }

    function testAcceptsCorrectPublicResult() public view {
        (bytes memory proof, bytes32[] memory inputs) = loadFixture("arithmetic");
        assertTrue(verifier.verify(proof, inputs), "valid proof rejected");
    }

    function testRejectsChangedPublicResult() public {
        (bytes memory proof, bytes32[] memory inputs) = loadFixture("arithmetic");
        inputs[0] = bytes32(uint256(13));
        vm.expectRevert(Errors.SumcheckFailed.selector);
        verifier.verify(proof, inputs);
    }

    function testRejectsTruncatedProof() public {
        (bytes memory proof, bytes32[] memory inputs) = loadFixture("arithmetic");
        assembly { mstore(proof, sub(mload(proof), 1)) }
        vm.expectRevert(
            abi.encodeWithSelector(Errors.ProofLengthWrongWithLogN.selector, LOG_N, proof.length, proof.length + 1)
        );
        verifier.verify(proof, inputs);
    }

    function testRejectsWrongPublicInputCount() public {
        (bytes memory proof,) = loadFixture("arithmetic");
        vm.expectRevert(Errors.PublicInputsLengthWrong.selector);
        verifier.verify(proof, new bytes32[](0));
    }
}
