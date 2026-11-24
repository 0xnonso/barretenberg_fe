// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    convertPairingPointsToG1,
    rejectPointAtInfinity,
    HonkVerifier,
    Honk,
    Fr,
    mulWithSeperator
} from "../../../reference/solidity/generated/ArithmeticVerifier.sol";

contract MsmReference is HonkVerifier {
    function accumulator(uint256[8] calldata limbs) external view {
        Fr[8] memory fields;
        for (uint256 i; i < 8; ++i) {
            fields[i] = Fr.wrap(limbs[i]);
        }
        (Honk.G1Point memory lhs, Honk.G1Point memory rhs) = convertPairingPointsToG1(fields);
        rejectPointAtInfinity(lhs);
        rejectPointAtInfinity(rhs);
        mulWithSeperator(Honk.G1Point(1, 2), lhs, Fr.wrap(1));
        mulWithSeperator(Honk.G1Point(1, 2), rhs, Fr.wrap(1));
    }

    function msm(uint256[141] calldata words) external view returns (uint256, uint256) {
        Honk.G1Point[] memory points = new Honk.G1Point[](47);
        Fr[] memory scalars = new Fr[](47);
        for (uint256 i; i < 47; ++i) {
            points[i] = Honk.G1Point(words[3 * i], words[3 * i + 1]);
            scalars[i] = Fr.wrap(words[3 * i + 2]);
        }
        Honk.G1Point memory p = batchMul(points, scalars);
        return (p.x, p.y);
    }
}
