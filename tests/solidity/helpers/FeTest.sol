// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// Shared fixture loading and deployment for Fe's raw creation bytecode.
abstract contract FeTest is Test {
    function deployProbe(string memory name) internal returns (address) {
        return deployFe(string.concat("out/probes/", name, ".creation.bin"));
    }

    function deployFe(string memory path) internal returns (address) {
        return deployCreation(vm.readFileBinary(path));
    }

    function deployCreation(bytes memory creation) internal returns (address deployed) {
        (deployed,) = measuredDeploy(creation);
    }

    /// Keep assertion overhead outside the reported CREATE gas.
    function measuredDeploy(bytes memory creation) internal returns (address deployed, uint256 used) {
        uint256 before = gasleft();
        assembly {
            deployed := create(0, add(creation, 32), mload(creation))
        }
        used = before - gasleft();
        assertNotEq(deployed, address(0), "creation reverted");
        assertGt(deployed.code.length, 0, "deployed contract has no code");
    }

    function loadFixture(string memory name) internal view returns (bytes memory proof, bytes32[] memory inputs) {
        string memory artifacts = string.concat("fixtures/", name, "/artifacts/");
        proof = vm.readFileBinary(string.concat(artifacts, "proof"));
        bytes memory raw = vm.readFileBinary(string.concat(artifacts, "public_inputs"));
        assertEq(raw.length % 32, 0, "public inputs must contain whole words");
        inputs = new bytes32[](raw.length / 32);
        for (uint256 i; i < inputs.length; ++i) {
            bytes32 word;
            assembly {
                word := mload(add(add(raw, 32), mul(i, 32)))
            }
            inputs[i] = word;
        }
    }
}
