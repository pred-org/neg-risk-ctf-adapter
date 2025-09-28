// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {ERC1155TokenReceiver} from "lib/solmate/src/tokens/ERC1155.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {INegRiskAdapter} from "./interfaces/INegRiskAdapter.sol";
import {IRevNegRiskAdapter} from "./interfaces/IRevNegRiskAdapter.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {NegRiskIdLib} from "./libraries/NegRiskIdLib.sol";

import {ICTFExchange} from "src/interfaces/ICTFExchange.sol";
import {OrderStatus} from "lib/ctf-exchange/src/exchange/libraries/OrderStructs.sol";

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

contract CrossMatchingAdapter is ReentrancyGuard, ERC1155TokenReceiver {
    // constants
    uint8    constant SIDE_BUY  = 0;
    uint8    constant SIDE_SELL = 1;
    bytes32  constant PARENT = bytes32(0);
    uint256  constant ONE = 1e6; // fixed-point for price (6 decimals to match USDC)
    address public constant YES_TOKEN_BURN_ADDRESS = address(bytes20(bytes32(keccak256("YES_TOKEN_BURN_ADDRESS"))));    
    address public constant NO_TOKEN_BURN_ADDRESS = address(bytes20(bytes32(keccak256("NO_TOKEN_BURN_ADDRESS"))));


    INegRiskAdapter public immutable neg;
    IRevNegRiskAdapter public immutable revNeg;
    IConditionalTokens public immutable ctf;
    ICTFExchange public immutable ctfExchange;
    WrappedCollateral public immutable wcol; // wrapped USDC
    IERC20 public immutable usdc;

    uint256[] internal PARTITION; // [YES, NO] = [1,2]
    uint256   constant PIVOT_INDEX_BIT = 1; // index 0 -> bit 1

    constructor(INegRiskAdapter neg_, IERC20 usdc_, ICTFExchange ctfExchange_, IRevNegRiskAdapter revNeg_) {
        revNeg = revNeg_;
        neg  = neg_;
        ctfExchange = ctfExchange_;
        ctf  = IConditionalTokens(neg_.ctf());
        wcol = WrappedCollateral(neg_.wcol());
        usdc = usdc_;
        PARTITION = new uint256[](2);
        PARTITION[0] = 1; // YES
        PARTITION[1] = 2; // NO
        
        // Approve CTF contract to transfer WCOL on our behalf
        wcol.approve(address(ctf), type(uint256).max);
        usdc.approve(address(neg), type(uint256).max);

        ctf.setApprovalForAll(address(revNeg), true);
        ctf.setApprovalForAll(address(neg), true);
        // Note: The vault must approve this contract to transfer USDC for seller returns
    }

    error UnsupportedToken();      // order.tokenId not recognized as YES (buy) or NO (sell)
    error SideNotSupported();      // only BUY-YES and SELL-NO supported in this adapter
    error PriceOutOfRange();       // price must be ≤ 1
    error BootstrapShortfall();    // not enough buyer USDC to bootstrap pivot split
    error SupplyInvariant();       // insufficient YES supply computed
    error NotSelfFinancing();      // net WCOL minted (!= 0) after operations
    error InvalidFillAmount();     // fill amount is invalid (zero or exceeds order quantity)
    error InvalidCombinedPrice();  // combined price of all orders must equal total shares
    error InsufficientUSDCBalance(); // insufficient USDC balance for WCOL minting

    struct Parsed {
        address maker;
        uint8   side;
        uint256 tokenId;
        uint256 priceQ6;    // USDC/share (≤ 1e6) - updated from priceQ18
        uint256 payAmount;    // = shares * price (for buy orders)
        uint256 counterPayAmount; // = shares * (1 - price) (for sell orders)
        bytes32 questionId;     // which question id
    }

    function hybridMatchOrders(
        bytes32 marketId,
        ICTFExchange.OrderIntent calldata takerOrder, 
        ICTFExchange.OrderIntent[][] calldata makerOrders, 
        uint256[] calldata makerFillAmounts,
        uint8 singleOrderCount
    ) external nonReentrant {
        // Pre-allocate arrays for single orders using the provided count
        ICTFExchange.OrderIntent[] memory singleMakerOrders = new ICTFExchange.OrderIntent[](singleOrderCount);
        uint256[] memory singleMakerFillAmounts = new uint256[](singleOrderCount);
        uint256 singleOrdersTakerAmount = 0;
        uint256 singleOrderIndex = 0;
        
        for (uint256 i = 0; i < makerOrders.length;) {
            ICTFExchange.OrderIntent[] calldata makerOrder = makerOrders[i];
            if (makerOrder.length == 1) {
                // Collect single maker orders for batch processing
                singleMakerOrders[singleOrderIndex] = makerOrder[0];
                singleMakerFillAmounts[singleOrderIndex] = makerFillAmounts[i];
                
                // For COMPLEMENTARY matches, calculate the correct taker fill amount
                // The taker fill amount should be the USDC amount needed to buy the tokens
                // For BUY orders: takerFillAmount = (makerFillAmount * takerOrder.price) / 1e6
                // For SELL orders: takerFillAmount = makerFillAmount (taker receives tokens directly)
                if (takerOrder.side == ICTFExchange.Side.BUY) {
                    // Taker is buying, so calculate USDC amount needed
                    uint256 usdcNeeded = (makerFillAmounts[i] * takerOrder.order.price) / 1e6;
                    singleOrdersTakerAmount += usdcNeeded;
                } else {
                    // Taker is selling, so the fill amount is the token amount
                    singleOrdersTakerAmount += makerFillAmounts[i];
                }
                singleOrderIndex++;
            } else {
                // cross match
                if (takerOrder.order.intent == ICTFExchange.Intent.LONG) {
                    // LONG
                    crossMatchLongOrders(marketId, takerOrder, makerOrder, makerFillAmounts[i]);
                } else {
                    // SHORT
                    crossMatchShortOrders(marketId, takerOrder, makerOrder, makerFillAmounts[i]);
                }
            }
            unchecked {
                ++i;
            }
        }
        
        // Process all single maker orders in a single batch call
        if (singleOrderCount > 0) {
            // Single call to match all orders at once
            ctfExchange.matchOrders(takerOrder, singleMakerOrders, singleOrdersTakerAmount, singleMakerFillAmounts);
        }
    }

    function crossMatchShortOrders(
        bytes32 marketId,
        ICTFExchange.OrderIntent calldata takerOrder,
        ICTFExchange.OrderIntent[] calldata multiOrderMaker,
        uint256 fillAmount
    ) public {
        if (fillAmount == 0) {
            revert InvalidFillAmount();
        }

        // Validate taker order signature and parameters
        ctfExchange.validateOrder(takerOrder);
        ctfExchange.updateOrderStatus(takerOrder, fillAmount);

        // Validate all maker orders signatures and parameters and update the order status
        for (uint256 i = 0; i < multiOrderMaker.length; i++) {
            ctfExchange.validateOrder(multiOrderMaker[i]);
            ctfExchange.updateOrderStatus(multiOrderMaker[i], fillAmount);
        }

        Parsed[] memory parsedOrders = new Parsed[](multiOrderMaker.length + 1);
        uint256 totalBuyUSDC = 0;
        uint256 totalSellUSDC = 0;
        uint256 totalCombinedPrice = 0;
        
        // Parse taker order
        parsedOrders[0] = _parseOrder(takerOrder, fillAmount);
        if (parsedOrders[0].side == SIDE_BUY) {
            totalBuyUSDC += parsedOrders[0].counterPayAmount;
        } else {
            totalSellUSDC += parsedOrders[0].counterPayAmount;
        }

        totalCombinedPrice += parsedOrders[0].priceQ6;
        
        // Parse maker orders
        for (uint256 i = 0; i < multiOrderMaker.length; i++) {
            parsedOrders[i + 1] = _parseOrder(multiOrderMaker[i], fillAmount);
            totalCombinedPrice += parsedOrders[i + 1].priceQ6;
            if (parsedOrders[i + 1].side == SIDE_BUY) {
                totalBuyUSDC += parsedOrders[i + 1].counterPayAmount;
            } else {
                // For sell orders, amount that we need for minting 
                totalSellUSDC += parsedOrders[i + 1].counterPayAmount;
            }
        }

        // The total combined price must equal to one
        if (totalCombinedPrice != ONE) {
            revert InvalidCombinedPrice();
        }

        // Execute cross-matching logic
        _executeShortCrossMatch(parsedOrders, marketId, totalSellUSDC, fillAmount);
    }

    function _executeShortCrossMatch(
        Parsed[] memory parsedOrders,
        bytes32 marketId,
        uint256 totalSellUSDC,
        uint256 fillAmount
    ) internal {
        _collectBuyerUSDC(parsedOrders, true);

        // TotalBuyUSDC + TotalSellUSDC = (length of parsedOrders - 1) * fillAmount
        // Add the fillAmount to this amount to get the total USDC that we need to complete the split
        usdc.transferFrom(neg.vault(), address(this), fillAmount + totalSellUSDC);

        // split positions for all the orders
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            bytes32 conditionId = neg.getConditionId(parsedOrders[i].questionId);
            neg.splitPosition(conditionId, fillAmount);
        }

        // Based on order is a BUY no or SELL yes, we will either directly distribute the NO tokens to the buyers or merge the NO tokens with the YES tokens to get USDC for the sellers
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == SIDE_BUY) {
                // Distribute NO tokens to the buyers
                _distributeNoTokens(parsedOrders[i], fillAmount);
            } else {
                // Merge NO tokens with YES tokens to get USDC for the sellers
                _mergeNoTokens(parsedOrders[i], fillAmount);
            }
        }

        // Merge all the YES tokens to get USDC
        uint8 pivotIndex = _getQuestionIndexFromPositionId(parsedOrders[0].tokenId, marketId);
        revNeg.mergeAllYesTokens(marketId, fillAmount, pivotIndex);

        // transfer the shares * ONE of USDC to the vault, since we took it from the vault
        usdc.transfer(neg.vault(), fillAmount + totalSellUSDC);
    }

    function _distributeNoTokens(
        Parsed memory order,
        uint256 fillAmount
    ) internal {
        // Distribute NO tokens to the buyers
        ctf.safeTransferFrom(address(this), order.maker, order.tokenId, fillAmount, "");
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
        neg.mergePositions(conditionId, fillAmount);
        usdc.transfer(order.maker, order.payAmount);
    }

    function crossMatchLongOrders(
        bytes32 marketId,
        ICTFExchange.OrderIntent calldata takerOrder,
        ICTFExchange.OrderIntent[] calldata multiOrderMaker,
        uint256 fillAmount
    ) public {
        if (fillAmount == 0) {
            revert InvalidFillAmount();
        }

        // Validate taker order signature and parameters
        ctfExchange.validateOrder(takerOrder);
        ctfExchange.updateOrderStatus(takerOrder, fillAmount);
        // Validate all maker orders signatures and parameters
        for (uint256 i = 0; i < multiOrderMaker.length; i++) {
            ctfExchange.validateOrder(multiOrderMaker[i]);
            ctfExchange.updateOrderStatus(multiOrderMaker[i], fillAmount);
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
        
        Parsed[] memory parsedOrders = new Parsed[](multiOrderMaker.length + 1);
        uint256 totalSellUSDC = 0;
        uint256 totalCombinedPrice = 0;
        
        // Parse taker order
        parsedOrders[0] = _parseOrder(takerOrder, fillAmount);
        if (parsedOrders[0].side == SIDE_SELL) {
            totalSellUSDC += parsedOrders[0].payAmount;
        }
        totalCombinedPrice += parsedOrders[0].priceQ6;
        
        // Parse maker orders
        for (uint256 i = 0; i < multiOrderMaker.length; i++) {
            parsedOrders[i + 1] = _parseOrder(multiOrderMaker[i], fillAmount);
            if (parsedOrders[i + 1].side == SIDE_SELL) {
                totalSellUSDC += parsedOrders[i + 1].payAmount;
            }
            totalCombinedPrice += parsedOrders[i + 1].priceQ6;
        }
        
        // Note: We can have:
        // 1. All buy orders: 4 users buying different YES tokens (Yes1, Yes2, Yes3, Yes4)
        // 2. All sell orders: users selling NO tokens (e.g., No Barca, No Arsenal, No Chelsea)
        // 3. Mixed buy/sell orders: some users buying YES, some selling NO
        
        // Validate that the combined price of all orders equals 1
        // This is required for cross-matching to work properly
        // 
        // Why this validation is crucial:
        // 1. For cross-matching to be self-financing, the total value of all orders must balance
        // 2. Each YES/NO token pair must sum to 1 (Yi + Ni = 1)
        // 3. If the combined price ≠ total shares, we cannot create a balanced position
        // 4. This prevents arbitrage and ensures the mechanism works correctly
        // 
        // Examples:
        // Scenario 1 (all buy): Buy Yes1(0.25) + Buy Yes2(0.25) + Buy Yes3(0.25) + Buy Yes4(0.25) = 1.0
        // Scenario 2 (mixed): Buy Yes1(0.25) + Sell No2(0.75) + Buy Yes3(0.25) + Sell No4(0.75) = 0.25 + 0.25 + 0.25 + 0.25 = 1.0
        // 
        // For sell orders, we use (1 - price) since Yi + Ni = 1
        
        // The total combined price must equal to one
        if (totalCombinedPrice != ONE) {
            revert InvalidCombinedPrice();
        }
        
        // Execute cross-matching logic
        _executeLongCrossMatch(parsedOrders, marketId, totalSellUSDC, fillAmount);
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
            // get from vault
            usdc.transferFrom(neg.vault(), address(this), totalSellUSDC);
        }
        
        // STEP 1: Split position for pivot question (use taker's question ID) to create YES + NO
        // Use the taker's question ID as the pivot since we know it's active (unresolved)
        uint8 pivotId = _getQuestionIndexFromPositionId(parsedOrders[0].tokenId, marketId);
        bytes32 pivotConditionId = neg.getConditionId(parsedOrders[0].questionId);
        
        // We need to split enough USDC to cover the CTF operation
        
        // Split the available USDC on pivot question to get YES + NO
        neg.splitPosition(pivotConditionId, fillAmount);
        
        // STEP 2: Use convertPositions to convert NO tokens to other YES tokens
        // The indexSet for convertPositions represents which NO positions we want to convert
        // We want to convert NO tokens from the pivot question to get YES tokens for other questions
        // So we need to provide an indexSet that represents the pivot NO position
        uint256 indexSet = 1 << pivotId; // This represents NO position for the pivot question
        
        // Approve NegRiskAdapter to handle our tokens
        ctf.setApprovalForAll(address(neg), true);
        
        // Convert NO tokens to YES tokens for other questions using NegRiskAdapter's convertPositions
        // We can only convert as much as we have NO tokens from the split operation
        neg.convertPositions(marketId, indexSet, fillAmount);
        
        // STEP 3: Distribute YES tokens to buyers
        _distributeYesTokens(parsedOrders, fillAmount);
        
        // STEP 4: Handle sell orders: return USDC to sellers
        uint256 totalVaultUSDC = _handleSellOrders(parsedOrders, fillAmount);
        
        // STEP 5: Return any remaining USDC to the vault to maintain self-financing
        // Since we're not taking USDC from the vault upfront for seller returns,
        // we only need to return any excess USDC from the CTF operations
        uint256 remainingUSDC = usdc.balanceOf(address(this));
        if (remainingUSDC == totalVaultUSDC) {
            usdc.transfer(neg.vault(), remainingUSDC);
        }
    }
    
    function _handleSellOrders(
        Parsed[] memory parsedOrders,
        uint256 fillAmount
    ) internal returns (uint256) {
        uint256 totalVaultUSDC = 0;
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == SIDE_SELL) {
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
        
        require(order.side == SIDE_SELL, "Order must be a sell order");
        uint256 noPositionId = order.tokenId;

        uint256 mergeAmount = fillAmount;
        
        // Transfer NO tokens from user to adapter
        ctf.safeTransferFrom(
            order.maker,
            address(this),
            noPositionId,
            mergeAmount,
            ""
        );
        
        // Get the condition ID for this question from the NegRiskAdapter
        bytes32 conditionId = neg.getConditionId(order.questionId);
        
        // Use NegRiskAdapter's mergePositions function instead of calling ConditionalTokens directly
        // This ensures the tokens are merged correctly with the right collateral token
        neg.mergePositions(conditionId, mergeAmount);
        
        // Now we have USDC from the merge operation
        // USDC TO pay to the seller
        uint256 usdcToPay = order.counterPayAmount;
        uint256 vaultUSDC = order.payAmount;
        
        // Transfer USDC to seller
        usdc.transfer(order.maker, usdcToPay);
        
        return vaultUSDC;
    }
    
    function _distributeYesTokens(
        Parsed[] memory parsedOrders,
        // bytes32 marketId,
        uint256 fillAmount
    ) internal {
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == SIDE_BUY) {
                
                // Get the YES token position ID for this specific question
                uint256 yesPositionId = parsedOrders[i].tokenId;
                
                // Transfer the specific YES token to the buyer
                ctf.safeTransferFrom(
                    address(this),
                    parsedOrders[i].maker,
                    yesPositionId,
                    fillAmount,
                    ""
                );

                // No YES tokens are left in the adapter
            }
        }
    }
    
    function _collectBuyerUSDC(Parsed[] memory parsedOrders, bool isShort) internal {
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == SIDE_BUY) {
                // For buy orders, we need to collect USDC from the buyer
                uint256 usdcAmount = isShort ? parsedOrders[i].counterPayAmount : parsedOrders[i].payAmount;
                
                // Transfer USDC from buyer to this contract
                usdc.transferFrom(parsedOrders[i].maker, address(this), usdcAmount);
            }
        }
    }
    
    function _parseOrder(
        ICTFExchange.OrderIntent calldata order,
        uint256 fillAmount
    ) internal view returns (Parsed memory) {
        uint256 priceQ6 = order.order.price;
        uint256 payUSDC = (priceQ6 * fillAmount) / ONE;
        // the usdc amount that we need to return to the seller
        uint256 usdcToReturn = (ONE - priceQ6) * fillAmount / ONE;

        // token side
        bool isYes = true;
        if (order.order.intent == ICTFExchange.Intent.LONG) {
            if (order.side == ICTFExchange.Side.BUY) {
                isYes = true;
            } else {
                isYes = false;
            }
        } else {
            if (order.side == ICTFExchange.Side.SELL) {
                isYes = true;
            } else {
                isYes = false;
            }
        }
        uint256 positionId = neg.getPositionId(order.order.questionId, isYes);
        require(positionId == order.tokenId, "Question ID mismatch");

        return Parsed({
            maker: order.order.maker,
            side: uint8(order.side),
            tokenId: order.tokenId,
            priceQ6: priceQ6,
            payAmount: payUSDC,
            counterPayAmount: usdcToReturn,
            questionId: order.order.questionId
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
    
    /*//////////////////////////////////////////////////////////////
                        ERC1155 TOKEN RECEIVER
    //////////////////////////////////////////////////////////////*/
    
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
