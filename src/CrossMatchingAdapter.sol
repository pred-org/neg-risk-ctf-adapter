// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {ERC1155TokenReceiver} from "lib/solmate/src/tokens/ERC1155.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {INegRiskAdapter} from "./interfaces/INegRiskAdapter.sol";
import {NegRiskOperator} from "./NegRiskOperator.sol";
import {IRevNegRiskAdapter} from "./interfaces/IRevNegRiskAdapter.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {NegRiskIdLib} from "./libraries/NegRiskIdLib.sol";
import {AssetOperations} from "lib/ctf-exchange/src/exchange/mixins/AssetOperations.sol";
import {ICTFExchange} from "src/interfaces/ICTFExchange.sol";
import {Helpers} from "src/libraries/Helpers.sol";
import {CalculatorHelper} from "lib/ctf-exchange/src/exchange/libraries/CalculatorHelper.sol";
import {OrderIntent, OrderStatus, Order, Side, Intent} from "lib/ctf-exchange/src/exchange/libraries/OrderStructs.sol";
import {ITradingEE} from "lib/ctf-exchange/src/exchange/interfaces/ITrading.sol";

/// @title ICrossMatchingAdapterEE
/// @notice CrossMatchingAdapter Errors and Events
interface ICrossMatchingAdapterEE {
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
}

/*
 * Cross-matching adapter for NegRisk events.
 * - Input: ctf-exchange Order[] (with .side BUY/SELL and .tokenId)
 * - Assumptions: BUY == buy YES, SELL == sell NO (this adapter reverts otherwise)
 * - Derives:
 *    * buyer funders from order.maker (USDC source)
 *    * seller funders from order.maker (NO source)
 *    * shares from order.quantity per side
 *    * unit price (USDC/share) from order.price
 *
 * Uses pivot index 0 (no external field) via neg.getQuestionId(marketId, 0).
 */

