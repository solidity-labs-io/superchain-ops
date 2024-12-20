pragma solidity 0.8.15;

import {MultisigProposal} from "src/fps/proposal/MultisigProposal.sol";
import {NetworkTranslator} from "src/fps/utils/NetworkTranslator.sol";
import {AddressRegistry as Addresses} from "src/fps/AddressRegistry.sol";
import {BASE_CHAIN_ID, OP_CHAIN_ID} from "src/fps/utils/Constants.sol";

interface SystemConfig {
    function setGasLimit(uint64) external;

    function gasLimit() external view returns (uint64);
}

contract Task00 is MultisigProposal("src/fps/example/task-00/taskConfig.toml") {
    using NetworkTranslator for uint256;

    /// TODO add support for passing the addresses object
    constructor() {
        Addresses _addresses = new Addresses("src/fps/addresses", "src/fps/example/task-00/taskConfig.toml");
        setAddresses(_addresses);
    }

    function name() public pure override returns (string memory) {
        return "Task 00";
    }

    function description() public pure override returns (string memory) {
        return "Set gas limit to 100,000";
    }

    function build() public override buildModifier {
        for (uint256 i = 0; i < l2ChainIds.length; i++) {
            /// view only, filtered out by Proposal.sol
            SystemConfig systemConfig = SystemConfig(addresses.getAddress("SystemConfigProxy", l2ChainIds[i]));

            /// mutative call, recorded by Proposal.sol for generating multisig calldata
            systemConfig.setGasLimit(100_000_000);
        }
    }

    function _validate() internal view override {
        for (uint256 i = 0; i < l2ChainIds.length; i++) {
            SystemConfig systemConfig = SystemConfig(addresses.getAddress("SystemConfigProxy", l2ChainIds[i]));
            assertEq(systemConfig.gasLimit(), 100_000, "Op gas limit not set");
        }
    }
}
