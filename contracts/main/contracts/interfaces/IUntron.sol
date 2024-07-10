//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./IUntronSender.sol";

interface ITronVerifier {
    function verify(IUntron.TronBlockHeader[19] calldata headers, bytes calldata proof) external returns (bool);
}

interface IUntron {
    struct TronBlockHeader {
        bytes32 blockId;
        bytes32 txRoot;
        Fulfillment[] fulfillments;
    }
    struct Buyer {
        address tronAddress;
        uint liquidity;
        uint rate;
        bool active;
    }
    struct Order {
        address from;

        address buyer;
        address tronAddress;
        uint amount;
        uint rate;
        uint revealFee;

        bytes32 recipient; // not "address" for non-EVM compatibility
        uint destinationChain;
        IUntronSender bridge;
        bytes bridgeData;
    }
    event OrderCreated(Order order);
    event OrderFulfilled(Fulfillment fulfillment);

    struct Fulfillment {
        Order order;
        uint usdtAmount;
        bytes32 txHash;
    }

    function oldRoots(bytes32) external returns (bytes32);
    function activeOrders(bytes32) external returns (uint);

    function setVerifier(ITronVerifier _verifier) external;
    function setRevealFee(uint _revealFee) external;
    function setMinOrderSize(uint _minOrderSize) external;

    function createOrder(address buyer, uint amount) external;
    function fulfillOrder(Order calldata _order, uint256 usdtAmount, bytes calldata transaction, bytes32 blockId, bytes32[] calldata proof) external;

    function updateRelay(TronBlockHeader[18] calldata _newHeaders, bytes calldata proof) external;
    function reorgRelay(TronBlockHeader[18][2] calldata cycles, bytes[2] calldata proofs) external;

    function isEligibleForPaymaster(address _address) external view returns (bool);
}