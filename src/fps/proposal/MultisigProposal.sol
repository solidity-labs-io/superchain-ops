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

    /// @notice storage slot for the fallback handler
    /// keccak256("fallback_manager.handler.address")
    bytes32 public constant FALLBACK_HANDLER_STORAGE_SLOT = 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;

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
    string public startingImplementationVersion;

    /// @notice whether or not storage besides owners and nonce is allowed to
    /// be modified with this proposal
    bool public safeConfigChangeAllowed;

    /// @notice whether or not owners are allowed to be modified with this proposal
    bool public safeOwnersChangeAllowed;

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
        bytes memory fileContents = vm.parseTOML(vm.readFile(path));
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

        /// Fetch starting owners, threshold, modules, fallback handler, and logic contract from the Gnosis Safe
        IGnosisSafe safe = IGnosisSafe(caller);
        startingOwners = safe.getOwners();
        startingThreshold = safe.getThreshold();
        (startingModules,) = safe.getModulesPaginated(address(0x1), MODULES_FETCH_AMOUNT);
        startingFallbackHandler = address(uint160(uint256(safe.getStorageAt(FALLBACK_HANDLER_STORAGE_SLOT, 1))));
        startingImplementationVersion = safe.VERSION();
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

        if(!safeOwnersChangeAllowed) {
            address[] memory owners = IGnosisSafe(multisig).getOwners();
            for (uint256 i = 0; i < owners.length; i++) {
                require(owners[i] == startingOwners[i], "MultisigProposal: owner mismatch");
            }
        }

        if(!safeConfigChangeAllowed) {
            uint256 threshold = IGnosisSafe(multisig).getThreshold();
            (address[] memory modules,) = IGnosisSafe(multisig).getModulesPaginated(address(0x1), MODULES_FETCH_AMOUNT);
            address fallbackHandler = address(uint160(uint256(IGnosisSafe(multisig).getStorageAt(FALLBACK_HANDLER_STORAGE_SLOT, 1))));
            string memory version = IGnosisSafe(multisig).VERSION();

            require(keccak256(abi.encodePacked(version)) == keccak256(abi.encodePacked(startingImplementationVersion)), "MultisigProposal: version mismatch");
            require(threshold == startingThreshold, "MultisigProposal: threshold mismatch");
            require(fallbackHandler == startingFallbackHandler, "MultisigProposal: fallback handler mismatch");

            for (uint256 i = 0; i < modules.length; i++) {
                require(modules[i] == startingModules[i], "MultisigProposal: module mismatch");
            }
        }

        require(IGnosisSafe(multisig).nonce() == nonce + 1, "MultisigProposal: nonce not incremented");

        _validate();
    }

    function _validate() internal view virtual;
}
