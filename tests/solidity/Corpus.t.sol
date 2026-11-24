// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeTest} from "./helpers/FeTest.sol";

interface CorpusVerifier {
    function verify(bytes calldata proof, bytes32[] calldata inputs) external view returns (bool);
}

// ABI identities for Forge's gas report. bench() replaces these runtimes with
// the exact deployed verifier code before calling verify; no wrapper executes.
contract FeGasReportTarget {
    error FeRuntimeNotInstalled();

    function verify(bytes calldata, bytes32[] calldata) external pure returns (bool) {
        revert FeRuntimeNotInstalled();
    }
}

contract SolidityGasReportTarget {
    error SolidityRuntimeNotInstalled();

    function verify(bytes calldata, bytes32[] calldata) external pure returns (bool) {
        revert SolidityRuntimeNotInstalled();
    }
}

abstract contract CorpusChecks is FeTest {
    error RevertMismatch(uint256 word, bytes fe, bytes solidity);

    /// One valid verification per verifier; used by scripts/bench.py.
    function bench(string memory name) internal {
        (address fe, address referenceVerifier) = deployPair(name);
        address feTarget = address(new FeGasReportTarget());
        address solidityTarget = address(new SolidityGasReportTarget());
        vm.etch(feTarget, fe.code);
        vm.etch(solidityTarget, referenceVerifier.code);
        assertEq(feTarget.code, fe.code, "Fe benchmark runtime differs");
        assertEq(solidityTarget.code, referenceVerifier.code, "Solidity benchmark runtime differs");
        (bytes memory proof, bytes32[] memory inputs) = loadFixture(name);
        assertTrue(CorpusVerifier(feTarget).verify(proof, inputs), "Fe rejected valid proof");
        assertTrue(CorpusVerifier(solidityTarget).verify(proof, inputs), "Solidity rejected valid proof");
    }

    function check(string memory name, bool recursive) internal {
        (address fe, address referenceVerifier) = deployPair(name);
        (bytes memory proof, bytes32[] memory inputs) = loadFixture(name);
        uint256 accumulator;
        for (uint256 i; i < 8; ++i) {
            uint256 word;
            assembly { word := mload(add(add(proof, 32), mul(i, 32))) }
            accumulator |= word;
        }
        assertEq((accumulator != 0), recursive, "unexpected accumulator branch");
        measure(name, fe, referenceVerifier, proof, inputs);
        // Canonical-looking one-word edits across every proof region, including recursive limbs.
        for (uint256 i; i < proof.length / 32; ++i) {
            uint256 old;
            assembly {
                old := mload(add(add(proof, 32), mul(i, 32)))
                mstore(add(add(proof, 32), mul(i, 32)), xor(old, 1))
            }
            bytes memory feError = rejects(fe, proof, inputs);
            bytes memory solError = rejects(referenceVerifier, proof, inputs);
            // Malformed curve points can exhaust Solidity's forwarded gas.
            // Compare payloads when the reference reaches its error handler.
            if (solError.length != 0 && keccak256(feError) != keccak256(solError)) {
                revert RevertMismatch(i, feError, solError);
            }
            assembly { mstore(add(add(proof, 32), mul(i, 32)), old) }
        }
        for (uint256 i; i < inputs.length; ++i) {
            bytes32 original = inputs[i];
            inputs[i] = bytes32(uint256(original) + 1);
            assertEq(rejects(fe, proof, inputs), rejects(referenceVerifier, proof, inputs), "revert data differs");
            inputs[i] = original;
        }
        assertEq(
            rejects(fe, proof, new bytes32[](inputs.length + 1)),
            rejects(referenceVerifier, proof, new bytes32[](inputs.length + 1)),
            "input count revert differs"
        );
    }

    function deployPair(string memory name) private returns (address fe, address referenceVerifier) {
        string memory build = string.concat("out/corpus/", name, "/");
        (address relations, uint256 relationsGas) =
            measuredDeploy(vm.readFileBinary(string.concat(build, "RelationsLib.bin")));
        (address transcript, uint256 transcriptGas) =
            measuredDeploy(vm.readFileBinary(string.concat(build, "ZKTranscriptLib.bin")));
        vm.etch(address(0x1001), relations.code);
        vm.etch(address(0x1002), transcript.code);
        bytes memory creation = vm.readFileBinary(string.concat(build, "fe.bin"));
        uint256 deployment;
        (fe, deployment) = measuredDeploy(creation);
        assertLe(fe.code.length, 24576, "EIP-170 exceeded");
        // Circuit-independent runtime plus 60 immutable words: the key and RelationsLib's address.
        assertEq(
            fe.code.length,
            vm.readFileBinary(string.concat(build, "fe.runtime.bin")).length + 60 * 32,
            "unexpected key data"
        );
        // The constructor's first CREATE deploys RelationsLib.
        address feRelations = computeCreateAddress(fe, 1);
        assertEq(
            keccak256(feRelations.code),
            keccak256(vm.readFileBinary(string.concat(build, "fe-relations.runtime.bin"))),
            "RelationsLib missing"
        );
        emit log_named_uint(string.concat(name, ".relations_bytes"), feRelations.code.length);
        uint256 verifierGas;
        (referenceVerifier, verifierGas) = measuredDeploy(vm.readFileBinary(string.concat(build, "solidity.bin")));
        emit log_named_uint(string.concat(name, ".runtime_bytes"), fe.code.length);
        emit log_named_uint(string.concat(name, ".deployment_gas"), deployment);
        emit log_named_uint(string.concat(name, ".solidity_verifier_bytes"), referenceVerifier.code.length);
        emit log_named_uint(string.concat(name, ".solidity_relations_bytes"), relations.code.length);
        emit log_named_uint(string.concat(name, ".solidity_transcript_bytes"), transcript.code.length);
        emit log_named_uint(string.concat(name, ".solidity_deployment_gas"), relationsGas + transcriptGas + verifierGas);
        emit log_named_uint(string.concat(name, ".solidity_verifier_deployment_gas"), verifierGas);
    }

    function measure(
        string memory name,
        address fe,
        address referenceVerifier,
        bytes memory proof,
        bytes32[] memory inputs
    ) private {
        uint256 before = gasleft();
        bool feAccepted = CorpusVerifier(fe).verify(proof, inputs);
        uint256 feGas = before - gasleft();
        before = gasleft();
        bool referenceAccepted = CorpusVerifier(referenceVerifier).verify(proof, inputs);
        uint256 referenceGas = before - gasleft();
        assertTrue(feAccepted, "Fe rejected valid proof");
        assertTrue(referenceAccepted, "Solidity rejected valid proof");
        emit log_named_uint(string.concat(name, ".verification_call_gas"), feGas);
        emit log_named_uint(string.concat(name, ".solidity_call_gas"), referenceGas);
    }

    function rejects(address target, bytes memory proof, bytes32[] memory inputs) private view returns (bytes memory) {
        (bool ok, bytes memory output) =
            target.staticcall{gas: 10_000_000}(abi.encodeCall(CorpusVerifier.verify, (proof, inputs)));
        assertFalse(ok, "invalid proof accepted or returned instead of reverting");
        return output;
    }
}

