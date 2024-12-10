// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Addresses} from "../proposals/Addresses.sol";

contract AddressesTest is Test {
    Addresses private addresses;

    function setUp() public {
        // Define the path to the TOML file
        string memory tomlFilePath = "proposals/chains/";

        // Define the chain IDs to be used
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 31337; // Assuming chain ID 1 for this test

        // Create the Addresses contract instance
        addresses = new Addresses(tomlFilePath, chainIds);
    }

    function testAddressesLoaded() public {
        // Test that the addresses are loaded correctly
        address deployerEOA = addresses.getAddress("DEPLOYER_EOA");
        address compoundGovernorBravo = addresses.getAddress("COMPOUND_GOVERNOR_BRAVO");
        address compoundConfigurator = addresses.getAddress("COMPOUND_CONFIGURATOR");
    }
}
