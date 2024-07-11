//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {IPaymaster, ExecutionResult, PAYMASTER_VALIDATION_SUCCESS_MAGIC} from "@matterlabs/zksync-contracts/l2/system-contracts/interfaces/IPaymaster.sol";
import {IPaymasterFlow} from "@matterlabs/zksync-contracts/l2/system-contracts/interfaces/IPaymasterFlow.sol";
import {TransactionHelper, Transaction} from "@matterlabs/zksync-contracts/l2/system-contracts/libraries/TransactionHelper.sol";
import "@matterlabs/zksync-contracts/l2/system-contracts/Constants.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IUntron.sol";
import "./interfaces/IUntronSender.sol";
import "./MerkleProof.sol";

contract Untron is Ownable, IPaymaster, IUntron {
    IERC20 usdc = IERC20(0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4); // USDC.e
    
    uint public authorityNonce;
  
    mapping(bytes32 => bytes32) public oldRoots; // blockId -> txRoot
    mapping(bytes32 => bool) internal fulfilled; // tron tx hash -> bool (nullifier)
    TronBlockHeader[19] internal newHeaders;
    address internal latestRelayer;

    mapping(bytes32 => uint) public activeOrders; // order hash -> timestamp until
    mapping(address => Buyer) internal buyers; // zksync address -> buyer
    mapping(address => address) internal tronAddresses; // tron address -> zksync address (buyer)

    // https://github.com/zkSync-Community-Hub/zksync-developers/discussions/621
    mapping(address => int) internal userHealth; // +1 for each fulfilled order, -1 for each unfulfilled

    Params internal _params;
    function params() public view returns (Params memory) {
        return _params;
    }
    function params(Params calldata __params) external onlyOwner {
        _params = __params;
    }

    function createOrder(address buyer, uint amount, bytes32 recipient, uint destinationChain, bytes memory bridgeData) external {
        require(buyers[buyer].active, "db");
        require(amount <= buyers[buyer].liquidity, "il");
        buyers[buyer].liquidity -= amount;

        Order memory order = Order({
            from: msg.sender,

            buyer: buyer,
            tronAddress: buyers[buyer].tronAddress,
            amount: amount,
            rate: buyers[buyer].rate,
            revealFee: params().revealFee,

            recipient: recipient,
            destinationChain: destinationChain,
            bridgeData: bridgeData
        });
        activeOrders[keccak256(abi.encode(order))] = block.timestamp + 600; // 10 mins

        emit OrderCreated(order);
    }

    function _verifyTronTx(bytes memory, uint, address) internal pure returns (bool) {
        // TODO
        return true;
    }

    function _fulfillOrders(Fulfillment[] memory fulfillments, address revealer) internal {

        IUntronSender.SendRequest[] memory requests = new IUntronSender.SendRequest[](fulfillments.length);
        uint totalAmount;
        uint totalRevealerFee;

        for (uint i = 0; i < fulfillments.length; i++) {
            Fulfillment memory fulfillment = fulfillments[i];
            Order memory order = fulfillment.order;

            uint orderTimeout = activeOrders[keccak256(abi.encode(order))];
            require(orderTimeout <= block.timestamp && orderTimeout != 0, "io");

            uint amount = fulfillment.usdtAmount * 1e18 / order.rate / 1e18 - order.revealFee;
            requests[0] = IUntronSender.SendRequest({
                to: order.recipient,
                amount: amount,
                chain: order.destinationChain,
                data: order.bridgeData
            });

            buyers[order.buyer].liquidity += order.amount - amount;
            totalAmount += amount;
            totalRevealerFee += order.revealFee;
            userHealth[order.from]++;
        }

        assert(usdc.transfer(address(params().crossChainSender), totalAmount));
        assert(usdc.transfer(revealer, totalRevealerFee));
        params().crossChainSender.crossChainSend(requests);
    }

    // should only be used when the order was skipped by the relayer
    function fulfillOrder(Order calldata _order, uint256 usdtAmount, bytes calldata transaction, bytes32 blockId, bytes32[] calldata proof) external {
        Order memory order = _order;

        // this can be ZK proven (see updateRelay())
        bytes32 txHash = sha256(transaction);
        bytes32 txRoot = oldRoots[blockId];
        require(MerkleProof.verify(proof, txRoot, txHash), "ne");

        require(_verifyTronTx(transaction, usdtAmount, order.tronAddress), "it");

        Fulfillment memory fulfillment = Fulfillment({
            order: order,
            usdtAmount: usdtAmount,
            txHash: txHash
        });
        Fulfillment[] memory fulfillments = new Fulfillment[](1);
        fulfillments[0] = fulfillment;
        _fulfillOrders(fulfillments, msg.sender);
    }

    function setBuyer(address tronAddress, uint liquidity, uint rate) external {
        assert(usdc.transferFrom(msg.sender, address(this), liquidity));
        buyers[msg.sender].tronAddress = tronAddress;
        buyers[msg.sender].liquidity += liquidity;
        buyers[msg.sender].rate = rate;
        buyers[msg.sender].active = true;
    }

    function closeBuyer() external {
        assert(usdc.transfer(msg.sender, buyers[msg.sender].liquidity));
        delete buyers[msg.sender];
    }

    function updateRelay(TronBlockHeader[18] calldata _newHeaders, bytes calldata proof) public {
        Fulfillment[] memory fulfillments = new Fulfillment[](params().maxTransfersPerCycle);
        uint y = 0;

        for (uint i = 1; i < 18; i++) {
            TronBlockHeader memory header = newHeaders[i];
            for (uint x = 0; x < header.fulfillments.length; i++) {
                Fulfillment memory fulfillment = header.fulfillments[x];
                fulfillments[y] = fulfillment;
                y++;
            }
            oldRoots[header.blockId] = header.txRoot;
        }

        _fulfillOrders(fulfillments, latestRelayer);

        newHeaders[0] = newHeaders[18];
        for (uint i = 0; i < 18; i++) {
            newHeaders[i+1] = _newHeaders[i];
        }
        assert(params().verifier.verify(newHeaders, proof));
    }

    function reorgRelay(TronBlockHeader[18][2] calldata cycles, bytes[2] calldata proofs) external {
        TronBlockHeader[18] memory cycle = cycles[0];

        for (uint i = 1; i < 18; i++) {
            newHeaders[i+1] = cycle[i];
        }
        assert(params().verifier.verify(newHeaders, proofs[0]));

        updateRelay(cycles[1], proofs[1]);
    }

    function isEligibleForPaymaster(address _address) public view returns (bool) {
        return userHealth[_address] > 0;
    }

    modifier onlyBootloader() {
        require(
            msg.sender == BOOTLOADER_FORMAL_ADDRESS
        );
        _;
    }

    function validateAndPayForPaymasterTransaction(
        bytes32,
        bytes32,
        Transaction calldata _transaction
    )
        external
        payable
        onlyBootloader
        returns (bytes4 magic, bytes memory x)
    {
        x;

        magic = PAYMASTER_VALIDATION_SUCCESS_MAGIC;

        address from = address(uint160(_transaction.from));
        if(_transaction.paymasterInput.length > 4) {
            (bytes32 hash, uint8 v, bytes32 r, bytes32 s) = abi.decode(_transaction.paymasterInput[4:], (bytes32,uint8,bytes32,bytes32));

            assert(ecrecover(hash, v, r, s) == params().paymasterAuthority);
            assert(address(uint160(uint256(hash))) == from);
            assert(uint256(hash) >> 160 == authorityNonce);

            userHealth[from]++;
            authorityNonce++;
        }

        require(_transaction.to == uint256(uint160(address(this))));
        require(isEligibleForPaymaster(from), "lh");
        userHealth[from]--;

        (bool success, ) = payable(BOOTLOADER_FORMAL_ADDRESS).call{
            value: _transaction.gasLimit * _transaction.maxFeePerGas
        }("");
        require(success);
    }

    function postTransaction(
        bytes calldata,
        Transaction calldata,
        bytes32,
        bytes32,
        ExecutionResult,
        uint256
    ) external payable override onlyBootloader {
    }
}
