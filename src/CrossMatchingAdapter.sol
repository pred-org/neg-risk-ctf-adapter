// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {INegRiskAdapter} from "./interfaces/INegRiskAdapter.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";

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
      Order order;
    }

    struct Order {
        uint256 salt;
        address maker;       // funder (USDC for BUY, NO for SELL)
        address signer;
        address taker;       // unused here
        uint256 tokenId;     // CTF ERC1155 id (YES or NO)
        uint256 price;       // USDC per share (fixed-point 18 decimals)
        uint256 quantity;    // number of shares to trade
        uint256 expiration;
        uint256 nonce;
        uint256 feeRateBps;
        uint8   intent; // 0 = LONG, 1 = SHORT
        uint8   signatureType;
        bytes   signature;
    }
}

contract CrossMatchingAdapter is ReentrancyGuard {
    // constants
    uint8    constant SIDE_BUY  = 0;
    uint8    constant SIDE_SELL = 1;
    bytes32  constant PARENT = bytes32(0);
    uint256  constant ONE = 1e18; // fixed-point for price

    INegRiskAdapter public immutable neg;
    IConditionalTokens public immutable ctf;
    WrappedCollateral public immutable wcol; // wrapped USDC
    IERC20 public immutable usdc;

    uint256[] internal PARTITION; // [YES, NO] = [1,2]
    uint256   constant PIVOT_INDEX_BIT = 1; // index 0 -> bit 1

    constructor(INegRiskAdapter neg_, IERC20 usdc_) {
        neg  = neg_;
        ctf  = IConditionalTokens(neg_.ctf());
        wcol = WrappedCollateral(neg_.wcol());
        usdc = usdc_;
        PARTITION = new uint256[](2);
        PARTITION[0] = 1; // YES
        PARTITION[1] = 2; // NO
    }

    event CrossMatched(
        bytes32 indexed marketId,
        uint256 pivotSplitUSDC,
        uint256 convertedNO0,
        uint256 totalBuyerDeposit,
        uint256 totalSellerPayout,
        uint256 residualToSolver
    );

    error UnsupportedToken();      // order.tokenId not recognized as YES (buy) or NO (sell)
    error SideNotSupported();      // only BUY-YES and SELL-NO supported in this adapter
    error PriceOutOfRange();       // price must be ≤ 1
    error BootstrapShortfall();    // not enough buyer USDC to bootstrap pivot split
    error SupplyInvariant();       // insufficient YES supply computed
    error NotSelfFinancing();      // net WCOL minted (!= 0) after operations

    struct Parsed {
        address maker;
        uint8   side;
        uint256 tokenId;
        uint256 shares;     // derived
        uint256 priceQ18;   // USDC/share (≤ 1e18)
        uint256 payUSDC;    // = shares * price
        uint8   qIndex;     // which question index
    }

    function crossMatchOrders(
        bytes32 marketId,
        ICTFExchange.OrderIntent[] calldata orders
    ) external nonReentrant {
        // ---- 0) Precompute YES/NO ids per question from NegRisk ----
        (bytes32[] memory cond, uint256[] memory YES, uint256[] memory NO) = _precomputeQuestionData(marketId);
        
        // ---- 1) Parse orders, classify, and compute pricing ----
        (Parsed[] memory P, uint256 totalBuyerDeposit, uint256 totalSellerPayout, uint256[] memory needYesBuy, uint256[] memory needYesMerge) = _parseAndClassifyOrders(orders, YES, NO);
        
        // ---- 2) Compute YES supply needed and plan pivot split/convert ----
        (uint256 S, uint256 maxNonPivot) = _computeSupplyNeeded(needYesBuy, needYesMerge);
        
        // Bootstrap safety: we need S USDC on hand to wrap before merges create WCOL.
        if (totalBuyerDeposit < S) revert BootstrapShortfall();
        
        // ---- 3) Pull USDC from BUY makers ----
        _pullBuyerDeposits(P);
        
        // ---- 4) Split on pivot and convert NO0 once ----
        _executePivotOperations(marketId, cond, S, maxNonPivot);
        
        // ---- 5) Deliver YES to BUYers ----
        _deliverYesToBuyers(P);
        
        // ---- 6) Pull NO from SELLers, merge, unwrap, and pay ----
        _processSellerOrders(P, cond);
        
        // ---- 8) Refund residual USDC to solver (who can pro-rata refund buyers off-chain) ----
        uint256 residual = usdc.balanceOf(address(this));
        if (residual > 0) {
            require(usdc.transfer(msg.sender, residual), "residual xfer");
        }

        emit CrossMatched(marketId, S, maxNonPivot, totalBuyerDeposit, totalSellerPayout, residual);
    }

    function _precomputeQuestionData(bytes32 marketId) internal view returns (
        bytes32[] memory cond,
        uint256[] memory YES,
        uint256[] memory NO
    ) {
        uint256 Q = neg.getQuestionCount(marketId);
        require(Q >= 2, "need binary+");
        cond = new bytes32[](Q);
        YES = new uint256[](Q);
        NO = new uint256[](Q);
        for (uint8 i = 0; i < Q; i++) {
            bytes32 qid = _questionId(marketId, i);
            cond[i] = neg.getConditionId(qid);
            YES[i] = neg.getPositionId(qid, true);
            NO[i] = neg.getPositionId(qid, false);
        }
    }

    function _parseAndClassifyOrders(
        ICTFExchange.OrderIntent[] calldata orders,
        uint256[] memory YES,
        uint256[] memory NO
    ) internal pure returns (
        Parsed[] memory P,
        uint256 totalBuyerDeposit,
        uint256 totalSellerPayout,
        uint256[] memory needYesBuy,
        uint256[] memory needYesMerge
    ) {
        P = new Parsed[](orders.length);
        totalBuyerDeposit = 0;
        totalSellerPayout = 0;
        needYesBuy = new uint256[](YES.length);
        needYesMerge = new uint256[](YES.length);

        for (uint256 k = 0; k < orders.length; k++) {
            ICTFExchange.OrderIntent calldata o = orders[k];

            // classify tokenId -> which question and side
            (bool found, uint8 qi, bool isYes) = _classify(o.tokenId, YES, NO);
            if (!found) revert UnsupportedToken();

            Parsed memory x;
            x.maker = o.order.maker;
            x.side = o.side;
            x.tokenId = o.tokenId;
            x.qIndex = qi;

            if (o.side == SIDE_BUY) {
                // BUY must be for YES only in this adapter
                if (!isYes) revert SideNotSupported();
                x.priceQ18 = o.order.price;                                    // USDC/share from order
                if (x.priceQ18 > ONE) revert PriceOutOfRange();
                x.shares = o.order.quantity;                                  // number of YES shares to buy
                x.payUSDC = _mulQ(x.shares, x.priceQ18);
                totalBuyerDeposit += x.payUSDC;
                needYesBuy[qi] += x.shares;
            } else if (o.side == SIDE_SELL) {
                // SELL must be NO in this adapter
                if (isYes) revert SideNotSupported();
                x.priceQ18 = o.order.price;                                    // USDC/share from order
                if (x.priceQ18 > ONE) revert PriceOutOfRange();
                x.shares = o.order.quantity;                                  // number of NO shares to sell
                x.payUSDC = _mulQ(x.shares, x.priceQ18);
                totalSellerPayout += x.payUSDC;
                needYesMerge[qi] += x.shares;                              // we will merge YES+NO
            } else {
                revert SideNotSupported();
            }
            P[k] = x;
        }
    }

    function _computeSupplyNeeded(
        uint256[] memory needYesBuy,
        uint256[] memory needYesMerge
    ) internal pure returns (uint256 S, uint256 maxNonPivot) {
        // For each question i, we need YES_i = buys + merges
        uint256[] memory needYES = new uint256[](needYesBuy.length);
        maxNonPivot = 0;
        for (uint8 i = 0; i < needYesBuy.length; i++) {
            needYES[i] = needYesBuy[i] + needYesMerge[i];
            if (i != 0 && needYES[i] > maxNonPivot) maxNonPivot = needYES[i];
        }
        uint256 pivotNeeded = needYES[0];

        // We must split at least max(pivotNeeded, maxNonPivot) on pivot (index 0).
        // (Split S mints YES0=S and NO0=S; converting NO0=T yields YES_j=T for all j!=0)
        S = pivotNeeded > maxNonPivot ? pivotNeeded : maxNonPivot;
    }

    function _pullBuyerDeposits(Parsed[] memory P) internal {
        for (uint256 k = 0; k < P.length; k++) {
            if (P[k].side == SIDE_BUY) {
                require(usdc.transferFrom(P[k].maker, address(this), P[k].payUSDC), "USDC pull fail");
            }
        }
    }

    function _executePivotOperations(
        bytes32 marketId,
        bytes32[] memory cond,
        uint256 S,
        uint256 maxNonPivot
    ) internal {
        // split S -> YES0 + NO0
        if (S > 0) {
            wcol.wrap(address(this), S);
            ctf.splitPosition(address(wcol), PARENT, cond[0], PARTITION, S);
        }

        // convert NO0 amount = maxNonPivot (we need T YES for all non-pivot questions)
        if (maxNonPivot > 0) {
            neg.convertPositions(marketId, PIVOT_INDEX_BIT, maxNonPivot);
        }

        // sanity supply check
        if (neg.getPositionId(_questionId(marketId, 0), true) == 0) revert SupplyInvariant();
        // YES available by construction:
        //  - YES0: S
        //  - YESj (j>0): maxNonPivot
        // And we ensured S >= pivotNeeded and S >= maxNonPivot
    }

    function _deliverYesToBuyers(Parsed[] memory P) internal {
        for (uint256 k = 0; k < P.length; k++) {
            if (P[k].side == SIDE_BUY) {
                IERC1155(address(ctf)).safeTransferFrom(address(this), P[k].maker, P[k].tokenId, P[k].shares, "");
            }
        }
    }

    function _processSellerOrders(Parsed[] memory P, bytes32[] memory cond) internal {
        for (uint256 k = 0; k < P.length; k++) {
            if (P[k].side == SIDE_SELL) {
                // Pull seller's NO
                IERC1155(address(ctf)).safeTransferFrom(P[k].maker, address(this), P[k].tokenId, P[k].shares, "");
                // Merge YES+NO on that question for 'shares'
                ctf.mergePositions(address(wcol), PARENT, cond[P[k].qIndex], PARTITION, P[k].shares);
                // Unwrap exactly 'shares' (1:1) and pay seller their price*shares (≤ shares)
                wcol.unwrap(address(this), P[k].shares);
                require(usdc.transfer(P[k].maker, P[k].payUSDC), "seller USDC xfer");
                // leftover USDC from this merge (shares - payUSDC) stays to contract residual
            }
        }
    }

    // ------- helpers -------
    /// Derive the per-question ID from marketId and question index.
    /// Per audit note 7.1: marketId has low 8 bits zero; questionId = marketId | index (low 8 bits).
    function _questionId(bytes32 marketId, uint8 index) internal pure returns (bytes32) {
        uint256 base = uint256(marketId) & ~uint256(0xff); // clear low 8 bits just in case
        return bytes32(base | uint256(index));
    }

    function _classify(uint256 tokenId, uint256[] memory YES, uint256[] memory NO)
        private pure
        returns (bool found, uint8 qIndex, bool isYes)
    {
        for (uint8 i=0;i<YES.length;i++){
            if (tokenId == YES[i]) return (true, i, true);
            if (tokenId == NO[i])  return (true, i, false);
        }
        return (false, 0, false);
    }

    function _divQ(uint256 a, uint256 b) private pure returns (uint256) {
        require(b>0,"DIV0"); return (a * ONE) / b;
    }
    function _mulQ(uint256 a, uint256 q) private pure returns (uint256) {
        return (a * q) / ONE;
    }
}
