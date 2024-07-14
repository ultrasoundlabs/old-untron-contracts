// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "../Untron.sol";

contract MockVerifier is ITronVerifier {
    function verifyCycle(Untron.TronBlockHeader[19] calldata, Untron.Deposit[] calldata, bytes calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}
