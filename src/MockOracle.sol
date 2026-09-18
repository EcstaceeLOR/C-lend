// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "./CollateralizedLending.sol";

/// @notice Test oracle returning USD prices in 1e18 precision.
contract MockOracle is IPriceOracle {
    struct PriceData {
        uint256 price;
        uint256 updatedAt;
    }

    mapping(address asset => PriceData) public prices;

    event PriceUpdated(address indexed asset, uint256 price, uint256 updatedAt);

    function setPrice(address asset, uint256 price) external {
        prices[asset] = PriceData({price: price, updatedAt: block.timestamp});
        emit PriceUpdated(asset, price, block.timestamp);
    }

    function setPriceWithTimestamp(address asset, uint256 price, uint256 updatedAt) external {
        prices[asset] = PriceData({price: price, updatedAt: updatedAt});
        emit PriceUpdated(asset, price, updatedAt);
    }

    function clearPrice(address asset) external {
        delete prices[asset];
        emit PriceUpdated(asset, 0, 0);
    }

    function getPrice(address asset) external view returns (uint256 price, uint256 updatedAt) {
        PriceData memory data = prices[asset];
        return (data.price, data.updatedAt);
    }
}
