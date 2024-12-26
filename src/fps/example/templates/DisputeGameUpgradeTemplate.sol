pragma solidity 0.8.15;

import {SystemConfig} from "src/fps/example/ISystemConfig.sol";
import {MultisigProposal} from "src/fps/proposal/MultisigProposal.sol";
import {NetworkTranslator} from "src/fps/utils/NetworkTranslator.sol";
import {AddressRegistry as Addresses} from "src/fps/AddressRegistry.sol";
import {BASE_CHAIN_ID, OP_CHAIN_ID, ADDRESSES_PATH} from "src/fps/utils/Constants.sol";
import {IDisputeGameFactory} from "src/fps/example/IDisputeGameFactory.sol";

import "forge-std/console.sol";

contract DisputeGameUpgradeTemplate is MultisigProposal {
    struct SetImplementation {
        uint32 gameType;
        address implementation;
        uint256 l2ChainId;
    }

    mapping(uint256 => SetImplementation) public setImplementations;

    function run(string memory taskConfigFilePath, string memory networkConfigFilePath) public {
        Addresses _addresses = new Addresses(ADDRESSES_PATH, networkConfigFilePath);

        init(taskConfigFilePath, networkConfigFilePath, _addresses);

        SetImplementation[] memory setImplementation =
            abi.decode(vm.parseToml(vm.readFile(networkConfigFilePath), ".implementations"), (SetImplementation[]));

        for (uint256 i = 0; i < setImplementation.length; i++) {
            setImplementations[setImplementation[i].l2ChainId] = setImplementation[i];
        }

        run();
    }

    function _build(uint256 chainId) internal override {
        /// view only, filtered out by Proposal.sol
        IDisputeGameFactory disputeGameFactory =
            IDisputeGameFactory(addresses.getAddress("DisputeGameFactoryProxy", chainId));

        if (setImplementations[chainId].l2ChainId != 0) {
            disputeGameFactory.setImplementation(
                setImplementations[chainId].gameType, setImplementations[chainId].implementation
            );
        }
    }

    function _validate(uint256 chainId) internal view override {
        IDisputeGameFactory disputeGameFactory =
            IDisputeGameFactory(addresses.getAddress("DisputeGameFactoryProxy", chainId));

        if (setImplementations[chainId].l2ChainId != 0) {
            assertEq(
                disputeGameFactory.gameImpls(setImplementations[chainId].gameType),
                setImplementations[chainId].implementation,
                "implementation not set"
            );
        }
    }
}
