pragma solidity 0.8.15;

import {MultisigProposal} from "src/fps/proposal/MultisigProposal.sol";
import {AddressRegistry as Addresses} from "src/fps/AddressRegistry.sol";
import {BASE_CHAIN_ID, OP_CHAIN_ID} from "src/fps/utils/Constants.sol";

interface SystemConfig {
    function setGasLimit(uint64) external;
}


contract Task00 is MultisigProposal("src/fps/example/task-00/taskConfig.toml") {
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
        AllowedStorageAccesses[] memory storageAccess = new AllowedStorageAccesses[](2);

        storageAccess[0].contractAddressIdentifier = "SystemConfigProxy";
        storageAccess[0].l2ChainId = BASE_CHAIN_ID;

        storageAccess[1].contractAddressIdentifier = "SystemConfigProxy";
        storageAccess[1].l2ChainId = OP_CHAIN_ID;

        return storageAccess;
    }

    function build() public override buildModifier() {
        /// view only, filtered out by Proposal.sol
        SystemConfig configBase = SystemConfig(addresses.getAddress("SystemConfig", BASE_CHAIN_ID));
        SystemConfig configOp = SystemConfig(addresses.getAddress("SystemConfig", OP_CHAIN_ID));
        /// mutative call, recorded by Proposal.sol for generating multisig calldata
        configBase.setGasLimit(100_000);
        configOp.setGasLimit(100_000);
    }
}
