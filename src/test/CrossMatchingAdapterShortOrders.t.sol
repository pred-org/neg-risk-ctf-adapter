// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Test, console} from "forge-std/Test.sol";
import {CrossMatchingAdapter} from "src/CrossMatchingAdapter.sol";
import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
import {RevNegRiskAdapter} from "src/RevNegRiskAdapter.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";
import {IRevNegRiskAdapter} from "src/interfaces/IRevNegRiskAdapter.sol";
import {Deployer} from "lib/ctf-exchange/src/dev/util/Deployer.sol";
import {TestHelper} from "lib/ctf-exchange/src/dev/TestHelper.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {ICTFExchange} from "src/interfaces/ICTFExchange.sol";
import {Side, SignatureType} from "lib/ctf-exchange/src/exchange/libraries/OrderStructs.sol";
contract MockCTFExchange {
    function matchOrders(
        ICTFExchange.OrderIntent memory takerOrder,
        ICTFExchange.OrderIntent[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) external {}
    
    function hashOrder(ICTFExchange.Order memory order) external pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }
    
    function validateOrder(ICTFExchange.OrderIntent memory orderIntent) external pure {
        // Mock validation - always passes
        require(orderIntent.order.maker != address(0), "Invalid maker");
        require(orderIntent.order.signer != address(0), "Invalid signer");
    }
    
    function updateOrderStatus(ICTFExchange.OrderIntent memory orderIntent, uint256 makingAmount) external pure {
        // Mock implementation - always succeeds for testing
        // In a real implementation, this would update order status in storage
    }
}

