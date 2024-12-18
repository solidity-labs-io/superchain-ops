pragma solidity 0.8.15;

import {console} from "forge-std/console.sol";

import {Proposal} from "./Proposal.sol";
import {MULTICALL_BYTECODE, SAFE_BYTECODE} from "src/fps/utils/Constants.sol";
import {AddressRegistry as Addresses} from "src/fps/AddressRegistry.sol";
import {IGnosisSafe, Enum} from "./IGnosisSafe.sol";
import {MULTICALL3_ADDRESS} from "src/fps/utils/Constants.sol";

abstract contract MultisigProposal is Proposal {
    bytes32 public constant MULTISIG_BYTECODE_HASH =
        bytes32(0xb89c1b3bdf2cf8827818646bce9a8f6e372885f8c55e5c07acbd307cb133b000);

    uint256 public nonce;

    struct Call3Value {
        address target;
        bool allowFailure;
        uint256 value;
        bytes callData;
    }

    struct TaskConfig {
        string safeAddressString;
        uint64 safeNonce;
    }

    constructor(string memory path) {
        bytes memory fileContents = bytes(vm.readFile(path));
        TaskConfig memory config = abi.decode(fileContents, (TaskConfig));

        /// whether or not to set the safe nonce manually
        nonce = config.safeNonce;

        /// get superchains
        Addresses.Superchain[] memory superchains = addresses.superchains();
        require(superchains.length > 0, "MultisigProposal: no superchains found");

        /// check that the safe address is the same for all superchains and set caller
        caller = addresses.getAddress(config.safeAddressString, superchain[0].chainId);
        for (uint256 i = 1; i < superchain.length; i++) {
            require(caller == addresses.getAddress(config.safeAddressString, superchain[i].chainId), "MultisigProposal: safe address mismatch");
        }
    }

    /// @notice return calldata, log if debug is set to true
    function getCalldata() public view override returns (bytes memory data) {
        /// get proposal actions
        (address[] memory targets, uint256[] memory values, bytes[] memory arguments) = getProposalActions();

        /// create calls array with targets and arguments
        Call3Value[] memory calls = new Call3Value[](targets.length);

        for (uint256 i; i < calls.length; i++) {
            require(targets[i] != address(0), "Invalid target for multisig");
            calls[i] = Call3Value({target: targets[i], allowFailure: false, value: values[i], callData: arguments[i]});
        }

        /// generate calldata
        data = abi.encodeWithSignature("aggregate3Value((address,bool,uint256,bytes)[])", calls);
    }

    function getDataToSign() public view returns (bytes memory data) {
        data = IGnosisSafe(caller).encodeTransactionData({
            to: MULTICALL3_ADDRESS,
            value: 0,
            data: getCalldata(),
            operation: Enum.Operation.DelegateCall,
            safeTxGas: 0,
            baseGas: 0,
            gasPrice: 0,
            gasToken: address(0),
            refundReceiver: address(0),
            _nonce: nonce
        });
    }

    function getHashToApprove() public view returns (bytes32 hash) {
        hash = keccak256(getDataToSign());
    }

    function simulate() public override {
        address multisig = caller;
        vm.startPrank(multisig);

        /// this is a hack because multisig execTransaction requires owners signatures
        /// so we cannot simulate it exactly as it will be executed on mainnet
        vm.etch(multisig, MULTICALL_BYTECODE);

        bytes memory data = getCalldata();

        (bool success,) = multisig.call{value: 0}(data);

        require(success, "MultisigProposal: simulateActions failed");

        /// revert contract code to original safe bytecode
        vm.etch(multisig, SAFE_BYTECODE);

        vm.stopPrank();
    }

    function print() public override {
        super.print();

        console.log("\n\n------------------ Data to Sign ------------------");
        console.logBytes(getDataToSign());

        console.log("\n\n------------------ Hash to Approve ------------------");
        console.logBytes32(getHashToApprove());
    }

    function validate() public override {
        AllowedStorageAccesses[] memory allowedStorageAccesses = getAllowedStorageAccess();

        for (uint256 i; i < _proposalStateChangeAddresses.length; i++) {
            address addr = _proposalStateChangeAddresses[i];
            bool isAllowed;
            for (uint256 j; j < allowedStorageAccesses.length; j++) {
                if (addresses.getAddress(allowedStorageAccesses[j].contractAddressIdentifier, allowedStorageAccesses[j].l2ChainId) == addr) {
                    isAllowed = true;
                    break;
                }
            }
            require(isAllowed, "MultisigProposal: address not in allowed storage accesses");
        }

    }
}
