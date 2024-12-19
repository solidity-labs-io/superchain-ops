pragma solidity 0.8.15;

import {console} from "forge-std/console.sol";

import {Proposal} from "./Proposal.sol";
import {IGnosisSafe, Enum} from "./IGnosisSafe.sol";
import {MULTICALL3_ADDRESS} from "src/fps/utils/Constants.sol";
import {AddressRegistry as Addresses} from "src/fps/AddressRegistry.sol";
import {MULTICALL_BYTECODE, SAFE_BYTECODE} from "src/fps/utils/Constants.sol";

abstract contract MultisigProposal is Proposal {
    bytes32 public constant MULTISIG_BYTECODE_HASH =
        bytes32(0xb89c1b3bdf2cf8827818646bce9a8f6e372885f8c55e5c07acbd307cb133b000);

    /// @notice offset for the nonce variable in Gnosis Safe
    bytes32 public constant NONCE_OFFSET = 0x0000000000000000000000000000000000000000000000000000000000000005;

    /// @notice the amount of modules to fetch from the Gnosis Safe
    uint256 public constant MODULES_FETCH_AMOUNT = 1_000;

    /// @notice nonce used for generating the safe transaction
    /// will be set to the value specified in the config file
    uint256 public nonce;

    /// @notice owners the safe started with
    address[] public startingOwners;

    /// @notice starting safe threshold
    uint256 public startingThreshold;

    /// @notice starting modules
    address[] public startingModules;

    /// @notice starting fallback handler
    address public startingFallbackHandler;

    /// @notice starting logic contract
    address public startingLogicContract;

    /// @notice whether or not storage besides owners and nonce is allowed to
    /// be modified with this proposal
    bool public safeConfigChangeAllowed;

    /// @notice array of L2 ChainIds this proposal will interface with
    /// TODO populate this in constructor, reading in toml config file
    uint256[] public l2ChainIds;

    /// @notice configured chain id
    uint256 public configChainId;

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
        Addresses.Superchain[] memory superchains = addresses.getSuperchains();
        require(superchains.length > 0, "MultisigProposal: no superchains found");

        /// check that the safe address is the same for all superchains and set caller
        caller = addresses.getAddress(config.safeAddressString, superchains[0].chainId);
        for (uint256 i = 1; i < superchains.length; i++) {
            require(
                caller == addresses.getAddress(config.safeAddressString, superchains[i].chainId),
                "MultisigProposal: safe address mismatch"
            );
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
                /// if this address was explicitly allowed in the proposal, or the caller is the multisig
                if (
                    addresses.getAddress(
                        allowedStorageAccesses[j].contractAddressIdentifier, allowedStorageAccesses[j].l2ChainId
                    ) == addr || addr == caller
                ) {
                    isAllowed = true;
                    break;
                }
            }

            /// make more verbose
            require(
                isAllowed,
                string(
                    abi.encodePacked(
                        "MultisigProposal: address ", vm.toString(addr), " not in allowed storage accesses"
                    )
                )
            );
        }

        if (_accountAccesses.length != 1) {
            require(safeConfigChangeAllowed == true, "MultisigProposal: ");

            /// TODO check if the changes made to the multisig were valid
            /// - check that modules are the same before and after
            /// - check that owners are the same before and after
            /// - check that the threshold is the same before and after
            /// - check that fallback handler is the same before and after
            /// - check that the logic contract is the same before and after
        } else if (_accountAccesses.length == 1) {
            require(
                _accountAccesses[0].slot == NONCE_OFFSET,
                string.concat(
                    "MultisigProposal: modified multisig slot ",
                    vm.toString(_accountAccesses[0].slot),
                    " instead of ",
                    vm.toString(NONCE_OFFSET)
                )
            );
        }

        _validate();
    }

    function _validate() internal view virtual;
}
