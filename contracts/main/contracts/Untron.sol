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
import "./interfaces/IStateProver.sol";
import "./MerkleProof.sol";

contract Untron is Ownable, IPaymaster, IUntron {
    ITronVerifier internal verifier;
    IERC20 immutable usdc;

    uint internal revealFee;
    uint internal minOrderSize;

    address internal paymasterAuthority;
    mapping(bytes32 => bool) usedApprovals;

    constructor(IERC20 _usdc) {
        usdc = _usdc;
    }
    
    mapping(bytes32 => bytes32) public oldRoots; // blockId -> txRoot
    mapping(bytes32 => bool) internal fulfilled; // tron tx hash -> bool (nullifier)
    TronBlockHeader[19] internal newHeaders;
    address internal latestRelayer;

    mapping(bytes32 => uint) public activeOrders; // order hash -> timestamp until
    mapping(address => Buyer) internal buyers; // zksync address -> buyer
    mapping(address => address) internal tronAddresses; // tron address -> zksync address (buyer)

    // https://github.com/zkSync-Community-Hub/zksync-developers/discussions/621
    mapping(address => int) internal userHealth; // +1 for each fulfilled order, -1 for each unfulfilled

    mapping(IUntronSender => Fulfillment[]) internal intents;
    mapping(uint => IUntronSender) public crossChainSenders;

    function setVerifier(ITronVerifier _verifier) external onlyOwner {
        verifier = _verifier;
    }

    function setRevealFee(uint _revealFee) external onlyOwner {
        revealFee = _revealFee;
    }

    function setMinOrderSize(uint _minOrderSize) external onlyOwner {
        minOrderSize = _minOrderSize;
    }

    function setPaymasterAuthority(address _paymasterAuthority) external onlyOwner {
        paymasterAuthority = _paymasterAuthority;
    }

    function setSender(uint chain, IUntronSender _crossChainSender) external onlyOwner {
        crossChainSenders[chain] = _crossChainSender;
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
            revealFee: revealFee,

            recipient: recipient,
            destinationChain: destinationChain,
            bridge: crossChainSenders[destinationChain],
            bridgeData: bridgeData
        });
        activeOrders[keccak256(abi.encode(order))] = block.timestamp + 600; // 10 mins

        emit OrderCreated(order);
    }

    function _verifyTronTx(bytes memory, uint, address) internal pure returns (bool) {
        // TODO
        return true;
    }

    function _queueOrder(Fulfillment memory fulfillment) internal {

        require(!fulfilled[fulfillment.txHash], "ff");
        Order memory order = fulfillment.order;

        intents[fulfillment.order.bridge].push(fulfillment);

        uint amount = fulfillment.usdtAmount * 1e18 / order.rate / 1e18 - order.revealFee;
        buyers[order.buyer].liquidity += order.amount - amount;
        fulfilled[fulfillment.txHash] = true;
        userHealth[order.from] += 2;
        
        emit OrderFulfilled(fulfillment);
    }

    // should only be used when the order was skipped by the relayer
    function queueOrder(Order calldata _order, uint256 usdtAmount, bytes calldata transaction, bytes32 blockId, bytes32[] calldata proof) external {
        Order memory order = _order;

        // this can be ZK proven (see updateRelay())
        bytes32 txHash = sha256(transaction);
        bytes32 txRoot = oldRoots[blockId];
        require(MerkleProof.verify(proof, txRoot, txHash), "ne");

        uint orderTimeout = activeOrders[keccak256(abi.encode(order))];
        require(orderTimeout <= block.timestamp && orderTimeout != 0, "io");

        require(_verifyTronTx(transaction, usdtAmount, order.tronAddress), "it");

        Fulfillment memory fulfillment = Fulfillment({
            order: order,
            usdtAmount: usdtAmount,
            txHash: txHash
        });
        _queueOrder(fulfillment);
        usdc.transfer(msg.sender, order.revealFee);
    }

    function updateRelay(TronBlockHeader[18] calldata _newHeaders, bytes calldata proof) public {
        uint totalRelayerFee = 0;
        for (uint i = 1; i < 18; i++) {
            TronBlockHeader memory header = newHeaders[i];
            for (uint x = 0; x < header.fulfillments.length; i++) {
                Fulfillment memory fulfillment = header.fulfillments[x];
                _queueOrder(fulfillment);
                totalRelayerFee += fulfillment.order.revealFee;
            }
            oldRoots[header.blockId] = header.txRoot;
        }

        usdc.transfer(latestRelayer, totalRelayerFee);

        newHeaders[0] = newHeaders[18];
        for (uint i = 0; i < 18; i++) {
            newHeaders[i+1] = _newHeaders[i];
        }
        assert(verifier.verify(newHeaders, proof));
    }

    function reorgRelay(TronBlockHeader[18][2] calldata cycles, bytes[2] calldata proofs) external {
        TronBlockHeader[18] memory cycle = cycles[0];

        for (uint i = 1; i < 18; i++) {
            newHeaders[i+1] = cycle[i];
        }
        assert(verifier.verify(newHeaders, proofs[0]));

        updateRelay(cycles[1], proofs[1]);
    }

    function claimIntents(IUntronSender chain, uint limit) external {
        Fulfillment[] memory transfers = new Fulfillment[](limit);
        for (uint i = 0; i < (limit | intents[chain].length); i++) {
            transfers[i] = intents[chain][i];
        }
        chain.crossChainSend(transfers);
    }

    function isEligibleForPaymaster(address _address) public view returns (bool) {
        return userHealth[_address] >= 0;
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

            assert(ecrecover(hash, v, r, s) == paymasterAuthority);
            assert(address(uint160(uint256(hash))) == from);

            userHealth[from]++;
            usedApprovals[hash] = true;
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