contract CorpusTest is CorpusChecks {
    function testArithmetic() public {
        check("arithmetic", false);
    }

    function testRangePoseidon() public {
        check("range_hash", false);
    }

    function testNoPublicInputs() public {
        check("no_public", false);
    }

    function testCurveLookup() public {
        check("curve_lookup", false);
    }

    function testRecursiveAccumulator() public {
        check("recursive", true);
    }

    function testMerkleBatch() public {
        check("merkle_batch", false);
    }

    function testSha256Large() public {
        check("sha256_large", false);
    }

    function testEcdsaCommitment() public {
        check("ecdsa_commitment", false);
    }

    function testEcdsaPublicBytes() public {
        check("ecdsa_batch", false);
    }
}

/// One test per fixture, so each measurement starts with fresh caller memory.
contract BenchTest is CorpusChecks {
    function testArithmetic() public {
        bench("arithmetic");
    }

    function testNoPublicInputs() public {
        bench("no_public");
    }

    function testRangePoseidon() public {
        bench("range_hash");
    }

    function testMerkleBatch() public {
        bench("merkle_batch");
    }

    function testCurveLookup() public {
        bench("curve_lookup");
    }

    function testSha256Large() public {
        bench("sha256_large");
    }

    function testEcdsaCommitment() public {
        bench("ecdsa_commitment");
    }

    function testEcdsaPublicBytes() public {
        bench("ecdsa_batch");
    }

    function testRecursiveAccumulator() public {
        bench("recursive");
    }
}
