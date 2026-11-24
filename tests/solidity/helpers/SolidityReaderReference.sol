// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fr, Q, Honk, bytesToFr, bytesToG1Point} from "../../../reference/solidity/generated/ArithmeticVerifier.sol";

contract SolidityReaderReference {
    function read(bytes calldata data, uint256 start, uint256 kind)
        external
        pure
        returns (uint256 first, uint256 second)
    {
        // Use bounded slices as loadProof does, not bytes32(shortSlice)'s padding.
        if (kind == 0) {
            return (uint256(bytes32(data[start:start + 32])), 0);
        }
        if (kind == 1) {
            return (Fr.unwrap(bytesToFr(data[start:start + 32])), 0);
        }
        if (kind == 2) {
            first = uint256(bytes32(data[start:start + 32]));
            require(first < Q);
            return (first, 0);
        }
        require(kind == 3);
        Honk.G1Point memory point = bytesToG1Point(data[start:start + 64]);
        return (point.x, point.y);
    }
}
