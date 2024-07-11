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
        bytes bridgeData;
    }
    event OrderCreated(Order order);
    event OrderFulfilled(Fulfillment fulfillment);

    struct Fulfillment {
        Order order;
        uint usdtAmount;
        bytes32 txHash;
    }
    struct Params {
        ITronVerifier verifier;
        uint revealFee;
        uint minOrderSize;
        address paymasterAuthority;
        IUntronSender crossChainSender;
        uint maxTransfersPerCycle;
    }

    function params() external view returns (Params memory);
    function params(Params calldata __params) external;

    function oldRoots(bytes32) external returns (bytes32);
    function activeOrders(bytes32) external returns (uint);

    function createOrder(address buyer, uint amount, bytes32 recipient, uint destinationChain, bytes memory bridgeData) external;
    function fulfillOrder(Order calldata _order, uint usdtAmount, bytes calldata transaction, bytes32 blockId, bytes32[] calldata proof) external;

    function setBuyer(address tronAddress, uint liquidity, uint rate) external;
    function closeBuyer() external;

    function updateRelay(TronBlockHeader[18] calldata _newHeaders, bytes calldata proof) external;
    function reorgRelay(TronBlockHeader[18][2] calldata cycles, bytes[2] calldata proofs) external;

    function isEligibleForPaymaster(address _address) external view returns (bool);
}