// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {ERC1155TokenReceiver} from "lib/solmate/src/tokens/ERC1155.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {INegRiskAdapter} from "./interfaces/INegRiskAdapter.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {NegRiskIdLib} from "./libraries/NegRiskIdLib.sol";

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
        uint256 price;       // USDC per share (fixed-point 18 decimals)
        uint256 quantity;    // number of shares to trade
        uint256 expiration;
        uint256 nonce;
        uint256 feeRateBps;
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
    uint256  constant ONE = 1e18; // fixed-point for price

    INegRiskAdapter public immutable neg;
    IConditionalTokens public immutable ctf;
    ICTFExchange public immutable ctfExchange;
    WrappedCollateral public immutable wcol; // wrapped USDC
    IERC20 public immutable usdc;

    uint256[] internal PARTITION; // [YES, NO] = [1,2]
    uint256   constant PIVOT_INDEX_BIT = 1; // index 0 -> bit 1

    constructor(INegRiskAdapter neg_, IERC20 usdc_, ICTFExchange ctfExchange_) {
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
        uint256 shares;     // derived
        uint256 priceQ18;   // USDC/share (≤ 1e18)
        uint256 payUSDC;    // = shares * price (for buy orders)
        uint256 usdcToReturn; // = shares * (1 - price) (for sell orders)
        uint8   qIndex;     // which question index
    }

    function hybridMatchOrders(
        ICTFExchange.OrderIntent calldata takerOrder, 
        ICTFExchange.OrderIntent[][] calldata makerOrders, 
        uint256 takerFillAmount, 
        uint256[] calldata makerFillAmounts
    ) external nonReentrant {
        for (uint256 i = 0; i < makerOrders.length;) {
            ICTFExchange.OrderIntent[] calldata makerOrder = makerOrders[i];
            if (makerOrder.length == 1) {
                // normal match
                uint256[] memory singleMakerFillAmount = new uint256[](1);
                singleMakerFillAmount[0] = makerFillAmounts[i];
                ctfExchange.matchOrders(takerOrder, makerOrder, takerFillAmount, singleMakerFillAmount);
            } else {
                // cross match
            }
            unchecked {
                ++i;
            }
        }
    }

    function crossMatchLongOrders(
        bytes32 marketId,
        ICTFExchange.OrderIntent calldata takerOrder,
        ICTFExchange.OrderIntent[] calldata makerOrders,
        uint256 takerFillAmount,
        uint256[] calldata makerFillAmounts
    ) external nonReentrant {
        // Cross-matching function that handles two scenarios:
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
        
        Parsed[] memory parsedOrders = new Parsed[](makerOrders.length + 1);
        uint256 totalBuyAmount = 0;
        uint256 totalSellAmount = 0;
        uint256 totalBuyUSDC = 0;
        uint256 totalSellUSDC = 0;
        
        // Parse taker order
        parsedOrders[0] = _parseOrder(takerOrder, takerFillAmount, marketId);
        if (parsedOrders[0].side == SIDE_BUY) {
            totalBuyAmount += parsedOrders[0].shares;
            totalBuyUSDC += parsedOrders[0].payUSDC;
        } else {
            totalSellAmount += parsedOrders[0].shares;
            totalSellUSDC += parsedOrders[0].payUSDC;
        }
        
        // Parse maker orders
        for (uint256 i = 0; i < makerOrders.length; i++) {
            parsedOrders[i + 1] = _parseOrder(makerOrders[i], makerFillAmounts[i], marketId);
            if (parsedOrders[i + 1].side == SIDE_BUY) {
                totalBuyAmount += parsedOrders[i + 1].shares;
                totalBuyUSDC += parsedOrders[i + 1].payUSDC;
            } else {
                totalSellAmount += parsedOrders[i + 1].shares;
                // For sell orders, we need to give USDC back to the user
                totalSellUSDC += parsedOrders[i + 1].usdcToReturn;
            }
        }
        
        // Validate that we have at least some orders
        if (totalBuyAmount == 0 && totalSellAmount == 0) {
            revert("Must have at least some orders");
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
        uint256 totalCombinedPrice = 0;
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == SIDE_BUY) {
                // For buy orders: add the price * shares
                totalCombinedPrice += parsedOrders[i].priceQ18;
            } else {
                // For sell orders: add (1 - price) * shares since Yi + Ni = 1
                uint256 sellPrice = parsedOrders[i].priceQ18;
                totalCombinedPrice += ONE - sellPrice;
            }
        }
        
        // The total combined price must equal to one
        if (totalCombinedPrice != ONE) {
            revert InvalidCombinedPrice();
        }
        
        // Use the provided marketId parameter
        
        // Execute cross-matching logic
        _executeCrossMatch(parsedOrders, marketId, totalBuyAmount, totalBuyUSDC, totalSellUSDC, totalSellAmount);
    }
    
    function _executeCrossMatch(
        Parsed[] memory parsedOrders,
        bytes32 marketId,
        uint256 totalBuyAmount,
        uint256 totalBuyUSDC,
        uint256 totalSellUSDC,
        uint256 totalSellAmount
    ) internal {
        uint256 totalCollateral = totalBuyUSDC + totalSellUSDC;
        

        uint256 balanceBefore = usdc.balanceOf(address(this));
        // Collect USDC from buyers before we can use it
        _collectBuyerUSDC(parsedOrders);
        
        // Verify we have the expected amount of USDC after collection
        uint256 actualUSDCBalance = usdc.balanceOf(address(this));
        require(actualUSDCBalance - balanceBefore == totalBuyUSDC, "Incorrect buy USDC balance");
        if (totalSellUSDC > 0) {
            // get from vault
            usdc.transferFrom(neg.vault(), address(this), totalSellUSDC);
        }

        uint256 balanceAfter = usdc.balanceOf(address(this));
        require(balanceAfter - actualUSDCBalance == totalSellUSDC, "Incorrect sell USDC balance");
        
        uint256 questionCount = neg.getQuestionCount(marketId);
        
        // STEP 1: Split position for pivot question (index 0) to create YES0 + NO0
        bytes32 pivotQuestionId = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 pivotConditionId = neg.getConditionId(pivotQuestionId);
        
        // We need to split enough USDC to cover the CTF operation
        
        // Give approval to NegRiskAdapter to spend our USDC
        usdc.approve(address(neg), totalCollateral);
        
        // Split the available USDC on pivot question to get YES0 + NO0
        neg.splitPosition(pivotConditionId, totalCollateral);
        
        // STEP 2: Use convertPositions to convert NO0 to other YES tokens (YES1, YES2, YES3...)
        if (questionCount > 1) {
            // The indexSet for convertPositions represents which NO positions we want to convert
            // We want to convert NO0 (index 0) to get YES1, YES2, YES3...
            // So we need to provide an indexSet that represents the NO0 position
            uint256 indexSet = 1; // This represents NO0 (index 0 = bit 0 = 2^0 = 1)
            
            // Approve NegRiskAdapter to handle our tokens
            ctf.setApprovalForAll(address(neg), true);
            
            // Convert NO0 to YES1, YES2, YES3... using NegRiskAdapter's convertPositions
            // We can only convert as much as we have NO0 tokens from the split operation
            neg.convertPositions(marketId, indexSet, totalCollateral);
        }
        
        // STEP 3: Distribute YES tokens to buyers
        _distributeYesTokens(parsedOrders, marketId);
        
        // STEP 4: Handle sell orders: return USDC to sellers
        uint256 totalVaultUSDC = _handleSellOrders(parsedOrders, marketId);
        
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
        bytes32 marketId
    ) internal returns (uint256) {
        uint256 totalVaultUSDC = 0;
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == SIDE_SELL) {
                // For sell orders, we need to merge the user's NO tokens with the generated YES tokens
                // to get USDC, which will be used to pay back the vault and the user
                
                uint8 qIndex = parsedOrders[i].side == SIDE_SELL ? parsedOrders[i].qIndex : 0;
                bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, qIndex);
                uint256 noPositionId = neg.getPositionId(questionId, false);
                uint256 yesPositionId = neg.getPositionId(questionId, true);
                
                // Get the user's NO token balance
                uint256 userNoBalance = ctf.balanceOf(parsedOrders[i].maker, noPositionId);
                require(userNoBalance >= parsedOrders[i].shares, "User doesn't have enough NO tokens to sell");
                
                // Transfer NO tokens from user to adapter
                ctf.safeTransferFrom(
                    parsedOrders[i].maker,
                    address(this),
                    noPositionId,
                    parsedOrders[i].shares,
                    ""
                );
                
                // Check if adapter has enough YES tokens for this question
                uint256 adapterYesBalance = ctf.balanceOf(address(this), yesPositionId);
                require(adapterYesBalance >= parsedOrders[i].shares, "Adapter doesn't have enough YES tokens for merge");
                
                // Merge NO + YES tokens to get USDC back
                // We need to create a partition that represents both NO and YES positions
                // For a binary outcome (YES/NO), the partition should be [1, 2] where:
                // 1 = NO position (index 0)
                // 2 = YES position (index 1)
                uint256[] memory partition = new uint256[](2);
                partition[0] = 1; // NO position (index 0)
                partition[1] = 2; // YES position (index 1)
                
                // Approve CTF to burn our tokens
                ctf.setApprovalForAll(address(ctf), true);
                
                // Merge positions to get USDC back
                // Use the minimum of available balances to avoid overflow
                uint256 mergeAmount = parsedOrders[i].shares;
                if (adapterYesBalance < mergeAmount) {
                    mergeAmount = adapterYesBalance;
                }
                
                ctf.mergePositions(
                    address(usdc),
                    bytes32(0), // parentCollectionId
                    questionId,
                    partition,
                    mergeAmount
                );
                
                // Now we have USDC from the merge operation
                // USDC TO pay to the seller
                uint256 usdcToPay = parsedOrders[i].payUSDC;
                totalVaultUSDC += parsedOrders[i].usdcToReturn;
                
                // Transfer USDC to seller
                usdc.transfer(parsedOrders[i].maker, usdcToPay);
            }
        }
        return totalVaultUSDC;
    }
    
    function _distributeYesTokens(
        Parsed[] memory parsedOrders,
        bytes32 marketId
    ) internal {
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == SIDE_BUY) {
                // Each buyer ordered a specific YES token for a specific question
                uint256 buyerShares = parsedOrders[i].shares;
                uint8 qIndex = parsedOrders[i].qIndex;
                
                // Get the YES token position ID for this specific question
                bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, qIndex);
                uint256 yesPositionId = neg.getPositionId(questionId, true);
                
                // Debug: Check if we have valid position IDs
                require(yesPositionId != 0, "Invalid position ID");
                
                // Check if the adapter has enough YES tokens to distribute
                uint256 adapterBalance = ctf.balanceOf(address(this), yesPositionId);
                
                // Debug: Log the position ID and balance
                require(adapterBalance > 0, "Adapter has no YES tokens for this position");
                
                // Calculate the actual amount to distribute (considering fees)
                // The adapter might have slightly less than buyerShares due to fees
                uint256 amountToDistribute = adapterBalance >= buyerShares ? buyerShares : adapterBalance;
                
                if (amountToDistribute > 0) {
                    // Transfer the specific YES token to the buyer
                    ctf.safeTransferFrom(
                        address(this),
                        parsedOrders[i].maker,
                        yesPositionId,
                        amountToDistribute,
                        ""
                    );
                }
            }
        }
    }
    
    function _collectBuyerUSDC(Parsed[] memory parsedOrders) internal {
        for (uint256 i = 0; i < parsedOrders.length; i++) {
            if (parsedOrders[i].side == SIDE_BUY) {
                // For buy orders, we need to collect USDC from the buyer
                uint256 usdcAmount = parsedOrders[i].payUSDC;
                
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
        if (fillAmount == 0 || fillAmount > order.makerAmount) {
            revert InvalidFillAmount();
        }
        
        // In production, the tokenId should be the actual position ID that the user wants to trade
        // We need to determine which question this position belongs to by checking all possible questions
        uint8 qIndex = _getQuestionIndexFromPositionId(order.tokenId, marketId);
        
        // Validate side (only BUY-YES and SELL-NO supported)
        if (order.side == SIDE_BUY) {
            // BUY orders are supported
        } else if (order.side == SIDE_SELL) {
            // SELL orders are supported
        } else {
            revert SideNotSupported();
        }
        
        // Validate price (must be <= 1)
        if (order.order.price > ONE) {
            revert PriceOutOfRange();
        }
        
        uint256 shares = fillAmount;
        uint256 priceQ18 = order.order.price;
        uint256 payUSDC = (shares * priceQ18) / ONE;
        uint256 usdcToReturn = (order.side == SIDE_SELL) ? ((ONE - priceQ18) * shares) / ONE : 0;
        
        return Parsed({
            maker: order.order.maker,
            side: order.side,
            tokenId: order.tokenId,
            shares: shares,
            priceQ18: priceQ18,
            payUSDC: payUSDC,
            usdcToReturn: usdcToReturn,
            qIndex: qIndex
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
