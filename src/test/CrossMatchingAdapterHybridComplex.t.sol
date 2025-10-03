// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {CrossMatchingAdapter, ICrossMatchingAdapterEE} from "src/CrossMatchingAdapter.sol";
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

contract CrossMatchingAdapterHybridComplexTest is Test, TestHelper {
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
    address public user4;
    address public user5;
    address public user6;
    
    // Private keys for signing
    uint256 internal _user1PK = 0x1111;
    uint256 internal _user2PK = 0x2222;
    uint256 internal _user3PK = 0x3333;
    uint256 internal _user4PK = 0x4444;
    uint256 internal _user5PK = 0x5555;
    uint256 internal _user6PK = 0x6666;

    // Market and question IDs
    bytes32 public marketId;
    bytes32 public questionId;
    
    // Position IDs for YES/NO tokens
    uint256 public yesPositionId;
    uint256 public noPositionId;

    uint256[] public dummyPayout;

    function setUp() public {
        dummyPayout = [0, 1];
        oracle = vm.createWallet("oracle").addr;
        // Deploy mock USDC first
        usdc = IERC20(address(new MockUSDC()));
        vm.label(address(usdc), "USDC");
        
        // Deploy real ConditionalTokens contract using Deployer
        ctf = IConditionalTokens(Deployer.ConditionalTokens());
        vm.label(address(ctf), "ConditionalTokens");
        
        // Deploy mock vault
        vault = address(new MockVault());
        vm.label(vault, "Vault");

        // Deploy NegRiskAdapter
        negRiskAdapter = new NegRiskAdapter(address(ctf), address(usdc), vault);
        negRiskOperator = new NegRiskOperator(address(negRiskAdapter));
        negRiskOperator.setOracle(address(oracle));
        vm.label(address(negRiskOperator), "NegRiskOperator");        vm.label(address(negRiskAdapter), "NegRiskAdapter");

        // Deploy real CTFExchange contract
        ctfExchange = new CTFExchange(address(usdc), address(negRiskAdapter), address(0), address(0));
        vm.label(address(ctfExchange), "CTFExchange");

        // Deploy RevNegRiskAdapter
        revNegRiskAdapter = new RevNegRiskAdapter(address(ctf), address(usdc), vault, INegRiskAdapter(address(negRiskAdapter)));
        vm.label(address(revNegRiskAdapter), "RevNegRiskAdapter");
        
        // Add RevNegRiskAdapter as owner of WrappedCollateral so it can mint tokens
        // We need to call this from the NegRiskAdapter since it's the owner
        vm.startPrank(address(negRiskAdapter));
        ctf.setApprovalForAll(address(ctfExchange), true);
        negRiskAdapter.wcol().addOwner(address(revNegRiskAdapter));
        vm.stopPrank();
        negRiskAdapter.addAdmin(address(ctfExchange));

        vm.startPrank(address(ctfExchange));
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        ctf.setApprovalForAll(address(ctfExchange), true);
        vm.stopPrank();

        // Deploy CrossMatchingAdapter
        adapter = new CrossMatchingAdapter(negRiskOperator, IERC20(address(usdc)), ICTFExchange(address(ctfExchange)), IRevNegRiskAdapter(address(revNegRiskAdapter)));
        vm.label(address(adapter), "CrossMatchingAdapter");

        // Setup vault with USDC and approve adapter
        MockUSDC(address(usdc)).mint(address(vault), 1000000000e6);
        vm.startPrank(address(vault));
        MockUSDC(address(usdc)).approve(address(adapter), type(uint256).max);
        vm.stopPrank();

        // Set up test users
        user1 = vm.addr(_user1PK);
        user2 = vm.addr(_user2PK);
        user3 = vm.addr(_user3PK);
        user4 = vm.addr(_user4PK);
        user5 = vm.addr(_user5PK);
        user6 = vm.addr(_user6PK);
        vm.label(user1, "User1");
        vm.label(user2, "User2");
        vm.label(user3, "User3");
        vm.label(user4, "User4");
        vm.label(user5, "User5");
        vm.label(user6, "User6");
        
        // Set up market and question
        marketId = negRiskOperator.prepareMarket(0, "Test Market");
        questionId = negRiskOperator.prepareQuestion(marketId, "Test Question", 0);
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
        ctf.setApprovalForAll(address(adapter), true);
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

        bool isYes = true;
        if (intent == uint8(ICTFExchange.Intent.LONG)) {
            if (side == uint8(ICTFExchange.Side.BUY)) {
                isYes = true;
            } else {
                isYes = false;
            }
        } else {
            if (side == uint8(ICTFExchange.Side.SELL)) {
                isYes = true;
            } else {
                isYes = false;
            }
        }
        if (!isYes) {
            price = 1e6 - price;
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

    function testHybridMatchOrdersComplexMixedScenario() public {
        console.log("=== Testing Complex Mixed Scenario: Multiple Single + Cross-Match Orders ===");
        
        // Create 6 questions for complex scenario
        bytes32[] memory questionIds = new bytes32[](6);
        uint256[] memory yesPositionIds = new uint256[](6);
        uint256[] memory noPositionIds = new uint256[](6);
        
        for (uint256 i = 0; i < 6; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            noPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPositionIds[i], negRiskAdapter.getConditionId(questionIds[i]));
        }

        vm.startPrank(oracle);
        negRiskOperator.reportPayouts(bytes32(0), dummyPayout);
        negRiskOperator.reportPayouts(bytes32(uint256(1)), dummyPayout);
        negRiskOperator.reportPayouts(bytes32(uint256(2)), dummyPayout);
        negRiskOperator.reportPayouts(bytes32(uint256(3)), dummyPayout);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 * negRiskOperator.DELAY_PERIOD());

        negRiskOperator.resolveQuestion(questionId);
        negRiskOperator.resolveQuestion(questionIds[0]);
        negRiskOperator.resolveQuestion(questionIds[1]);
        negRiskOperator.resolveQuestion(questionIds[2]);

        // Setup: 3 single orders + 1 cross-match order (3 makers)
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](4);
        uint256[] memory makerFillAmounts = new uint256[](4);
        
        // Single order 1: User2 sells YES tokens for question 5 (price 0.25) - SHORT intent
        _mintTokensToUser(user2, yesPositionIds[5], 2e6);
        makerOrders[0].orders = new ICTFExchange.OrderIntent[](1);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[5], 1, 2e6, 0.5e6, questionIds[5], 1, _user2PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.SINGLE;
        makerFillAmounts[0] = 0.1e6;

        vm.prank(user2);
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        
        // Single order 2: User3 sells YES tokens for question 5 (price 0.25) - SHORT intent
        _mintTokensToUser(user3, yesPositionIds[5], 2e6);
        makerOrders[1].orders = new ICTFExchange.OrderIntent[](1);
        makerOrders[1].orders[0] = _createAndSignOrder(user3, yesPositionIds[5], 1, 2e6, 0.5e6, questionIds[5], 1, _user3PK);
        makerOrders[1].orderType = CrossMatchingAdapter.OrderType.SINGLE;
        makerFillAmounts[1] = 0.1e6;

        vm.prank(user3);
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        
        // Single order 3: User4 sells YES tokens for question 5 (price 0.25) - SHORT intent
        _mintTokensToUser(user4, yesPositionIds[5], 2e6);
        makerOrders[2].orders = new ICTFExchange.OrderIntent[](1);
        makerOrders[2].orders[0] = _createAndSignOrder(user4, yesPositionIds[5], 1, 2e6, 0.5e6, questionIds[5], 1, _user4PK);
        makerOrders[2].orderType = CrossMatchingAdapter.OrderType.SINGLE;
        makerFillAmounts[2] = 0.1e6;

        vm.prank(user4);
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        
        // Cross-match order: User5 and User6 buy different tokens (prices 0.4 + 0.3 = 0.7) - LONG intent
        makerOrders[3].orders = new ICTFExchange.OrderIntent[](2);
        makerOrders[3].orders[0] = _createAndSignOrder(user5, yesPositionIds[3], 0, 0.4e6, 1e6, questionIds[3], 0, _user5PK);
        makerOrders[3].orders[1] = _createAndSignOrder(user6, yesPositionIds[4], 0, 0.3e6, 1e6, questionIds[4], 0, _user6PK);
        makerOrders[3].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        makerFillAmounts[3] = 0.1e6;

        vm.prank(user5);
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        vm.prank(user6);
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        
        // Taker order: User1 buys YES tokens for question 5 (price 0.3) - LONG intent
        // Note: Single orders (SHORT) and cross-match orders (LONG) are processed separately
        // Single orders: 0.25 + 0.15 + 0.1 = 0.5 (complementary matching via CTFExchange)
        // Cross-match orders: 0.4 + 0.3 = 0.7 (cross-matching via crossMatchLongOrders)
        // Taker order: 0.3 (participates in cross-match)
        // Cross-match total: 0.7 + 0.3 = 1.0 ✓
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[5], 0, 0.3e6, 1e6, questionIds[5], 0, _user1PK);
        
        // Record initial balances for verification
        uint256 initialUser1USDC = usdc.balanceOf(user1);
        
        // Execute hybrid match orders (3 single orders, 1 cross-match)
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 3);
        
        // Verify token balances
        assertEq(ctf.balanceOf(user1, yesPositionIds[5]), 0.4e6, "User1 should receive YES tokens from cross-match");
        assertEq(ctf.balanceOf(user2, yesPositionIds[5]), 2e6 - makerFillAmounts[0], "User2 should have sold YES tokens");
        assertEq(ctf.balanceOf(user3, yesPositionIds[5]), 2e6 - makerFillAmounts[1], "User3 should have sold YES tokens");
        assertEq(ctf.balanceOf(user4, yesPositionIds[5]), 2e6 - makerFillAmounts[2], "User4 should have sold YES tokens");
        assertEq(ctf.balanceOf(user5, yesPositionIds[3]), makerFillAmounts[3], "User5 should receive YES tokens from cross-match");
        assertEq(ctf.balanceOf(user6, yesPositionIds[4]), makerFillAmounts[3], "User6 should receive YES tokens from cross-match");
        
        // Verify USDC balance changes
        uint256 expectedUser1USDCChange = (makerFillAmounts[0] * (makerOrders[0].orders[0].order.price)) / 1e6 + 
                                        (makerFillAmounts[1] * (makerOrders[1].orders[0].order.price)) / 1e6 + 
                                        (makerFillAmounts[2] * (makerOrders[2].orders[0].order.price)) / 1e6 +
                                        (makerFillAmounts[3] * takerOrder.order.price) / 1e6;
        assertEq(usdc.balanceOf(user1), initialUser1USDC - expectedUser1USDCChange, "User1 USDC balance should decrease for single orders");
        
        // Verify cross-match participants received their tokens
        assertEq(ctf.balanceOf(user5, yesPositionIds[3]), makerFillAmounts[3], "User5 should have received YES tokens from cross-match");
        assertEq(ctf.balanceOf(user6, yesPositionIds[4]), makerFillAmounts[3], "User6 should have received YES tokens from cross-match");
        
        // Verify no tokens were left in adapter
        assertEq(ctf.balanceOf(address(adapter), yesPositionIds[5]), 0, "Adapter should not hold any YES tokens");
        assertEq(ctf.balanceOf(address(adapter), yesPositionIds[3]), 0, "Adapter should not hold any YES tokens");
        assertEq(ctf.balanceOf(address(adapter), yesPositionIds[4]), 0, "Adapter should not hold any YES tokens");
        
        console.log("Complex mixed scenario test passed!");
    }

    function testHybridMatchOrdersLargeScaleScenario() public {
        console.log("=== Testing Large Scale Scenario: 10 Questions, Multiple Orders ===");
        
        // Create 10 questions
        bytes32[] memory questionIds = new bytes32[](10);
        uint256[] memory yesPositionIds = new uint256[](10);
        
        for (uint256 i = 0; i < 10; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        // Create 5 single orders + 2 cross-match orders
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](7);
        uint256[] memory makerFillAmounts = new uint256[](7);
        
        uint256 noPositionId0 = negRiskAdapter.getPositionId(questionIds[0], false);

        // Single orders (5) - each with price 0.55
        // Buying NO tokens, short intent
        for (uint256 i = 0; i < 5; i++) {
            MockUSDC(address(usdc)).mint(vm.addr(1000 + i), 1e6);
            vm.prank(vm.addr(1000 + i));
            usdc.approve(address(ctfExchange), 1e6);
            makerOrders[i].orders = new ICTFExchange.OrderIntent[](1);
            makerOrders[i].orders[0] = _createAndSignOrder(
                vm.addr(1000 + i), 
                noPositionId0, 
                0, 
                0.55e6, 
                1e6, 
                questionIds[0], 
                1, 
                1000 + i
            );
            makerOrders[i].orderType = CrossMatchingAdapter.OrderType.SINGLE;
            makerFillAmounts[i] = 0.05e6;
        }

        vm.startPrank(oracle);
        negRiskOperator.reportPayouts(bytes32(0), dummyPayout);
        negRiskOperator.reportPayouts(bytes32(uint256(2)), dummyPayout);
        negRiskOperator.reportPayouts(bytes32(uint256(3)), dummyPayout);
        negRiskOperator.reportPayouts(bytes32(uint256(4)), dummyPayout);
        negRiskOperator.reportPayouts(bytes32(uint256(5)), dummyPayout);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 * negRiskOperator.DELAY_PERIOD());

        negRiskOperator.resolveQuestion(questionId);
        negRiskOperator.resolveQuestion(questionIds[1]);
        negRiskOperator.resolveQuestion(questionIds[2]);
        negRiskOperator.resolveQuestion(questionIds[3]);
        negRiskOperator.resolveQuestion(questionIds[4]);
        
        // Cross-match orders (2) - prices 0.2 + 0.15 + 0.05 + 0.1 + 0.05 = 0.55
        makerOrders[5].orders = new ICTFExchange.OrderIntent[](5);
        makerOrders[5].orders[0] = _createAndSignOrder(user2, yesPositionIds[5], 0, 0.2e6, 1e6, questionIds[5], 0, _user2PK);
        makerOrders[5].orders[1] = _createAndSignOrder(user3, yesPositionIds[6], 0, 0.15e6, 1e6, questionIds[6], 0, _user3PK);
        makerOrders[5].orders[2] = _createAndSignOrder(user4, yesPositionIds[7], 0, 0.05e6, 1e6, questionIds[7], 0, _user4PK);
        makerOrders[5].orders[3] = _createAndSignOrder(user5, yesPositionIds[8], 0, 0.1e6, 1e6, questionIds[8], 0, _user5PK);
        makerOrders[5].orders[4] = _createAndSignOrder(user6, yesPositionIds[9], 0, 0.05e6, 1e6, questionIds[9], 0, _user6PK);
        makerOrders[5].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        makerFillAmounts[5] = 0.05e6;
        
        // Cross-match order (3) - prices 0.1 + 0.25 + 0.05 + 0.07 + 0.08 = 0.55
        // Use different users to avoid duplicate orders
        makerOrders[6].orders = new ICTFExchange.OrderIntent[](5);
        
        // Mint USDC to the new users for cross-match order 2
        for (uint256 i = 2000; i <= 2004; i++) {
            MockUSDC(address(usdc)).mint(vm.addr(i), 1e6);
            vm.prank(vm.addr(i));
            usdc.approve(address(ctfExchange), 1e6);
            vm.prank(vm.addr(i));
            usdc.approve(address(adapter), 1e6);
        }
        
        makerOrders[6].orders[0] = _createAndSignOrder(vm.addr(2000), yesPositionIds[7], 0, 0.1e6, 1e6, questionIds[7], 0, 2000);
        makerOrders[6].orders[1] = _createAndSignOrder(vm.addr(2001), yesPositionIds[8], 0, 0.25e6, 1e6, questionIds[8], 0, 2001);
        makerOrders[6].orders[2] = _createAndSignOrder(vm.addr(2002), yesPositionIds[9], 0, 0.05e6, 1e6, questionIds[9], 0, 2002);
        makerOrders[6].orders[3] = _createAndSignOrder(vm.addr(2003), yesPositionIds[5], 0, 0.07e6, 1e6, questionIds[5], 0, 2003);
        makerOrders[6].orders[4] = _createAndSignOrder(vm.addr(2004), yesPositionIds[6], 0, 0.08e6, 1e6, questionIds[6], 0, 2004);
        makerOrders[6].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        makerFillAmounts[6] = 0.05e6;
        
        // Taker order - price 0.45 (participating in cross-match)
        // Total prices: 0.55 (single) + 0.45 (taker) = 1.0
        // Total prices: 0.55 (cross-match 1) + 0.45 (taker) = 1.0
        // Total prices: 0.55 (cross-match 2) + 0.45 (taker) = 1.0
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[0], 0, 0.45e6, 1e6, questionIds[0], 0, _user1PK);

        // Since minting of tokens didn't happen, we need to mint USDC to the NegRiskAdapter
        // TODO: Need to check it
        MockUSDC(address(usdc)).mint(address(ctfExchange), 3e6);

        // Execute hybrid match orders (5 single orders, 2 cross-match)
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 5);
        
        // Verify token balances for single order makers (NO tokens)
        for (uint256 i = 0; i < 5; i++) {
            address singleOrderMaker = vm.addr(1000 + i);
            assertEq(ctf.balanceOf(singleOrderMaker, noPositionId0), makerFillAmounts[i]*makerOrders[i].orders[0].takerAmount/makerOrders[i].orders[0].makerAmount, 
                string(abi.encodePacked("Single order maker ", vm.toString(i), " should receive NO tokens")));
        }
        
        // Verify cross-match participants received their tokens
        assertEq(ctf.balanceOf(user2, yesPositionIds[5]), makerFillAmounts[5], "User2 should receive YES tokens from cross-match 1");
        assertEq(ctf.balanceOf(user3, yesPositionIds[6]), makerFillAmounts[5], "User3 should receive YES tokens from cross-match 1");
        assertEq(ctf.balanceOf(user4, yesPositionIds[7]), makerFillAmounts[5], "User4 should receive YES tokens from cross-match 1");
        assertEq(ctf.balanceOf(user5, yesPositionIds[8]), makerFillAmounts[5], "User5 should receive YES tokens from cross-match 1");
        assertEq(ctf.balanceOf(user6, yesPositionIds[9]), makerFillAmounts[5], "User6 should receive YES tokens from cross-match 1");
        
        // Verify cross-match 2 participants received their tokens
        assertEq(ctf.balanceOf(vm.addr(2000), yesPositionIds[7]), makerFillAmounts[6], "User 2000 should receive YES tokens from cross-match 2");
        assertEq(ctf.balanceOf(vm.addr(2001), yesPositionIds[8]), makerFillAmounts[6], "User 2001 should receive YES tokens from cross-match 2");
        assertEq(ctf.balanceOf(vm.addr(2002), yesPositionIds[9]), makerFillAmounts[6], "User 2002 should receive YES tokens from cross-match 2");
        assertEq(ctf.balanceOf(vm.addr(2003), yesPositionIds[5]), makerFillAmounts[6], "User 2003 should receive YES tokens from cross-match 2");
        assertEq(ctf.balanceOf(vm.addr(2004), yesPositionIds[6]), makerFillAmounts[6], "User 2004 should receive YES tokens from cross-match 2");
        
        // Verify taker received tokens, 2 * 0.05e6 for the cross match orders and 5 * makerFillAmounts[0]*makerOrders[0].orders[0].takerAmount/makerOrders[0].orders[0].makerAmount for the single orders
        assertEq(ctf.balanceOf(user1, yesPositionIds[0]), 2*0.05e6 + 5 * makerFillAmounts[0]*makerOrders[0].orders[0].takerAmount/makerOrders[0].orders[0].makerAmount, "User1 should receive YES tokens from taker order");
        
        // Verify no tokens were left in adapter
        assertEq(ctf.balanceOf(address(adapter), yesPositionIds[0]), 0, "Adapter should not hold any YES tokens");
        assertEq(ctf.balanceOf(address(adapter), noPositionId0), 0, "Adapter should not hold any NO tokens");
        
        console.log("Large scale scenario test passed!");
    }

    function testHybridMatchOrdersAllSellOrdersScenario() public {
        console.log("=== Testing All Sell Orders Scenario ===");
        
        // Create 4 questions for cross-matching
        bytes32[] memory questionIds = new bytes32[](4);
        uint256[] memory yesPositionIds = new uint256[](4);
        uint256[] memory noPositionIds = new uint256[](4);

        questionIds[0] = questionId;
        yesPositionIds[0] = yesPositionId;
        noPositionIds[0] = noPositionId;
        
        for (uint256 i = 1; i < 4; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            noPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPositionIds[i], negRiskAdapter.getConditionId(questionIds[i]));
        }

        _mintTokensToUser(user1, noPositionIds[0], 1e6);
        _mintTokensToUser(user2, noPositionIds[1], 1e6);
        _mintTokensToUser(user3, noPositionIds[2], 1e6);
        _mintTokensToUser(user4, noPositionIds[3], 1e6);
        
        // Setup: Cross-match scenario with 4 users selling NO tokens
        // Combined price must equal 1.0: 0.25 + 0.25 + 0.25 + 0.25 = 1.0
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
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
        
        // Cross-match order: 3 makers selling NO tokens at 0.25 each
        // Combined with taker (0.25) = 0.25 + 0.25 + 0.25 + 0.25 = 1.0
        makerOrders[0].orders = new ICTFExchange.OrderIntent[](3);
        // Sending 0.75e6 here instead of 0.25e6, as the createAndSignOrder function will convert the price to 0.25
        makerOrders[0].orders[0] = _createAndSignOrder(user2, noPositionIds[1], 1, 1e6, 0.75e6, questionIds[1], 0, _user2PK);
        makerOrders[0].orders[1] = _createAndSignOrder(user3, noPositionIds[2], 1, 1e6, 0.75e6, questionIds[2], 0, _user3PK);
        makerOrders[0].orders[2] = _createAndSignOrder(user4, noPositionIds[3], 1, 1e6, 0.75e6, questionIds[3], 0, _user4PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        makerFillAmounts[0] = 1e6;
        
        // Taker order: User1 selling NO tokens for question 0 - price 0.25
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, noPositionIds[0], 1, 1e6, 0.75e6, questionIds[0], 0, _user1PK);
        
        // Since minting of tokens didn't happen, we need to mint USDC to the NegRiskAdapter
        MockUSDC(address(usdc)).mint(address(negRiskAdapter.wcol()), 3e6);

        // Record initial balances for verification
        uint256 initialUser1USDC = usdc.balanceOf(user1);
        uint256 initialUser2USDC = usdc.balanceOf(user2);
        uint256 initialUser3USDC = usdc.balanceOf(user3);
        uint256 initialUser4USDC = usdc.balanceOf(user4);
        
        // Execute hybrid match orders (0 single orders, 1 cross-match)
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 0);
        
        // Verify all users lost their NO tokens (sold them)
        assertEq(ctf.balanceOf(user1, noPositionIds[0]), 0, "User1 should have sold all NO tokens");
        assertEq(ctf.balanceOf(user2, noPositionIds[1]), 0, "User2 should have sold all NO tokens");
        assertEq(ctf.balanceOf(user3, noPositionIds[2]), 0, "User3 should have sold all NO tokens");
        assertEq(ctf.balanceOf(user4, noPositionIds[3]), 0, "User4 should have sold all NO tokens");
        
        // Verify all users received USDC for their tokens
        assertEq(usdc.balanceOf(user1), initialUser1USDC + 0.75e6, "User1 should receive USDC for tokens sold");
        assertEq(usdc.balanceOf(user2), initialUser2USDC + 0.75e6, "User2 should receive USDC for tokens sold");
        assertEq(usdc.balanceOf(user3), initialUser3USDC + 0.75e6, "User3 should receive USDC for tokens sold");
        assertEq(usdc.balanceOf(user4), initialUser4USDC + 0.75e6, "User4 should receive USDC for tokens sold");
        
        // Verify no tokens were left in adapter
        assertEq(ctf.balanceOf(address(adapter), noPositionIds[0]), 0, "Adapter should not hold any NO tokens");
        assertEq(ctf.balanceOf(address(adapter), noPositionIds[1]), 0, "Adapter should not hold any NO tokens");
        assertEq(ctf.balanceOf(address(adapter), noPositionIds[2]), 0, "Adapter should not hold any NO tokens");
        assertEq(ctf.balanceOf(address(adapter), noPositionIds[3]), 0, "Adapter should not hold any NO tokens");
        
        console.log("All sell orders scenario test passed!");
    }

    // ========================================
    // EDGE CASE TESTS
    // ========================================

    function testHybridMatchOrdersInvalidCombinedPrice() public {
        console.log("=== Testing Invalid Combined Price Edge Case ===");
        
        // Create 3 questions
        bytes32[] memory questionIds = new bytes32[](3);
        uint256[] memory yesPositionIds = new uint256[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }

        vm.prank(oracle);
        negRiskOperator.reportPayouts(bytes32(0), dummyPayout);

        vm.warp(block.timestamp + 2 * negRiskOperator.DELAY_PERIOD());

        negRiskOperator.resolveQuestion(questionId);
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        uint256[] memory makerFillAmounts = new uint256[](1);
        
        // Create orders with prices that don't sum to 1.0
        makerOrders[0].orders = new ICTFExchange.OrderIntent[](2);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.3e6, 1e6, questionIds[0], 0, _user2PK); // 0.3
        makerOrders[0].orders[1] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.4e6, 1e6, questionIds[1], 0, _user3PK); // 0.4
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        makerFillAmounts[0] = 0.1e6;
        
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[2], 0, 0.2e6, 1e6, questionIds[2], 0, _user1PK); // 0.2
        
        // Total price = 0.3 + 0.4 + 0.2 = 0.9 ≠ 1.0, should revert
        vm.expectRevert(ICrossMatchingAdapterEE.InvalidCombinedPrice.selector);
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 0);
        
        console.log("Invalid combined price edge case test passed!");
    }

    function testHybridMatchOrdersInsufficientUSDCBalance() public {
        console.log("=== Testing Insufficient USDC Balance Edge Case ===");
        uint256 randomUserPk = 0x00012345;
        address randomUser = vm.addr(randomUserPk);
        // Setup user with insufficient USDC
        vm.startPrank(randomUser);
        deal(address(usdc), randomUser, 1e5); // Only 1 USDC
        usdc.approve(address(adapter), type(uint256).max);
        usdc.approve(address(ctfExchange), type(uint256).max);
        ctf.setApprovalForAll(address(ctfExchange), true);
        vm.stopPrank();
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        uint256[] memory makerFillAmounts = new uint256[](1);

        _mintTokensToUser(user2, yesPositionId, 1e6);
        
        makerOrders[0].orders = new ICTFExchange.OrderIntent[](1);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionId, 1, 1e6, 0.5e6, questionId, 1, _user2PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.SINGLE;
        makerFillAmounts[0] = 0.1e6;

        vm.startPrank(user2);
        ctf.setApprovalForAll(address(ctfExchange), true);
        ctf.setApprovalForAll(address(adapter), true);
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        vm.stopPrank();
        
        // Taker order requiring more USDC than user1 has
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(randomUser, yesPositionId, 0, 2e6, 1e6, questionId, 0, randomUserPk);
        
        // This should revert due to insufficient USDC balance
        vm.expectRevert();
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 1);
        
        console.log("Insufficient USDC balance edge case test passed!");
    }

    function testHybridMatchOrdersInvalidSingleOrderCount() public {
        console.log("=== Testing Invalid Single Order Count Edge Case ===");
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](2);
        uint256[] memory makerFillAmounts = new uint256[](2);
        
        // Create 2 single orders
        makerOrders[0].orders = new ICTFExchange.OrderIntent[](1);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionId, 1, 1e6, 0.5e6, questionId, 1, _user2PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.SINGLE;
        makerFillAmounts[0] = 0.1e6;
        
        makerOrders[1].orders = new ICTFExchange.OrderIntent[](1);
        makerOrders[1].orders[0] = _createAndSignOrder(user3, yesPositionId, 1, 1e6, 0.5e6, questionId, 1, _user3PK);
        makerOrders[1].orderType = CrossMatchingAdapter.OrderType.SINGLE;
        makerFillAmounts[1] = 0.1e6;
        
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionId, 0, 1e6, 1e6, questionId, 0, _user1PK);
        
        // Pass incorrect single order count (1 instead of 2)
        // This should cause array bounds issues
        vm.expectRevert();
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 1);
        
        console.log("Invalid single order count edge case test passed!");
    }

    // ========================================
    // STRESS TESTS
    // ========================================

    function testHybridMatchOrdersExtremePriceDistribution() public {
        console.log("=== Testing Extreme Price Distribution ===");
        
        // Create 5 questions with extreme price distributions
        bytes32[] memory questionIds = new bytes32[](5);
        uint256[] memory yesPositionIds = new uint256[](5);
        
        for (uint256 i = 0; i < 5; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        uint256[] memory makerFillAmounts = new uint256[](1);

        vm.prank(oracle);
        negRiskOperator.reportPayouts(bytes32(0), dummyPayout);

        vm.warp(block.timestamp + 2 * negRiskOperator.DELAY_PERIOD());

        negRiskOperator.resolveQuestion(questionId);
        
        // Extreme price distribution: 0.1, 0.1, 0.1, 0.1, 0.6
        makerOrders[0].orders = new ICTFExchange.OrderIntent[](4);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.1e6, 1e6, questionIds[0], 0, _user2PK);
        makerOrders[0].orders[1] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.1e6, 1e6, questionIds[1], 0, _user3PK);
        makerOrders[0].orders[2] = _createAndSignOrder(user4, yesPositionIds[2], 0, 0.1e6, 1e6, questionIds[2], 0, _user4PK);
        makerOrders[0].orders[3] = _createAndSignOrder(user5, yesPositionIds[3], 0, 0.1e6, 1e6, questionIds[3], 0, _user5PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        makerFillAmounts[0] = 0.1e6;
        
        // Taker order - price 0.6
        // Total prices: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[4], 0, 0.6e6, 1e6, questionIds[4], 0, _user1PK);
        
        // Record initial balances for verification
        uint256 initialUser1USDC = usdc.balanceOf(user1);
        uint256 initialUser2USDC = usdc.balanceOf(user2);
        uint256 initialUser3USDC = usdc.balanceOf(user3);
        uint256 initialUser4USDC = usdc.balanceOf(user4);
        uint256 initialUser5USDC = usdc.balanceOf(user5);
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 0);
        
        // Verify all participants received their tokens
        assertEq(ctf.balanceOf(user1, yesPositionIds[4]), makerFillAmounts[0], "User1 should receive YES tokens from taker order");
        assertEq(ctf.balanceOf(user2, yesPositionIds[0]), makerFillAmounts[0], "User2 should receive YES tokens from cross-match");
        assertEq(ctf.balanceOf(user3, yesPositionIds[1]), makerFillAmounts[0], "User3 should receive YES tokens from cross-match");
        assertEq(ctf.balanceOf(user4, yesPositionIds[2]), makerFillAmounts[0], "User4 should receive YES tokens from cross-match");
        assertEq(ctf.balanceOf(user5, yesPositionIds[3]), makerFillAmounts[0], "User5 should receive YES tokens from cross-match");
        
        // Verify USDC balance changes (users should pay for tokens received)
        assertEq(usdc.balanceOf(user1), (initialUser1USDC - (makerFillAmounts[0] * takerOrder.order.price)/1e6), "User1 should pay USDC for tokens received");
        assertEq(usdc.balanceOf(user2), (initialUser2USDC - (makerFillAmounts[0] * makerOrders[0].orders[0].order.price)/1e6), "User2 should pay USDC for tokens received");
        assertEq(usdc.balanceOf(user3), (initialUser3USDC - (makerFillAmounts[0] * makerOrders[0].orders[0].order.price)/1e6), "User3 should pay USDC for tokens received");
        assertEq(usdc.balanceOf(user4), (initialUser4USDC - (makerFillAmounts[0] * makerOrders[0].orders[0].order.price)/1e6), "User4 should pay USDC for tokens received");
        assertEq(usdc.balanceOf(user5), (initialUser5USDC - (makerFillAmounts[0] * makerOrders[0].orders[0].order.price)/1e6), "User5 should pay USDC for tokens received");
        
        // Verify no tokens were left in adapter
        for (uint256 i = 0; i < 5; i++) {
            assertEq(ctf.balanceOf(address(adapter), yesPositionIds[i]), 0, 
                string(abi.encodePacked("Adapter should not hold any YES tokens for question ", vm.toString(i))));
        }
        
        console.log("Extreme price distribution test passed!");
    }

    // ========================================
    // SELF-FINANCING VERIFICATION TESTS
    // ========================================

    function testHybridMatchOrdersSelfFinancingProperty() public {
        console.log("=== Testing Self-Financing Property ===");
        
        // Create 4 questions
        bytes32[] memory questionIds = new bytes32[](4);
        uint256[] memory yesPositionIds = new uint256[](4);
        
        for (uint256 i = 0; i < 4; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        vm.prank(oracle);
        negRiskOperator.reportPayouts(bytes32(0), dummyPayout);

        vm.warp(block.timestamp + 2 * negRiskOperator.DELAY_PERIOD());

        negRiskOperator.resolveQuestion(questionId);

        // Record initial adapter balances
        uint256 initialUSDCBalance = usdc.balanceOf(address(adapter));
        uint256 initialWCOLBalance = negRiskAdapter.wcol().balanceOf(address(adapter));
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](2);
        uint256[] memory makerFillAmounts = new uint256[](2);
        
        // Single order - price 0.25
        makerOrders[0].orders = new ICTFExchange.OrderIntent[](1);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[3], 1, 1e6, 0.25e6, questionIds[3], 1, _user2PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.SINGLE;
        makerFillAmounts[0] = 0.1e6;

        _mintTokensToUser(user2, yesPositionIds[3], 1e6);

        vm.prank(user2);
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        
        // Cross-match order - prices 0.35 + 0.25 + 0.15 = 0.75
        makerOrders[1].orders = new ICTFExchange.OrderIntent[](3);
        makerOrders[1].orders[0] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.35e6, 1e6, questionIds[1], 0, _user3PK);
        makerOrders[1].orders[1] = _createAndSignOrder(user4, yesPositionIds[2], 0, 0.25e6, 1e6, questionIds[2], 0, _user4PK);
        makerOrders[1].orders[2] = _createAndSignOrder(user5, yesPositionIds[0], 0, 0.15e6, 1e6, questionIds[0], 0, _user5PK);
        makerOrders[1].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        makerFillAmounts[1] = 0.1e6;
        
        // Taker order - price 0.25
        // Total prices: 0.25 + 0.75 = 1.0
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[3], 0, 0.25e6, 1e6, questionIds[3], 0, _user1PK);
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 1);
        
        // Verify self-financing property
        uint256 finalUSDCBalance = usdc.balanceOf(address(adapter));
        uint256 finalWCOLBalance = negRiskAdapter.wcol().balanceOf(address(adapter));
        
        assertEq(finalUSDCBalance, initialUSDCBalance, "Adapter should have no net USDC change");
        assertEq(finalWCOLBalance, initialWCOLBalance, "Adapter should have no net WCOL change");
        
        console.log("Self-financing property test passed!");
    }


    // TODO: need to check this with vaibhav
    function testHybridMatchOrdersSelfFinancingPropertyMintSellOrder() public {
        console.log("=== Testing Self-Financing Property with mint and sell order ===");
        
        // Create 4 questions
        bytes32[] memory questionIds = new bytes32[](4);
        uint256[] memory yesPositionIds = new uint256[](4);
        
        for (uint256 i = 0; i < 4; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }

        vm.prank(oracle);
        negRiskOperator.reportPayouts(bytes32(0), dummyPayout);

        vm.warp(block.timestamp + 2 * negRiskOperator.DELAY_PERIOD());

        negRiskOperator.resolveQuestion(questionId);
        
        // Record initial adapter balances
        uint256 initialUSDCBalance = usdc.balanceOf(address(adapter));
        uint256 initialWCOLBalance = negRiskAdapter.wcol().balanceOf(address(adapter));
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](2);
        uint256[] memory makerFillAmounts = new uint256[](2);

        uint256 noPositionId3 = negRiskAdapter.getPositionId(questionIds[3], false);
        
        // Single order - price 0.25
        makerOrders[0].orders = new ICTFExchange.OrderIntent[](1);
        // need to check this with vaibhav
        makerOrders[0].orders[0] = _createAndSignOrder(user2, noPositionId3, 0, 0.75e6, 1e6, questionIds[3], 1, _user2PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.SINGLE;
        makerFillAmounts[0] = 0.1e6;

        // _mintTokensToUser(user2, yesPositionIds[3], 1e6);
        MockUSDC(address(usdc)).mint(address(user2), 1e6);
        MockUSDC(address(usdc)).mint(address(negRiskAdapter.wcol()), 1e6);
        MockUSDC(address(usdc)).mint(address(ctfExchange), 1e6);

        vm.prank(user2);
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        
        // Cross-match order - prices 0.35 + 0.25 + 0.15 = 0.75
        makerOrders[1].orders = new ICTFExchange.OrderIntent[](3);
        makerOrders[1].orders[0] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.35e6, 1e6, questionIds[1], 0, _user3PK);
        makerOrders[1].orders[1] = _createAndSignOrder(user4, yesPositionIds[2], 0, 0.25e6, 1e6, questionIds[2], 0, _user4PK);
        makerOrders[1].orders[2] = _createAndSignOrder(user5, yesPositionIds[0], 0, 0.15e6, 1e6, questionIds[0], 0, _user5PK);
        makerOrders[1].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        makerFillAmounts[1] = 0.1e6;
        
        // Taker order - price 0.25
        // Total prices: 0.25 + 0.75 = 1.0
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[3], 0, 0.25e6, 1e6, questionIds[3], 0, _user1PK);
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 1);
        
        // Verify self-financing property
        uint256 finalUSDCBalance = usdc.balanceOf(address(adapter));
        uint256 finalWCOLBalance = negRiskAdapter.wcol().balanceOf(address(adapter));
        
        assertEq(finalUSDCBalance, initialUSDCBalance, "Adapter should have no net USDC change");
        assertEq(finalWCOLBalance, initialWCOLBalance, "Adapter should have no net WCOL change");
        
        console.log("Self-financing property test passed!");
    }

    function testHybridMatchOrdersBalanceConservation() public {
        console.log("=== Testing Balance Conservation ===");
        
        // Create 3 questions
        bytes32[] memory questionIds = new bytes32[](3);
        uint256[] memory yesPositionIds = new uint256[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }

        vm.prank(oracle);
        negRiskOperator.reportPayouts(bytes32(0), dummyPayout);

        vm.warp(block.timestamp + 2 * negRiskOperator.DELAY_PERIOD());

        negRiskOperator.resolveQuestion(questionId);
        
        // Record initial total balances
        uint256 initialTotalUSDC = usdc.totalSupply();
        uint256 initialVaultUSDC = usdc.balanceOf(vault);
        uint256 initialUser1USDC = usdc.balanceOf(user1);
        uint256 initialUser2USDC = usdc.balanceOf(user2);
        uint256 initialUser3USDC = usdc.balanceOf(user3);
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        uint256[] memory makerFillAmounts = new uint256[](1);
        
        // Cross-match order - prices 0.3 + 0.4 = 0.7
        makerOrders[0].orders = new ICTFExchange.OrderIntent[](2);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.3e6, 1e6, questionIds[0], 0, _user2PK);
        makerOrders[0].orders[1] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.4e6, 1e6, questionIds[1], 0, _user3PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        makerFillAmounts[0] = 0.1e6;
        
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[2], 0, 0.3e6, 1e6, questionIds[2], 0, _user1PK);
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 0);
        
        // Verify token balances
        assertEq(ctf.balanceOf(user1, yesPositionIds[2]), makerFillAmounts[0], "User1 should receive YES tokens from taker order");
        assertEq(ctf.balanceOf(user2, yesPositionIds[0]), makerFillAmounts[0], "User2 should receive YES tokens from cross-match");
        assertEq(ctf.balanceOf(user3, yesPositionIds[1]), makerFillAmounts[0], "User3 should receive YES tokens from cross-match");
        
        // Verify USDC balance changes
        assertEq(usdc.balanceOf(user1), initialUser1USDC - (makerFillAmounts[0] * takerOrder.order.price)/1e6, "User1 should pay USDC for tokens received");
        assertEq(usdc.balanceOf(user2), initialUser2USDC - (makerFillAmounts[0] * makerOrders[0].orders[0].order.price)/1e6, "User2 should pay USDC for tokens received");
        assertEq(usdc.balanceOf(user3), initialUser3USDC - (makerFillAmounts[0] * makerOrders[0].orders[1].order.price)/1e6, "User3 should pay USDC for tokens received");
        
        // Verify no tokens were left in adapter
        assertEq(ctf.balanceOf(address(adapter), yesPositionIds[0]), 0, "Adapter should not hold any YES tokens");
        assertEq(ctf.balanceOf(address(adapter), yesPositionIds[1]), 0, "Adapter should not hold any YES tokens");
        assertEq(ctf.balanceOf(address(adapter), yesPositionIds[2]), 0, "Adapter should not hold any YES tokens");
        
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
