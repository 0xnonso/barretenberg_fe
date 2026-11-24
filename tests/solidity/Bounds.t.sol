// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeTest} from "./helpers/FeTest.sol";

interface IBoundsProbe {
    function decode(bytes calldata data, uint256 logN) external pure returns (uint256);
    function stage(uint256 mode, uint256 logN) external view returns (bool);
    function msm(uint256 len) external view returns (uint256);
}

contract BoundsTest is FeTest {
    IBoundsProbe private fe;

    function setUp() public {
        fe = IBoundsProbe(deployProbe("BoundsProbe"));
    }

    function testDecoderRejectsInvalidDimensionsBeforeLengthOrIndexing() public {
        uint256[4] memory invalid = [uint256(0), 1, 26, type(uint256).max];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(abi.encodeWithSignature("UnsupportedLogN(uint256)", invalid[i]));
            fe.decode(new bytes(0), invalid[i]);
        }
        vm.expectRevert(abi.encodeWithSignature("UnsupportedLogN(uint256)", uint256(26)));
        fe.decode(new bytes(12608), 26);
    }

    function testDecoderAcceptsBothDimensionBoundaries() public view {
        assertEq(fe.decode(new bytes(32 * (82 + 12 * 2)), 2), 2);
        assertEq(fe.decode(new bytes(32 * (82 + 12 * 25)), 25), 25);
    }

    function testEveryDimensionedStageRejectsInvalidDimensions() public {
        uint256[4] memory invalid = [uint256(0), 1, 26, type(uint256).max];
        for (uint256 mode; mode < 10; ++mode) {
            for (uint256 i; i < invalid.length; ++i) {
                vm.expectRevert(abi.encodeWithSignature("UnsupportedLogN(uint256)", invalid[i]));
                fe.stage(mode, invalid[i]);
            }
        }
    }

    function testStageBoundariesRemainUsable() public view {
        for (uint256 mode; mode < 10; ++mode) {
            // Opening terms also require enough circuit rows for the key's public inputs.
            assertTrue(fe.stage(mode, mode == 9 ? 4 : 2));
            assertTrue(fe.stage(mode, 25));
        }
    }

    function testMsmChecksCapacityAndAcceptsEmptyPrefix() public view {
        assertEq(fe.msm(0), 0);
        assertEq(fe.msm(1), 1);
        assertEq(fe.msm(2), 2);
        assertEq(fe.msm(type(uint256).max), 2);
    }
}
