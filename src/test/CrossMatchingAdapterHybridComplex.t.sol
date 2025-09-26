// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {CrossMatchingAdapter} from "src/CrossMatchingAdapter.sol";
import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
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

contract CrossMatchingAdapterHybridComplexTest is Test, TestHelper {
    CrossMatchingAdapter public adapter;
    NegRiskAdapter public negRiskAdapter;
    RevNegRiskAdapter public revNegRiskAdapter;
    CTFExchange public ctfExchange;
    IConditionalTokens public ctf;
    IERC20 public usdc;
    address public vault;
    
    // Test users
    address public user1;
    address public user2;
    address public user3;
    address public user4;
    address public user5;
    address public user6;
    
    // Private keys for signing
    uint256 internal user1PK = 0x1111;
    uint256 internal user2PK = 0x2222;
    uint256 internal user3PK = 0x3333;
    uint256 internal user4PK = 0x4444;
    uint256 internal user5PK = 0x5555;
    uint256 internal user6PK = 0x6666;

    // Market and question IDs
    bytes32 public marketId;
    bytes32 public questionId;
    
    // Position IDs for YES/NO tokens
    uint256 public yesPositionId;
    uint256 public noPositionId;

    function setUp() public {
        // Deploy mock USDC first
        usdc = IERC20(address(new MockUSDC()));
        vm.label(address(usdc), "USDC");
        
        // Deploy real ConditionalTokens contract using Deployer
        ctf = IConditionalTokens(Deployer.ConditionalTokens());
        vm.label(address(ctf), "ConditionalTokens");

        // Deploy real CTFExchange contract
        ctfExchange = new CTFExchange(address(usdc), address(ctf), address(0), address(0));
        vm.label(address(ctfExchange), "CTFExchange");
        
        // Deploy mock vault
        vault = address(new MockVault());
        vm.label(vault, "Vault");

        // Deploy NegRiskAdapter
        negRiskAdapter = new NegRiskAdapter(address(ctf), address(usdc), vault);
        vm.label(address(negRiskAdapter), "NegRiskAdapter");

        // Deploy RevNegRiskAdapter
        revNegRiskAdapter = new RevNegRiskAdapter(address(ctf), address(usdc), vault, INegRiskAdapter(address(negRiskAdapter)));
        vm.label(address(revNegRiskAdapter), "RevNegRiskAdapter");
        
        // Add RevNegRiskAdapter as owner of WrappedCollateral so it can mint tokens
        // We need to call this from the NegRiskAdapter since it's the owner
        vm.startPrank(address(negRiskAdapter));
        negRiskAdapter.wcol().addOwner(address(revNegRiskAdapter));
        vm.stopPrank();

        // Deploy CrossMatchingAdapter
        adapter = new CrossMatchingAdapter(INegRiskAdapter(address(negRiskAdapter)), IERC20(address(usdc)), ICTFExchange(address(ctfExchange)), IRevNegRiskAdapter(address(revNegRiskAdapter)));
        vm.label(address(adapter), "CrossMatchingAdapter");

        // Setup vault with USDC and approve adapter
        MockUSDC(address(usdc)).mint(address(vault), 1000000000e6);
        vm.startPrank(address(vault));
        MockUSDC(address(usdc)).approve(address(adapter), type(uint256).max);
        vm.stopPrank();

        // Set up test users
        user1 = vm.addr(user1PK);
        user2 = vm.addr(user2PK);
        user3 = vm.addr(user3PK);
        user4 = vm.addr(user4PK);
        user5 = vm.addr(user5PK);
        user6 = vm.addr(user6PK);
        vm.label(user1, "User1");
        vm.label(user2, "User2");
        vm.label(user3, "User3");
        vm.label(user4, "User4");
        vm.label(user5, "User5");
        vm.label(user6, "User6");
        
        // Set up market and question
        marketId = negRiskAdapter.prepareMarket(0, "Test Market");
        questionId = negRiskAdapter.prepareQuestion(marketId, "Test Question");
        yesPositionId = negRiskAdapter.getPositionId(questionId, true);
        noPositionId = negRiskAdapter.getPositionId(questionId, false);
        
        // Set up initial token balances
        _setupUser(user1, 100000000e6);
        _setupUser(user2, 100000000e6);
        _setupUser(user3, 100000000e6);
        _setupUser(user4, 100000000e6);
        _setupUser(user5, 100000000e6);
        _setupUser(user6, 100000000e6);
        
        // Register tokens with CTFExchange
        _registerTokensWithCTFExchange(yesPositionId, noPositionId, negRiskAdapter.getConditionId(questionId));
        
        // Set the CrossMatchingAdapter as an operator for CTFExchange
        vm.prank(address(this));
        ctfExchange.addOperator(address(adapter));
        
        // Set CTFExchange as operator for ConditionalTokens (ERC1155)
        ctf.setApprovalForAll(address(ctfExchange), true);
    }
    
    function _registerTokensWithCTFExchange(uint256 yesTokenId, uint256 noTokenId, bytes32 conditionId) internal {
        ctfExchange.registerToken(yesTokenId, noTokenId, conditionId);
    }
    
    function _setupUser(address user, uint256 usdcBalance) internal {
        vm.startPrank(user);
        deal(address(usdc), user, usdcBalance);
        usdc.approve(address(adapter), type(uint256).max);
        usdc.approve(address(ctfExchange), type(uint256).max);
        ctf.setApprovalForAll(address(ctfExchange), true);
        vm.stopPrank();
    }
    
    function _mintTokensToUser(address user, uint256 tokenId, uint256 amount) internal {
        dealERC1155(address(ctf), user, tokenId, amount);
    }
    
    function _createAndSignOrder(
        address maker,
        uint256 tokenId,
        uint8 side,
        uint256 makerAmount,
        uint256 takerAmount,
        bytes32 questionIdParam,
        uint8 intent,
        uint256 privateKey
    ) internal returns (ICTFExchange.OrderIntent memory) {
        uint256 price;
        uint256 quantity;
        if (side == uint8(ICTFExchange.Side.BUY)) {
            price = (makerAmount * 1e6) / takerAmount;
            quantity = takerAmount;
        } else {
            price = (takerAmount * 1e6) / makerAmount;
            quantity = makerAmount;
        }
        
        ICTFExchange.Order memory order = ICTFExchange.Order({
            salt: 1,
            signer: maker,
            maker: maker,
            taker: address(0),
            price: price,
            quantity: quantity,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            questionId: questionIdParam,
            intent: ICTFExchange.Intent(intent),
            signatureType: ICTFExchange.SignatureType.EOA,
            signature: new bytes(0)
        });
        
        // Convert ICTFExchange.Order to Order for hashing
        Order memory orderForHash = Order({
            salt: order.salt,
            maker: order.maker,
            signer: order.signer,
            taker: order.taker,
            price: order.price,
            quantity: order.quantity,
            expiration: order.expiration,
            nonce: order.nonce,
            feeRateBps: order.feeRateBps,
            questionId: order.questionId,
            intent: Intent(uint8(order.intent)),
            signatureType: SignatureType(uint8(order.signatureType)),
            signature: order.signature
        });
        
        order.signature = _signMessage(privateKey, ctfExchange.hashOrder(orderForHash));
        
        return ICTFExchange.OrderIntent({
            tokenId: tokenId,
            side: ICTFExchange.Side(side),
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            order: order
        });
    }
    
    function _signMessage(uint256 pk, bytes32 message) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, message);
        sig = abi.encodePacked(r, s, v);
    }

    // ========================================
    // COMPLEX SCENARIO TESTS
    // ========================================

    function test_HybridMatchOrders_ComplexMixedScenario() public {
        console.log("=== Testing Complex Mixed Scenario: Multiple Single + Cross-Match Orders ===");
        
        // Create 6 questions for complex scenario
        bytes32[] memory questionIds = new bytes32[](6);
        uint256[] memory yesPositionIds = new uint256[](6);
        uint256[] memory noPositionIds = new uint256[](6);
        
        for (uint256 i = 0; i < 6; i++) {
            questionIds[i] = negRiskAdapter.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            noPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPositionIds[i], negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        // Setup: 3 single orders + 1 cross-match order (3 makers)
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](4);
        uint256[] memory makerFillAmounts = new uint256[](4);
        
        // Single order 1: User2 sells YES tokens for question 0 (price 0.25) - SHORT intent
        _mintTokensToUser(user2, yesPositionIds[0], 2e6);
        makerOrders[0] = new ICTFExchange.OrderIntent[](1);
        makerOrders[0][0] = _createAndSignOrder(user2, yesPositionIds[0], 1, 2e6, 0.5e6, questionIds[0], 1, user2PK);
        makerFillAmounts[0] = 0.1e6;
        
        // Single order 2: User3 sells YES tokens for question 1 (price 0.15) - SHORT intent
        _mintTokensToUser(user3, yesPositionIds[1], 2e6);
        makerOrders[1] = new ICTFExchange.OrderIntent[](1);
        makerOrders[1][0] = _createAndSignOrder(user3, yesPositionIds[1], 1, 2e6, 0.3e6, questionIds[1], 1, user3PK);
        makerFillAmounts[1] = 0.1e6;
        
        // Single order 3: User4 sells YES tokens for question 2 (price 0.1) - SHORT intent
        _mintTokensToUser(user4, yesPositionIds[2], 2e6);
        makerOrders[2] = new ICTFExchange.OrderIntent[](1);
        makerOrders[2][0] = _createAndSignOrder(user4, yesPositionIds[2], 1, 2e6, 0.2e6, questionIds[2], 1, user4PK);
        makerFillAmounts[2] = 0.1e6;
        
        // Cross-match order: User5 and User6 buy different tokens (prices 0.4 + 0.3 = 0.7) - LONG intent
        makerOrders[3] = new ICTFExchange.OrderIntent[](2);
        makerOrders[3][0] = _createAndSignOrder(user5, yesPositionIds[3], 0, 0.4e6, 1e6, questionIds[3], 0, user5PK);
        makerOrders[3][1] = _createAndSignOrder(user6, yesPositionIds[4], 0, 0.3e6, 1e6, questionIds[4], 0, user6PK);
        makerFillAmounts[3] = 0.1e6;
        
        // Taker order: User1 buys YES tokens for question 5 (price 0.3) - LONG intent
        // Note: Single orders (SHORT) and cross-match orders (LONG) are processed separately
        // Single orders: 0.25 + 0.15 + 0.1 = 0.5 (complementary matching via CTFExchange)
        // Cross-match orders: 0.4 + 0.3 = 0.7 (cross-matching via crossMatchLongOrders)
        // Taker order: 0.3 (participates in cross-match)
        // Cross-match total: 0.7 + 0.3 = 1.0 ✓
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[5], 0, 0.3e6, 1e6, questionIds[5], 0, user1PK);
        uint256 takerFillAmount = 0.1e6;
        
        // Debug: Print the prices to see what's happening
        console.log("Taker order price: %s", takerOrder.order.price);
        console.log("Maker order 1 price: %s", makerOrders[0][0].order.price);
        console.log("Maker order 2 price: %s", makerOrders[1][0].order.price);
        console.log("Maker order 3 price: %s", makerOrders[2][0].order.price);
        console.log("Maker order 4 price 1: %s", makerOrders[3][0].order.price);
        console.log("Maker order 4 price 2: %s", makerOrders[3][1].order.price);
        
        // Execute hybrid match orders (3 single orders, 1 cross-match)
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts, 3);
        
        // Verify balances
        assertEq(ctf.balanceOf(user1, yesPositionIds[5]), takerFillAmount, "User1 should receive YES tokens from cross-match");
        assertEq(ctf.balanceOf(user2, yesPositionIds[0]), 2e6 - makerFillAmounts[0], "User2 should have sold YES tokens");
        assertEq(ctf.balanceOf(user3, yesPositionIds[1]), 2e6 - makerFillAmounts[1], "User3 should have sold YES tokens");
        assertEq(ctf.balanceOf(user4, yesPositionIds[2]), 2e6 - makerFillAmounts[2], "User4 should have sold YES tokens");
        assertEq(ctf.balanceOf(user5, yesPositionIds[3]), makerFillAmounts[3], "User5 should receive YES tokens from cross-match");
        assertEq(ctf.balanceOf(user6, yesPositionIds[4]), makerFillAmounts[3], "User6 should receive YES tokens from cross-match");
        
        console.log("Complex mixed scenario test passed!");
    }

    function test_HybridMatchOrders_LargeScaleScenario() public {
        console.log("=== Testing Large Scale Scenario: 10 Questions, Multiple Orders ===");
        
        // Create 10 questions
        bytes32[] memory questionIds = new bytes32[](10);
        uint256[] memory yesPositionIds = new uint256[](10);
        
        for (uint256 i = 0; i < 10; i++) {
            questionIds[i] = negRiskAdapter.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        // Create 5 single orders + 2 cross-match orders
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](7);
        uint256[] memory makerFillAmounts = new uint256[](7);
        
        // Single orders (5) - each with price 0.1, total = 0.5
        for (uint256 i = 0; i < 5; i++) {
            _mintTokensToUser(vm.addr(1000 + i), yesPositionIds[i], 1e6);
            makerOrders[i] = new ICTFExchange.OrderIntent[](1);
            makerOrders[i][0] = _createAndSignOrder(
                vm.addr(1000 + i), 
                yesPositionIds[i], 
                1, 
                1e6, 
                0.1e6, 
                questionIds[i], 
                1, 
                1000 + i
            );
            makerFillAmounts[i] = 0.05e6;
        }
        
        // Cross-match orders (2) - prices 0.1 + 0.1 = 0.2
        makerOrders[5] = new ICTFExchange.OrderIntent[](2);
        makerOrders[5][0] = _createAndSignOrder(user2, yesPositionIds[5], 0, 0.1e6, 1e6, questionIds[5], 0, user2PK);
        makerOrders[5][1] = _createAndSignOrder(user3, yesPositionIds[6], 0, 0.1e6, 1e6, questionIds[6], 0, user3PK);
        makerFillAmounts[5] = 0.05e6;
        
        // Cross-match order (3) - prices 0.1 + 0.1 + 0.1 = 0.3
        makerOrders[6] = new ICTFExchange.OrderIntent[](3);
        makerOrders[6][0] = _createAndSignOrder(user4, yesPositionIds[7], 0, 0.1e6, 1e6, questionIds[7], 0, user4PK);
        makerOrders[6][1] = _createAndSignOrder(user5, yesPositionIds[8], 0, 0.1e6, 1e6, questionIds[8], 0, user5PK);
        makerOrders[6][2] = _createAndSignOrder(user6, yesPositionIds[9], 0, 0.1e6, 1e6, questionIds[9], 0, user6PK);
        makerFillAmounts[6] = 0.05e6;
        
        // Taker order - price 0.0 (not buying, just participating in cross-match)
        // Total prices: 0.5 (single) + 0.2 (cross-match 1) + 0.3 (cross-match 2) + 0.0 (taker) = 1.0
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[0], 0, 0.0e6, 1e6, questionIds[0], 0, user1PK);
        uint256 takerFillAmount = 0.05e6;
        
        // Execute hybrid match orders (5 single orders, 2 cross-match)
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts, 5);
        
        console.log("Large scale scenario test passed!");
    }

    function test_HybridMatchOrders_AllSellOrdersScenario() public {
        console.log("=== Testing All Sell Orders Scenario ===");
        
        // Create 4 questions for cross-matching
        bytes32[] memory questionIds = new bytes32[](4);
        uint256[] memory yesPositionIds = new uint256[](4);
        uint256[] memory noPositionIds = new uint256[](4);
        
        for (uint256 i = 0; i < 4; i++) {
            questionIds[i] = negRiskAdapter.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            noPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPositionIds[i], negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        // Setup: Cross-match scenario with 4 users selling NO tokens
        // Combined price must equal 1.0: 0.25 + 0.25 + 0.25 + 0.25 = 1.0
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](1);
        uint256[] memory makerFillAmounts = new uint256[](1);
        
        // Mint NO tokens to users for cross-match and set up approvals
        for (uint256 i = 0; i < 4; i++) {
            _mintTokensToUser(vm.addr(2000 + i), noPositionIds[i], 1e6);
            // Approve adapter to transfer tokens
            vm.prank(vm.addr(2000 + i));
            ctf.setApprovalForAll(address(adapter), true);
        }
        
        // User1 (taker) needs NO tokens since they're selling
        _mintTokensToUser(user1, noPositionIds[0], 1e6);
        vm.prank(user1);
        ctf.setApprovalForAll(address(adapter), true);
        
        // The adapter needs WrappedCollateral tokens for the cross-match operation
        // First, add the adapter as an owner of WrappedCollateral
        vm.startPrank(address(negRiskAdapter));
        negRiskAdapter.wcol().addOwner(address(adapter));
        vm.stopPrank();
        
        // Give the adapter USDC for unwrapping WrappedCollateral
        deal(address(usdc), address(adapter), 100e6);
        
        // Then mint WrappedCollateral tokens to the adapter
        vm.startPrank(address(adapter));
        negRiskAdapter.wcol().mint(10e6); // Mint 10 WCOL to adapter
        vm.stopPrank();
        
        // Cross-match order: 3 makers selling NO tokens at 0.25 each
        // Combined with taker (0.25) = 0.25 + 0.25 + 0.25 + 0.25 = 1.0
        makerOrders[0] = new ICTFExchange.OrderIntent[](3);
        makerOrders[0][0] = _createAndSignOrder(vm.addr(2001), noPositionIds[1], 1, 1e6, 0.25e6, questionIds[1], 0, 2001);
        makerOrders[0][1] = _createAndSignOrder(vm.addr(2002), noPositionIds[2], 1, 1e6, 0.25e6, questionIds[2], 0, 2002);
        makerOrders[0][2] = _createAndSignOrder(vm.addr(2003), noPositionIds[3], 1, 1e6, 0.25e6, questionIds[3], 0, 2003);
        makerFillAmounts[0] = 0.1e6;
        
        // Taker order: User1 selling NO tokens for question 0 - price 0.25
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, noPositionIds[0], 1, 1e6, 0.25e6, questionIds[0], 0, user1PK);
        uint256 takerFillAmount = 0.1e6;
        
        // Debug: Check adapter's YES token balance before execution
        console.log("Adapter YES token balance before execution:", ctf.balanceOf(address(adapter), yesPositionIds[0]));
        
        // Execute hybrid match orders (0 single orders, 1 cross-match)
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts, 0);
        
        console.log("All sell orders scenario test passed!");
    }

    // ========================================
    // EDGE CASE TESTS
    // ========================================

    function test_HybridMatchOrders_ZeroFillAmount() public {
        console.log("=== Testing Zero Fill Amount Edge Case ===");
        
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](1);
        uint256[] memory makerFillAmounts = new uint256[](1);
        
        makerOrders[0] = new ICTFExchange.OrderIntent[](1);
        makerOrders[0][0] = _createAndSignOrder(user2, yesPositionId, 1, 1e6, 0.5e6, questionId, 1, user2PK);
        makerFillAmounts[0] = 0; // Zero fill amount
        
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionId, 0, 0.5e6, 1e6, questionId, 0, user1PK);
        uint256 takerFillAmount = 0; // Zero fill amount
        
        // This should revert with InvalidFillAmount
        vm.expectRevert(abi.encodeWithSelector(CrossMatchingAdapter.InvalidFillAmount.selector));
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts, 1);
        
        console.log("Zero fill amount edge case test passed!");
    }

    function test_HybridMatchOrders_InvalidCombinedPrice() public {
        console.log("=== Testing Invalid Combined Price Edge Case ===");
        
        // Create 3 questions
        bytes32[] memory questionIds = new bytes32[](3);
        uint256[] memory yesPositionIds = new uint256[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            questionIds[i] = negRiskAdapter.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](1);
        uint256[] memory makerFillAmounts = new uint256[](1);
        
        // Create orders with prices that don't sum to 1.0
        makerOrders[0] = new ICTFExchange.OrderIntent[](2);
        makerOrders[0][0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.3e6, 1e6, questionIds[0], 0, user2PK); // 0.3
        makerOrders[0][1] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.4e6, 1e6, questionIds[1], 0, user3PK); // 0.4
        makerFillAmounts[0] = 0.1e6;
        
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[2], 0, 0.2e6, 1e6, questionIds[2], 0, user1PK); // 0.2
        uint256 takerFillAmount = 0.1e6;
        
        // Total price = 0.3 + 0.4 + 0.2 = 0.9 ≠ 1.0, should revert
        vm.expectRevert(CrossMatchingAdapter.InvalidCombinedPrice.selector);
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts, 0);
        
        console.log("Invalid combined price edge case test passed!");
    }

    function test_HybridMatchOrders_InsufficientUSDCBalance() public {
        console.log("=== Testing Insufficient USDC Balance Edge Case ===");
        
        // Setup user with insufficient USDC
        vm.startPrank(user1);
        deal(address(usdc), user1, 1e6); // Only 1 USDC
        usdc.approve(address(adapter), type(uint256).max);
        usdc.approve(address(ctfExchange), type(uint256).max);
        ctf.setApprovalForAll(address(ctfExchange), true);
        vm.stopPrank();
        
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](1);
        uint256[] memory makerFillAmounts = new uint256[](1);
        
        makerOrders[0] = new ICTFExchange.OrderIntent[](1);
        makerOrders[0][0] = _createAndSignOrder(user2, yesPositionId, 1, 1e6, 0.5e6, questionId, 1, user2PK);
        makerFillAmounts[0] = 0.1e6;
        
        // Taker order requiring more USDC than user1 has
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionId, 0, 2e6, 1e6, questionId, 0, user1PK);
        uint256 takerFillAmount = 0.1e6;
        
        // This should revert due to insufficient USDC balance
        vm.expectRevert();
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts, 1);
        
        console.log("Insufficient USDC balance edge case test passed!");
    }

    function test_HybridMatchOrders_InvalidSingleOrderCount() public {
        console.log("=== Testing Invalid Single Order Count Edge Case ===");
        
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](2);
        uint256[] memory makerFillAmounts = new uint256[](2);
        
        // Create 2 single orders
        makerOrders[0] = new ICTFExchange.OrderIntent[](1);
        makerOrders[0][0] = _createAndSignOrder(user2, yesPositionId, 1, 1e6, 0.5e6, questionId, 1, user2PK);
        makerFillAmounts[0] = 0.1e6;
        
        makerOrders[1] = new ICTFExchange.OrderIntent[](1);
        makerOrders[1][0] = _createAndSignOrder(user3, yesPositionId, 1, 1e6, 0.5e6, questionId, 1, user3PK);
        makerFillAmounts[1] = 0.1e6;
        
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionId, 0, 1e6, 1e6, questionId, 0, user1PK);
        uint256 takerFillAmount = 0.1e6;
        
        // Pass incorrect single order count (1 instead of 2)
        // This should cause array bounds issues
        vm.expectRevert();
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts, 1);
        
        console.log("Invalid single order count edge case test passed!");
    }

    // ========================================
    // STRESS TESTS
    // ========================================

    function test_HybridMatchOrders_MaximumOrdersStressTest() public {
        console.log("=== Testing Maximum Orders Stress Test ===");
        
        // Create 20 questions for stress test
        bytes32[] memory questionIds = new bytes32[](20);
        uint256[] memory yesPositionIds = new uint256[](20);
        
        for (uint256 i = 0; i < 20; i++) {
            questionIds[i] = negRiskAdapter.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        // Create 10 single orders + 5 cross-match orders
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](15);
        uint256[] memory makerFillAmounts = new uint256[](15);
        
        // Single orders (10) - each with price 0.05, total = 0.5
        for (uint256 i = 0; i < 10; i++) {
            _mintTokensToUser(vm.addr(3000 + i), yesPositionIds[i], 1e6);
            makerOrders[i] = new ICTFExchange.OrderIntent[](1);
            makerOrders[i][0] = _createAndSignOrder(
                vm.addr(3000 + i), 
                yesPositionIds[i], 
                1, 
                1e6, 
                0.05e6, 
                questionIds[i], 
                1, 
                3000 + i
            );
            makerFillAmounts[i] = 0.01e6; // Small amounts to avoid overflow
        }
        
        // Cross-match orders (5) - each with prices 0.05 + 0.05 = 0.1, total = 0.5
        for (uint256 i = 0; i < 5; i++) {
            makerOrders[10 + i] = new ICTFExchange.OrderIntent[](2);
            makerOrders[10 + i][0] = _createAndSignOrder(
                vm.addr(4000 + i * 2), 
                yesPositionIds[10 + i], 
                0, 
                0.05e6, 
                1e6, 
                questionIds[10 + i], 
                0, 
                4000 + i * 2
            );
            makerOrders[10 + i][1] = _createAndSignOrder(
                vm.addr(4000 + i * 2 + 1), 
                yesPositionIds[15 + i], 
                0, 
                0.05e6, 
                1e6, 
                questionIds[15 + i], 
                0, 
                4000 + i * 2 + 1
            );
            makerFillAmounts[10 + i] = 0.01e6;
        }
        
        // Taker order - price 0.0 (not buying, just participating)
        // Total prices: 0.5 (single) + 0.5 (cross-match) + 0.0 (taker) = 1.0
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[0], 0, 0.0e6, 1e6, questionIds[0], 0, user1PK);
        uint256 takerFillAmount = 0.01e6;
        
        // Execute hybrid match orders (10 single orders, 5 cross-match)
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts, 10);
        
        console.log("Maximum orders stress test passed!");
    }

    function test_HybridMatchOrders_ExtremePriceDistribution() public {
        console.log("=== Testing Extreme Price Distribution ===");
        
        // Create 5 questions with extreme price distributions
        bytes32[] memory questionIds = new bytes32[](5);
        uint256[] memory yesPositionIds = new uint256[](5);
        
        for (uint256 i = 0; i < 5; i++) {
            questionIds[i] = negRiskAdapter.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](1);
        uint256[] memory makerFillAmounts = new uint256[](1);
        
        // Extreme price distribution: 0.1, 0.1, 0.1, 0.1, 0.6
        makerOrders[0] = new ICTFExchange.OrderIntent[](4);
        makerOrders[0][0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.1e6, 1e6, questionIds[0], 0, user2PK);
        makerOrders[0][1] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.1e6, 1e6, questionIds[1], 0, user3PK);
        makerOrders[0][2] = _createAndSignOrder(user4, yesPositionIds[2], 0, 0.1e6, 1e6, questionIds[2], 0, user4PK);
        makerOrders[0][3] = _createAndSignOrder(user5, yesPositionIds[3], 0, 0.1e6, 1e6, questionIds[3], 0, user5PK);
        makerFillAmounts[0] = 0.1e6;
        
        // Taker order - price 0.6
        // Total prices: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[4], 0, 0.6e6, 1e6, questionIds[4], 0, user1PK);
        uint256 takerFillAmount = 0.1e6;
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts, 0);
        
        console.log("Extreme price distribution test passed!");
    }

    // ========================================
    // SELF-FINANCING VERIFICATION TESTS
    // ========================================

    function test_HybridMatchOrders_SelfFinancingProperty() public {
        console.log("=== Testing Self-Financing Property ===");
        
        // Create 4 questions
        bytes32[] memory questionIds = new bytes32[](4);
        uint256[] memory yesPositionIds = new uint256[](4);
        
        for (uint256 i = 0; i < 4; i++) {
            questionIds[i] = negRiskAdapter.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        // Record initial adapter balances
        uint256 initialUSDCBalance = usdc.balanceOf(address(adapter));
        uint256 initialWCOLBalance = negRiskAdapter.wcol().balanceOf(address(adapter));
        
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](2);
        uint256[] memory makerFillAmounts = new uint256[](2);
        
        // Single order - price 0.25
        makerOrders[0] = new ICTFExchange.OrderIntent[](1);
        makerOrders[0][0] = _createAndSignOrder(user2, yesPositionIds[0], 1, 1e6, 0.25e6, questionIds[0], 1, user2PK);
        makerFillAmounts[0] = 0.1e6;
        
        // Cross-match order - prices 0.25 + 0.25 = 0.5
        makerOrders[1] = new ICTFExchange.OrderIntent[](2);
        makerOrders[1][0] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.25e6, 1e6, questionIds[1], 0, user3PK);
        makerOrders[1][1] = _createAndSignOrder(user4, yesPositionIds[2], 0, 0.25e6, 1e6, questionIds[2], 0, user4PK);
        makerFillAmounts[1] = 0.1e6;
        
        // Taker order - price 0.25
        // Total prices: 0.25 + 0.5 + 0.25 = 1.0
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[3], 0, 0.25e6, 1e6, questionIds[3], 0, user1PK);
        uint256 takerFillAmount = 0.1e6;
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts, 1);
        
        // Verify self-financing property
        uint256 finalUSDCBalance = usdc.balanceOf(address(adapter));
        uint256 finalWCOLBalance = negRiskAdapter.wcol().balanceOf(address(adapter));
        
        assertEq(finalUSDCBalance, initialUSDCBalance, "Adapter should have no net USDC change");
        assertEq(finalWCOLBalance, initialWCOLBalance, "Adapter should have no net WCOL change");
        
        console.log("Self-financing property test passed!");
    }

    function test_HybridMatchOrders_BalanceConservation() public {
        console.log("=== Testing Balance Conservation ===");
        
        // Create 3 questions
        bytes32[] memory questionIds = new bytes32[](3);
        uint256[] memory yesPositionIds = new uint256[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            questionIds[i] = negRiskAdapter.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        // Record initial total balances
        uint256 initialTotalUSDC = usdc.totalSupply();
        uint256 initialVaultUSDC = usdc.balanceOf(vault);
        
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](1);
        uint256[] memory makerFillAmounts = new uint256[](1);
        
        makerOrders[0] = new ICTFExchange.OrderIntent[](2);
        makerOrders[0][0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.3e6, 1e6, questionIds[0], 0, user2PK);
        makerOrders[0][1] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.4e6, 1e6, questionIds[1], 0, user3PK);
        makerFillAmounts[0] = 0.1e6;
        
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[2], 0, 0.3e6, 1e6, questionIds[2], 0, user1PK);
        uint256 takerFillAmount = 0.1e6;
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts, 0);
        
        // Verify balance conservation
        uint256 finalTotalUSDC = usdc.totalSupply();
        uint256 finalVaultUSDC = usdc.balanceOf(vault);
        
        assertEq(finalTotalUSDC, initialTotalUSDC, "Total USDC supply should be conserved");
        assertEq(finalVaultUSDC, initialVaultUSDC, "Vault USDC balance should be conserved");
        
        console.log("Balance conservation test passed!");
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

// Mock Vault contract
contract MockVault {
    mapping(address => uint256) public balanceOf;
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
