// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CrossMatchingAdapter} from "src/CrossMatchingAdapter.sol";
import {ICrossMatchingAdapter} from "src/interfaces/ICrossMatchingAdapter.sol";
import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
import {NegRiskOperator} from "src/NegRiskOperator.sol";
import {RevNegRiskAdapter} from "src/RevNegRiskAdapter.sol";
import {IRevNegRiskAdapter} from "src/interfaces/IRevNegRiskAdapter.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";
import {ICTFExchange} from "src/interfaces/ICTFExchange.sol";
import {CTFExchange} from "lib/ctf-exchange/src/exchange/CTFExchange.sol";
import {Side, SignatureType, Order, Intent, OrderIntent} from "lib/ctf-exchange/src/exchange/libraries/OrderStructs.sol";

import {Deployer} from "lib/ctf-exchange/src/dev/util/Deployer.sol";
import {TestHelper} from "lib/ctf-exchange/src/dev/TestHelper.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";

/// @title CrossMatchingAdapterFeeForwardingTest
/// @notice Tests that fees from ctfExchange.matchOrders are properly forwarded to the vault
/// @dev Tests all 4 scenarios:
///      1. Taker BUY + Maker SELL (COMPLEMENTARY) - fees in taker's tokenId + USDC
///      2. Taker SELL + Maker BUY (COMPLEMENTARY) - fees in USDC + maker's tokenId
///      3. Taker BUY + Maker BUY (MINT) - fees in BOTH tokenIds
///      4. Taker SELL + Maker SELL (MERGE) - fees only in USDC
contract CrossMatchingAdapterFeeForwardingTest is Test, TestHelper {
    CrossMatchingAdapter public adapter;
    NegRiskAdapter public negRiskAdapter;
    NegRiskOperator public negRiskOperator;
    RevNegRiskAdapter public revNegRiskAdapter;
    CTFExchange public ctfExchange;
    IConditionalTokens public ctf;
    IERC20 public usdc;
    address public vault;

    address public oracle;
    
    // Test users
    address public user1;
    address public user2;
    address public user3;
    
    // Private keys for signing
    uint256 internal _user1PK = 0x1111;
    uint256 internal _user2PK = 0x2222;
    uint256 internal _user3PK = 0x3333;

    // Market and question IDs
    bytes32 public marketId;
    bytes32 public questionId;
    
    // Position IDs for YES/NO tokens
    uint256 public yesPositionId;
    uint256 public noPositionId;

    uint256[] public dummyPayout;
    
    // Fee rate for testing (100 bps = 1%)
    uint256 constant FEE_RATE_BPS = 100;

    function setUp() public {
        dummyPayout = [0, 1];
        oracle = vm.createWallet("oracle").addr;
        
        // Deploy mock USDC
        usdc = IERC20(address(new MockUSDC()));
        vm.label(address(usdc), "USDC");
        
        // Deploy ConditionalTokens
        ctf = IConditionalTokens(Deployer.ConditionalTokens());
        vm.label(address(ctf), "ConditionalTokens");
        
        // Deploy vault
        vault = address(new MockVault());
        vm.label(vault, "Vault");

        // Deploy NegRiskAdapter
        negRiskAdapter = new NegRiskAdapter(address(ctf), address(usdc), vault);
        negRiskOperator = new NegRiskOperator(address(negRiskAdapter));
        negRiskOperator.setOracle(address(oracle));
        vm.label(address(negRiskOperator), "NegRiskOperator");
        vm.label(address(negRiskAdapter), "NegRiskAdapter");

        // Deploy CTFExchange
        ctfExchange = new CTFExchange(address(usdc), address(negRiskAdapter), address(0), address(0));
        vm.label(address(ctfExchange), "CTFExchange");

        // Deploy RevNegRiskAdapter
        revNegRiskAdapter = new RevNegRiskAdapter(address(ctf), address(usdc), vault, INegRiskAdapter(address(negRiskAdapter)));
        vm.label(address(revNegRiskAdapter), "RevNegRiskAdapter");
        
        negRiskAdapter.addAdmin(address(ctfExchange));

        vm.startPrank(address(ctfExchange));
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        ctf.setApprovalForAll(address(ctfExchange), true);
        vm.stopPrank();

        // Deploy CrossMatchingAdapter
        adapter = new CrossMatchingAdapter(negRiskOperator, ICTFExchange(address(ctfExchange)), IRevNegRiskAdapter(address(revNegRiskAdapter)));
        vm.label(address(adapter), "CrossMatchingAdapter");

        vm.startPrank(address(negRiskAdapter));
        ctf.setApprovalForAll(address(ctfExchange), true);
        negRiskAdapter.wcol().addOwner(address(revNegRiskAdapter));
        negRiskAdapter.wcol().addOwner(address(adapter));
        vm.stopPrank();

        // Setup vault with USDC
        MockUSDC(address(usdc)).mint(address(vault), 1000000000e6);
        vm.startPrank(address(vault));
        MockUSDC(address(usdc)).approve(address(adapter), type(uint256).max);
        vm.stopPrank();

        // Set up test users
        user1 = vm.addr(_user1PK);
        user2 = vm.addr(_user2PK);
        user3 = vm.addr(_user3PK);
        vm.label(user1, "User1");
        vm.label(user2, "User2");
        vm.label(user3, "User3");
        
        // Set up market and question
        marketId = negRiskOperator.prepareMarket(0, "Test Market");
        questionId = negRiskOperator.prepareQuestion(marketId, "Test Question", 0);
        yesPositionId = negRiskAdapter.getPositionId(questionId, true);
        noPositionId = negRiskAdapter.getPositionId(questionId, false);
        
        // Set up users
        _setupUser(user1, 100000000e6);
        _setupUser(user2, 100000000e6);
        _setupUser(user3, 100000000e6);
        
        // Register tokens
        ctfExchange.registerToken(yesPositionId, noPositionId, negRiskAdapter.getConditionId(questionId), questionId);
        
        // Set adapter as operator
        ctfExchange.addOperator(address(adapter));
        
        ctf.setApprovalForAll(address(ctfExchange), true);
    }
    
    function _setupUser(address user, uint256 usdcBalance) internal {
        vm.startPrank(user);
        deal(address(usdc), user, usdcBalance);
        usdc.approve(address(adapter), type(uint256).max);
        usdc.approve(address(ctfExchange), type(uint256).max);
        ctf.setApprovalForAll(address(ctfExchange), true);
        ctf.setApprovalForAll(address(adapter), true);
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        vm.stopPrank();
    }
    
    function _mintTokensToUser(address user, uint256 tokenId, uint256 amount) internal {
        dealERC1155(address(ctf), user, tokenId, amount);
    }

    function _createAndSignOrderWithFee(
        address maker,
        uint256 tokenId,
        uint8 side,
        uint256 makerAmount,
        uint256 takerAmount,
        bytes32 questionIdParam,
        uint8 intent,
        uint256 feeRateBps,
        uint256 privateKey
    ) internal returns (OrderIntent memory) {
        (uint256 price, uint256 quantity) = _calculatePriceAndQuantity(side, makerAmount, takerAmount, intent);
        
        Order memory order = _buildOrder(maker, tokenId, price, quantity, questionIdParam, intent, feeRateBps);
        order.signature = _signMessage(privateKey, ctfExchange.hashOrder(order));
        
        return OrderIntent({
            tokenId: tokenId,
            side: Side(side),
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            order: order
        });
    }

    function _calculatePriceAndQuantity(
        uint8 side,
        uint256 makerAmount,
        uint256 takerAmount,
        uint8 intent
    ) internal pure returns (uint256 price, uint256 quantity) {
        if (side == uint8(Side.BUY)) {
            price = (makerAmount * 1e6) / takerAmount;
            quantity = takerAmount;
        } else {
            price = (takerAmount * 1e6) / makerAmount;
            quantity = makerAmount;
        }

        bool isYes = _determineIsYes(side, intent);
        if (!isYes) {
            price = 1e6 - price;
        }
    }

    function _determineIsYes(uint8 side, uint8 intent) internal pure returns (bool) {
        if (intent == uint8(Intent.LONG)) {
            return side == uint8(Side.BUY);
        } else {
            return side == uint8(Side.SELL);
        }
    }

    function _buildOrder(
        address maker,
        uint256 tokenId,
        uint256 price,
        uint256 quantity,
        bytes32 questionIdParam,
        uint8 intent,
        uint256 feeRateBps
    ) internal view returns (Order memory) {
        return Order({
            salt: uint256(keccak256(abi.encodePacked(maker, block.timestamp, tokenId))),
            signer: maker,
            maker: maker,
            taker: address(0),
            price: price,
            quantity: quantity,
            expiration: 0,
            nonce: 0,
            feeRateBps: feeRateBps,
            questionId: questionIdParam,
            intent: Intent(intent),
            signatureType: SignatureType.EOA,
            signature: new bytes(0)
        });
    }
    
    function _signMessage(uint256 pk, bytes32 message) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, message);
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice Calculate expected fee using the same formula as CTFExchange
    /// @dev Fee formula: baseRate * min(price, 1-price) * outcomeTokens / (price * BPS_DIVISOR) for BUY
    ///                   baseRate * min(price, 1-price) * outcomeTokens / (BPS_DIVISOR * ONE) for SELL
    ///      Then multiplied by feeRatio/BPS_DIVISOR
    function _calculateExpectedFee(
        uint256 feeRateBps,
        uint256 outcomeTokens,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side,
        uint256 feeRatio
    ) internal pure returns (uint256 fee) {
        uint256 ONE = 1e18;
        uint256 BPS_DIVISOR = 10_000;
        
        // Calculate price based on side
        uint256 price;
        if (side == Side.BUY) {
            price = takerAmount != 0 ? makerAmount * ONE / takerAmount : 0;
        } else {
            price = makerAmount != 0 ? takerAmount * ONE / makerAmount : 0;
        }
        
        if (feeRateBps > 0 && price > 0 && price <= ONE) {
            uint256 minPrice = price < ONE - price ? price : ONE - price;
            
            if (side == Side.BUY) {
                // Fee charged on Token Proceeds
                fee = (feeRateBps * minPrice * outcomeTokens) / (price * BPS_DIVISOR);
            } else {
                // Fee charged on Collateral proceeds
                fee = feeRateBps * minPrice * outcomeTokens / (BPS_DIVISOR * ONE);
            }
            
            // Apply fee ratio
            fee = fee * feeRatio / BPS_DIVISOR;
        }
    }

    /// @notice Test Case 1: Taker BUY + Maker SELL (COMPLEMENTARY)
    /// Fees: Taker fee in CTF tokens (YES), Maker fee in USDC
    function testFeeForwarding_TakerBuy_MakerSell() public {
        console2.log("=== Test Case 1: Taker BUY + Maker SELL (COMPLEMENTARY) ===");
        
        // Order parameters
        uint256 makerTokenAmount = 1e6;      // tokens being sold
        uint256 makerUsdcAmount = 0.6e6;     // USDC to receive
        uint256 takerUsdcAmount = 0.6e6;     // USDC to pay
        uint256 takerTokenAmount = 1e6;      // tokens to receive
        
        // Mint YES tokens to user1 (maker/seller)
        _mintTokensToUser(user1, yesPositionId, 10e6);
        
        // Create maker order: SELL YES tokens at 0.6 price
        ICrossMatchingAdapter.MakerOrder[] memory makerOrders = new ICrossMatchingAdapter.MakerOrder[](1);
        uint256[] memory takerFillAmounts = new uint256[](1);
        
        makerOrders[0].orders = new OrderIntent[](1);
        makerOrders[0].orders[0] = _createAndSignOrderWithFee(
            user1,
            yesPositionId,
            uint8(Side.SELL),
            makerTokenAmount,
            makerUsdcAmount,
            questionId,
            uint8(Intent.SHORT),
            FEE_RATE_BPS,
            _user1PK
        );
        makerOrders[0].orderType = ICrossMatchingAdapter.OrderType.SINGLE;
        makerOrders[0].makerFillAmounts = new uint256[](1);
        makerOrders[0].makerFillAmounts[0] = makerTokenAmount;
        takerFillAmounts[0] = takerUsdcAmount;
        
        // Create taker order: BUY YES tokens at 0.6 price
        OrderIntent memory takerOrder = _createAndSignOrderWithFee(
            user2,
            yesPositionId,
            uint8(Side.BUY),
            takerUsdcAmount,
            takerTokenAmount,
            questionId,
            uint8(Intent.LONG),
            FEE_RATE_BPS,
            _user2PK
        );
        
        // Calculate expected fees
        // Maker fee (SELL order): charged in USDC, uses FEE_RATIO (3333)
        uint256 expectedMakerFee = _calculateExpectedFee(
            FEE_RATE_BPS,
            makerTokenAmount,           // outcomeTokens = tokens being sold
            makerTokenAmount,           // makerAmount
            makerUsdcAmount,            // takerAmount
            Side.SELL,
            3333                        // FEE_RATIO for maker
        );
        
        // Taker fee (BUY order): charged in tokens, uses BPS_DIVISOR (10000)
        uint256 expectedTakerFee = _calculateExpectedFee(
            FEE_RATE_BPS,
            takerTokenAmount,           // outcomeTokens = tokens being received
            takerUsdcAmount,            // makerAmount
            takerTokenAmount,           // takerAmount
            Side.BUY,
            10000                       // BPS_DIVISOR for taker
        );
        
        console2.log("Expected maker fee (USDC):", expectedMakerFee);
        console2.log("Expected taker fee (YES tokens):", expectedTakerFee);
        
        // Record initial balances
        uint256 initialVaultUSDC = usdc.balanceOf(vault);
        uint256 initialVaultYES = ctf.balanceOf(vault, yesPositionId);
        
        // Execute hybrid match
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmounts, 1);
        
        // Verify adapter has no remaining tokens (fees forwarded)
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
        assertEq(ctf.balanceOf(address(adapter), yesPositionId), 0, "Adapter should have no remaining YES tokens");
        
        // Calculate actual fees received by vault
        uint256 actualUsdcFee = usdc.balanceOf(vault) - initialVaultUSDC;
        uint256 actualTokenFee = ctf.balanceOf(vault, yesPositionId) - initialVaultYES;
        
        console2.log("Actual USDC fee forwarded to vault:", actualUsdcFee);
        console2.log("Actual YES token fee forwarded to vault:", actualTokenFee);
        
        // Verify exact fee amounts
        assertEq(actualUsdcFee, expectedMakerFee, "USDC fee should match expected maker fee");
        assertEq(actualTokenFee, expectedTakerFee, "YES token fee should match expected taker fee");
        
        // Verify fees are non-zero (sanity check)
        assertTrue(actualUsdcFee > 0, "USDC fee should be greater than 0");
        assertTrue(actualTokenFee > 0, "Token fee should be greater than 0");
        
        console2.log("Test Case 1 PASSED: Exact fees verified and forwarded correctly");
    }

    /// @notice Test Case 2: Taker SELL + Maker BUY (COMPLEMENTARY)
    /// Fees: Taker fee in USDC, Maker fee in CTF tokens (YES)
    function testFeeForwarding_TakerSell_MakerBuy() public {
        console2.log("=== Test Case 2: Taker SELL + Maker BUY (COMPLEMENTARY) ===");
        
        // Order parameters
        uint256 makerUsdcAmount = 0.6e6;     // USDC to pay
        uint256 makerTokenAmount = 1e6;      // tokens to receive
        uint256 takerTokenAmount = 1e6;      // tokens being sold
        uint256 takerUsdcAmount = 0.6e6;     // USDC to receive
        
        // Mint YES tokens to user2 (taker/seller)
        _mintTokensToUser(user2, yesPositionId, 10e6);
        
        // Create maker order: BUY YES tokens at 0.6 price
        ICrossMatchingAdapter.MakerOrder[] memory makerOrders = new ICrossMatchingAdapter.MakerOrder[](1);
        uint256[] memory takerFillAmounts = new uint256[](1);
        
        makerOrders[0].orders = new OrderIntent[](1);
        makerOrders[0].orders[0] = _createAndSignOrderWithFee(
            user1,
            yesPositionId,
            uint8(Side.BUY),
            makerUsdcAmount,
            makerTokenAmount,
            questionId,
            uint8(Intent.LONG),
            FEE_RATE_BPS,
            _user1PK
        );
        makerOrders[0].orderType = ICrossMatchingAdapter.OrderType.SINGLE;
        makerOrders[0].makerFillAmounts = new uint256[](1);
        makerOrders[0].makerFillAmounts[0] = makerUsdcAmount;
        takerFillAmounts[0] = takerTokenAmount;
        
        // Create taker order: SELL YES tokens at 0.6 price
        OrderIntent memory takerOrder = _createAndSignOrderWithFee(
            user2,
            yesPositionId,
            uint8(Side.SELL),
            takerTokenAmount,
            takerUsdcAmount,
            questionId,
            uint8(Intent.SHORT),
            FEE_RATE_BPS,
            _user2PK
        );
        
        // Calculate expected fees
        // Maker fee (BUY order): charged in tokens, uses FEE_RATIO (3333)
        uint256 expectedMakerFee = _calculateExpectedFee(
            FEE_RATE_BPS,
            makerTokenAmount,           // outcomeTokens = tokens being received
            makerUsdcAmount,            // makerAmount
            makerTokenAmount,           // takerAmount
            Side.BUY,
            3333                        // FEE_RATIO for maker
        );
        
        // Taker fee (SELL order): charged in USDC, uses BPS_DIVISOR (10000)
        uint256 expectedTakerFee = _calculateExpectedFee(
            FEE_RATE_BPS,
            takerTokenAmount,           // outcomeTokens = tokens being sold
            takerTokenAmount,           // makerAmount
            takerUsdcAmount,            // takerAmount
            Side.SELL,
            10000                       // BPS_DIVISOR for taker
        );
        
        console2.log("Expected maker fee (YES tokens): ", expectedMakerFee);
        console2.log("Expected taker fee (USDC): ", expectedTakerFee);
        
        // Record initial balances
        uint256 initialVaultUSDC = usdc.balanceOf(vault);
        uint256 initialVaultYES = ctf.balanceOf(vault, yesPositionId);
        
        // Execute hybrid match
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmounts, 1);
        
        // Verify adapter has no remaining tokens
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
        assertEq(ctf.balanceOf(address(adapter), yesPositionId), 0, "Adapter should have no remaining YES tokens");
        
        // Calculate actual fees received by vault
        uint256 actualUsdcFee = usdc.balanceOf(vault) - initialVaultUSDC;
        uint256 actualTokenFee = ctf.balanceOf(vault, yesPositionId) - initialVaultYES;
        
        console2.log("Actual USDC fee forwarded to vault: ", actualUsdcFee);
        console2.log("Actual YES token fee forwarded to vault: ", actualTokenFee);
        
        // Verify exact fee amounts
        assertEq(actualUsdcFee, expectedTakerFee, "USDC fee should match expected taker fee");
        assertEq(actualTokenFee, expectedMakerFee, "YES token fee should match expected maker fee");
        
        // Verify fees are non-zero (sanity check)
        assertTrue(actualUsdcFee > 0, "USDC fee should be greater than 0");
        assertTrue(actualTokenFee > 0, "Token fee should be greater than 0");
        
        console2.log("Test Case 2 PASSED: Exact fees verified and forwarded correctly");
    }

    /// @notice Test Case 3: Taker BUY NO + Maker SELL NO (COMPLEMENTARY on NO tokens)
    /// Fees: Taker fee in NO tokens, Maker fee in USDC
    function testFeeForwarding_TakerBuyNO_MakerSellNO() public {
        console2.log("=== Test Case 3: Taker BUY NO + Maker SELL NO (COMPLEMENTARY) ===");
        
        // Order parameters - price at 0.4 for NO tokens
        uint256 makerTokenAmount = 1e6;      // NO tokens being sold
        uint256 makerUsdcAmount = 0.4e6;     // USDC to receive
        uint256 takerUsdcAmount = 0.4e6;     // USDC to pay
        uint256 takerTokenAmount = 1e6;      // NO tokens to receive
        
        // Mint NO tokens to maker (seller)
        _mintTokensToUser(user1, noPositionId, 10e6);
        
        // Create maker order: SELL NO tokens at 0.4 price
        ICrossMatchingAdapter.MakerOrder[] memory makerOrders = new ICrossMatchingAdapter.MakerOrder[](1);
        uint256[] memory takerFillAmounts = new uint256[](1);
        
        makerOrders[0].orders = new OrderIntent[](1);
        makerOrders[0].orders[0] = _createAndSignOrderWithFee(
            user1,
            noPositionId,
            uint8(Side.SELL),
            makerTokenAmount,
            makerUsdcAmount,
            questionId,
            uint8(Intent.LONG),
            FEE_RATE_BPS,
            _user1PK
        );
        makerOrders[0].orderType = ICrossMatchingAdapter.OrderType.SINGLE;
        makerOrders[0].makerFillAmounts = new uint256[](1);
        makerOrders[0].makerFillAmounts[0] = makerTokenAmount;
        takerFillAmounts[0] = takerUsdcAmount;
        
        // Create taker order: BUY NO tokens at 0.4 price
        OrderIntent memory takerOrder = _createAndSignOrderWithFee(
            user2,
            noPositionId,
            uint8(Side.BUY),
            takerUsdcAmount,
            takerTokenAmount,
            questionId,
            uint8(Intent.SHORT),
            FEE_RATE_BPS,
            _user2PK
        );
        
        // Calculate expected fees
        // Maker fee (SELL order): charged in USDC, uses FEE_RATIO (3333)
        uint256 expectedMakerFee = _calculateExpectedFee(
            FEE_RATE_BPS,
            makerTokenAmount,
            makerTokenAmount,
            makerUsdcAmount,
            Side.SELL,
            3333
        );
        
        // Taker fee (BUY order): charged in tokens, uses BPS_DIVISOR (10000)
        uint256 expectedTakerFee = _calculateExpectedFee(
            FEE_RATE_BPS,
            takerTokenAmount,
            takerUsdcAmount,
            takerTokenAmount,
            Side.BUY,
            10000
        );
        
        console2.log("Expected maker fee (USDC): ", expectedMakerFee);
        console2.log("Expected taker fee (NO tokens): ", expectedTakerFee);
        
        // Record initial balances
        uint256 initialVaultUSDC = usdc.balanceOf(vault);
        uint256 initialVaultNO = ctf.balanceOf(vault, noPositionId);
        
        // Execute hybrid match
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmounts, 1);
        
        // Verify adapter has no remaining tokens
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
        assertEq(ctf.balanceOf(address(adapter), noPositionId), 0, "Adapter should have no remaining NO tokens");
        
        // Calculate actual fees received by vault
        uint256 actualUsdcFee = usdc.balanceOf(vault) - initialVaultUSDC;
        uint256 actualTokenFee = ctf.balanceOf(vault, noPositionId) - initialVaultNO;
        
        console2.log("Actual USDC fee forwarded to vault: ", actualUsdcFee);
        console2.log("Actual NO token fee forwarded to vault: ", actualTokenFee);
        
        // Verify exact fee amounts
        assertEq(actualUsdcFee, expectedMakerFee, "USDC fee should match expected maker fee");
        assertEq(actualTokenFee, expectedTakerFee, "NO token fee should match expected taker fee");
        
        // Verify fees are non-zero
        assertTrue(actualUsdcFee > 0, "USDC fee should be greater than 0");
        assertTrue(actualTokenFee > 0, "Token fee should be greater than 0");
        
        console2.log("Test Case 3 PASSED: Exact fees verified and forwarded correctly");
    }

    /// @notice Test Case 4: Taker SELL NO + Maker BUY NO (COMPLEMENTARY on NO tokens)
    /// Fees: Taker fee in USDC, Maker fee in NO tokens
    function testFeeForwarding_TakerSellNO_MakerBuyNO() public {
        console2.log("=== Test Case 4: Taker SELL NO + Maker BUY NO (COMPLEMENTARY) ===");
        
        // Order parameters - price at 0.4 for NO tokens
        uint256 makerUsdcAmount = 0.4e6;     // USDC to pay
        uint256 makerTokenAmount = 1e6;      // NO tokens to receive
        uint256 takerTokenAmount = 1e6;      // NO tokens being sold
        uint256 takerUsdcAmount = 0.4e6;     // USDC to receive
        
        // Mint NO tokens to taker (seller)
        _mintTokensToUser(user2, noPositionId, 10e6);
        
        // Create maker order: BUY NO tokens at 0.4 price
        ICrossMatchingAdapter.MakerOrder[] memory makerOrders = new ICrossMatchingAdapter.MakerOrder[](1);
        uint256[] memory takerFillAmounts = new uint256[](1);
        
        makerOrders[0].orders = new OrderIntent[](1);
        makerOrders[0].orders[0] = _createAndSignOrderWithFee(
            user1,
            noPositionId,
            uint8(Side.BUY),
            makerUsdcAmount,
            makerTokenAmount,
            questionId,
            uint8(Intent.SHORT),
            FEE_RATE_BPS,
            _user1PK
        );
        makerOrders[0].orderType = ICrossMatchingAdapter.OrderType.SINGLE;
        makerOrders[0].makerFillAmounts = new uint256[](1);
        makerOrders[0].makerFillAmounts[0] = makerUsdcAmount;
        takerFillAmounts[0] = takerTokenAmount;
        
        // Create taker order: SELL NO tokens at 0.4 price
        OrderIntent memory takerOrder = _createAndSignOrderWithFee(
            user2,
            noPositionId,
            uint8(Side.SELL),
            takerTokenAmount,
            takerUsdcAmount,
            questionId,
            uint8(Intent.LONG),
            FEE_RATE_BPS,
            _user2PK
        );
        
        // Calculate expected fees
        // Maker fee (BUY order): charged in tokens, uses FEE_RATIO (3333)
        uint256 expectedMakerFee = _calculateExpectedFee(
            FEE_RATE_BPS,
            makerTokenAmount,
            makerUsdcAmount,
            makerTokenAmount,
            Side.BUY,
            3333
        );
        
        // Taker fee (SELL order): charged in USDC, uses BPS_DIVISOR (10000)
        uint256 expectedTakerFee = _calculateExpectedFee(
            FEE_RATE_BPS,
            takerTokenAmount,
            takerTokenAmount,
            takerUsdcAmount,
            Side.SELL,
            10000
        );
        
        console2.log("Expected maker fee (NO tokens): ", expectedMakerFee);
        console2.log("Expected taker fee (USDC): ", expectedTakerFee);
        
        // Record initial balances
        uint256 initialVaultUSDC = usdc.balanceOf(vault);
        uint256 initialVaultNO = ctf.balanceOf(vault, noPositionId);
        
        // Execute hybrid match
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmounts, 1);
        
        // Verify adapter has no remaining tokens
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
        assertEq(ctf.balanceOf(address(adapter), noPositionId), 0, "Adapter should have no remaining NO tokens");
        
        // Calculate actual fees received by vault
        uint256 actualUsdcFee = usdc.balanceOf(vault) - initialVaultUSDC;
        uint256 actualTokenFee = ctf.balanceOf(vault, noPositionId) - initialVaultNO;
        
        console2.log("Actual USDC fee forwarded to vault: ", actualUsdcFee);
        console2.log("Actual NO token fee forwarded to vault: ", actualTokenFee);
        
        // Verify exact fee amounts
        assertEq(actualUsdcFee, expectedTakerFee, "USDC fee should match expected taker fee");
        assertEq(actualTokenFee, expectedMakerFee, "NO token fee should match expected maker fee");
        
        // Verify fees are non-zero
        assertTrue(actualUsdcFee > 0, "USDC fee should be greater than 0");
        assertTrue(actualTokenFee > 0, "Token fee should be greater than 0");
        
        console2.log("Test Case 4 PASSED: Exact fees verified and forwarded correctly");
    }

    /// @notice Test with multiple makers to ensure all fees are forwarded
    function testFeeForwarding_MultipleMakers() public {
        console2.log("=== Test: Multiple Makers Fee Forwarding ===");
        
        // Order parameters - each maker sells 1M tokens at 0.6 price
        uint256 makerTokenAmount = 1e6;
        uint256 makerUsdcAmount = 0.6e6;
        uint256 takerTotalUsdcAmount = 1.2e6;  // Buying from 2 makers
        uint256 takerTotalTokenAmount = 2e6;   // Total 2M tokens
        
        // Mint YES tokens to makers (sellers)
        _mintTokensToUser(user1, yesPositionId, 10e6);
        _mintTokensToUser(user3, yesPositionId, 10e6);
        
        // Create 2 maker orders: both SELL YES tokens
        ICrossMatchingAdapter.MakerOrder[] memory makerOrders = new ICrossMatchingAdapter.MakerOrder[](2);
        uint256[] memory takerFillAmounts = new uint256[](2);
        
        // Maker 1 - SELL YES token
        makerOrders[0].orders = new OrderIntent[](1);
        makerOrders[0].orders[0] = _createAndSignOrderWithFee(
            user1,
            yesPositionId,
            uint8(Side.SELL),
            makerTokenAmount,
            makerUsdcAmount,
            questionId,
            uint8(Intent.SHORT),
            FEE_RATE_BPS,
            _user1PK
        );
        makerOrders[0].orderType = ICrossMatchingAdapter.OrderType.SINGLE;
        makerOrders[0].makerFillAmounts = new uint256[](1);
        makerOrders[0].makerFillAmounts[0] = makerTokenAmount;
        takerFillAmounts[0] = makerUsdcAmount;
        
        // Maker 2 - SELL YES token
        makerOrders[1].orders = new OrderIntent[](1);
        makerOrders[1].orders[0] = _createAndSignOrderWithFee(
            user3,
            yesPositionId,
            uint8(Side.SELL),
            makerTokenAmount,
            makerUsdcAmount,
            questionId,
            uint8(Intent.SHORT),
            FEE_RATE_BPS,
            _user3PK
        );
        makerOrders[1].orderType = ICrossMatchingAdapter.OrderType.SINGLE;
        makerOrders[1].makerFillAmounts = new uint256[](1);
        makerOrders[1].makerFillAmounts[0] = makerTokenAmount;
        takerFillAmounts[1] = makerUsdcAmount;
        
        // Create taker order: BUY YES tokens
        OrderIntent memory takerOrder = _createAndSignOrderWithFee(
            user2,
            yesPositionId,
            uint8(Side.BUY),
            takerTotalUsdcAmount,
            takerTotalTokenAmount,
            questionId,
            uint8(Intent.LONG),
            FEE_RATE_BPS,
            _user2PK
        );
        
        // Calculate expected fees
        // Each maker fee (SELL order): charged in USDC, uses FEE_RATIO (3333)
        uint256 expectedMakerFeeEach = _calculateExpectedFee(
            FEE_RATE_BPS,
            makerTokenAmount,
            makerTokenAmount,
            makerUsdcAmount,
            Side.SELL,
            3333
        );
        uint256 expectedTotalMakerFee = expectedMakerFeeEach * 2;
        
        // Taker fee (BUY order): charged in tokens, uses BPS_DIVISOR (10000)
        uint256 expectedTakerFee = _calculateExpectedFee(
            FEE_RATE_BPS,
            takerTotalTokenAmount,
            takerTotalUsdcAmount,
            takerTotalTokenAmount,
            Side.BUY,
            10000
        );
        
        console2.log("Expected total maker fees (USDC): %s (each: %s)", expectedTotalMakerFee, expectedMakerFeeEach);
        console2.log("Expected taker fee (YES tokens): ", expectedTakerFee);
        
        // Record initial balances
        uint256 initialVaultUSDC = usdc.balanceOf(vault);
        uint256 initialVaultYES = ctf.balanceOf(vault, yesPositionId);
        
        // Execute hybrid match with 2 single orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmounts, 2);
        
        // Verify adapter has no remaining tokens
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
        assertEq(ctf.balanceOf(address(adapter), yesPositionId), 0, "Adapter should have no remaining YES tokens");
        
        // Calculate actual fees received by vault
        uint256 actualUsdcFee = usdc.balanceOf(vault) - initialVaultUSDC;
        uint256 actualTokenFee = ctf.balanceOf(vault, yesPositionId) - initialVaultYES;
        
        console2.log("Actual USDC fee forwarded to vault: ", actualUsdcFee);
        console2.log("Actual YES token fee forwarded to vault: ", actualTokenFee);
        
        // Verify exact fee amounts
        assertEq(actualUsdcFee, expectedTotalMakerFee, "USDC fee should match expected total maker fees");
        assertEq(actualTokenFee, expectedTakerFee, "YES token fee should match expected taker fee");
        
        // Verify fees are non-zero
        assertTrue(actualUsdcFee > 0, "USDC fee should be greater than 0");
        assertTrue(actualTokenFee > 0, "Token fee should be greater than 0");
        
        console2.log("Multiple makers test PASSED: Exact fees verified and forwarded correctly");
    }
}

// Mock USDC contract
contract MockUSDC {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

// Mock Vault contract that can receive ERC1155 tokens
contract MockVault {
    mapping(address => uint256) public balanceOf;
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // ERC1155 receiver implementation
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