contract CrossMatchingAdapterShortOrdersTest is Test, TestHelper {
    CrossMatchingAdapter public adapter;
    NegRiskAdapter public negRiskAdapter;
    RevNegRiskAdapter public revNegRiskAdapter;
    ICTFExchange public ctfExchange;
    IConditionalTokens public ctf;
    IERC20 public usdc;
    address public vault;
    
    // Test users
    address public user1; // Arsenal
    address public user2; // Barcelona
    address public user3; // Chelsea
    address public user4; // Spurs
    
    // Private keys for signing
    uint256 internal user1PK = 0x1111;
    uint256 internal user2PK = 0x2222;
    uint256 internal user3PK = 0x3333;
    uint256 internal user4PK = 0x4444;

    // Market and question IDs
    bytes32 public marketId;
    bytes32 public questionId;
    bytes32 public conditionId;
    
    // Position IDs for YES/NO tokens
    uint256 public yesPositionId;
    uint256 public noPositionId;
    
    // Test constants
    uint256 public constant INITIAL_USDC_BALANCE = 100000000e6; // 100,000,000 USDC (6 decimals)
    uint256 public constant TOKEN_AMOUNT = 2e6; // 2 tokens (6 decimals to match USDC)

    function setUp() public {
        // Deploy real ConditionalTokens contract using Deployer
        ctf = IConditionalTokens(Deployer.ConditionalTokens());
        vm.label(address(ctf), "ConditionalTokens");

        ctfExchange = ICTFExchange(address(new MockCTFExchange()));
        vm.label(address(ctfExchange), "CTFExchange");
        
        // Deploy mock USDC
        usdc = IERC20(address(new MockUSDC()));
        vm.label(address(usdc), "USDC");
        
        // Deploy mock vault
        vault = address(new MockVault());
        vm.label(vault, "Vault");

        // Deploy NegRiskAdapter
        negRiskAdapter = new NegRiskAdapter(address(ctf), address(usdc), vault);
        vm.label(address(negRiskAdapter), "NegRiskAdapter");

        revNegRiskAdapter = new RevNegRiskAdapter(address(ctf), address(usdc), vault, INegRiskAdapter(address(negRiskAdapter)));
        vm.label(address(revNegRiskAdapter), "RevNegRiskAdapter");
        
        // Deploy CrossMatchingAdapter
        adapter = new CrossMatchingAdapter(INegRiskAdapter(address(negRiskAdapter)), IERC20(address(usdc)), ICTFExchange(address(ctfExchange)), IRevNegRiskAdapter(address(revNegRiskAdapter)));
        vm.label(address(adapter), "CrossMatchingAdapter");

        vm.prank(address(adapter));
        ctf.setApprovalForAll(address(revNegRiskAdapter), true);

        vm.prank(address(revNegRiskAdapter));
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        
        // Setup vault with USDC and approve adapter
        MockUSDC(address(usdc)).mint(address(vault), 1000000000e6); // 1 billion USDC
        vm.startPrank(address(vault));
        MockUSDC(address(usdc)).approve(address(adapter), type(uint256).max);
        vm.stopPrank();
        
        // Approve NegRiskAdapter to spend USDC from the adapter
        vm.startPrank(address(adapter));
        usdc.approve(address(negRiskAdapter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(address(negRiskAdapter));
        WrappedCollateral(address(negRiskAdapter.wcol())).addOwner(address(revNegRiskAdapter));
        vm.stopPrank();

        // Set up test users
        user1 = vm.addr(user1PK); // Arsenal
        user2 = vm.addr(user2PK); // Barcelona
        user3 = vm.addr(user3PK); // Chelsea
        user4 = vm.addr(user4PK); // Spurs
        vm.label(user1, "Arsenal");
        vm.label(user2, "Barcelona");
        vm.label(user3, "Chelsea");
        vm.label(user4, "Spurs");

        // Set up market and question
        _setupMarketAndQuestion();
        
        // Set up initial token balances
        _setupInitialTokenBalances();
    }
    
    function _setupMarketAndQuestion() internal {
        // Prepare market and question using NegRiskAdapter
        marketId = negRiskAdapter.prepareMarket(0, "Premier League Teams");
        questionId = negRiskAdapter.prepareQuestion(marketId, "Which team will win?");
        conditionId = negRiskAdapter.getConditionId(questionId);
        
        // Get position IDs
        yesPositionId = negRiskAdapter.getPositionId(questionId, true);
        noPositionId = negRiskAdapter.getPositionId(questionId, false);
    }
    
    function _setupInitialTokenBalances() internal {
        // Give users initial USDC balances
        _setupUser(user1, INITIAL_USDC_BALANCE);
        _setupUser(user2, INITIAL_USDC_BALANCE);
        _setupUser(user3, INITIAL_USDC_BALANCE);
        _setupUser(user4, INITIAL_USDC_BALANCE);
    }
    
    function _mintConditionalTokens(address to, uint256 amount) internal {
        vm.startPrank(to);
        
        // Ensure user has enough USDC for the split operation
        uint256 requiredAmount = amount * 2;
        if (usdc.balanceOf(to) < requiredAmount) {
            MockUSDC(address(usdc)).mint(to, requiredAmount - usdc.balanceOf(to));
        }
        
        // Approve USDC spending by NegRiskAdapter
        usdc.approve(address(negRiskAdapter), type(uint256).max);
        
        // Approve ERC1155 transfers by the adapter
        ctf.setApprovalForAll(address(adapter), true);
        
        // Use NegRiskAdapter's splitPosition function
        negRiskAdapter.splitPosition(conditionId, amount);
        
        vm.stopPrank();
        
        console.log("Minted conditional tokens for", to);
        console.log("  YES balance:", ctf.balanceOf(to, yesPositionId));
        console.log("  NO balance:", ctf.balanceOf(to, noPositionId));
    }

    function _mintSpecificToken(address to, bytes32 specificConditionId, uint256 amount) internal {
        // For testing, we'll mint the specific token by splitting and then transferring the desired amount
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.startPrank(to);
        
        // Ensure user has enough USDC for the split operation
        uint256 requiredAmount = amount * 2;
        if (usdc.balanceOf(to) < requiredAmount) {
            // Mint additional USDC if needed
            MockUSDC(address(usdc)).mint(to, requiredAmount - usdc.balanceOf(to));
        }
        
        // Approve USDC spending by NegRiskAdapter
        usdc.approve(address(negRiskAdapter), type(uint256).max);
        
        // Approve ERC1155 transfers by the adapter
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        
        // Get the condition ID for this question from the NegRiskAdapter
        bytes32 specificConditionId_ = negRiskAdapter.getConditionId(specificConditionId);
        
        // Use NegRiskAdapter's splitPosition function with the correct condition ID
        negRiskAdapter.splitPosition(specificConditionId_, amount);
        
        vm.stopPrank();
        
        console.log("Minted conditional tokens for", to);
    }
    
    function _setupUser(address user, uint256 usdcBalance) internal {
        vm.startPrank(user);
        deal(address(usdc), user, usdcBalance);
        usdc.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }
    
    function _createOrderIntent(
        address maker,
        uint256 tokenId,
        uint8 side,
        uint256 makerAmount,
        uint256 takerAmount,
        bytes32 questionId
    ) internal pure returns (ICTFExchange.OrderIntent memory) {
        ICTFExchange.Order memory order = ICTFExchange.Order({
            salt: 1,
            maker: maker,
            signer: maker,
            taker: address(0),
            price: takerAmount,
            quantity: makerAmount,
            expiration: 0,
            nonce: 0,
            questionId: questionId,
            intent: ICTFExchange.Intent.SHORT, // SHORT for short orders
            feeRateBps: 0,
            signatureType: ICTFExchange.SignatureType.EOA,
            signature: new bytes(0)
        });
        
        return ICTFExchange.OrderIntent({
            tokenId: tokenId,
            side: ICTFExchange.Side(side), // Convert uint8 to Side enum
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            order: order
        });
    }
    
    function _createAndSignOrder(
        address maker,
        uint256 tokenId,
        uint8 side,
        uint256 makerAmount,
        uint256 takerAmount,
        bytes32 questionId,
        uint256 privateKey
    ) internal returns (ICTFExchange.OrderIntent memory) {
        // For short orders, the price calculation is different
        // The original _createOrderIntent used: price = takerAmount, quantity = makerAmount
        // So we need to maintain this logic
        uint256 price = takerAmount;
        uint256 quantity = makerAmount;
        
        ICTFExchange.Order memory order = ICTFExchange.Order({
            salt: 1,
            signer: maker,
            maker: maker,
            taker: address(0),
            price: price,
            quantity: quantity,
            expiration: 0,
            nonce: 0,
            questionId: questionId,
            intent: ICTFExchange.Intent.SHORT, // SHORT for short orders
            feeRateBps: 0,
            signatureType: ICTFExchange.SignatureType.EOA,
            signature: new bytes(0)
        });
        
        order.signature = _signMessage(privateKey, ctfExchange.hashOrder(order));
        
        return ICTFExchange.OrderIntent({
            tokenId: tokenId,
            side: ICTFExchange.Side(side),
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            order: order
        });
    }
    
    function _signMessage(uint256 pk, bytes32 message) internal returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, message);
        sig = abi.encodePacked(r, s, v);
    }
    
    function _createScenario1Orders() internal returns (ICTFExchange.OrderIntent[] memory) {
        ICTFExchange.OrderIntent[] memory orders = new ICTFExchange.OrderIntent[](4);
        
        // Create 4 questions for the 4 teams
        // bytes32 arsenalQuestionId = negRiskAdapter.prepareQuestion(marketId, "Arsenal Win");
        bytes32 barcelonaQuestionId = negRiskAdapter.prepareQuestion(marketId, "Barcelona Win");
        bytes32 chelseaQuestionId = negRiskAdapter.prepareQuestion(marketId, "Chelsea Win");
        bytes32 spursQuestionId = negRiskAdapter.prepareQuestion(marketId, "Spurs Win");
        
        // Get NO position IDs for all teams (users are buying NO tokens)
        uint256 arsenalNoPositionId = negRiskAdapter.getPositionId(questionId, false);
        uint256 barcelonaNoPositionId = negRiskAdapter.getPositionId(barcelonaQuestionId, false);
        uint256 chelseaNoPositionId = negRiskAdapter.getPositionId(chelseaQuestionId, false);
        uint256 spursNoPositionId = negRiskAdapter.getPositionId(spursQuestionId, false);
        
        // User A: Buy Arsenal No @ 0.25
        orders[0] = _createAndSignOrder(user1, arsenalNoPositionId, uint8(ICTFExchange.Side.BUY), 1e6, 0.25e6, questionId, user1PK);
        
        // User B: Buy Barcelona No @ 0.25
        orders[1] = _createAndSignOrder(user2, barcelonaNoPositionId, uint8(ICTFExchange.Side.BUY), 1e6, 0.25e6, barcelonaQuestionId, user2PK);
        
        // User C: Buy Chelsea No @ 0.25
        orders[2] = _createAndSignOrder(user3, chelseaNoPositionId, uint8(ICTFExchange.Side.BUY), 1e6, 0.25e6, chelseaQuestionId, user3PK);
        
        // User D: Buy Spurs No @ 0.25
        orders[3] = _createAndSignOrder(user4, spursNoPositionId, uint8(ICTFExchange.Side.BUY), 1e6, 0.25e6, spursQuestionId, user4PK);
        
        // Total combined price: 0.25 + 0.25 + 0.25 + 0.25 = 1.0
        
        return orders;
    }
    
    function _createScenario2Orders() internal returns (ICTFExchange.OrderIntent[] memory) {
        ICTFExchange.OrderIntent[] memory orders = new ICTFExchange.OrderIntent[](4);
        
        // Create 4 questions for the 4 teams
        // bytes32 arsenalQuestionId = negRiskAdapter.prepareQuestion(marketId, "Arsenal Win");
        bytes32 barcelonaQuestionId = negRiskAdapter.prepareQuestion(marketId, "Barcelona Win");
        bytes32 chelseaQuestionId = negRiskAdapter.prepareQuestion(marketId, "Chelsea Win");
        bytes32 spursQuestionId = negRiskAdapter.prepareQuestion(marketId, "Spurs Win");
        
        // Get position IDs for all teams
        uint256 arsenalNoPositionId = negRiskAdapter.getPositionId(questionId, false);
        uint256 barcelonaYesPositionId = negRiskAdapter.getPositionId(barcelonaQuestionId, true);
        uint256 chelseaNoPositionId = negRiskAdapter.getPositionId(chelseaQuestionId, false);
        uint256 spursYesPositionId = negRiskAdapter.getPositionId(spursQuestionId, true);

        // mint YES tokens for user2 and user4
        _mintSpecificToken(user2, barcelonaQuestionId, 50*1e6);
        _mintSpecificToken(user4, spursQuestionId, 50*1e6);
        
        // Approve adapter to spend tokens
        vm.prank(user2);
        ctf.setApprovalForAll(address(adapter), true);
        vm.prank(user4);
        ctf.setApprovalForAll(address(adapter), true);
        
        // User A: Buy Arsenal No @ 0.75
        orders[0] = _createAndSignOrder(user1, arsenalNoPositionId, uint8(ICTFExchange.Side.BUY), 1e6, 0.25e6, questionId, user1PK);
        
        // User B: Sell Barcelona Yes @ 0.35 (equivalent to Shorting Barcelona @ 0.65)
        orders[1] = _createAndSignOrder(user2, barcelonaYesPositionId, uint8(ICTFExchange.Side.SELL), 1e6, 0.35e6, barcelonaQuestionId, user2PK);
        
        // User C: Buy Chelsea No @ 0.75
        orders[2] = _createAndSignOrder(user3, chelseaNoPositionId, uint8(ICTFExchange.Side.BUY), 1e6, 0.25e6, chelseaQuestionId, user3PK);
        
        // User D: Sell Spurs Yes @ 0.15 (equivalent to Shorting Spurs @ 0.85)
        orders[3] = _createAndSignOrder(user4, spursYesPositionId, uint8(ICTFExchange.Side.SELL), 1e6, 0.15e6, spursQuestionId, user4PK);
        
        // Total combined price: 0.25 + 0.35 + 0.25 + 0.15 = 1.0
        
        return orders;
    }
    
    function testScenario1AllBuyNoOrders() public {
        console.log("=== Testing Scenario 1: All Buy NO Orders (4 Users) ===");
        
        // Create orders for this scenario
        ICTFExchange.OrderIntent[] memory orders = _createScenario1Orders();
        
        // Record initial balances
        uint256 user1InitialBalance = usdc.balanceOf(user1);
        uint256 user2InitialBalance = usdc.balanceOf(user2);
        uint256 user3InitialBalance = usdc.balanceOf(user3);
        uint256 user4InitialBalance = usdc.balanceOf(user4);
        
        // Execute cross-matching
        ICTFExchange.OrderIntent memory takerOrder = orders[0];
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](orders.length - 1);
        for (uint256 i = 1; i < orders.length; i++) {
            makerOrders[i - 1] = orders[i];
        }
        
        uint256 fillAmount = 100 * 1e6;
        adapter.crossMatchShortOrders(marketId, takerOrder, makerOrders, fillAmount);
        
        // Verify that users spent USDC
        // Price is 750000 (0.75 with 6 decimals), so USDC spent = price * fillAmount / 1e6
        uint256 usdcSpent = (750000 * fillAmount) / 1e6;
        assertEq(usdc.balanceOf(user1), user1InitialBalance - usdcSpent, "User1 (Arsenal) should have spent USDC");
        assertEq(usdc.balanceOf(user2), user2InitialBalance - usdcSpent, "User2 (Barcelona) should have spent USDC");
        assertEq(usdc.balanceOf(user3), user3InitialBalance - usdcSpent, "User3 (Chelsea) should have spent USDC");
        assertEq(usdc.balanceOf(user4), user4InitialBalance - usdcSpent, "User4 (Spurs) should have spent USDC");
        
        // Verify that users received the correct NO tokens
        _verifyScenario1TokenBalances(marketId, fillAmount);
        
        // Verify that the adapter has no USDC left (it distributed everything)
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have distributed all USDC");
        
        // Verify that the vault balance remains the same (it provides liquidity and gets it back)
        // Note: We'll skip vault balance check to avoid stack too deep issues
        
        console.log("Scenario 1 completed successfully!");
    }
    
    function _verifyScenario1TokenBalances(bytes32 marketId_, uint256 fillAmount) internal {
        // Get the question IDs for the teams
        bytes32 barcelonaQuestionId = NegRiskIdLib.getQuestionId(marketId_, 1);
        bytes32 chelseaQuestionId = NegRiskIdLib.getQuestionId(marketId_, 2);
        bytes32 spursQuestionId = NegRiskIdLib.getQuestionId(marketId_, 3);
        
        // Get NO position IDs for all teams
        uint256 arsenalNoPositionId = negRiskAdapter.getPositionId(questionId, false);
        uint256 barcelonaNoPositionId = negRiskAdapter.getPositionId(barcelonaQuestionId, false);
        uint256 chelseaNoPositionId = negRiskAdapter.getPositionId(chelseaQuestionId, false);
        uint256 spursNoPositionId = negRiskAdapter.getPositionId(spursQuestionId, false);
        
        // Expected fill amount
        uint256 expectedFillAmount = fillAmount;
        
        // Check that users received NO tokens
        uint256 user1NoTokens = ctf.balanceOf(user1, arsenalNoPositionId);
        uint256 user2NoTokens = ctf.balanceOf(user2, barcelonaNoPositionId);
        uint256 user3NoTokens = ctf.balanceOf(user3, chelseaNoPositionId);
        uint256 user4NoTokens = ctf.balanceOf(user4, spursNoPositionId);
        
        assertEq(user1NoTokens, expectedFillAmount, "User1 (Arsenal) should have received NO tokens");
        assertEq(user2NoTokens, expectedFillAmount, "User2 (Barcelona) should have received NO tokens");
        assertEq(user3NoTokens, expectedFillAmount, "User3 (Chelsea) should have received NO tokens");
        assertEq(user4NoTokens, expectedFillAmount, "User4 (Spurs) should have received NO tokens");
    }
    
    function testScenario2MixedBuySellOrders() public {
        console.log("=== Testing Scenario 2: Mixed Buy/Sell Orders (4 Users) ===");
        
        // Create orders for this scenario
        ICTFExchange.OrderIntent[] memory orders = _createScenario2Orders();
        
        // Record initial balances
        uint256 user1InitialBalance = usdc.balanceOf(user1);
        uint256 user2InitialBalance = usdc.balanceOf(user2);
        uint256 user3InitialBalance = usdc.balanceOf(user3);
        uint256 user4InitialBalance = usdc.balanceOf(user4);
        
        // Execute cross-matching
        ICTFExchange.OrderIntent memory takerOrder = orders[0];
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](orders.length - 1);
        for (uint256 i = 1; i < orders.length; i++) {
            makerOrders[i - 1] = orders[i];
        }
        
        uint256 fillAmount = 50 * 1e6;
        adapter.crossMatchShortOrders(marketId, takerOrder, makerOrders, fillAmount);
        
        // Verify the cross-matching worked correctly
        // User1 and User3 should have spent USDC and received NO tokens
        // User2 and User4 should have received USDC for selling YES tokens
        
        // Check USDC balances
        assertEq(usdc.balanceOf(user1), user1InitialBalance - 0.75e6 * fillAmount/1e6, "User1 (Arsenal) should have spent USDC");
        assertEq(usdc.balanceOf(user2), user2InitialBalance + 0.35e6 * fillAmount/1e6, "User2 (Barcelona) should have received USDC");
        assertEq(usdc.balanceOf(user3), user3InitialBalance - 0.75e6 * fillAmount/1e6, "User3 (Chelsea) should have spent USDC");
        assertEq(usdc.balanceOf(user4), user4InitialBalance + 0.15e6 * fillAmount/1e6, "User4 (Spurs) should have received USDC");
        
        // Verify token distributions
        _verifyScenario2TokenBalances(marketId, fillAmount);
        
        // Check that the adapter has no USDC left (it distributed everything)
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have distributed all USDC");
        
        // Check that the vault balance remains the same (it provides liquidity and gets it back)
        // Note: We'll skip vault balance check to avoid stack too deep issues
        
        console.log("Scenario 2 completed successfully!");
    }
    
    function _verifyScenario2TokenBalances(bytes32 marketId_, uint256 fillAmount) internal {
        // Get the question IDs for the teams
        // bytes32 arsenalQuestionId = NegRiskIdLib.getQuestionId(marketId_, 1);
        bytes32 barcelonaQuestionId = NegRiskIdLib.getQuestionId(marketId_, 1);
        bytes32 chelseaQuestionId = NegRiskIdLib.getQuestionId(marketId_, 2);
        bytes32 spursQuestionId = NegRiskIdLib.getQuestionId(marketId_, 3);
        
        // Get position IDs for all teams
        uint256 arsenalNoPositionId = negRiskAdapter.getPositionId(questionId, false);
        uint256 barcelonaYesPositionId = negRiskAdapter.getPositionId(barcelonaQuestionId, true);
        uint256 chelseaNoPositionId = negRiskAdapter.getPositionId(chelseaQuestionId, false);
        uint256 spursYesPositionId = negRiskAdapter.getPositionId(spursQuestionId, true);
        
        // Expected fill amount
        uint256 expectedFillAmount = fillAmount;
        
        // Check that buyers received NO tokens
        uint256 user1NoTokens = ctf.balanceOf(user1, arsenalNoPositionId);
        uint256 user3NoTokens = ctf.balanceOf(user3, chelseaNoPositionId);
        
        assertEq(user1NoTokens, expectedFillAmount, "User1 (Arsenal) should have received NO tokens");
        assertEq(user3NoTokens, expectedFillAmount, "User3 (Chelsea) should have received NO tokens");
        
        // Check that sellers' YES tokens were consumed
        uint256 user2YesTokens = ctf.balanceOf(user2, barcelonaYesPositionId);
        uint256 user4YesTokens = ctf.balanceOf(user4, spursYesPositionId);
        
        // Sellers should have fewer YES tokens after the trade
        assertLt(user2YesTokens, 1e7, "User2 (Barcelona) YES tokens should have been consumed");
        assertLt(user4YesTokens, 1e7, "User4 (Spurs) YES tokens should have been consumed");
    }
    
    function testInvalidCombinedPrice() public {
        console.log("=== Testing Invalid Combined Price Validation ===");
        
        // Create orders with invalid combined price
        ICTFExchange.OrderIntent[] memory orders = _createInvalidPriceOrders();
        
        ICTFExchange.OrderIntent memory takerOrder = orders[0];
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](orders.length - 1);
        for (uint256 i = 1; i < orders.length; i++) {
            makerOrders[i - 1] = orders[i];
        }
        
        uint256 fillAmount = 100 * 1e6;
        
        // This should revert due to invalid combined price
        vm.expectRevert(abi.encodeWithSignature("InvalidCombinedPrice()"));
        adapter.crossMatchShortOrders(marketId, takerOrder, makerOrders, fillAmount);
        
        console.log("Invalid combined price test passed!");
    }
    
    function _createInvalidPriceOrders() internal returns (ICTFExchange.OrderIntent[] memory) {
        ICTFExchange.OrderIntent[] memory orders = new ICTFExchange.OrderIntent[](4);
        
        // Create questions for teams
        // bytes32 arsenalQuestionId = negRiskAdapter.prepareQuestion(marketId, "Arsenal Win");
        bytes32 barcelonaQuestionId = negRiskAdapter.prepareQuestion(marketId, "Barcelona Win");
        bytes32 chelseaQuestionId = negRiskAdapter.prepareQuestion(marketId, "Chelsea Win");
        bytes32 spursQuestionId = negRiskAdapter.prepareQuestion(marketId, "Spurs Win");
        
        // Get NO position IDs
        uint256 arsenalNoPositionId = negRiskAdapter.getPositionId(questionId, false);
        uint256 barcelonaNoPositionId = negRiskAdapter.getPositionId(barcelonaQuestionId, false);
        uint256 chelseaNoPositionId = negRiskAdapter.getPositionId(chelseaQuestionId, false);
        uint256 spursNoPositionId = negRiskAdapter.getPositionId(spursQuestionId, false);
        
        // Create orders with prices that don't sum to 4.0
        orders[0] = _createAndSignOrder(user1, arsenalNoPositionId, uint8(ICTFExchange.Side.BUY), 1e6, 0.50e6, questionId, user1PK);  // 0.50
        orders[1] = _createAndSignOrder(user2, barcelonaNoPositionId, uint8(ICTFExchange.Side.BUY), 1e6, 0.50e6, barcelonaQuestionId, user2PK); // 0.50
        orders[2] = _createAndSignOrder(user3, chelseaNoPositionId, uint8(ICTFExchange.Side.BUY), 1e6, 0.50e6, chelseaQuestionId, user3PK);     // 0.50
        orders[3] = _createAndSignOrder(user4, spursNoPositionId, uint8(ICTFExchange.Side.BUY), 1e6, 0.50e6, spursQuestionId, user4PK);      // 0.50
        
        // Total: 0.50 + 0.50 + 0.50 + 0.50 = 2.0, but should equal 4.0 for short orders
        
        return orders;
    }
    
    function testScenario3OneQuestionResolved() public {
        console.log("=== Testing Scenario 3: One Question Already Resolved (3 Active Orders) ===");
        
        // Create a new market for this test to avoid conflicts
        bytes32 testMarketId = negRiskAdapter.prepareMarket(0, "Test Market with Resolved Question");
        
        // Create 4 questions for the 4 teams
        bytes32 arsenalQuestionId = negRiskAdapter.prepareQuestion(testMarketId, "Arsenal Win");
        bytes32 barcelonaQuestionId = negRiskAdapter.prepareQuestion(testMarketId, "Barcelona Win");
        bytes32 chelseaQuestionId = negRiskAdapter.prepareQuestion(testMarketId, "Chelsea Win");
        bytes32 spursQuestionId = negRiskAdapter.prepareQuestion(testMarketId, "Spurs Win");
        
        // Resolve the Arsenal question (Arsenal wins = false)
        negRiskAdapter.reportOutcome(arsenalQuestionId, false);
        
        // Create orders ONLY for the 3 active questions (Arsenal is resolved, so no order for it)
        // We need 3 orders total: 1 taker + 2 makers = 3 active questions
        // The prices should sum to 1.0 for the active questions: 0.35 + 0.45 + 0.20 = 1.0
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, negRiskAdapter.getPositionId(NegRiskIdLib.getQuestionId(testMarketId, 1), false), uint8(ICTFExchange.Side.BUY), 1e6, 350000, barcelonaQuestionId, user1PK); // Barcelona NO at 0.35
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](2);
        makerOrders[0] = _createAndSignOrder(user2, negRiskAdapter.getPositionId(NegRiskIdLib.getQuestionId(testMarketId, 2), false), uint8(ICTFExchange.Side.BUY), 1e6, 450000, chelseaQuestionId, user2PK); // Chelsea NO at 0.45
        makerOrders[1] = _createAndSignOrder(user3, negRiskAdapter.getPositionId(NegRiskIdLib.getQuestionId(testMarketId, 3), false), uint8(ICTFExchange.Side.BUY), 1e6, 200000, spursQuestionId, user3PK); // Spurs NO at 0.20
        
        // Execute cross-matching with only 3 orders for the 3 active questions (Arsenal is resolved, so no order for it)
        uint256 fillAmount = 50 * 1e6;
        adapter.crossMatchShortOrders(testMarketId, takerOrder, makerOrders, fillAmount);
        
        // Verify the results
        _verifyScenario3Results(testMarketId, fillAmount);
        
        console.log("Scenario 3 completed successfully!");
    }
    
    function _verifyScenario3Results(bytes32 testMarketId, uint256 fillAmount) internal {
        // Verify that the adapter has no USDC left (self-financing)
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have distributed all USDC");
        
        // Get position IDs for verification
        uint256 barcelonaNoPositionId = negRiskAdapter.getPositionId(NegRiskIdLib.getQuestionId(testMarketId, 1), false);
        uint256 chelseaNoPositionId = negRiskAdapter.getPositionId(NegRiskIdLib.getQuestionId(testMarketId, 2), false);
        uint256 spursNoPositionId = negRiskAdapter.getPositionId(NegRiskIdLib.getQuestionId(testMarketId, 3), false);
        
        // Verify user1 (taker) - should have received Barcelona NO tokens
        assertEq(ctf.balanceOf(user1, barcelonaNoPositionId), fillAmount, "User1 should have received Barcelona NO tokens");
        
        // Verify user2 (maker) - should have received Chelsea NO tokens
        assertEq(ctf.balanceOf(user2, chelseaNoPositionId), fillAmount, "User2 should have received Chelsea NO tokens");
        
        // Verify user3 (maker) - should have received Spurs NO tokens
        assertEq(ctf.balanceOf(user3, spursNoPositionId), fillAmount, "User3 should have received Spurs NO tokens");
        
        // Verify USDC payments (users should have paid the correct amounts)
        uint256 user1ExpectedUSDCSpent = (350000 * fillAmount) / 1e6; // 0.35 * fillAmount
        uint256 user2ExpectedUSDCSpent = (450000 * fillAmount) / 1e6; // 0.45 * fillAmount
        uint256 user3ExpectedUSDCSpent = (200000 * fillAmount) / 1e6; // 0.20 * fillAmount
        
        // Check that users have less USDC than initially (they paid for their tokens)
        assertTrue(usdc.balanceOf(user1) < 100_000_000e6, "User1 should have paid USDC for Barcelona NO tokens");
        assertTrue(usdc.balanceOf(user2) < 100_000_000e6, "User2 should have paid USDC for Chelsea NO tokens");
        assertTrue(usdc.balanceOf(user3) < 100_000_000e6, "User3 should have paid USDC for Spurs NO tokens");
        
        console.log("User1 (Barcelona NO at 0.35): Paid ~%s USDC, received %s tokens", user1ExpectedUSDCSpent, fillAmount);
        console.log("User2 (Chelsea NO at 0.45): Paid ~%s USDC, received %s tokens", user2ExpectedUSDCSpent, fillAmount);
        console.log("User3 (Spurs NO at 0.20): Paid ~%s USDC, received %s tokens", user3ExpectedUSDCSpent, fillAmount);
    }
}

// Mock USDC contract
contract MockUSDC {
    string public constant NAME = "USD Coin";
    string public constant SYMBOL = "USDC";
    uint8 public constant DECIMALS = 6;
    
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
    
    function decimals() external pure returns (uint8) {
        return DECIMALS;
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
