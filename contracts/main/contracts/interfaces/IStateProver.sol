//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./IUntron.sol";

interface IStateProver {
    function proveIntent(IUntron.Order calldata order, bytes calldata proof) external returns (bool);
    function proveIntentBatch(IUntron.Order[] calldata orders, bytes calldata proof) external returns (bool);
}