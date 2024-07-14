// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/ITransferrer.sol";
import "./MerkleProof.sol";

interface ITronVerifier {
    function verifyCycle(Untron.TronBlockHeader[19] calldata, Untron.Deposit[] calldata, bytes calldata)
        external
        returns (bool);
}

contract Untron is Ownable {
    // The full implementation of the Untron.finance system

    // USDC is defined as USDC.e on ZKsync Era Network
    // USDT is defined as USDT on Tron Network

    struct Params {
        ITronVerifier verifier;
        ITransferrer transferrer;
        //
        address ownerBonder;
        uint256 minOrderSize; // USDT
        uint256 minOrderBond; // ETH
        uint256 orderExpiryFine; // USDC
        uint256 minRelayerStake; // ETH
        uint256 missedDepositSlash; // ETH
        uint256 closeFee; // USDC
    }

    Params internal _params;

    function params() public view returns (Params memory) {
        return _params;
    }

    function params(Params calldata __params) external onlyOwner {
        _params = __params;
    }

    IERC20 constant usdc = IERC20(0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4);

    constructor() Ownable(msg.sender) {}

    struct Buyer {
        uint256 liquidity; // USDC
        uint256 rate; // USDC per 1 USDT
        uint256 minDepositSize; // USDT
        //
        address[16] tronAddresses;
        mapping(address => bytes32) orders;
        bool active;
    }

    struct Order {
        // creation metadata
        address creator;
        address bonder;
        // order details
        address buyer;
        uint256 orderSize; // USDT
        uint256 rate; // USDC per 1 USDT
        uint256 minDepositSize;
        address tronAddress;
        uint256 deadline; // Tron block number
        // transfer details
        ITransferrer transferrer;
        bytes transferData;
        // order status
        uint256 deposited; // USDT
        bool closed;
    }

    struct TronBlockHeader {
        bytes32 blockId;
        bytes32 txRoot;
    }

    struct Deposit {
        bytes32 orderId;
        bytes32 txHash;
        address to;
        uint256 amount;
    }

    // P2P-related elements
    mapping(address => Buyer) public buyers;
    mapping(bytes32 => Order) public orders;
    mapping(address => address) public tronAddresses;

    // Relay-related elements
    TronBlockHeader[19] internal pendingHeaders;
    Deposit[] internal pendingDeposits;
    mapping(bytes32 => bool) internal seenDeposit;
    address latestRelayer;

    // Bonding-related elements
    mapping(address => uint256) public relayerStakes;
    mapping(address => uint256) public bonders;
    mapping(address => bytes32) public bonderOrders;

    // Buyer-related functions

    function setBuyer(uint256 liquidity, uint256 rate, uint256 minDepositSize) external {
        require(usdc.transferFrom(msg.sender, address(this), liquidity));
        buyers[msg.sender].liquidity += liquidity;
        buyers[msg.sender].rate = rate;
        buyers[msg.sender].minDepositSize = minDepositSize;
        buyers[msg.sender].active = true;
    }

    function setTronAddresses(address[16] calldata _tronAddresses) external {
        buyers[msg.sender].tronAddresses = _tronAddresses;
    }

    function closeBuyer() external {
        require(usdc.transfer(msg.sender, buyers[msg.sender].liquidity));
        buyers[msg.sender].active = false;
    }

    // Order-related functions

    function createOrder(
        address buyer,
        uint256 tronAddressIndex,
        uint256 orderSize,
        ITransferrer transferrer,
        bytes calldata transferData,
        bytes calldata bonderSignature
    ) external returns (bytes32 orderHash) {
        (bytes32 h, uint8 v, bytes32 r, bytes32 s) = abi.decode(bonderSignature, (bytes32, uint8, bytes32, bytes32));
        require(h == keccak256(abi.encode(msg.sender, buyer, tronAddressIndex, orderSize, transferData)));
        address bonder = ecrecover(h, v, r, s);
        require(bonders[bonder] >= params().minOrderBond);
        require(bonderOrders[bonder] == bytes32(0));

        address tronAddress = buyers[buyer].tronAddresses[tronAddressIndex];
        require(tronAddress != address(0));
        require(buyers[buyer].orders[tronAddress] == bytes32(0));

        uint256 rate = buyers[buyer].rate;

        Order memory order = Order({
            creator: msg.sender,
            bonder: bonder,
            buyer: buyer,
            orderSize: orderSize,
            rate: rate,
            minDepositSize: buyers[buyer].minDepositSize,
            tronAddress: tronAddress,
            deadline: getBlockNumber(pendingHeaders[0].blockId) + 100, // 100 blocks @ 5 min
            transferrer: transferrer,
            transferData: transferData,
            deposited: 0,
            closed: false
        });
        orderHash = keccak256(abi.encode(order));

        buyers[buyer].orders[tronAddress] = orderHash;
        orders[orderHash] = order;
        if (bonder != params().ownerBonder) {
            // owner bonder can bond unlimited number of orders at one time
            bonderOrders[bonder] = orderHash;
        }

        buyers[buyer].liquidity -= usdtToUsdc(orderSize, rate);
    }

    function _closeOrder(bytes32 orderId, uint256 fee) internal {
        require(!orders[orderId].closed);

        orders[orderId].closed = true;
        address buyer = orders[orderId].buyer;
        buyers[buyer].orders[orders[orderId].tronAddress] = bytes32(0);
        bonderOrders[orders[orderId].bonder] = bytes32(0);

        uint256 rate = orders[orderId].rate;
        uint256 amount = usdtToUsdc(orders[orderId].deposited, rate);

        orders[orderId].transferrer.processTransfer(amount - fee, orders[orderId].transferData);
        buyers[buyer].liquidity += usdtToUsdc(orders[orderId].orderSize, rate) - amount;
    }

    function closeOrder(bytes32 orderId) external {
        require(getBlockNumber(pendingHeaders[0].blockId) > orders[orderId].deadline);

        uint256 fee = params().closeFee;
        _closeOrder(orderId, fee);
        require(usdc.transfer(msg.sender, fee));
    }

    // Deposit-related functions

    function _processDeposits(Deposit[] memory deposits, address revealer) internal {
        uint256 totalClosed;
        uint256 fee = params().closeFee;

        for (uint256 i = 0; i < deposits.length; i++) {
            Deposit memory deposit = deposits[i];
            orders[deposit.orderId].deposited += deposit.amount;

            if (orders[deposit.orderId].deposited >= orders[deposit.orderId].orderSize) {
                _closeOrder(deposit.orderId, fee);
                totalClosed++;
            }
        }

        require(usdc.transfer(revealer, fee * totalClosed));
    }

    function _queueDeposit(Deposit memory deposit) internal {
        pendingDeposits.push(deposit);
        seenDeposit[keccak256(abi.encode(deposit))] = true;
    }

    function queueDeposit(uint256 headerIndex, Deposit calldata deposit, bytes calldata proof) external {
        require(verifyTx(pendingHeaders[headerIndex].txRoot, deposit, proof));

        _queueDeposit(deposit);

        uint256 slash = params().missedDepositSlash;
        uint256 relayerStake = relayerStakes[latestRelayer];
        (bool s,) = payable(msg.sender).call{value: relayerStake - (relayerStake - slash)}("");
        require(s);
        relayerStakes[latestRelayer] -= slash;
    }

    // Relay-related functions

    modifier onlyRelayer() {
        require(relayerStakes[msg.sender] >= params().missedDepositSlash);
        _;
    }

    function updateRelay(TronBlockHeader[18] calldata newHeaders, Deposit[] calldata newDeposits, bytes calldata proof)
        public
        onlyRelayer
    {
        _processDeposits(pendingDeposits, msg.sender);

        pendingDeposits = newDeposits;
        pendingHeaders[0] = pendingHeaders[18];
        for (uint256 i = 0; i < 18; i++) {
            pendingHeaders[i + 1] = newHeaders[i];
        }

        require(params().verifier.verifyCycle(pendingHeaders, pendingDeposits, proof));
    }

    function reorgRelay(
        TronBlockHeader[18][2] calldata cycles,
        Deposit[][2] calldata _deposits,
        bytes[2] calldata proofs
    ) external onlyRelayer {
        pendingDeposits = _deposits[0];
        for (uint256 i = 0; i < 18; i++) {
            pendingHeaders[i + 1] = cycles[0][i];
        }

        require(params().verifier.verifyCycle(pendingHeaders, pendingDeposits, proofs[0]));

        updateRelay(cycles[1], _deposits[1], proofs[1]);
    }

    function verifyTx(bytes32 txRoot, Deposit memory, bytes memory proof) internal pure returns (bool success) {
        (bytes memory tronTx, bytes32[] memory merkleProof) = abi.decode(proof, (bytes, bytes32[]));

        bytes32 txHash = sha256(tronTx);
        require(MerkleProof.verify(merkleProof, txRoot, txHash));

        // TODO: verify transaction body

        success = true;
    }

    function supplyRelayer(address relayer) external payable {
        relayerStakes[relayer] += msg.value;
    }

    function closeRelayer() external {
        (bool s,) = payable(msg.sender).call{value: relayerStakes[msg.sender]}("");
        require(s);

        relayerStakes[msg.sender] = 0;
    }

    // Tools

    function usdtToUsdc(uint256 usdtAmount, uint256 rate) internal pure returns (uint256) {
        return usdtAmount * rate / 1e6;
    }

    function getBlockNumber(bytes32 blockId) internal pure returns (uint256) {
        return uint256(blockId) >> 192;
    }
}
