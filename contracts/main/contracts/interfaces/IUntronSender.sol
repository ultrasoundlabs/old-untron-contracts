//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

interface IUntronSender {
    struct SendRequest {
        bytes32 to;
        uint amount;
        uint chain;
        bytes data;
    }

    function crossChainSend(SendRequest[] calldata requests) external;
}