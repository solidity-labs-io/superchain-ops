pragma solidity 0.8.15;

import {MultisigProposal} from "src/fps/proposal/MultisigProposal.sol";
import {AddressRegistry as Addresses} from "src/fps/AddressRegistry.sol";
import {BASE_CHAIN_ID, OP_CHAIN_ID} from "src/fps/utils/Constants.sol";

interface SystemConfig {
    function setGasLimit(uint64) external;
}

/// TODO:
///  - MultisigProposal update:
///      - default validate function where we check that only the allowed storage accesses are modified
///      - default function to check in the validate function that no safe configs are changed
contract Task00 is MultisigProposal("src/fps/example/task-00/chainlistExample.toml") {
    constructor() {
        addresses = new Addresses("src/fps/addresses", "src/fps/example/task-00/chainlistExample.toml");
    }

    function name() public pure override returns (string memory) {
        return "Task 00";
    }

    function description() public pure override returns (string memory) {
        return "Task 00 - Set gas limit to 100,000";
    }

    function getAllowedStorageAccess() public pure override returns (AllowedStorageAccesses[] memory) {
        AllowedStorageAccesses[] memory storageAccess = new AllowedStorageAccesses[](1);

        storageAccess[0].contractAddressIdentifier = "SystemConfig";
        storageAccess[0].l2ChainId = BASE_CHAIN_ID;

        return storageAccess;
    }

    function build() public override {
        /// view only, filtered out by Proposal.sol
        SystemConfig config = SystemConfig(addresses.getAddress("SystemConfig", BASE_CHAIN_ID));

        /// mutative call, recorded by Proposal.sol for generating multisig calldata
        config.setGasLimit(100_000);
    }
}
