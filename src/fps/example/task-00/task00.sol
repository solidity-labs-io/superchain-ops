pragma solidity 0.8.15;

import {SystemConfig} from "src/fps/example/ISystemConfig.sol";
import {MultisigProposal} from "src/fps/proposal/MultisigProposal.sol";
import {NetworkTranslator} from "src/fps/utils/NetworkTranslator.sol";
import {AddressRegistry as Addresses} from "src/fps/AddressRegistry.sol";
import {BASE_CHAIN_ID, OP_CHAIN_ID} from "src/fps/utils/Constants.sol";

contract Task00 is MultisigProposal("src/fps/example/task-00/taskConfig.toml", "task1") {
    using NetworkTranslator for uint256;

    /// @notice New gas limit to be set
    uint64 public constant NEW_GAS_LIMIT = 100_000_000;

    /// TODO add support for passing the addresses object
    constructor() {
        Addresses _addresses = new Addresses("src/fps/addresses", "src/fps/example/task-00/taskConfig.toml", "task1");
        setAddresses(_addresses);
    }

    function name() public pure override returns (string memory) {
        return "Task 00";
    }

    function description() public pure override returns (string memory) {
        return "Set gas limit to 100,000";
    }

    function build() public override buildModifier {
        Addresses.Superchain[] memory superchains = addresses.getSuperchains();

        for (uint256 i = 0; i < superchains.length; i++) {
            /// view only, filtered out by Proposal.sol
            SystemConfig systemConfig = SystemConfig(addresses.getAddress("SystemConfigProxy", superchains[i].chainId));

            /// mutative call, recorded by Proposal.sol for generating multisig calldata
            systemConfig.setGasLimit(NEW_GAS_LIMIT);
        }
    }

    function _validate() internal view override {
        Addresses.Superchain[] memory superchains = addresses.getSuperchains();
        for (uint256 i = 0; i < superchains.length; i++) {
            SystemConfig systemConfig = SystemConfig(addresses.getAddress("SystemConfigProxy", superchains[i].chainId));
            assertEq(systemConfig.gasLimit(), NEW_GAS_LIMIT, "Op gas limit not set");
        }
    }
}
