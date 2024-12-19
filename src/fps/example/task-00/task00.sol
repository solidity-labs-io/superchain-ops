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
        /// todo make the library to get the chain id
        storageAccess[0].l2ChainId = BASE_CHAIN_ID;

        storageAccess[1].contractAddressIdentifier = "SystemConfigProxy";
        storageAccess[1].l2ChainId = OP_CHAIN_ID;

        return storageAccess;
    }

    function build() public override buildModifier {
        /// TODO make another version that does loop over config

        for (uint256 i = 0; i < l2ChainIds.length; i++) {
            /// TODO add a helper function to NetworkTranslator that allows you
            /// to go from an L2 ChainId to the corresponding L1 ChainId
            SystemConfig config = SystemConfig(addresses.getAddress("SystemConfig", l2ChainIds[i].toNetworkChainid(configChainId)));
            config.setGasLimit(100_000);
        }

        // /// view only, filtered out by Proposal.sol
        // SystemConfig configBase = SystemConfig(addresses.getAddress("SystemConfig", BASE_CHAIN_ID));
        // SystemConfig configOp = SystemConfig(addresses.getAddress("SystemConfig", OP_CHAIN_ID));

        // /// mutative call, recorded by Proposal.sol for generating multisig calldata
        // configBase.setGasLimit(100_000);
        // configOp.setGasLimit(100_000);
    }

    function _validate() internal view override {
        for (uint256 i = 0; i < l2ChainIds.length; i++) {
            SystemConfig config = SystemConfig(addresses.getAddress("SystemConfig", l2ChainIds[i].toNetworkChainid()));
            assertEq(config.gasLimit(), 100_000, "Op gas limit not set");
        }

        // assertEq(configBase.gasLimit(), 100_000, "Base gas limit not set");
        // assertEq(configOp.gasLimit() , 100_000, "Op gas limit not set");
    }
}
