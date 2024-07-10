//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./IUntron.sol";

interface IUntronSender {
    function crossChainSend(IUntron.Fulfillment[] calldata transfers) external;
}