pragma solidity 0.8.15;

import {SystemConfig} from "src/fps/example/ISystemConfig.sol";
import {MultisigProposal} from "src/fps/proposal/MultisigProposal.sol";
import {NetworkTranslator} from "src/fps/utils/NetworkTranslator.sol";
import {AddressRegistry as Addresses} from "src/fps/AddressRegistry.sol";
import {BASE_CHAIN_ID, OP_CHAIN_ID, ADDRESSES_PATH} from "src/fps/utils/Constants.sol";

contract GasConfigTemplate is MultisigProposal {
    struct GasConfig {
        uint256 chainId;
        uint64 gasLimit;
    }

    mapping(uint256 => uint64) public gasLimits;

    /// TODO read this in and set it in the constructor
    struct SetGasConfig {
        uint256 l2ChainId;
        uint256 overhead;
        uint256 scalar;
    }

    SetGasConfig[] public setGasConfigs;

    /// TODO add support for passing the addresses object
    function run(string memory taskConfigFilePath, string memory networkConfigFilePath) public {
        init(taskConfigFilePath, networkConfigFilePath);

        Addresses _addresses = new Addresses(ADDRESSES_PATH, networkConfigFilePath);
        setAddresses(_addresses);

        GasConfig[] memory gasConfig =
            abi.decode(vm.parseToml(vm.readFile(networkConfigFilePath), ".gasConfigs.gasLimits"), (GasConfig[]));

        /// set gasLimits for each chain
        for (uint256 i = 0; i < gasConfig.length; i++) {
            gasLimits[gasConfig[i].chainId] = gasConfig[i].gasLimit;
        }

        run();
    }

    function _build(uint256 chainId) internal override {
        /// view only, filtered out by Proposal.sol
        SystemConfig systemConfig = SystemConfig(addresses.getAddress("SystemConfigProxy", chainId));

        /// mutative call, recorded by Proposal.sol for generating multisig calldata
        systemConfig.setGasLimit(gasLimits[chainId]);
    }

    function _validate(uint256 chainId) internal view override {
        SystemConfig systemConfig = SystemConfig(addresses.getAddress("SystemConfigProxy", chainId));
        assertEq(systemConfig.gasLimit(), gasLimits[chainId], "Op gas limit not set");
    }
}
