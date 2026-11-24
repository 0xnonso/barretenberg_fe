// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Fr as ReferenceFr, FrLib} from "../../../reference/solidity/generated/ArithmeticVerifier.sol";

contract SolidityInversionProbe {
    function invert(uint256 a) external view returns (uint256) {
        return ReferenceFr.unwrap(FrLib.invert(FrLib.from(a)));
    }

    function divide(uint256 a, uint256 b) external view returns (uint256) {
        return ReferenceFr.unwrap(FrLib.div(FrLib.from(a), FrLib.from(b)));
    }

    function pow(uint256 a, uint256 exponent) external view returns (uint256) {
        return ReferenceFr.unwrap(FrLib.pow(FrLib.from(a), exponent));
    }
}
