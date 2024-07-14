// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

interface ITransferrer {
    function processTransfer(uint256, bytes memory) external;
}
