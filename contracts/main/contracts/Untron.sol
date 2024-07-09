//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {IPaymaster, ExecutionResult, PAYMASTER_VALIDATION_SUCCESS_MAGIC} from "@matterlabs/zksync-contracts/l2/system-contracts/interfaces/IPaymaster.sol";
import {IPaymasterFlow} from "@matterlabs/zksync-contracts/l2/system-contracts/interfaces/IPaymasterFlow.sol";
import {TransactionHelper, Transaction} from "@matterlabs/zksync-contracts/l2/system-contracts/libraries/TransactionHelper.sol";
import "@matterlabs/zksync-contracts/l2/system-contracts/Constants.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MerkleProof.sol";

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
        address tronAddress;
        uint amount;
        uint rate;

        address buyer;
    }
    event OrderCreated(Order order);
    event OrderFulfilled(Order order);

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

contract Untron is Ownable, IPaymaster, IUntron {
    ITronVerifier internal verifier;
    IERC20 immutable usdc;

    uint internal revealFee;
    uint internal minOrderSize;

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

    function setVerifier(ITronVerifier _verifier) external onlyOwner {
        verifier = _verifier;
    }

    function setRevealFee(uint _revealFee) external onlyOwner {
        revealFee = _revealFee;
    }

    function setMinOrderSize(uint _minOrderSize) external onlyOwner {
        minOrderSize = _minOrderSize;
    }

    function createOrder(address buyer, uint amount) external {
        require(buyers[buyer].active, "db");
        require(amount <= buyers[buyer].liquidity, "il");
        buyers[buyer].liquidity -= amount;

        Order memory order = Order({
            from: msg.sender,
            tronAddress: buyers[buyer].tronAddress,
            amount: amount,
            rate: buyers[buyer].rate,

            buyer: buyer
        });
        activeOrders[keccak256(abi.encode(order))] = block.timestamp + 600; // 10 mins

        emit OrderCreated(order);
    }

    function _verifyTronTx(bytes memory _transaction, uint _usdtAmount, address _recipient) internal pure returns (bool) {
        // TODO
        return true;
    }

    function _fulfillOrder(Fulfillment memory fulfillment, address revealer) internal {

        require(!fulfilled[fulfillment.txHash], "ff");
        Order memory order = fulfillment.order;

        uint amount = fulfillment.usdtAmount * 1e18 / order.rate;
        require(usdc.transfer(order.from, (amount < order.amount ? amount : order.amount) - revealFee), "if");
        require(usdc.transfer(revealer, revealFee), "if");

        buyers[order.buyer].liquidity += order.amount - amount;
        fulfilled[fulfillment.txHash] = true;
        userHealth[order.from] += 2;
        emit OrderFulfilled(order);
    }

    // should only be used when the order was skipped by the relayer
    function fulfillOrder(Order calldata _order, uint256 usdtAmount, bytes calldata transaction, bytes32 blockId, bytes32[] calldata proof) external {
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
        _fulfillOrder(fulfillment, msg.sender);
    }

    function updateRelay(TronBlockHeader[18] calldata _newHeaders, bytes calldata proof) public {
        for (uint i = 1; i < 18; i++) {
            TronBlockHeader memory header = newHeaders[i];
            for (uint x = 0; x < header.fulfillments.length; i++) {
                _fulfillOrder(header.fulfillments[x], latestRelayer);
            }
            oldRoots[header.blockId] = header.txRoot;
        }

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
        returns (bytes4 magic, bytes memory)
    {

        magic = PAYMASTER_VALIDATION_SUCCESS_MAGIC;
        require(_transaction.paymasterInput.length >= 4);

        require(_transaction.to == uint256(uint160(address(this))));
        require(isEligibleForPaymaster(address(uint160(_transaction.from))), "lh");
        userHealth[address(uint160(_transaction.from))]--;

        bytes4 paymasterInputSelector = bytes4(
            _transaction.paymasterInput[0:4]
        );
        if (paymasterInputSelector == IPaymasterFlow.general.selector) {
            uint256 requiredETH = _transaction.gasLimit *
                _transaction.maxFeePerGas;

            (bool success, ) = payable(BOOTLOADER_FORMAL_ADDRESS).call{
                value: requiredETH
            }("");
            require(success);
        } else {
            revert();
        }
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
