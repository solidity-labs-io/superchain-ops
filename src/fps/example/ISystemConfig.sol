pragma solidity 0.8.15;

interface SystemConfig {
    function setGasLimit(uint64) external;

    function gasLimit() external view returns (uint64);
}