contract CrossMatchingAdapter is ReentrancyGuard, ERC1155TokenReceiver, AssetOperations, ICrossMatchingAdapterEE {
    // constants
    uint256  constant ONE = 1e6; // fixed-point for price (6 decimals to match USDC)

    NegRiskOperator public immutable negOperator;
    INegRiskAdapter public immutable neg;
    IRevNegRiskAdapter public immutable revNeg;
    IConditionalTokens public immutable ctf;
    ICTFExchange public immutable ctfExchange;
    WrappedCollateral public immutable wcol; // wrapped USDC
    IERC20 public immutable usdc;

    constructor(NegRiskOperator negOperator_, ICTFExchange ctfExchange_, IRevNegRiskAdapter revNeg_) {
        negOperator = negOperator_;
        revNeg = revNeg_;
        neg  = INegRiskAdapter(address(negOperator_.nrAdapter()));
        ctfExchange = ctfExchange_;
        ctf  = IConditionalTokens(neg.ctf());
        wcol = WrappedCollateral(neg.wcol());
        usdc = IERC20(address(neg.col()));
        
        // Approve CTF contract to transfer WCOL on our behalf
        wcol.approve(address(ctf), type(uint256).max);
        usdc.approve(address(neg), type(uint256).max);
        usdc.approve(address(wcol), type(uint256).max);

        ctf.setApprovalForAll(address(revNeg), true);
        ctf.setApprovalForAll(address(neg), true);
    }
    
    struct Parsed {
        address maker;
        Side side;
        uint256 tokenId;
        uint256 priceQ6;    
        uint256 payAmount;    // = shares * price (for buy orders)
        uint256 counterPayAmount; // = shares * (1 - price) (for sell orders)
        bytes32 questionId;     
        uint256 feeRateBps;     // fee rate in basis points
        uint256 feeAmount;     // fee amount
        uint256 makingAmount; // making amount
        uint256 takingAmount; // taking amount
    }

    struct MakerOrder {
        OrderIntent[] orders;
        OrderType orderType;
        uint256[] makerFillAmounts;
    }

    enum OrderType {
        SINGLE,
        CROSS_MATCH
    }

    /// @notice Modifier to check that all unresolved questions are present in the orders
    /// @param marketId The market ID to check
    /// @param makerOrders Array of maker orders
    modifier allUnresolvedQuestionsPresent(
        bytes32 marketId,
        OrderIntent[] calldata makerOrders
    ) {
        validateAllUnresolvedQuestionsPresentLength(marketId, makerOrders);
        _;
    }

    function validateAllUnresolvedQuestionsPresentLength(
        bytes32 marketId,
        OrderIntent[] calldata makerOrders
    ) internal view {
        uint256 questionCount = neg.getQuestionCount(marketId);
        uint256 unresolvedQuestionCount = 0;
        for (uint256 i = 0; i < questionCount; i++) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, uint8(i));
            if (_isQuestionUnresolved(questionId)) {
                unresolvedQuestionCount++;
            }
        }
        // For unresolved questions, we need exactly one order per question
        if (makerOrders.length + 1 != unresolvedQuestionCount) {
            revert MissingUnresolvedQuestion();
        }
    }

    /// @notice Internal function to check if a question is unresolved using NegRiskOperator
    /// @param questionId The question ID to check
    /// @return true if the question is unresolved, false if resolved
    function _isQuestionUnresolved(bytes32 questionId) internal view returns (bool) {
        uint256 reportedAt_ = negOperator.reportedAt(questionId);
        
        // If not reported at all, it's unresolved
        if (reportedAt_ == 0) {
            return true;
        }
        
        // If reported, check if it's been resolved
        bytes32 conditionId = neg.getConditionId(questionId);
        return ctf.payoutDenominator(conditionId) == 0;
    }

    function hybridMatchOrders(
        bytes32 marketId,
        OrderIntent calldata takerOrder, 
        MakerOrder[] calldata makerOrders, 
        uint256[] calldata takerFillAmounts,
        uint8 singleOrderCount
    ) external nonReentrant {
        if (makerOrders.length != takerFillAmounts.length) {
            revert MakerFillLengthMismatch();
        }

        OrderIntent[] memory singleMakerOrders;
        uint256[] memory singleMakerFillAmounts;
        uint256 singleOrdersTakerAmount = 0;
        uint256 singleOrderIndex = 0;
        if (singleOrderCount > 0) {
            singleMakerOrders = new OrderIntent[](singleOrderCount);
            singleMakerFillAmounts = new uint256[](singleOrderCount);
        }
        bool isLong = takerOrder.order.intent == Intent.LONG;

        for (uint256 i = 0; i < makerOrders.length;) {
            MakerOrder calldata makerOrder = makerOrders[i];
            if (makerOrder.orderType == OrderType.SINGLE) {
                if (makerOrder.orders.length != 1 || makerOrder.makerFillAmounts.length != 1) {
                    revert InvalidSingleOrderShape();
                }
                // Collect single maker orders for batch processing
                singleMakerOrders[singleOrderIndex] = makerOrder.orders[0];
                singleMakerFillAmounts[singleOrderIndex] = makerOrder.makerFillAmounts[0];

                singleOrdersTakerAmount += takerFillAmounts[i];
                
                singleOrderIndex++;
            } else {
                // cross match - extract variables to reduce stack depth
                {
                    bytes32 mId = marketId;
                    OrderIntent calldata tOrder = takerOrder;
                    uint256 fillAmount = takerFillAmounts[i];
                    uint256[] calldata makerFills = makerOrder.makerFillAmounts;
                    OrderIntent[] calldata makerOrderList = makerOrder.orders;
                    
                    if (isLong) {
                        // LONG
                        crossMatchLongOrders(mId, tOrder, makerOrderList, fillAmount, makerFills);
                    } else {
                        // SHORT
                        crossMatchShortOrders(mId, tOrder, makerOrderList, fillAmount, makerFills);
                    }
                }
            }
            unchecked {
                ++i;
            }
        }
        
        if (singleOrderIndex != singleOrderCount) {
            revert SingleOrderCountMismatch();
        }

        // Process all single maker orders in a single batch call
        if (singleOrderCount > 0) {
            // Single call to match all orders at once
            ctfExchange.matchOrders(takerOrder, singleMakerOrders, singleOrdersTakerAmount, singleMakerFillAmounts);
        }
    }

    function crossMatchShortOrders(
        bytes32 marketId,
        OrderIntent calldata takerOrder,
        OrderIntent[] calldata multiOrderMaker,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts
    ) public allUnresolvedQuestionsPresent(marketId, multiOrderMaker) {
        uint256 fillAmount;
        Parsed[] memory parsedOrders;

        uint256 totalSellUSDC;
        uint256 totalCombinedPrice;

        {
            // Validate taker order signature and parameters
            (uint256 takingAmount, ) = ctfExchange.performOrderChecks(takerOrder, takerFillAmount);

            if (takerOrder.side == Side.BUY) {
                fillAmount = takingAmount;
            } else {
                fillAmount = takerFillAmount;
            }

            if (fillAmount == 0) {
                revert InvalidFillAmount();
            }

            parsedOrders = new Parsed[](multiOrderMaker.length + 1);
            parsedOrders[0] = _parseOrder(takerOrder, fillAmount, takerFillAmount, takingAmount);
        }
 
        totalCombinedPrice = parsedOrders[0].priceQ6;
        if (parsedOrders[0].side == Side.SELL) {
            totalSellUSDC = parsedOrders[0].counterPayAmount;
        }

        // Validate all maker orders signatures and parameters and update the order status
        for (uint256 i = 0; i < multiOrderMaker.length; ) {
            (uint256 makerTakingAmount, ) = ctfExchange.performOrderChecks(multiOrderMaker[i], makerFillAmounts[i]);
            parsedOrders[i + 1] = _parseOrder(multiOrderMaker[i], fillAmount, makerFillAmounts[i], makerTakingAmount);
            totalCombinedPrice += parsedOrders[i + 1].priceQ6;
            if (parsedOrders[i + 1].side == Side.SELL) {
                // For sell orders, amount that we need for minting
                totalSellUSDC += parsedOrders[i + 1].counterPayAmount;
            }
            unchecked {
                ++i;
            }
        }

        // The total combined price must be greater than or equal to one
        if (totalCombinedPrice < ONE) {
            revert InvalidCombinedPrice();
        }

        // Execute cross-matching logic (fees will be collected from tokens during execution)
        _executeShortCrossMatch(parsedOrders, marketId, totalSellUSDC, fillAmount);

        // Refund any leftover tokens pulled from the taker to the taker order
        _refundLeftoverTokens(takerOrder);
    }

    function _executeShortCrossMatch(
        Parsed[] memory parsedOrders,
        bytes32 marketId,
        uint256 totalSellUSDC,
        uint256 fillAmount
    ) internal {
        _collectBuyerUSDC(parsedOrders, true);

        // TotalBuyUSDC + TotalSellUSDC = (length of parsedOrders - 1) * fillAmount
        // Add the fillAmount to this amount to get the total WCOL that we need to complete the split
        wcol.mint(fillAmount + totalSellUSDC);

        for (uint256 i = 0; i < parsedOrders.length; ) {
            Parsed memory order = parsedOrders[i];
            bytes32 conditionId = neg.getConditionId(order.questionId);
            _splitPosition(conditionId, fillAmount);

            if (i != 0) { // only process maker orders
                if (order.side == Side.BUY) {
                    _distributeNoTokens(order, fillAmount);
                } else {
                    _mergeNoTokens(order, fillAmount);
                }
            }

            unchecked {
                ++i;
            }
        }

        uint256 takingAmount = _updateTakingWithSurplus(parsedOrders[0].takingAmount, parsedOrders[0].tokenId);
        if (parsedOrders[0].side == Side.BUY) {
            uint256 feeAmount = CalculatorHelper.calculateFee(parsedOrders[0].feeRateBps, takingAmount, parsedOrders[0].makingAmount, parsedOrders[0].takingAmount, parsedOrders[0].side,ctfExchange.FEE_RATIO());
            parsedOrders[0].feeAmount = feeAmount;
            _distributeNoTokens(parsedOrders[0], fillAmount);
        } else {
            uint256 feeAmount = CalculatorHelper.calculateFee(parsedOrders[0].feeRateBps, parsedOrders[0].makingAmount, parsedOrders[0].makingAmount, parsedOrders[0].takingAmount, parsedOrders[0].side,ctfExchange.FEE_RATIO());
            parsedOrders[0].feeAmount = feeAmount;
            _mergeNoTokens(parsedOrders[0], fillAmount);
        }

        // Merge all the YES tokens to get USDC
        uint8 pivotIndex = _getQuestionIndexFromPositionId(parsedOrders[0].tokenId, marketId);
        revNeg.mergeAllYesTokens(marketId, fillAmount, pivotIndex);
        // wrap the generated USDC to the adapter
        wcol.wrap(address(this), fillAmount);

        // Fees are collected during token distribution/merging

        // burn the WCOL, since we minted it earlier
        wcol.burn(fillAmount + totalSellUSDC);
    }

    function _distributeNoTokens(
        Parsed memory order,
        uint256 fillAmount
    ) internal {
        // Calculate fee for this order
        uint256 feeAmount = order.feeAmount;
        uint256 amountOut = fillAmount - feeAmount;
        
        // Collect fee in NO tokens if any
        if (feeAmount > 0) {
            ctf.safeTransferFrom(address(this), address(neg.vault()), order.tokenId, feeAmount, "");
        }
        
        // Distribute remaining NO tokens to the buyer
        if (amountOut > 0) {
            ctf.safeTransferFrom(address(this), order.maker, order.tokenId, amountOut, "");
        }
    }

    function _mergeNoTokens(
        Parsed memory order,
        uint256 fillAmount
    ) internal {
        // transfer the YES tokens to the adapter that the maker is selling
        ctf.safeTransferFrom(order.maker, address(this), order.tokenId, fillAmount, "");
        
        // Merge NO tokens with user's YES tokens to get USDC for the sellers
        // The NO tokens are already in the adapter from the split operation
        bytes32 conditionId = neg.getConditionId(order.questionId);
        _mergePositions(conditionId, fillAmount);
        
        // Calculate fee for this order
        uint256 feeAmount = (fillAmount * order.feeRateBps) / 10000;
        uint256 amountOut = order.payAmount - feeAmount;
        
        // Collect fee in USDC if any
        if (feeAmount > 0) {
            wcol.unwrap(neg.vault(), feeAmount);
        }
        
        // Transfer remaining USDC to the seller
        if (amountOut > 0) {
            wcol.unwrap(order.maker, amountOut);
        }
    }

    function crossMatchLongOrders(
        bytes32 marketId,
        OrderIntent calldata takerOrder,
        OrderIntent[] calldata multiOrderMaker,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts
    ) public allUnresolvedQuestionsPresent(marketId, multiOrderMaker) {
        uint256 fillAmount;
        Parsed[] memory parsedOrders;
        {
            // Validate taker order signature and parameters
            (uint256 takingAmount, ) = ctfExchange.performOrderChecks(takerOrder, takerFillAmount);

            if (takerOrder.side == Side.BUY) {
                fillAmount = takingAmount;
            } else {
                fillAmount = takerFillAmount;
            }

            if (fillAmount == 0) {
                revert InvalidFillAmount();
            }

            parsedOrders = new Parsed[](multiOrderMaker.length + 1);

            // Store parsed taker order; maker orders are validated in the aggregation loop below
            parsedOrders[0] = _parseOrder(takerOrder, fillAmount, takerFillAmount, takingAmount);
        }

        // Cross-matching function that handles scenarios including resolved questions:
        // 
        // Scenario 1: All buy orders (e.g., 4 users buying Yes1, Yes2, Yes3, Yes4)
        // - Collect USDC from all buyers
        // - Mint WCOL for the total USDC
        // - Split to get YES1 + NO1
        // - Convert NO1 to YES2 + YES3 + YES4
        // - Distribute all YES tokens to respective buyers
        //
        // Scenario 2: Mixed buy/sell orders (e.g., users buying Yes1/Yes3, selling No2/No4)
        // - Collect USDC from buyers
        // - Collect NO tokens from sellers
        // - Mint WCOL for USDC from buyers
        // - Split to get YES1 + NO1
        // - Convert NO1 to YES2 + YES3 + YES4
        // - Distribute YES tokens to buyers
        // - Merge YES tokens with NO tokens from sellers to get USDC
        // - Return USDC to sellers
        // - Burn remaining WCOL to maintain self-financing
        //
        // Scenario 3: Some questions resolved (e.g., Arsenal resolved, users trading on Barcelona, Chelsea, Spurs)
        // - Only process orders for active (unresolved) questions
        // - Use taker's question ID as pivot instead of hardcoded 0
        // - Handle USDC flow correctly for partial market scenarios
        
        uint256 totalSellUSDC;
        {
            totalSellUSDC = 0;
            uint256 totalCombinedPrice = 0;
            
            // Note: We can have:
            // 1. All buy orders: 4 users buying different YES tokens (Yes1, Yes2, Yes3, Yes4)
            // 2. All sell orders: users selling NO tokens (e.g., No Barca, No Arsenal, No Chelsea)
            // 3. Mixed buy/sell orders: some users buying YES, some selling NO
            
            // Parse taker order
            if (parsedOrders[0].side == Side.SELL) {
                totalSellUSDC += parsedOrders[0].payAmount;
            }
            totalCombinedPrice += parsedOrders[0].priceQ6;
            
            // Parse maker orders
            for (uint256 i = 0; i < multiOrderMaker.length; ) {
                (uint256 makerTakingAmount, ) = ctfExchange.performOrderChecks(multiOrderMaker[i], makerFillAmounts[i]);
                parsedOrders[i + 1] = _parseOrder(multiOrderMaker[i], fillAmount, makerFillAmounts[i], makerTakingAmount);
                if (parsedOrders[i + 1].side == Side.SELL) {
                    totalSellUSDC += parsedOrders[i + 1].payAmount;
                }
                totalCombinedPrice += parsedOrders[i + 1].priceQ6;
                unchecked {
                    ++i;
                }
            }
            
            // Validate that the combined price of all orders equals or exceeds 1
            if (totalCombinedPrice < ONE) {
                revert InvalidCombinedPrice();
            }
        }
        
        // Execute cross-matching logic
        _executeLongCrossMatch(parsedOrders, marketId, totalSellUSDC, fillAmount);

        // Refund any leftover tokens pulled from the taker to the taker order
        _refundLeftoverTokens(takerOrder);
    }
    
    function _executeLongCrossMatch(
        Parsed[] memory parsedOrders,
        bytes32 marketId,
        uint256 totalSellUSDC,
        uint256 fillAmount
    ) internal {
        // Collect USDC from buyers before we can use it
        _collectBuyerUSDC(parsedOrders, false);

        
        if (totalSellUSDC > 0) {
            // mint wcol here
            wcol.mint(totalSellUSDC);
        }
        
        // STEP 1: Split position for pivot question (use taker's question ID) to create YES + NO
        // Use the taker's question ID as the pivot since we know it's active (unresolved)
        uint8 pivotId = _getQuestionIndexFromPositionId(parsedOrders[0].tokenId, marketId);
        bytes32 pivotConditionId = neg.getConditionId(parsedOrders[0].questionId);
        
        // We need to split enough USDC to cover the CTF operation
        
        // Split the available WCOL on pivot question to get YES + NO
        _splitPosition(pivotConditionId, fillAmount);
        
        // STEP 2: Use convertPositions to convert NO tokens to other YES tokens
        // The indexSet for convertPositions represents which NO positions we want to convert
        // We want to convert NO tokens from the pivot question to get YES tokens for other questions
        // So we need to provide an indexSet that represents the pivot NO position
        uint256 indexSet = 1 << pivotId; // This represents NO position for the pivot question

        // Convert NO tokens to YES tokens for other questions using NegRiskAdapter's convertPositions
        // We can only convert as much as we have NO tokens from the split operation
        neg.convertPositions(marketId, indexSet, fillAmount);
        
        // STEP 3: Distribute YES tokens to buyers
        _handleBuyOrders(parsedOrders, fillAmount);
        
        // STEP 4: Handle sell orders: return USDC to sellers
        uint256 totalVaultUSDC = _handleSellOrders(parsedOrders, fillAmount);

        uint256 takingAmount = _updateTakingWithSurplus(parsedOrders[0].takingAmount, parsedOrders[0].tokenId);
        if (parsedOrders[0].side == Side.BUY) {
            uint256 feeAmount = CalculatorHelper.calculateFee(parsedOrders[0].feeRateBps, takingAmount, parsedOrders[0].makingAmount, parsedOrders[0].takingAmount, parsedOrders[0].side,ctfExchange.FEE_RATIO());
            parsedOrders[0].feeAmount = feeAmount;
            _processBuyOrder(parsedOrders[0], fillAmount);
        } else {
            uint256 feeAmount = CalculatorHelper.calculateFee(parsedOrders[0].feeRateBps, parsedOrders[0].makingAmount, parsedOrders[0].makingAmount, parsedOrders[0].takingAmount, parsedOrders[0].side,ctfExchange.FEE_RATIO());
            parsedOrders[0].feeAmount = feeAmount;
            totalVaultUSDC += _processSellOrder(parsedOrders[0], fillAmount);
        }

        // STEP 5: Burning extra WCOL to maintain self-financing
        // Since we're minting WCOL for seller returns,
        // we need to burn it back to maintain self-financing
        uint256 remainingWCOL = wcol.balanceOf(address(this));
        if (remainingWCOL > 0 && remainingWCOL >= totalVaultUSDC) {
            wcol.burn(totalVaultUSDC);
        }
    }
    
    function _handleSellOrders(
        Parsed[] memory parsedOrders,
        uint256 fillAmount
    ) internal returns (uint256) {
        uint256 totalVaultUSDC = 0;
        for (uint256 i = 1; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == Side.SELL) {
                totalVaultUSDC += _processSellOrder(parsedOrders[i], fillAmount);
            }
        }
        return totalVaultUSDC;
    }
    
    function _processSellOrder(
        Parsed memory order,
        // bytes32 marketId,
        uint256 fillAmount
    ) internal returns (uint256) {
        // For sell orders, we need to merge the user's NO tokens with the generated YES tokens
        // to get USDC, which will be used to pay back the vault and the user
        
        require(order.side == Side.SELL, "Order must be a sell order");
        uint256 noPositionId = order.tokenId;
        
        // Transfer NO tokens from user to adapter
        ctf.safeTransferFrom(
            order.maker,
            address(this),
            noPositionId,
            fillAmount,
            ""
        );
        
        // Get the condition ID for this question from the NegRiskAdapter
        bytes32 conditionId = neg.getConditionId(order.questionId);
        
        // Use NegRiskAdapter's mergePositions function instead of calling ConditionalTokens directly
        // This ensures the tokens are merged correctly with the right collateral token
        _mergePositions(conditionId, fillAmount);
        
        // Calculate fee for this order
        uint256 feeAmount = order.feeAmount;
        uint256 amountOut = order.counterPayAmount - feeAmount;
        
        // Collect fee in USDC if any
        if (feeAmount > 0) {
            wcol.unwrap(neg.vault(), feeAmount);
        }
        
        // Transfer remaining USDC to the seller
        if (amountOut > 0) {
            wcol.unwrap(order.maker, amountOut);
        }
        
        return order.payAmount;
    }

    function _handleBuyOrders(
        Parsed[] memory parsedOrders,
        uint256 fillAmount
    ) internal {
        for (uint256 i = 1; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == Side.BUY) {
                _processBuyOrder(parsedOrders[i], fillAmount);
            }
        }
    }
    
    function _processBuyOrder(
        Parsed memory order,
        uint256 fillAmount
    ) internal {
        if (order.side == Side.BUY) {
            
            // Get the YES token position ID for this specific question
            uint256 yesPositionId = order.tokenId;
            
            // Calculate fee for this order
            uint256 feeAmount = order.feeAmount;
            uint256 amountOut = fillAmount - feeAmount;
            
            // Collect fee in YES tokens if any
            if (feeAmount > 0) {
                ctf.safeTransferFrom(address(this), address(neg.vault()), yesPositionId, feeAmount, "");
            }
            
            // Distribute remaining YES tokens to the buyer
            if (amountOut > 0) {
                ctf.safeTransferFrom(
                    address(this),
                    order.maker,
                    yesPositionId,
                    amountOut,
                    ""
                );
            }

            // No YES tokens are left in the adapter
        }
    }
    
    /// @dev internal function to collect USDC from buyers and wrap it to WCOL
    function _collectBuyerUSDC(Parsed[] memory parsedOrders, bool isShort) internal {
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == Side.BUY) {
                // For buy orders, we need to collect USDC from the buyer
                uint256 usdcAmount = isShort ? parsedOrders[i].counterPayAmount : parsedOrders[i].payAmount;
                
                // Transfer USDC from buyer to this contract
                usdc.transferFrom(parsedOrders[i].maker, address(this), usdcAmount);
                // wrap the USDC to WCOL
                wcol.wrap(address(this), usdcAmount);
            }
        }
    }
    
    function _parseOrder(
        OrderIntent calldata order,
        uint256 fillAmount,
        uint256 makingAmount,
        uint256 takingAmount
    ) internal view returns (Parsed memory) {
        uint256 priceQ6 = order.order.price;
        uint256 payUSDC = (priceQ6 * fillAmount) / ONE;
        // the usdc amount that we need to return to the seller
        uint256 usdcToReturn = (ONE - priceQ6) * fillAmount / ONE;

        uint256 feeAmount = CalculatorHelper.calculateFee(order.order.feeRateBps, order.side == Side.BUY ? takingAmount : makingAmount, order.makerAmount, order.takerAmount, order.side,ctfExchange.FEE_RATIO());

        // token side
        bool isYes = true;
        if (order.order.intent == Intent.LONG) {
            if (order.side == Side.BUY) {
                isYes = true;
            } else {
                isYes = false;
            }
        } else {
            if (order.side == Side.SELL) {
                isYes = true;
            } else {
                isYes = false;
            }
        }
        uint256 positionId = neg.getPositionId(order.order.questionId, isYes);
        require(positionId == order.tokenId, "Question ID mismatch");

        return Parsed({
            maker: order.order.maker,
            side: order.side,
            tokenId: order.tokenId,
            priceQ6: priceQ6,
            payAmount: payUSDC,
            counterPayAmount: usdcToReturn,
            questionId: order.order.questionId,
            feeRateBps: order.order.feeRateBps,
            feeAmount: feeAmount,
            makingAmount: makingAmount,
            takingAmount: takingAmount
        });
    }
    
    /// @dev Maps a position ID to its corresponding question index
    /// @param positionId The position ID to map
    /// @param marketId The market ID for context
    /// @return qIndex The question index (0-based)
    function _getQuestionIndexFromPositionId(uint256 positionId, bytes32 marketId) internal view returns (uint8) {
        // Production-ready implementation: iterate through questions to find matching position ID
        uint256 questionCount = neg.getQuestionCount(marketId);
        
        for (uint8 i = 0; i < questionCount; i++) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, i);
            
            // Check if this position ID matches either YES or NO for this question
            uint256 yesPositionId = neg.getPositionId(questionId, true);
            uint256 noPositionId = neg.getPositionId(questionId, false);
            
            if (positionId == yesPositionId || positionId == noPositionId) {
                return i;
            }
        }
        
        // If we can't find a matching question, revert
        revert UnsupportedToken();
    }

    function getCollateral() public view override returns (address) {
        return address(wcol);
    }

    function getCtf() public view override returns (address) {
        return address(ctf);
    }

    function _refundLeftoverTokens(
        OrderIntent calldata takerOrder
    ) internal {
        uint256 makerAssetId;
        if (takerOrder.side == Side.BUY){
            makerAssetId = 0;
        } else {
            makerAssetId = takerOrder.tokenId;
        }

        uint256 refund = _getBalance(makerAssetId);
        if (makerAssetId == 0) {
            wcol.unwrap(takerOrder.order.maker, refund);
        } else {
            if (refund > 0) _transfer(address(this), takerOrder.order.maker, makerAssetId, refund);
        }
    }

    function _mergePositions(bytes32 _conditionId, uint256 _amount) internal {
        ctf.mergePositions(address(wcol), bytes32(0), _conditionId, Helpers.partition(), _amount);
    }

    /// @dev internal function to avoid stack too deep in convertPositions
    function _splitPosition(bytes32 _conditionId, uint256 _amount) internal {
        ctf.splitPosition(address(wcol), bytes32(0), _conditionId, Helpers.partition(), _amount);
    }

    function _updateTakingWithSurplus(uint256 minimumAmount, uint256 tokenId) internal returns (uint256) {
        uint256 actualAmount = _getBalance(tokenId);
        if (actualAmount < minimumAmount) revert ITradingEE.TooLittleTokensReceived();
        return actualAmount;
    }
}
