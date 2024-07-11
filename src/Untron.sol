//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {
    IPaymaster,
    ExecutionResult,
    PAYMASTER_VALIDATION_SUCCESS_MAGIC
} from "era-contracts/system-contracts/contracts/interfaces/IPaymaster.sol";
import {IPaymasterFlow} from "era-contracts/system-contracts/contracts/interfaces/IPaymasterFlow.sol";
import {
    TransactionHelper, Transaction
} from "era-contracts/system-contracts/contracts/libraries/TransactionHelper.sol";
import "era-contracts/system-contracts/contracts/Constants.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IUntron.sol";
import "./interfaces/IUntronSender.sol";
import "./MerkleProof.sol";

contract Untron is Ownable, IPaymaster, IUntron {
    IERC20 usdc = IERC20(0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4); // USDC.e

    uint256 public authorityNonce;

    mapping(bytes32 => bool) internal txSeenBefore; // tron tx hash -> bool (nullifier)
    TronBlockHeader[19] internal pendingHeaders;
    Order[] internal pendingOrders;
    address internal latestRelayer;

    mapping(address => Buyer) internal buyers; // zksync address -> buyer
    mapping(address => address) internal tronAddresses; // tron address -> zksync address (buyer)

    mapping(bytes32 => uint256) internal validUntil; // order hash -> timestamp
    mapping(bytes32 => bool) internal isFulfilled; // order hash -> timestamp

    // https://github.com/zkSync-Community-Hub/zksync-developers/discussions/621
    mapping(address => int256) internal userHealth; // +1 for each fulfilled order, -1 for each unfulfilled

    Params internal _params;

    function params() public view returns (Params memory) {
        return _params;
    }

    function params(Params calldata __params) external onlyOwner {
        _params = __params;
    }

    constructor() Ownable(msg.sender) {}

    function createOrder(
        address buyer,
        uint256 amount,
        bytes32 recipient,
        uint256 destinationChain,
        bytes memory bridgeData
    ) external {
        require(buyers[buyer].active, "db");
        require(amount <= buyers[buyer].liquidity, "il");
        buyers[buyer].liquidity -= amount;

        Order memory order = Order({
            from: msg.sender,
            buyer: buyer,
            tronAddress: buyers[buyer].tronAddress,
            inAmount: amount,
            outAmount: amount * 1e18 / buyers[buyer].rate / 1e18,
            revealFee: params().revealFee,
            recipient: recipient,
            destinationChain: destinationChain,
            bridgeData: bridgeData
        });
        bytes32 orderHash = keccak256(abi.encode(order));
        validUntil[orderHash] = block.timestamp + 300;

        emit OrderCreated(order);
    }

    function _verifyTronTx(bytes memory, uint256, address) internal pure returns (bool) {
        // TODO
        return true;
    }

    function _fulfillOrders(Order[] memory orders, address revealer) internal {
        IUntronSender.SendRequest[] memory requests = new IUntronSender.SendRequest[](orders.length);
        uint256 totalAmount;
        uint256 totalRevealerFee;

        for (uint256 i = 0; i < orders.length; i++) {
            Order memory order = orders[i];

            uint256 orderTimeout = validUntil[keccak256(abi.encode(order))];
            require(orderTimeout <= block.timestamp && orderTimeout != 0, "io");

            uint256 amount = order.outAmount - order.revealFee;
            requests[i] = IUntronSender.SendRequest({
                to: order.recipient,
                amount: amount,
                chain: order.destinationChain,
                data: order.bridgeData
            });

            totalAmount += amount;
            totalRevealerFee += order.revealFee;
            userHealth[order.from]++;
        }

        assert(usdc.transfer(address(params().crossChainSender), totalAmount));
        assert(usdc.transfer(revealer, totalRevealerFee));
        params().crossChainSender.crossChainSend(requests);
    }

    // should only be used when the order was skipped by the relayer
    function fulfillOrder(
        Order calldata _order,
        uint256 usdtAmount,
        bytes calldata transaction,
        uint256 headerIndex,
        bytes32[] calldata proof
    ) external {
        Order memory order = _order;

        // this can be ZK proven (see updateRelay())
        bytes32 txHash = sha256(transaction);
        require(MerkleProof.verify(proof, pendingHeaders[headerIndex].txRoot, txHash), "ne");

        require(_verifyTronTx(transaction, usdtAmount, order.tronAddress), "it");

        Order[] memory orders = new Order[](1);
        orders[0] = order;
        _fulfillOrders(orders, msg.sender);
    }

    function closeOrder(Order calldata order) external {
        bytes32 orderHash = keccak256(abi.encode(order));

        require(!isFulfilled[orderHash]);
        require(validUntil[orderHash] > block.timestamp);

        buyers[order.buyer].liquidity += order.outAmount;
    }

    function setBuyer(address tronAddress, uint256 liquidity, uint256 rate) external {
        require(usdc.transferFrom(msg.sender, address(this), liquidity));
        buyers[msg.sender].tronAddress = tronAddress;
        buyers[msg.sender].liquidity += liquidity;
        buyers[msg.sender].rate = rate;
        buyers[msg.sender].active = true;
    }

    function closeBuyer() external {
        require(usdc.transfer(msg.sender, buyers[msg.sender].liquidity));
        delete buyers[msg.sender];
    }

    function updateRelay(TronBlockHeader[18] calldata newHeaders, Order[] calldata newOrders, bytes calldata proof)
        public
    {
        _fulfillOrders(pendingOrders, latestRelayer);

        pendingHeaders[0] = pendingHeaders[18];
        for (uint256 i = 0; i < 18; i++) {
            pendingHeaders[i + 1] = newHeaders[i];
        }
        pendingOrders = newOrders;

        require(params().verifier.verify(pendingHeaders, pendingOrders, proof));
    }

    function reorgRelay(TronBlockHeader[18][2] calldata cycles, Order[][2] calldata orders, bytes[2] calldata proofs)
        external
    {
        TronBlockHeader[18] memory cycle = cycles[0];

        for (uint256 i = 1; i < 18; i++) {
            pendingHeaders[i + 1] = cycle[i];
        }
        require(params().verifier.verify(pendingHeaders, orders[0], proofs[0]));

        updateRelay(cycles[1], orders[1], proofs[1]);
    }

    function isEligibleForPaymaster(address _address) public view returns (bool) {
        return userHealth[_address] > 0;
    }

    modifier onlyBootloader() {
        require(msg.sender == BOOTLOADER_FORMAL_ADDRESS);
        _;
    }

    function validateAndPayForPaymasterTransaction(bytes32, bytes32, Transaction calldata _transaction)
        external
        payable
        onlyBootloader
        returns (bytes4 magic, bytes memory x)
    {
        x;

        magic = PAYMASTER_VALIDATION_SUCCESS_MAGIC;

        address from = address(uint160(_transaction.from));
        if (_transaction.paymasterInput.length > 4) {
            (bytes32 hash, uint8 v, bytes32 r, bytes32 s) =
                abi.decode(_transaction.paymasterInput[4:], (bytes32, uint8, bytes32, bytes32));

            assert(ecrecover(hash, v, r, s) == params().paymasterAuthority);
            assert(address(uint160(uint256(hash))) == from);
            assert(uint256(hash) >> 160 == authorityNonce);

            userHealth[from]++;
            authorityNonce++;
        }

        require(_transaction.to == uint256(uint160(address(this))));
        require(isEligibleForPaymaster(from), "lh");
        userHealth[from]--;

        (bool success,) =
            payable(BOOTLOADER_FORMAL_ADDRESS).call{value: _transaction.gasLimit * _transaction.maxFeePerGas}("");
        require(success);
    }

    function postTransaction(bytes calldata, Transaction calldata, bytes32, bytes32, ExecutionResult, uint256)
        external
        payable
        override
        onlyBootloader
    {}
}
