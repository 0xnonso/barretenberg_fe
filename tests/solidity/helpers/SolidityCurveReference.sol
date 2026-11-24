// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Honk, FrLib, ecAdd, ecMul, negateInplace} from "../../../reference/solidity/generated/ArithmeticVerifier.sol";

contract SolidityCurveReference {
    function add(uint256 x1, uint256 y1, uint256 x2, uint256 y2) external view returns (uint256, uint256) {
        Honk.G1Point memory p = ecAdd(Honk.G1Point(x1, y1), Honk.G1Point(x2, y2));
        return (p.x, p.y);
    }

    function mul(uint256 x, uint256 y, uint256 scalar) external view returns (uint256, uint256) {
        Honk.G1Point memory p = ecMul(FrLib.from(scalar), Honk.G1Point(x, y));
        return (p.x, p.y);
    }

    function negate(uint256 x, uint256 y) external pure returns (uint256, uint256) {
        Honk.G1Point memory p = negateInplace(Honk.G1Point(x, y));
        return (p.x, p.y);
    }

    function validate(uint256 x, uint256 y) external view returns (uint256, uint256) {
        // Independent membership oracle: the actual EVM precompile validates P.
        Honk.G1Point memory p = ecMul(FrLib.from(1), Honk.G1Point(x, y));
        return (p.x, p.y);
    }
}
