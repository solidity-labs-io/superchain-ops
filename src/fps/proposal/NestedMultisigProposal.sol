pragma solidity 0.8.15;

import {console} from "forge-std/console.sol"; 

import {IGnosisSafe, Enum} from "src/fps/proposal/IGnosisSafe.sol";
import {MultisigProposal} from "src/fps/proposal/MultisigProposal.sol";

abstract contract NestedMultisigProposal is MultisigProposal {

    function _generateApproveMulticallData() internal view returns (bytes memory) {
        bytes32 hash = keccak256(_getDataToSign(caller, getCalldata()));
        Call3Value memory call = Call3Value({
            target: caller,
            allowFailure: false,
            value: 0,
            callData: abi.encodeCall(IGnosisSafe(caller).approveHash, (hash))
        });

        Call3Value[] memory calls = _toArray(call);

        return abi.encodeWithSignature("aggregate3Value((address,bool,uint256,bytes)[])", calls);
    }

    function printDataToSign() public virtual override view {
        bytes memory callData = _generateApproveMulticallData();

        for (uint256 i; i < startingOwners.length; i++) {
            bytes memory dataToSign = _getDataToSign(startingOwners[i], callData);
            console.logBytes(dataToSign);
        }
    }

    function printHashToApprove() public virtual override view {
        bytes memory callData = _generateApproveMulticallData();

        for (uint256 i; i < startingOwners.length; i++) {
            bytes32 hash = keccak256(_getDataToSign(startingOwners[i], callData));
            console.logBytes32(hash);
        }
    }

    function _toArray(Call3Value memory call) internal pure returns (Call3Value[] memory) {
        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = call;
        return calls;
    }
}
