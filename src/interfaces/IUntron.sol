//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./IUntronSender.sol";

interface ITronVerifier {
    function verify(IUntron.TronBlockHeader[19] calldata headers, IUntron.Order[] calldata orders, bytes calldata proof)
        external
        returns (bool);
}

interface IUntron {
    struct TronBlockHeader {
        bytes32 blockId;
        bytes32 txRoot;
    }

    struct Buyer {
        address tronAddress;
        uint256 liquidity;
        uint256 rate;
        bool active;
    }

    struct Order {
        address from;
        address buyer;
        address tronAddress;
        uint256 inAmount;
        uint256 outAmount;
        uint256 revealFee;
        bytes32 recipient; // not "address" for non-EVM compatibility
        uint256 destinationChain;
        bytes bridgeData;
    }

    event OrderCreated(Order order);
    event OrderFulfilled(Order order, bytes32 txHash);

    struct Params {
        ITronVerifier verifier;
        uint256 revealFee;
        uint256 minOrderSize;
        address paymasterAuthority;
        IUntronSender crossChainSender;
        uint256 maxTransfersPerCycle;
    }

    function params() external view returns (Params memory);
    function params(Params calldata __params) external;

    function createOrder(
        address buyer,
        uint256 amount,
        bytes32 recipient,
        uint256 destinationChain,
        bytes memory bridgeData
    ) external;
    function fulfillOrder(
        Order calldata _order,
        uint256 usdtAmount,
        bytes calldata transaction,
        uint256 headerIndex,
        bytes32[] calldata proof
    ) external;
    function closeOrder(Order calldata order) external;

    function setBuyer(address tronAddress, uint256 liquidity, uint256 rate) external;
    function closeBuyer() external;

    function updateRelay(TronBlockHeader[18] calldata newHeaders, Order[] calldata newOrders, bytes calldata proof)
        external;
    function reorgRelay(TronBlockHeader[18][2] calldata cycles, Order[][2] calldata orders, bytes[2] calldata proofs)
        external;

    function isEligibleForPaymaster(address _address) external view returns (bool);
}
