// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {OrderIntent, Side} from "lib/ctf-exchange/src/exchange/libraries/OrderStructs.sol";
import {NegRiskOperator} from "src/NegRiskOperator.sol";
import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";
import {IRevNegRiskAdapter} from "src/interfaces/IRevNegRiskAdapter.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {ICTFExchange} from "src/interfaces/ICTFExchange.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @title ICrossMatchingAdapter
/// @notice Interface for CrossMatchingAdapter contract
interface ICrossMatchingAdapter {
    // Errors
    error UnsupportedToken();      // order.tokenId not recognized as YES (buy) or NO (sell)
    error SideNotSupported();      // only BUY-YES and SELL-NO supported in this adapter
    error PriceOutOfRange();       // price must be ≤ 1
    error BootstrapShortfall();    // not enough buyer USDC to bootstrap pivot split
    error SupplyInvariant();       // insufficient YES supply computed
    error NotSelfFinancing();      // net WCOL minted (!= 0) after operations
    error InvalidFillAmount();     // fill amount is invalid (zero or exceeds order quantity)
    error InvalidCombinedPrice();  // combined price of all orders must equal total shares
    error InsufficientUSDCBalance(); // insufficient USDC balance for WCOL minting
    error InvalidUSDCBalance(); // invalid USDC balance for WCOL minting
    error MissingUnresolvedQuestion(); // some unresolved questions are missing from orders
    error SingleOrderCountMismatch(); // provided single order count does not match detected orders
    error MakerFillLengthMismatch(); // taker fill lengths do not match maker orders length
    error InvalidSingleOrderShape(); // single maker order must have exactly one nested order and fill amount
    error NoConvertiblePositions();
    error MarketNotPrepared();

    // Events
    event OrderFilled(bytes32 indexed orderHash, address indexed maker, address indexed taker, uint256 makerAssetId, uint256 takerAssetId, uint256 makerAmountFilled, uint256 takerAmountFilled, uint256 fee);
    event OrdersMatched(bytes32 indexed takerOrderHash, address indexed takerOrderMaker, uint256 makerAssetId, uint256 takerAssetId, uint256 makerAmountFilled, uint256 takerAmountFilled);

    // Structs
    struct MakerOrder {
        OrderIntent[] orders;
        OrderType orderType;
        uint256[] makerFillAmounts;
    }

    // Enums
    enum OrderType {
        SINGLE,
        CROSS_MATCH
    }

    // Public State Variables
    function negOperator() external view returns (NegRiskOperator);
    function neg() external view returns (INegRiskAdapter);
    function revNeg() external view returns (IRevNegRiskAdapter);
    function ctf() external view returns (IConditionalTokens);
    function ctfExchange() external view returns (ICTFExchange);
    function wcol() external view returns (WrappedCollateral);
    function usdc() external view returns (IERC20);

    // Public Functions
    function hybridMatchOrders(
        bytes32 marketId,
        OrderIntent calldata takerOrder,
        MakerOrder[] calldata makerOrders,
        uint256[] calldata takerFillAmounts,
        uint8 singleOrderCount
    ) external;

    function crossMatchShortOrders(
        bytes32 marketId,
        OrderIntent calldata takerOrder,
        OrderIntent[] calldata multiOrderMaker,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts
    ) external;

    function crossMatchLongOrders(
        bytes32 marketId,
        OrderIntent calldata takerOrder,
        OrderIntent[] calldata multiOrderMaker,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts
    ) external;

    function getCollateral() external view returns (address);
    function getCtf() external view returns (address);
}

