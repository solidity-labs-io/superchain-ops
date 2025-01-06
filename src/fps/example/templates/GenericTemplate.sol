pragma solidity 0.8.15;

import {MultisigProposal} from "src/fps/proposal/MultisigProposal.sol";
import {AddressRegistry as Addresses} from "src/fps/AddressRegistry.sol";
import {ADDRESSES_PATH} from "src/fps/utils/Constants.sol";

abstract contract GenericTemplate is MultisigProposal {
    /// @notice Runs the proposal with the given task and network configuration file paths. Sets the address registry, initializes the proposal and processes the proposal.
    /// @param taskConfigFilePath The path to the task configuration file.
    /// @param networkConfigFilePath The path to the network configuration file.
    function run(string memory taskConfigFilePath, string memory networkConfigFilePath) public virtual {
        Addresses _addresses = new Addresses(ADDRESSES_PATH, networkConfigFilePath);

        _init(taskConfigFilePath, networkConfigFilePath, _addresses);

        processProposal();
    }
}
