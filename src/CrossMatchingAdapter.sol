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

import {console2} from "forge-std/console2.sol";

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

interface ICTFExchange {
    struct OrderIntent {
      /// @notice Token Id of the CTF ERC1155 asset to be bought or sold
      /// If BUY, this is the tokenId of the asset to be bought, i.e the makerAssetId
      /// If SELL, this is the tokenId of the asset to be sold, i.e the takerAssetId
      uint256 tokenId;
      /// @notice The side of the order: BUY or SELL
      uint8 side; // 0 = BUY, 1 = SELL
      uint256 makerAmount;
      uint256 takerAmount;
      Order order;
    }
    struct Order {
        uint256 salt;
        address maker;       // funder (USDC for BUY, NO for SELL)
        address signer;
        address taker;       // unused here
        uint256 price;       // USDC per share (fixed-point 6 decimals)
        uint256 quantity;    // number of shares to trade
        uint256 expiration;
        uint256 nonce;
        uint256 feeRateBps;
        bytes32 questionId;
        uint8   intent; // 0 = LONG, 1 = SHORT
        uint8   signatureType;
        bytes   signature;
    }

    function matchOrders(
        OrderIntent memory takerOrder,
        OrderIntent[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) external;
}

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
        uint256 payUSDC;    // = shares * price (for buy orders)
        uint256 usdcToReturn; // = shares * (1 - price) (for sell orders)
        bytes32 questionId;     // which question id
    }

    function hybridMatchOrders(
        bytes32 marketId,
        ICTFExchange.OrderIntent calldata takerOrder, 
        ICTFExchange.OrderIntent[][] calldata makerOrders, 
        uint256 takerFillAmount, 
        uint256[] calldata makerFillAmounts
    ) external nonReentrant {
        uint256[] memory singleMakerFillAmount = new uint256[](1);
        singleMakerFillAmount[0] = 0;
        ICTFExchange.OrderIntent[] memory singleMakerOrder = new ICTFExchange.OrderIntent[](1);
        for (uint256 i = 0; i < makerOrders.length;) {
            ICTFExchange.OrderIntent[] calldata makerOrder = makerOrders[i];
            if (makerOrder.length == 1) {
                singleMakerFillAmount[0] += makerFillAmounts[i];
                singleMakerOrder[0] = makerOrder[0];
                // normal match
            } else {
                // cross match
                if (takerOrder.order.intent == 0) {
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
        ctfExchange.matchOrders(takerOrder, singleMakerOrder, takerFillAmount, singleMakerFillAmount);
    }

    function crossMatchShortOrders(
        bytes32 marketId,
        ICTFExchange.OrderIntent calldata takerOrder,
        ICTFExchange.OrderIntent[] calldata multiOrderMaker,
        uint256 fillAmount
    ) public nonReentrant {
        if (fillAmount == 0) {
            revert InvalidFillAmount();
        }

        Parsed[] memory parsedOrders = new Parsed[](multiOrderMaker.length + 1);
        uint256 totalBuyUSDC = 0;
        uint256 totalSellUSDC = 0;
        uint256 totalCombinedPrice = 0;

        // Check that we have orders for at least some questions in the market
        // The function can handle cases where some questions are already resolved
        uint256 questionCount = neg.getQuestionCount(marketId);
        require(multiOrderMaker.length + 1 <= questionCount, "Cannot have more orders than questions in the market");
        
        // Parse taker order
        parsedOrders[0] = _parseOrder(takerOrder, fillAmount, marketId);
        if (parsedOrders[0].side == SIDE_BUY) {
            totalBuyUSDC += parsedOrders[0].usdcToReturn;
        } else {
            totalSellUSDC += parsedOrders[0].usdcToReturn;
        }

        totalCombinedPrice += parsedOrders[0].priceQ6;
        
        // Parse maker orders
        for (uint256 i = 0; i < multiOrderMaker.length; i++) {
            parsedOrders[i + 1] = _parseOrder(multiOrderMaker[i], fillAmount, marketId);
            totalCombinedPrice += parsedOrders[i + 1].priceQ6;
            if (parsedOrders[i + 1].side == SIDE_BUY) {
                totalBuyUSDC += parsedOrders[i + 1].usdcToReturn;
            } else {
                // For sell orders, amount that we need for minting 
                totalSellUSDC += parsedOrders[i + 1].usdcToReturn;
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
                _mergeNoTokens(parsedOrders[i], marketId, fillAmount);
            }
        }

        // Merge all the YES tokens to get USDC
        require(ctf.balanceOf(address(this), neg.getPositionId(parsedOrders[0].questionId, true)) == fillAmount, "YES tokens should be at the target yes position");
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
        bytes32 marketId,
        uint256 fillAmount
    ) internal {
        // transfer the YES tokens to the adapter that the maker is selling
        ctf.safeTransferFrom(order.maker, address(this), order.tokenId, fillAmount, "");
        
        // Merge NO tokens with user's YES tokens to get USDC for the sellers
        // The NO tokens are already in the adapter from the split operation
        bytes32 conditionId = neg.getConditionId(order.questionId);
        neg.mergePositions(conditionId, fillAmount);
        usdc.transfer(order.maker, order.payUSDC);
    }

    function crossMatchLongOrders(
        bytes32 marketId,
        ICTFExchange.OrderIntent calldata takerOrder,
        ICTFExchange.OrderIntent[] calldata multiOrderMaker,
        uint256 fillAmount
    ) public nonReentrant {
        if (fillAmount == 0) {
            revert InvalidFillAmount();
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
        
        // Check that we have orders for at least some questions in the market
        // The function can handle cases where some questions are already resolved
        uint256 questionCount = neg.getQuestionCount(marketId);
        require(multiOrderMaker.length + 1 <= questionCount, "Cannot have more orders than questions in the market");
        
        Parsed[] memory parsedOrders = new Parsed[](multiOrderMaker.length + 1);
        uint256 totalBuyUSDC = 0;
        uint256 totalSellUSDC = 0;
        uint256 totalCombinedPrice = 0;
        
        // Parse taker order
        parsedOrders[0] = _parseOrder(takerOrder, fillAmount, marketId);
        if (parsedOrders[0].side == SIDE_BUY) {
            totalBuyUSDC += parsedOrders[0].payUSDC;
        } else {
            totalSellUSDC += parsedOrders[0].payUSDC;
        }
        totalCombinedPrice += parsedOrders[0].priceQ6;
        
        // Parse maker orders
        for (uint256 i = 0; i < multiOrderMaker.length; i++) {
            parsedOrders[i + 1] = _parseOrder(multiOrderMaker[i], fillAmount, marketId);
            if (parsedOrders[i + 1].side == SIDE_BUY) {
                totalBuyUSDC += parsedOrders[i + 1].payUSDC;
            } else {
                // For sell orders, amount that we need for minting 
                totalSellUSDC += parsedOrders[i + 1].payUSDC;
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
        _executeLongCrossMatch(parsedOrders, marketId, totalBuyUSDC, totalSellUSDC, fillAmount);
    }
    
    function _executeLongCrossMatch(
        Parsed[] memory parsedOrders,
        bytes32 marketId,
        uint256 totalBuyUSDC,
        uint256 totalSellUSDC,
        uint256 fillAmount
    ) internal {
        uint256 totalCollateral = totalBuyUSDC + totalSellUSDC;

        // Collect USDC from buyers before we can use it
        _collectBuyerUSDC(parsedOrders, false);
        
        if (totalSellUSDC > 0) {
            // get from vault
            usdc.transferFrom(neg.vault(), address(this), totalSellUSDC);
        }

        
        uint256 questionCount = neg.getQuestionCount(marketId);
        
        // STEP 1: Split position for pivot question (use taker's question ID) to create YES + NO
        // Use the taker's question ID as the pivot since we know it's active (unresolved)
        uint8 pivotId = _getQuestionIndexFromPositionId(parsedOrders[0].tokenId, marketId);
        bytes32 pivotConditionId = neg.getConditionId(parsedOrders[0].questionId);
        
        // We need to split enough USDC to cover the CTF operation
        
        // Split the available USDC on pivot question to get YES + NO
        neg.splitPosition(pivotConditionId, totalCollateral);
        
        // STEP 2: Use convertPositions to convert NO tokens to other YES tokens
        if (questionCount > 1) {
            // The indexSet for convertPositions represents which NO positions we want to convert
            // We want to convert NO tokens from the pivot question to get YES tokens for other questions
            // So we need to provide an indexSet that represents the pivot NO position
            uint256 indexSet = 1 << pivotId; // This represents NO position for the pivot question
            
            // Approve NegRiskAdapter to handle our tokens
            ctf.setApprovalForAll(address(neg), true);
            
            // Convert NO tokens to YES tokens for other questions using NegRiskAdapter's convertPositions
            // We can only convert as much as we have NO tokens from the split operation
            neg.convertPositions(marketId, indexSet, totalCollateral);
        }
        
        // STEP 3: Distribute YES tokens to buyers
        _distributeYesTokens(parsedOrders, fillAmount);
        
        // STEP 4: Handle sell orders: return USDC to sellers
        uint256 totalVaultUSDC = _handleSellOrders(parsedOrders, marketId, fillAmount);
        
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
        bytes32 marketId,
        uint256 fillAmount
    ) internal returns (uint256) {
        uint256 totalVaultUSDC = 0;
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == SIDE_SELL) {
                totalVaultUSDC += _processSellOrder(parsedOrders[i], marketId, fillAmount);
            }
        }
        return totalVaultUSDC;
    }
    
    function _processSellOrder(
        Parsed memory order,
        bytes32 marketId,
        uint256 fillAmount
    ) internal returns (uint256) {
        // For sell orders, we need to merge the user's NO tokens with the generated YES tokens
        // to get USDC, which will be used to pay back the vault and the user
        
        require(order.side == SIDE_SELL, "Order must be a sell order");
        uint256 noPositionId = order.tokenId;
        uint256 yesPositionId = neg.getPositionId(order.questionId, true);

        uint256 mergeAmount = fillAmount;
        
        // Get the user's NO token balance
        uint256 userNoBalance = ctf.balanceOf(order.maker, noPositionId);
        require(userNoBalance >= mergeAmount, "User doesn't have enough NO tokens to sell");
        
        // Transfer NO tokens from user to adapter
        ctf.safeTransferFrom(
            order.maker,
            address(this),
            noPositionId,
            mergeAmount,
            ""
        );
        
        // Check if adapter has enough YES tokens for this question
        uint256 adapterYesBalance = ctf.balanceOf(address(this), yesPositionId);
        require(adapterYesBalance >= order.usdcToReturn, "Adapter doesn't have enough YES tokens for merge");
        
        // Get the condition ID for this question from the NegRiskAdapter
        bytes32 conditionId = neg.getConditionId(order.questionId);
        
        // Use NegRiskAdapter's mergePositions function instead of calling ConditionalTokens directly
        // This ensures the tokens are merged correctly with the right collateral token
        neg.mergePositions(conditionId, mergeAmount);
        
        // Now we have USDC from the merge operation
        // USDC TO pay to the seller
        uint256 usdcToPay = order.usdcToReturn;
        uint256 vaultUSDC = order.payUSDC;
        
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
                // Each buyer ordered a specific YES token for a specific question
                // uint256 buyerShares = fillAmount;
                
                // Get the YES token position ID for this specific question
                uint256 yesPositionId = parsedOrders[i].tokenId;
                
                // Check if the adapter has enough YES tokens to distribute
                uint256 adapterBalance = ctf.balanceOf(address(this), yesPositionId);
                
                if (fillAmount > 0) {
                    // Transfer the specific YES token to the buyer
                    ctf.safeTransferFrom(
                        address(this),
                        parsedOrders[i].maker,
                        yesPositionId,
                        fillAmount,
                        ""
                    );
                }
                // burn remaining YES tokens
                ctf.safeTransferFrom(
                    address(this),
                    YES_TOKEN_BURN_ADDRESS,
                    yesPositionId,
                    adapterBalance - fillAmount,
                    ""
                );
            }
        }
    }
    
    function _collectBuyerUSDC(Parsed[] memory parsedOrders, bool isShort) internal {
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == SIDE_BUY) {
                // For buy orders, we need to collect USDC from the buyer
                uint256 usdcAmount = isShort ? parsedOrders[i].usdcToReturn : parsedOrders[i].payUSDC;
                
                // Transfer USDC from buyer to this contract
                usdc.transferFrom(parsedOrders[i].maker, address(this), usdcAmount);
            }
        }
    }
    
    function _parseOrder(
        ICTFExchange.OrderIntent calldata order,
        uint256 fillAmount,
        bytes32 marketId
    ) internal view returns (Parsed memory) {
        // In production, the tokenId should be the actual position ID that the user wants to trade
        // We need to determine which question this position belongs to by checking all possible questions
        // uint8 qIndex = _getQuestionIndexFromPositionId(order.tokenId, marketId);
    
        
        // Validate price (must be <= 1)
        if (order.order.price > ONE) {
            revert PriceOutOfRange();
        }
        
        uint256 priceQ6 = order.order.price;
        uint256 payUSDC = (priceQ6 * fillAmount) / ONE;
        // the usdc amount that we need to return to the seller
        uint256 usdcToReturn = (ONE - priceQ6) * fillAmount / ONE;

        // token side
        bool isYes = true;
        if (order.order.intent == 0) {
            if (order.side == SIDE_BUY) {
                isYes = true;
            } else {
                isYes = false;
            }
        } else {
            if (order.side == SIDE_SELL) {
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
            payUSDC: payUSDC,
            usdcToReturn: usdcToReturn,
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
