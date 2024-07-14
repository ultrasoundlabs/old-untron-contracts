// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/ITransferrer.sol";
import "./interfaces/external/V3SpokePoolInterface.sol";

contract AcrossTransferrer is ITransferrer {
    V3SpokePoolInterface immutable spokePool;
    IERC20 immutable usdc;
    address immutable untron;

    constructor(V3SpokePoolInterface _spokePool, IERC20 _usdc, address _untron) {
        spokePool = _spokePool;
        usdc = _usdc;
        untron = _untron;
    }

    function processTransfer(uint256 amount, bytes memory data) external {
        require(msg.sender == untron);

        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        (uint256 toChainId, address recipient, uint256 fee) = abi.decode(data, (uint256, address, uint256));

        if (toChainId == chainId) {
            require(usdc.transfer(recipient, amount));
        } else {
            spokePool.depositV3(
                address(this),
                recipient,
                address(usdc),
                address(0),
                amount,
                amount - fee,
                chainId,
                address(0),
                uint32(block.timestamp - 36),
                uint32(block.timestamp + 1800),
                0,
                ""
            );
        }
    }
}
