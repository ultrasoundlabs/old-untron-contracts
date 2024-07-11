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
        usdc.approve(address(_spokePool), type(uint256).max);
    }

    function crossChainSend(SendRequest[] calldata requests) external {
        for (uint256 i = 0; i < requests.length; i++) {
            SendRequest calldata request = requests[i];

            address to = address(uint160(uint256(request.to)));

            if (request.chain == 324) {
                usdc.transfer(to, request.amount);
            } else {
                uint256 totalRelayFee = abi.decode(request.data, (uint256));
                spokePool.depositV3(
                    address(this),
                    to,
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
}
