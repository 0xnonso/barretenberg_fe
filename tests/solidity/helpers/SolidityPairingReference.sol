// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Honk, FrLib, ecMul, pairing} from "../../../reference/solidity/generated/ArithmeticVerifier.sol";

contract SolidityPairingReference {
    // Generic encoding oracle, separate from the pinned fixed-SRS helper below.
    function check(uint256[12] calldata words) external view returns (uint256, bool) {
        (bool success, bytes memory output) = address(8).staticcall(abi.encode(words));
        if (!success) {
            return (7, false);
        }
        return (0, abi.decode(output, (bool)));
    }

    function pinned(uint256 x1, uint256 y1, uint256 x2, uint256 y2) external view returns (bool) {
        return pairing(Honk.G1Point(x1, y1), Honk.G1Point(x2, y2));
    }

    function multiple(uint256 scalar) external view returns (uint256, uint256) {
        Honk.G1Point memory p = ecMul(FrLib.from(scalar), Honk.G1Point(1, 2));
        return (p.x, p.y);
    }
}
