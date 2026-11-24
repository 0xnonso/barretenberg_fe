// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeTest} from "./helpers/FeTest.sol";
import {RelationsLib, Honk, Fr, FrLib, MODULUS} from "../../reference/solidity/generated/ArithmeticVerifier.sol";

interface IRelationsProbe {
    function relations(
        uint256[41] calldata values,
        uint256[5] calldata parameters,
        uint256 gateWeight,
        uint256[30] calldata alphas
    ) external pure returns (uint256[31] memory, uint256);
}

contract RelationsTest is FeTest {
    IRelationsProbe private fe;

    function setUp() public {
        fe = IRelationsProbe(deployProbe("RelationsProbe"));
    }

    function testFuzzEverySubrelation(uint256 seed, uint256 gateWeight) public view {
        uint256[41] memory values;
        uint256[5] memory parameters;
        uint256[30] memory alphas;
        for (uint256 i; i < 41; ++i) {
            values[i] = uint256(keccak256(abi.encode(seed, i))) % MODULUS;
        }
        for (uint256 i; i < 5; ++i) {
            parameters[i] = uint256(keccak256(abi.encode(seed, i + 41))) % MODULUS;
        }
        for (uint256 i; i < 30; ++i) {
            alphas[i] = uint256(keccak256(abi.encode(seed, i + 46))) % MODULUS;
        }
        assertRelations(values, parameters, gateWeight % MODULUS, alphas);
    }

    function testZeroGateWeightKeepsOnlyDependentRelations() public view {
        uint256[41] memory values;
        uint256[5] memory parameters = [uint256(2), 3, 5, 7, 11];
        uint256[30] memory alphas;
        for (uint256 i; i < 41; ++i) {
            values[i] = i + 2;
        }
        for (uint256 i; i < 30; ++i) {
            alphas[i] = i + 1;
        }
        (uint256[31] memory result,) = fe.relations(values, parameters, 0, alphas);
        for (uint256 i; i < 31; ++i) {
            if (i != 4 && i != 21) {
                assertEq(result[i], 0);
            }
        }
        assertNotEq(result[4], 0);
        assertNotEq(result[21], 0);
        assertRelations(values, parameters, 0, alphas);
    }

    function testSelectorModesAndAlphaBasis() public view {
        uint256[41] memory values;
        uint256[5] memory parameters = [uint256(2), 3, 5, 7, 11];
        uint256[30] memory alphas;
        for (uint256 i; i < 41; ++i) {
            values[i] = i + 1;
        }
        for (uint256 mode; mode < 4; ++mode) {
            values[21] = mode; // Q_ARITH
            values[15] = mode % 2; // Q_M also selects elliptic doubling.
            values[19] = mode % 2; // Q_L distinguishes memory/ROM patterns.
            assertRelations(values, parameters, 13, alphas);
        }
        (uint256[31] memory evaluations, uint256 sum) = fe.relations(values, parameters, 13, alphas);
        assertEq(sum, evaluations[0]);
        for (uint256 i; i < 30; ++i) {
            alphas[i] = 1;
            (, sum) = fe.relations(values, parameters, 13, alphas);
            assertEq(sum, addmod(evaluations[0], evaluations[i + 1], MODULUS));
            alphas[i] = 0;
        }
    }

    function assertRelations(
        uint256[41] memory values,
        uint256[5] memory parameters,
        uint256 gateWeight,
        uint256[30] memory alphas
    ) private view {
        (uint256[31] memory result, uint256 sum) = fe.relations(values, parameters, gateWeight, alphas);
        Fr[41] memory p;
        Fr[30] memory weights;
        for (uint256 i; i < 41; ++i) {
            p[i] = FrLib.from(values[i]);
        }
        for (uint256 i; i < 30; ++i) {
            weights[i] = FrLib.from(alphas[i]);
        }
        Honk.RelationParameters memory rp = Honk.RelationParameters(
            FrLib.from(parameters[0]),
            FrLib.from(parameters[1]),
            FrLib.from(parameters[2]),
            FrLib.from(parameters[3]),
            FrLib.from(parameters[4])
        );
        Fr domain = FrLib.from(gateWeight);
        Fr[31] memory expected;
        RelationsLib.accumulateArithmeticRelation(p, expected, domain);
        RelationsLib.accumulatePermutationRelation(p, rp, expected, domain);
        RelationsLib.accumulateLogDerivativeLookupRelation(p, rp, expected, domain);
        RelationsLib.accumulateDeltaRangeRelation(p, expected, domain);
        RelationsLib.accumulateEllipticRelation(p, expected, domain);
        RelationsLib.accumulateMemoryRelation(p, rp, expected, domain);
        RelationsLib.accumulateRomLogupRelation(p, rp, expected, domain);
        RelationsLib.accumulateNnfRelation(p, expected, domain);
        RelationsLib.accumulatePoseidonExternalRelation(p, expected, domain);
        RelationsLib.accumulatePoseidonInternalRelation(p, expected, domain);
        for (uint256 i; i < 31; ++i) {
            assertEq(result[i], Fr.unwrap(expected[i]), "subrelation differs");
        }
        assertEq(
            sum,
            Fr.unwrap(RelationsLib.accumulateRelationEvaluations(p, rp, weights, domain)),
            "relation batching differs"
        );
    }
}
