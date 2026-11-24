// SPDX-License-Identifier: Apache-2.0
// Instrumented reference verifyShplemini exposing its MSM terms.
// The Libra assertion is tested separately.
import {
    HonkVerifier,
    HonkVerificationKey,
    Honk,
    ZKTranscript,
    ZKTranscriptLib,
    CommitmentSchemeLib,
    Fr,
    FrLib,
    ONE,
    SUBGROUP_GENERATOR,
    SMALL_IPA_BOUNDARY_OPENING_IDX,
    NUM_SMALL_IPA_OPENING_CLAIMS,
    NUMBER_UNSHIFTED_ZK,
    NUMBER_TO_BE_SHIFTED,
    NUM_MASKING_POLYNOMIALS,
    LOG_N,
    VK_HASH,
    NUMBER_OF_PUBLIC_INPUTS
} from "../../../reference/solidity/generated/ArithmeticVerifier.sol";
pragma solidity 0.8.30;

contract OpeningReference is HonkVerifier {
    using FrLib for Fr;

    function terms(bytes calldata data, bytes32[] calldata inputs) external view returns (uint256[141] memory words) {
        Honk.ZKProof memory proof = ZKTranscriptLib.loadProof(data, LOG_N);
        Honk.VerificationKey memory vk = HonkVerificationKey.loadVerificationKey();
        ZKTranscript memory tp =
            ZKTranscriptLib.generateTranscript(proof, inputs, VK_HASH, NUMBER_OF_PUBLIC_INPUTS, LOG_N);
        CommitmentSchemeLib.ShpleminiIntermediates memory mem;

        Fr[] memory powers_of_evaluation_challenge = CommitmentSchemeLib.computeSquares(tp.geminiR, $LOG_N);
        Fr[] memory scalars = new Fr[]($MSMSize);
        Honk.G1Point[] memory commitments = new Honk.G1Point[]($MSMSize);

        mem.posInvertedDenominator = (tp.shplonkZ - powers_of_evaluation_challenge[0]).invert();
        mem.negInvertedDenominator = (tp.shplonkZ + powers_of_evaluation_challenge[0]).invert();

        mem.unshiftedScalar = mem.posInvertedDenominator + (tp.shplonkNu * mem.negInvertedDenominator);
        mem.shiftedScalar =
            tp.geminiR.invert() * (mem.posInvertedDenominator - (tp.shplonkNu * mem.negInvertedDenominator));

        scalars[0] = Fr.wrap(1);
        commitments[0] = proof.shplonkQ;

        /* Batch multivariate opening claims, shifted and unshifted
        * The vector of scalars is populated as follows:
        * \f[
        * \left(
        * - \left(\frac{1}{z-r} + \nu \times \frac{1}{z+r}\right),
        * \ldots,
        * - \rho^{i+k-1} \times \left(\frac{1}{z-r} + \nu \times \frac{1}{z+r}\right),
        * - \rho^{i+k} \times \frac{1}{r} \times \left(\frac{1}{z-r} - \nu \times \frac{1}{z+r}\right),
        * \ldots,
        * - \rho^{k+m-1} \times \frac{1}{r} \times \left(\frac{1}{z-r} - \nu \times \frac{1}{z+r}\right)
        * \right)
        * \f]
        *
        * The following vector is concatenated to the vector of commitments:
        * \f[
        * f_0, \ldots, f_{m-1}, f_{\text{shift}, 0}, \ldots, f_{\text{shift}, k-1}
        * \f]
        *
        * Simultaneously, the evaluation of the multilinear polynomial
        * \f[
        * \sum \rho^i \cdot f_i + \sum \rho^{i+k} \cdot f_{\text{shift}, i}
        * \f]
        * at the challenge point \f$ (u_0,\ldots, u_{n-1}) \f$ is computed.
        *
        * This approach minimizes the number of iterations over the commitments to multilinear polynomials
        * and eliminates the need to store the powers of \f$ \rho \f$.
        */
        // For ZK flavors: evaluations array is [gemini_masking_poly, qm, qc, ql, qr, ...]
        mem.batchingChallenge = Fr.wrap(1);
        mem.batchedEvaluation = Fr.wrap(0);

        mem.unshiftedScalarNeg = mem.unshiftedScalar.neg();
        mem.shiftedScalarNeg = mem.shiftedScalar.neg();

        for (uint256 i = 1; i <= NUMBER_UNSHIFTED_ZK; ++i) {
            scalars[i] = mem.unshiftedScalarNeg * mem.batchingChallenge;
            mem.batchedEvaluation = mem.batchedEvaluation
                + (proof.sumcheckEvaluations[i - NUM_MASKING_POLYNOMIALS] * mem.batchingChallenge);
            mem.batchingChallenge = mem.batchingChallenge * tp.rho;
        }
        // g commitments are accumulated at r
        // For each of the to be shifted commitments perform the shift in place by
        // adding to the unshifted value.
        // We do so, as the values are to be used in batchMul later, and as
        // `a * c + b * c = (a + b) * c` this will allow us to reduce memory and compute.
        // Applied to w1, w2, w3, w4 and zPerm
        for (uint256 i = 0; i < NUMBER_TO_BE_SHIFTED; ++i) {
            uint256 scalarOff = i + SHIFTED_COMMITMENTS_START;
            uint256 evaluationOff = i + NUMBER_UNSHIFTED_ZK;

            scalars[scalarOff] = scalars[scalarOff] + (mem.shiftedScalarNeg * mem.batchingChallenge);
            mem.batchedEvaluation =
                mem.batchedEvaluation + (proof.sumcheckEvaluations[evaluationOff] * mem.batchingChallenge);
            mem.batchingChallenge = mem.batchingChallenge * tp.rho;
        }

        commitments[1] = proof.geminiMaskingPoly;

        commitments[2] = vk.s1;
        commitments[3] = vk.s2;
        commitments[4] = vk.s3;
        commitments[5] = vk.s4;
        commitments[6] = vk.id1;
        commitments[7] = vk.id2;
        commitments[8] = vk.id3;
        commitments[9] = vk.id4;
        commitments[10] = vk.lagrangeFirst;
        commitments[11] = vk.lagrangeLast;
        commitments[12] = vk.qLookup;
        commitments[13] = vk.t1;
        commitments[14] = vk.t2;
        commitments[15] = vk.t3;
        commitments[16] = vk.t4;
        commitments[17] = vk.qm;
        commitments[18] = vk.qr;
        commitments[19] = vk.qo;
        commitments[20] = vk.qc;
        commitments[21] = vk.ql;
        commitments[22] = vk.q4;
        commitments[23] = vk.qArith;
        commitments[24] = vk.qDeltaRange;
        commitments[25] = vk.qElliptic;
        commitments[26] = vk.qMemory;
        commitments[27] = vk.qNnf;
        commitments[28] = vk.qPoseidon2External;
        commitments[29] = vk.qPoseidon2Internal;

        commitments[30] = proof.w1;
        commitments[31] = proof.w2;
        commitments[32] = proof.w3;
        commitments[33] = proof.w4;
        commitments[34] = proof.zPerm;
        commitments[35] = proof.lookupInverses;
        commitments[36] = proof.lookupReadCounts;
        commitments[37] = proof.lookupReadTags;

        Fr[] memory foldPosEvaluations = CommitmentSchemeLib.computeFoldPosEvaluations(
            tp.sumCheckUChallenges,
            mem.batchedEvaluation,
            proof.geminiAEvaluations,
            powers_of_evaluation_challenge,
            $LOG_N
        );

        mem.constantTermAccumulator = foldPosEvaluations[0] * mem.posInvertedDenominator;
        mem.constantTermAccumulator =
            mem.constantTermAccumulator + (proof.geminiAEvaluations[0] * tp.shplonkNu * mem.negInvertedDenominator);

        mem.batchingChallenge = tp.shplonkNu.sqr();
        uint256 boundary = NUMBER_UNSHIFTED_ZK + 1;

        for (uint256 i = 0; i < $LOG_N - 1; ++i) {
            bool dummy_round = i >= ($LOG_N - 1);

            if (!dummy_round) {
                mem.posInvertedDenominator = (tp.shplonkZ - powers_of_evaluation_challenge[i + 1]).invert();
                mem.negInvertedDenominator = (tp.shplonkZ + powers_of_evaluation_challenge[i + 1]).invert();

                mem.scalingFactorPos = mem.batchingChallenge * mem.posInvertedDenominator;
                mem.scalingFactorNeg = mem.batchingChallenge * tp.shplonkNu * mem.negInvertedDenominator;
                scalars[boundary + i] = mem.scalingFactorNeg.neg() + mem.scalingFactorPos.neg();

                // Accumulate the const term contribution given by
                // v^{2l} * Aₗ(r^{2ˡ}) /(z-r^{2^l}) + v^{2l+1} * Aₗ(-r^{2ˡ}) /(z+ r^{2^l})
                Fr accumContribution = mem.scalingFactorNeg * proof.geminiAEvaluations[i + 1];
                accumContribution = accumContribution + mem.scalingFactorPos * foldPosEvaluations[i + 1];
                mem.constantTermAccumulator = mem.constantTermAccumulator + accumContribution;
            }
            mem.batchingChallenge = mem.batchingChallenge * tp.shplonkNu * tp.shplonkNu;

            commitments[boundary + i] = proof.geminiFoldComms[i];
        }

        boundary += $LOG_N - 1;

        // Denominators 1/(z - point_i) for the five opening points {r, g*r, r, 1, r}.
        mem.denominators[0] = ONE.div(tp.shplonkZ - tp.geminiR);
        mem.denominators[1] = ONE.div(tp.shplonkZ - SUBGROUP_GENERATOR * tp.geminiR);
        mem.denominators[2] = mem.denominators[0];
        mem.denominators[SMALL_IPA_BOUNDARY_OPENING_IDX] = ONE.div(tp.shplonkZ - ONE);
        mem.denominators[NUM_SMALL_IPA_OPENING_CLAIMS - 1] = mem.denominators[0];

        for (uint256 i = 0; i < SMALL_IPA_BOUNDARY_OPENING_IDX; i++) {
            Fr scalingFactor = mem.denominators[i] * mem.batchingChallenge;
            mem.batchingScalars[i] = scalingFactor.neg();
            mem.batchingChallenge = mem.batchingChallenge * tp.shplonkNu;
            mem.constantTermAccumulator = mem.constantTermAccumulator + scalingFactor * proof.libraPolyEvals[i];
        }

        // Boundary slot: claimed value is hardcoded 0, so no constantTermAccumulator contribution.
        {
            Fr scalingFactor = mem.denominators[SMALL_IPA_BOUNDARY_OPENING_IDX] * mem.batchingChallenge;
            mem.batchingScalars[SMALL_IPA_BOUNDARY_OPENING_IDX] = scalingFactor.neg();
            mem.batchingChallenge = mem.batchingChallenge * tp.shplonkNu;
        }

        for (uint256 i = SMALL_IPA_BOUNDARY_OPENING_IDX + 1; i < NUM_SMALL_IPA_OPENING_CLAIMS; i++) {
            Fr scalingFactor = mem.denominators[i] * mem.batchingChallenge;
            mem.batchingScalars[i] = scalingFactor.neg();
            mem.batchingChallenge = mem.batchingChallenge * tp.shplonkNu;
            mem.constantTermAccumulator = mem.constantTermAccumulator + scalingFactor * proof.libraPolyEvals[i - 1];
        }

        // Group per-claim batching scalars by commitment: [G], [A] (three openings), [Q].
        scalars[boundary] = mem.batchingScalars[0];
        scalars[boundary + 1] =
            mem.batchingScalars[1] + mem.batchingScalars[2] + mem.batchingScalars[SMALL_IPA_BOUNDARY_OPENING_IDX];
        scalars[boundary + 2] = mem.batchingScalars[NUM_SMALL_IPA_OPENING_CLAIMS - 1];

        for (uint256 i = 0; i < LIBRA_COMMITMENTS; i++) {
            commitments[boundary++] = proof.libraCommitments[i];
        }

        commitments[boundary] = Honk.G1Point({x: 1, y: 2});
        scalars[boundary++] = mem.constantTermAccumulator;

        // Libra is checked independently by the production verifier and tests.

        Honk.G1Point memory quotient_commitment = proof.kzgQuotient;

        commitments[boundary] = quotient_commitment;
        scalars[boundary] = tp.shplonkZ;

        require($MSMSize * 3 == words.length);
        for (uint256 i; i < $MSMSize; ++i) {
            words[3 * i] = commitments[i].x;
            words[3 * i + 1] = commitments[i].y;
            words[3 * i + 2] = Fr.unwrap(scalars[i]);
        }
    }

    function fold(uint256[5] calldata u, uint256 batched, uint256[5] calldata negative, uint256 r)
        external
        view
        returns (uint256[5] memory squares, uint256[5] memory positive)
    {
        Fr[25] memory challenges;
        Fr[25] memory evaluations;
        for (uint256 i; i < 5; ++i) {
            challenges[i] = FrLib.from(u[i]);
            evaluations[i] = FrLib.from(negative[i]);
        }
        Fr[] memory powers = CommitmentSchemeLib.computeSquares(FrLib.from(r), 5);
        Fr[] memory result =
            CommitmentSchemeLib.computeFoldPosEvaluations(challenges, FrLib.from(batched), evaluations, powers, 5);
        for (uint256 i; i < 5; ++i) {
            squares[i] = Fr.unwrap(powers[i]);
            positive[i] = Fr.unwrap(result[i]);
        }
    }

    function libra(uint256[4] calldata evaluations, uint256 r, uint256[5] calldata u, uint256 claimed)
        external
        view
        returns (bool)
    {
        Fr[4] memory evals;
        Fr[25] memory challenges;
        for (uint256 i; i < 4; ++i) {
            evals[i] = FrLib.from(evaluations[i]);
        }
        for (uint256 i; i < 5; ++i) {
            challenges[i] = FrLib.from(u[i]);
        }
        return checkEvalsConsistency(evals, FrLib.from(r), challenges, FrLib.from(claimed));
    }
}
