//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IUntronSender.sol";
import "./interfaces/external/V3SpokePoolInterface.sol";

contract AcrossSender is IUntronSender {
    
    IERC20 immutable usdc;
    address immutable untron;
    V3SpokePoolInterface immutable spokePool;

    constructor(IERC20 _usdc, address _untron, V3SpokePoolInterface _spokePool) {
        usdc = _usdc;
        untron = _untron;
        spokePool = _spokePool;
        usdc.approve(address(_spokePool), type(uint).max);
    }

    function crossChainSend(SendRequest[] calldata requests) external {
        for (uint i = 0; i < requests.length; i++) {
            SendRequest calldata request = requests[i];

            uint totalRelayFee = abi.decode(request.data, (uint));
            spokePool.depositV3(
                address(this),
                address(uint160(uint256(request.to))),
                address(usdc),
                address(0),
                request.amount,
                request.amount - totalRelayFee,
                request.chain,
                address(0),
                uint32(block.timestamp - 36),
                uint32(block.timestamp + 1800),
                0,
                ""
            );
        }
    }
}