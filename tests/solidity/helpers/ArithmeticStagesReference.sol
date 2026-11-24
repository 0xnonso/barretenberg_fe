// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    Honk,
    LOG_N,
    NUMBER_OF_PUBLIC_INPUTS,
    VK_HASH,
    ZKTranscriptLib,
    ZKTranscript,
    Fr,
    FrLib,
    HonkVerifier
} from "../../../reference/solidity/generated/ArithmeticVerifier.sol";

contract ArithmeticStagesReference is HonkVerifier {
    function sumcheck(bytes calldata data, bytes32[] calldata inputs) external view returns (bool) {
        Honk.ZKProof memory p = ZKTranscriptLib.loadProof(data, LOG_N);
        ZKTranscript memory t = ZKTranscriptLib.generateTranscript(p, inputs, VK_HASH, NUMBER_OF_PUBLIC_INPUTS, LOG_N);
        t.relationParameters.publicInputsDelta = computePublicInputDelta(
            inputs, p.pairingPointObject, t.relationParameters.beta, t.relationParameters.gamma, 5
        );
        return verifySumcheck(p, t);
    }

    function rounds(bytes calldata data, bytes32[] calldata inputs) external view returns (uint256, uint256) {
        Honk.ZKProof memory p = ZKTranscriptLib.loadProof(data, LOG_N);
        ZKTranscript memory t = ZKTranscriptLib.generateTranscript(p, inputs, VK_HASH, NUMBER_OF_PUBLIC_INPUTS, LOG_N);
        Fr target = t.libraChallenge * p.libraSum;
        Fr gate = FrLib.from(1);
        for (uint256 i; i < LOG_N; ++i) {
            require(p.sumcheckUnivariates[i][0] + p.sumcheckUnivariates[i][1] == target);
            target = computeNextTargetSum(p.sumcheckUnivariates[i], t.sumCheckUChallenges[i]);
            gate = gate * (FrLib.from(1) + t.sumCheckUChallenges[i] * (t.gateChallenges[i] - FrLib.from(1)));
        }
        return (Fr.unwrap(target), Fr.unwrap(gate));
    }

    function delta(uint256[11] calldata words) external view returns (uint256) {
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = bytes32(words[0]);
        Fr[8] memory limbs;
        for (uint256 i; i < 8; ++i) {
            limbs[i] = FrLib.from(words[i + 1]);
        }
        return Fr.unwrap(computePublicInputDelta(inputs, limbs, FrLib.from(words[9]), FrLib.from(words[10]), 5));
    }

    function interpolate(uint256[9] calldata values, uint256 u) external view returns (uint256) {
        Fr[9] memory round;
        for (uint256 i; i < 9; ++i) {
            round[i] = FrLib.from(values[i]);
        }
        return Fr.unwrap(computeNextTargetSum(round, FrLib.from(u)));
    }
}
