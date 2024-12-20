pragma solidity 0.8.15;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";

import {IProposal} from "src/fps/proposal/IProposal.sol";
import {BytesHelper} from "src/fps/utils/BytesHelper.sol";
import {IGnosisSafe, Enum} from "src/fps/proposal/IGnosisSafe.sol";
import {NetworkTranslator} from "src/fps/utils/NetworkTranslator.sol";
import {AddressRegistry as Addresses} from "src/fps/AddressRegistry.sol";
import {MULTICALL_BYTECODE, SAFE_BYTECODE} from "src/fps/utils/Constants.sol";
import {MULTICALL3_ADDRESS, ETHEREUM_CHAIN_ID, SEPOLIA_CHAIN_ID} from "src/fps/utils/Constants.sol";

abstract contract MultisigProposal is Test, Script, IProposal {
    using BytesHelper for bytes;
    using NetworkTranslator for uint256;

    /// @notice offset for the nonce variable in Gnosis Safe
    bytes32 public constant NONCE_OFFSET = 0x0000000000000000000000000000000000000000000000000000000000000005;

    /// @notice the amount of modules to fetch from the Gnosis Safe
    uint256 public constant MODULES_FETCH_AMOUNT = 1_000;

    /// @notice storage slot for the fallback handler
    /// keccak256("fallback_manager.handler.address")
    bytes32 public constant FALLBACK_HANDLER_STORAGE_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;

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

    /// @notice flag to print internal proposal logs, default is false
    bool internal DEBUG;

    /// @notice flag to initiate pre-build mocking processes, default is true
    bool internal DO_MOCK;

    /// @notice flag to transform plain solidity code into calldata encoded for the
    /// user's governance model, default is true
    bool internal DO_BUILD;

    /// @notice flag to simulate saved actions during the `build` step, default is true
    bool internal DO_SIMULATE;

    /// @notice flag to validate the system state post-proposal simulation, default is true
    bool internal DO_VALIDATE;

    /// @notice flag to print proposal description, actions, and calldata, default is true
    bool internal DO_PRINT;

    /// @notice Addresses contract
    Addresses public addresses;

    /// @notice primary fork id
    uint256 public primaryForkId;

    /// @notice The address of the caller for the proposal
    /// is set in the multisig proposal constructor
    address public caller;

    /// @notice struct to store allowed storage accesses
    /// maps a chainid to an array of allowed storage accesses for that chain
    AllowedStorageAccesses[] private _allowedStorageAccesses;

    /// addresses that are allowed to be the receivers of delegate calls
    mapping(address => bool) private _allowedDelegateCalls;

    struct Action {
        address target;
        uint256 value;
        bytes arguments;
        string description;
    }

    struct TransferInfo {
        address to;
        uint256 value;
        address tokenAddress;
    }

    struct StateInfo {
        bytes32 slot;
        bytes32 oldValue;
        bytes32 newValue;
    }

    /// @notice transfers during proposal execution
    mapping(address => TransferInfo[]) private _proposalTransfers;

    /// @notice state changes during proposal execution
    mapping(address => StateInfo[]) private _stateInfos;

    /// @notice addresses involved in state changes or token transfers
    address[] private _proposalTransferFromAddresses;

    /// @notice map if an address is affected in proposal execution
    mapping(address => bool) private _isProposalTransferFromAddress;

    address[] internal _proposalStateChangeAddresses;

    /// @notice stores the gnosis safe accesses for the proposal
    VmSafe.StorageAccess[] internal _accountAccesses;

    /// @notice stores the addresses touched by the proposal state changes
    mapping(address => bool) internal _isProposalStateChangeAddress;

    /// @notice starting snapshot of the contract state before the calls are made
    uint256 private _startSnapshot;

    /// @notice list of actions to be executed, regardless of proposal type
    /// they all follow the same structure
    Action[] public actions;

    struct Call3Value {
        address target;
        bool allowFailure;
        uint256 value;
        bytes callData;
    }

    /// Task TOML config file values

    struct TaskConfig {
        string[] allowedStorageAccesses;
        string[] authorizedDelegateCalls;
        string safeAddressString;
        bool safeConfigChange;
        bool safeOwnersChange;
    }

    /// configuration set at construction
    TaskConfig public config;

    /// @notice buildModifier to be used by the build function to populate the
    /// actions array
    modifier buildModifier() {
        require(caller != address(0), "Must set addresses object for multisig address to be set");

        if (DO_SIMULATE || DO_PRINT) {
            require(DO_BUILD, "Cannot simulate/print without first building");
        }

        _startBuild();
        _;
        _endBuild();
    }

    constructor(string memory path, string memory taskName) {
        /// read in proposal configuration
        DEBUG = vm.envOr("DEBUG", false);

        DO_MOCK = vm.envOr("DO_MOCK", true);
        DO_BUILD = vm.envOr("DO_BUILD", true);
        DO_SIMULATE = vm.envOr("DO_SIMULATE", true);
        DO_VALIDATE = vm.envOr("DO_VALIDATE", true);
        DO_PRINT = vm.envOr("DO_PRINT", true);

        bytes memory fileContents = vm.parseToml(vm.readFile(path), ".task");
        config = abi.decode(fileContents, (TaskConfig));

        safeConfigChangeAllowed = config.safeConfigChange;
        safeOwnersChangeAllowed = config.safeOwnersChange;

        string memory networkName;
        if(block.chainid == ETHEREUM_CHAIN_ID) {
            networkName = "mainnet";
        } else if (block.chainid == SEPOLIA_CHAIN_ID) {
            networkName = "sepolia";
        } else {
            revert("Unsupported network");
        }

        bytes memory safeNonce = vm.parseToml(vm.readFile(path), string(abi.encodePacked(".", networkName, ".", taskName, ".safeNonce")));
        nonce = abi.decode(safeNonce, (uint256));
    }

    /// @notice function to be used by forge script.
    /// @dev use flags to determine which actions to take
    ///      this function shoudn't be overriden.
    function run() public {
        console.log("run function start");
        if (DO_MOCK) mock();
        console.log("run function mocked");
        if (DO_BUILD) build();
        console.log("run function deployed");
        if (DO_SIMULATE) simulate();
        console.log("run function simulated");
        if (DO_VALIDATE) validate();
        console.log("run function validated");
        if (DO_PRINT) print();
        console.log("run function printed");
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

    function printDataToSign() public virtual view {
        console.logBytes(_getDataToSign(caller, getCalldata()));
    }

    function printHashToApprove() public virtual view {
        bytes32 hash = keccak256(_getDataToSign(caller, getCalldata()));
        console.logBytes32(hash);
    }

    function _getDataToSign(address safe, bytes memory data) internal view returns (bytes memory) {
        return IGnosisSafe(safe).encodeTransactionData({
            to: MULTICALL3_ADDRESS,
            value: 0,
            data: data,
            operation: Enum.Operation.DelegateCall,
            safeTxGas: 0,
            baseGas: 0,
            gasPrice: 0,
            gasToken: address(0),
            refundReceiver: address(0),
            _nonce: nonce
        });
    }

    /// @notice actually simulates the proposal.
    ///         e.g. schedule and execute on Timelock Controller,
    ///         proposes, votes and execute on Governor Bravo, etc.
    function simulate() public {
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

    /// @notice returns the allowed storage accesses for the current chain id
    function getAllowedStorageAccess() public view returns (AllowedStorageAccesses[] memory) {
        return _allowedStorageAccesses;
    }

    /// @notice execute post-proposal checks.
    ///          e.g. read state variables of the deployed contracts to make
    ///          sure they are deployed and initialized correctly, or read
    ///          states that are expected to have changed during the simulate step.
    function validate() public view override {
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

        if (!safeOwnersChangeAllowed) {
            address[] memory owners = IGnosisSafe(caller).getOwners();
            for (uint256 i = 0; i < owners.length; i++) {
                require(owners[i] == startingOwners[i], "MultisigProposal: owner mismatch");
            }
        }

        if (!safeConfigChangeAllowed) {
            uint256 threshold = IGnosisSafe(caller).getThreshold();
            (address[] memory modules,) = IGnosisSafe(caller).getModulesPaginated(address(0x1), MODULES_FETCH_AMOUNT);
            address fallbackHandler = address(
                uint160(
                    uint256(IGnosisSafe(caller).getStorageAt(uint256(FALLBACK_HANDLER_STORAGE_SLOT), 1).getFirstWord())
                )
            );
            string memory version = IGnosisSafe(caller).VERSION();

            require(
                keccak256(abi.encodePacked(version)) == keccak256(abi.encodePacked(startingImplementationVersion)),
                "MultisigProposal: multisig contract upgraded"
            );
            require(threshold == startingThreshold, "MultisigProposal: threshold changed");
            require(fallbackHandler == startingFallbackHandler, "MultisigProposal: fallback handler changed");

            for (uint256 i = 0; i < modules.length; i++) {
                require(modules[i] == startingModules[i], "MultisigProposal: module changed");
            }
        }

        // todo: simulate with private key so that nonce is incremented
        // require(IGnosisSafe(caller).nonce() == nonce + 1, "MultisigProposal: safe nonce not incremented");

        _validate();
    }

    function _validate() internal view virtual;

    /// @notice get proposal actions
    function getProposalActions()
        public
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory arguments)
    {
        uint256 actionsLength = actions.length;
        require(actionsLength > 0, "No actions found");

        targets = new address[](actionsLength);
        values = new uint256[](actionsLength);
        arguments = new bytes[](actionsLength);

        for (uint256 i; i < actionsLength; i++) {
            require(actions[i].target != address(0), "Invalid target for proposal");
            /// if there are no args and no eth, the action is not valid
            require(
                (actions[i].arguments.length == 0 && actions[i].value > 0) || actions[i].arguments.length > 0,
                "Invalid arguments for proposal"
            );
            targets[i] = actions[i].target;
            arguments[i] = actions[i].arguments;
            values[i] = actions[i].value;
        }
    }

    /// --------------------------------------------------------------------
    /// --------------------------------------------------------------------
    /// --------------------------- Public functions -----------------------
    /// --------------------------------------------------------------------
    /// --------------------------------------------------------------------

    /// @notice set the Addresses contract
    function setAddresses(Addresses _addresses) public override {
        require(address(addresses) == address(0), "Addresses already set");

        addresses = _addresses;

        /// get superchains
        ///
        Addresses.Superchain[] memory superchains = addresses.getSuperchains();
        require(superchains.length > 0, "MultisigProposal: no superchains found");

        /// check that the safe address is the same for all superchains and then set safe in storage
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
        startingFallbackHandler =
            address(uint160(uint256(safe.getStorageAt(uint256(FALLBACK_HANDLER_STORAGE_SLOT), 1).getFirstWord())));
        startingImplementationVersion = safe.VERSION();

        for (uint256 i = 0; i < config.allowedStorageAccesses.length; i++) {
            for (uint256 j = 0; j < superchains.length; j++) {
                _allowedStorageAccesses.push(
                    AllowedStorageAccesses({
                        contractAddressIdentifier: config.allowedStorageAccesses[i],
                        l2ChainId: superchains[j].chainId
                    })
                );
            }
        }

        for (uint256 i = 0; i < config.authorizedDelegateCalls.length; i++) {
            for (uint256 j = 0; j < superchains.length; j++) {
                _allowedDelegateCalls[addresses.getAddress(config.authorizedDelegateCalls[i], superchains[j].chainId)] = true;
            }
        }
    }

    /// TODO can we remove this??

    /// @notice set the primary fork id
    function setPrimaryForkId(uint256 _primaryForkId) public override {
        primaryForkId = _primaryForkId;
    }

    /// @notice helper function to mock on-chain data
    ///         e.g. pranking, etching, etc.
    function mock() public virtual {}

    /// @notice build the proposal actions
    /// @dev contract calls must be perfomed in plain solidity.
    ///      overriden requires using buildModifier modifier to leverage
    ///      foundry snapshot and state diff recording to populate the actions array.
    function build() public virtual;

    /// @notice print proposal description, actions and calldata
    function print() public virtual {
        console.log("\n---------------- Proposal Description ----------------");
        console.log(description());

        console.log("\n------------------ Proposal Actions ------------------");
        for (uint256 i; i < actions.length; i++) {
            console.log("%d). %s", i + 1, actions[i].description);
            console.log("target: %s\npayload", _getAddressLabel(actions[i].target));
            console.logBytes(actions[i].arguments);
            console.log("\n");
        }

        console.log("\n----------------- Proposal Transfers -------------------");
        for (uint256 i; i < _proposalTransferFromAddresses.length; i++) {
            address account = _proposalTransferFromAddresses[i];

            console.log("\n\n", string(abi.encodePacked(_getAddressLabel(account), ":")));

            // print token transfers
            TransferInfo[] memory transfers = _proposalTransfers[account];
            if (transfers.length > 0) {
                console.log("\n Transfers:");
            }
            for (uint256 j; j < transfers.length; j++) {
                if (transfers[j].tokenAddress == address(0)) {
                    console.log(
                        string(
                            abi.encodePacked(
                                "Sent ", vm.toString(transfers[j].value), " ETH to ", _getAddressLabel(transfers[j].to)
                            )
                        )
                    );
                } else {
                    console.log(
                        string(
                            abi.encodePacked(
                                "Sent ",
                                vm.toString(transfers[j].value),
                                " ",
                                _getAddressLabel(transfers[j].tokenAddress),
                                " to ",
                                _getAddressLabel(transfers[j].to)
                            )
                        )
                    );
                }
            }
        }

        console.log("\n----------------- Proposal State Changes -------------------");
        // print state changes
        for (uint256 k; k < _proposalStateChangeAddresses.length; k++) {
            address account = _proposalStateChangeAddresses[k];
            StateInfo[] memory stateChanges = _stateInfos[account];
            if (stateChanges.length > 0) {
                console.log("\n State Changes for account:", _getAddressLabel(account));
            }
            for (uint256 j; j < stateChanges.length; j++) {
                console.log("Slot:", vm.toString(stateChanges[j].slot));
                console.log("- ", vm.toString(stateChanges[j].oldValue));
                console.log("+ ", vm.toString(stateChanges[j].newValue));
            }
        }

        _printProposalCalldata();

        console.log("\n\n------------------ Data to Sign ------------------");
        printDataToSign();

        console.log("\n\n------------------ Hash to Approve ------------------");
        printHashToApprove();
    }

    /// --------------------------------------------------------------------
    /// --------------------------------------------------------------------
    /// ------------------------- Internal functions -----------------------
    /// --------------------------------------------------------------------
    /// --------------------------------------------------------------------

    /// @notice validate actions inclusion
    /// default implementation check for duplicate actions
    function _validateAction(address target, uint256 value, bytes memory data) internal virtual {
        uint256 actionsLength = actions.length;
        for (uint256 i = 0; i < actionsLength; i++) {
            // Check if the target, arguments and value matches with other exciting actions.
            bool isDuplicateTarget = actions[i].target == target;
            bool isDuplicateArguments = keccak256(actions[i].arguments) == keccak256(data);
            bool isDuplicateValue = actions[i].value == value;

            require(!(isDuplicateTarget && isDuplicateArguments && isDuplicateValue), "Duplicated action found");
        }
    }

    /// @notice validate actions
    function _validateActions() internal virtual {
        /// TODO implement checks for order of calls to validate different templatized operations
    }

    /// @notice print proposal calldata
    function _printProposalCalldata() internal virtual {
        console.log("\n\n------------------ Proposal Calldata ------------------");
        console.logBytes(getCalldata());
    }

    /// --------------------------------------------------------------------
    /// --------------------------------------------------------------------
    /// ------------------------- Private functions ------------------------
    /// --------------------------------------------------------------------
    /// --------------------------------------------------------------------

    /// @notice to be used by the build function to create a governance proposal
    /// kick off the process of creating a governance proposal by:
    ///  1). taking a snapshot of the current state of the contract
    ///  2). starting prank as the caller
    ///  3). starting a $recording of all calls created during the proposal
    function _startBuild() private {
        vm.startPrank(caller);

        _startSnapshot = vm.snapshot();

        vm.startStateDiffRecording();
    }

    /// @notice to be used at the end of the build function to snapshot
    /// the actions performed by the proposal and revert these changes
    /// then, stop the prank and record the state diffs and actions that
    /// were taken by the proposal.
    function _endBuild() private {
        VmSafe.AccountAccess[] memory accountAccesses = vm.stopAndReturnStateDiff();

        vm.stopPrank();

        /// roll back all state changes made during the governance proposal
        require(vm.revertTo(_startSnapshot), "failed to revert back to snapshot, unsafe state to run proposal");

        _processStateDiffChanges(accountAccesses);

        for (uint256 i = 0; i < accountAccesses.length; i++) {
            /// store all gnosis safe storage accesses that are writes
            for (uint256 j = 0; j < accountAccesses[i].storageAccesses.length; j++) {
                if (accountAccesses[i].account == caller && accountAccesses[i].storageAccesses[j].isWrite) {
                    _accountAccesses.push(accountAccesses[i].storageAccesses[j]);
                }
            }

            if (accountAccesses[i].kind == VmSafe.AccountAccessKind.DelegateCall) {
                require(
                    _allowedDelegateCalls[accountAccesses[i].account],
                    string.concat("Unauthorized DelegateCall to address ", vm.getLabel(accountAccesses[i].account))
                );
            }

            /// only care about calls from the original caller,
            /// static calls are ignored,
            /// calls to and from Addresses and the vm contract are ignored
            /// ignore calls to vm in the build function
            /// TODO should we remove this condition? it may filter out calls that we need
            if (
                accountAccesses[i].account != address(addresses) && accountAccesses[i].account != address(vm)
                    && accountAccesses[i].accessor != address(addresses)
                    && accountAccesses[i].kind == VmSafe.AccountAccessKind.Call && accountAccesses[i].accessor == caller
            ) {
                /// caller is correct, not a subcall
                _validateAction(accountAccesses[i].account, accountAccesses[i].value, accountAccesses[i].data);

                actions.push(
                    Action({
                        value: accountAccesses[i].value,
                        target: accountAccesses[i].account,
                        arguments: accountAccesses[i].data,
                        description: string(
                            abi.encodePacked(
                                "calling ",
                                _getAddressLabel(accountAccesses[i].account),
                                " with ",
                                vm.toString(accountAccesses[i].value),
                                " eth and ",
                                vm.toString(accountAccesses[i].data),
                                " data."
                            )
                        )
                    })
                );
            }
        }

        _validateActions();
    }

    /// @notice helper method to get transfers and state changes of proposal affected addresses
    function _processStateDiffChanges(VmSafe.AccountAccess[] memory accountAccesses) internal {
        for (uint256 i = 0; i < accountAccesses.length; i++) {
            // process ETH transfer changes
            _processETHTransferChanges(accountAccesses[i]);

            // process ERC20 transfer changes
            _processERC20TransferChanges(accountAccesses[i]);

            // process state changes
            _processStateChanges(accountAccesses[i].storageAccesses);
        }
    }

    /// @notice helper method to get eth transfers of proposal affected addresses
    function _processETHTransferChanges(VmSafe.AccountAccess memory accountAccess) internal {
        address account = accountAccess.account;
        // get eth transfers
        if (accountAccess.value != 0) {
            // add address to proposal transfer from addresses array only if not already added
            if (!_isProposalTransferFromAddress[accountAccess.accessor]) {
                _isProposalTransferFromAddress[accountAccess.accessor] = true;
                _proposalTransferFromAddresses.push(accountAccess.accessor);
            }
            _proposalTransfers[accountAccess.accessor].push(
                TransferInfo({to: account, value: accountAccess.value, tokenAddress: address(0)})
            );
        }
    }

    /// @notice helper method to get ERC20 token transfers of proposal affected addresses
    function _processERC20TransferChanges(VmSafe.AccountAccess memory accountAccess) internal {
        bytes memory data = accountAccess.data;
        if (data.length <= 4) {
            return;
        }

        // get function selector from calldata
        bytes4 selector = bytes4(data);

        // get function params
        bytes memory params = new bytes(data.length - 4);
        for (uint256 j = 0; j < data.length - 4; j++) {
            params[j] = data[j + 4];
        }

        address from;
        address to;
        uint256 value;
        // 'transfer' selector in ERC20 token
        if (selector == 0xa9059cbb) {
            (to, value) = abi.decode(params, (address, uint256));
            from = accountAccess.accessor;
        }
        // 'transferFrom' selector in ERC20 token
        else if (selector == 0x23b872dd) {
            (from, to, value) = abi.decode(params, (address, address, uint256));
        } else {
            return;
        }

        // add address to proposal transfer from addresses array only if not already added
        if (!_isProposalTransferFromAddress[from]) {
            _isProposalTransferFromAddress[from] = true;
            _proposalTransferFromAddresses.push(from);
        }

        _proposalTransfers[from].push(TransferInfo({to: to, value: value, tokenAddress: accountAccess.account}));
    }

    /// @notice helper method to get state changes of proposal affected addresses
    function _processStateChanges(VmSafe.StorageAccess[] memory storageAccess) internal {
        for (uint256 i; i < storageAccess.length; i++) {
            address account = storageAccess[i].account;

            // get only state changes for write storage access
            if (storageAccess[i].isWrite) {
                _stateInfos[account].push(
                    StateInfo({
                        slot: storageAccess[i].slot,
                        oldValue: storageAccess[i].previousValue,
                        newValue: storageAccess[i].newValue
                    })
                );
            }

            // add address to proposal state change addresses array only if not already added
            if (!_isProposalStateChangeAddress[account] && _stateInfos[account].length != 0) {
                _isProposalStateChangeAddress[account] = true;
                _proposalStateChangeAddresses.push(account);
            }
        }
    }

    /// @notice helper method to get labels for addresses
    function _getAddressLabel(address contractAddress) internal view returns (string memory) {
        string memory label = vm.getLabel(contractAddress);

        bytes memory prefix = bytes("unlabeled:");
        bytes memory strBytes = bytes(label);

        if (strBytes.length >= prefix.length) {
            // check if address is unlabeled
            for (uint256 i = 0; i < prefix.length; i++) {
                if (strBytes[i] != prefix[i]) {
                    // return "{LABEL} @{ADDRESS}" if address is labeled
                    return string(abi.encodePacked(label, " @", vm.toString(contractAddress)));
                }
            }
        } else {
            // return "{LABEL} @{ADDRESS}" if address is labeled
            return string(abi.encodePacked(label, " @", vm.toString(contractAddress)));
        }

        // return "UNLABELED @{ADDRESS}" if address is unlabeled
        return string(abi.encodePacked("UNLABELED @", vm.toString(contractAddress)));
    }

    /// @notice proposal name, e.g. "BIP15".
    /// @dev override this to set the proposal name.
    function name() external view virtual returns (string memory);

    /// @notice proposal description.
    /// @dev override this to set the proposal description.
    function description() public view virtual returns (string memory);
}
