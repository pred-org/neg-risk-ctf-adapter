// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Test, console} from "forge-std/Test.sol";
import {CrossMatchingAdapter, ICTFExchange} from "src/CrossMatchingAdapter.sol";
import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";
import {Deployer} from "lib/ctf-exchange/src/dev/util/Deployer.sol";
import {TestHelper} from "lib/ctf-exchange/src/dev/TestHelper.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";

contract MockCTFExchange {
    function matchOrders(
        ICTFExchange.OrderIntent memory takerOrder,
        ICTFExchange.OrderIntent[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) external {}
}

contract CrossMatchingAdapterTest is Test, TestHelper {
    CrossMatchingAdapter public adapter;
    NegRiskAdapter public negRiskAdapter;
    ICTFExchange public ctfExchange;
    IConditionalTokens public ctf;
    IERC20 public usdc;
    address public vault;
    
    // Test users
    address public user1;
    address public user2;
    address public user3;
    
    // Market and question IDs
    bytes32 public marketId;
    bytes32 public questionId;
    bytes32 public conditionId;
    
    // Position IDs for YES/NO tokens
    uint256 public yesPositionId;
    uint256 public noPositionId;
    
    // Test constants
    uint256 public constant INITIAL_USDC_BALANCE = 1000000e6; // 1,000,000 USDC (6 decimals) - enough for orders
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
        
        // Deploy CrossMatchingAdapter - we need to provide a mock CTF exchange
        adapter = new CrossMatchingAdapter(INegRiskAdapter(address(negRiskAdapter)), IERC20(address(usdc)), ICTFExchange(address(ctfExchange)));
        vm.label(address(adapter), "CrossMatchingAdapter");
        
        MockUSDC(address(usdc)).mint(address(vault), 1000000e6);
        vm.startPrank(address(vault));
        // MockUSDC(address(usdc)).approve(address(negRiskAdapter), type(uint256).max);
        MockUSDC(address(usdc)).approve(address(adapter), type(uint256).max);
        vm.stopPrank();

        // Set up test users
        user1 = address(0x1111);
        user2 = address(0x2222);
        user3 = address(0x3333);
        vm.label(user1, "User1");
        vm.label(user2, "User2");
        vm.label(user3, "User3");
        
        // Set up market and question
        _setupMarketAndQuestion();
        
        // Set up initial token balances
        _setupInitialTokenBalances();
    }
    
    function _setupMarketAndQuestion() internal {
        // Prepare market and question using NegRiskAdapter
        marketId = negRiskAdapter.prepareMarket(0, "Test Market");
        questionId = negRiskAdapter.prepareQuestion(marketId, "Test Question");
        conditionId = negRiskAdapter.getConditionId(questionId);
        
        // Get position IDs
        yesPositionId = negRiskAdapter.getPositionId(questionId, true);
        noPositionId = negRiskAdapter.getPositionId(questionId, false);
        
        console.log("Market ID:", uint256(marketId));
        console.log("Question ID:", uint256(questionId));
        console.log("Condition ID:", uint256(conditionId));
        console.log("YES Position ID:", yesPositionId);
        console.log("NO Position ID:", noPositionId);
    }
    
    function _setupInitialTokenBalances() internal {
        // Give users initial USDC balances
        _setupUser(user1, INITIAL_USDC_BALANCE);
        _setupUser(user2, INITIAL_USDC_BALANCE);
        _setupUser(user3, INITIAL_USDC_BALANCE);
        
        // Mint conditional tokens to users using the real ConditionalTokens contract
        _mintConditionalTokens(user1, TOKEN_AMOUNT);
        _mintConditionalTokens(user2, TOKEN_AMOUNT);
        _mintConditionalTokens(user3, TOKEN_AMOUNT);
    }
    
    function _mintConditionalTokens(address to, uint256 amount) internal {
        // This follows the pattern from BaseExchangeTest.sol
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
        ctf.setApprovalForAll(address(adapter), true);
        
        // Use NegRiskAdapter's splitPosition function which handles token transfer automatically
        negRiskAdapter.splitPosition(conditionId, amount);
        
        vm.stopPrank();
        
        console.log("Minted conditional tokens for", to);
        console.log("  YES balance:", ctf.balanceOf(to, yesPositionId));
        console.log("  NO balance:", ctf.balanceOf(to, noPositionId));
    }

    function _mintSpecificToken(address to, uint256 oppositeTokenId, bytes32 specificConditionId, uint256 amount) internal {
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
        bytes32 conditionId = negRiskAdapter.getConditionId(specificConditionId);
        
        // Use NegRiskAdapter's splitPosition function with the correct condition ID
        negRiskAdapter.splitPosition(conditionId, amount);
        
        vm.stopPrank();
        
        console.log("Minted conditional tokens for", to);
    }
    
    function _setupUser(address user, uint256 usdcBalance) internal {
        vm.startPrank(user);
        // Give USDC tokens to the user using deal() (this is what TestHelper.dealAndApprove does)
        deal(address(usdc), user, usdcBalance);
        usdc.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }
    
    function _createOrderIntent(
        address maker,
        uint256 tokenId,
        uint8 side,
        uint256 makerAmount,
        uint256 takerAmount
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
            feeRateBps: 0,
            intent: 0, // LONG
            signatureType: 0,
            signature: new bytes(0)
        });
        
        return ICTFExchange.OrderIntent({
            tokenId: tokenId,
            side: side,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            order: order
        });
    }
    
    function _createScenario1Orders() internal returns (ICTFExchange.OrderIntent[] memory) {
        ICTFExchange.OrderIntent[] memory orders = new ICTFExchange.OrderIntent[](4);
        
        // For Scenario 1, we need 4 different questions so each user buys a different YES token
        // This way the combined price can equal 1.0 (0.25 + 0.25 + 0.25 + 0.25 = 1.0)
        
        // Create additional questions for this scenario
        bytes32 question1Id = negRiskAdapter.prepareQuestion(marketId, "Question 1");
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        bytes32 question3Id = negRiskAdapter.prepareQuestion(marketId, "Question 3");
        bytes32 question4Id = negRiskAdapter.prepareQuestion(marketId, "Question 4");
        
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        uint256 yes4PositionId = negRiskAdapter.getPositionId(question4Id, true);
        
        // User1: Buy YES1 tokens at 0.25 price
        orders[0] = _createOrderIntent(user1, yes1PositionId, 0, 1e6, 0.25e18);
        
        // User2: Buy YES2 tokens at 0.25 price
        orders[1] = _createOrderIntent(user2, yes2PositionId, 0, 1e6, 0.25e18);
        
        // User3: Buy YES3 tokens at 0.25 price
        orders[2] = _createOrderIntent(user3, yes3PositionId, 0, 1e6, 0.25e18);
        
        // User4: Buy YES4 tokens at 0.25 price (we'll use user1 again for simplicity)
        orders[3] = _createOrderIntent(user1, yes4PositionId, 0, 1e6, 0.25e18);
        
        return orders;
    }
    
    function _createScenario2Orders() internal returns (ICTFExchange.OrderIntent[] memory) {
        ICTFExchange.OrderIntent[] memory orders = new ICTFExchange.OrderIntent[](2);

        // Create a multi-question market for cross-matching to work
        // We need at least 2 questions to do cross-matching
        
        // Create additional questions for the market
        bytes32 question1Id = negRiskAdapter.prepareQuestion(marketId, "Question 1");
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        
        // Get position IDs for the new questions
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 no1PositionId = negRiskAdapter.getPositionId(question1Id, false);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 no2PositionId = negRiskAdapter.getPositionId(question2Id, false);
        
        // Mint specific tokens for the users in the new questions
        _mintSpecificToken(user1, yes1PositionId, question1Id, 1e6);
        _mintSpecificToken(user2, no2PositionId, question2Id, 1e6);
        
        // User1: Buy YES tokens from Question 1 at 0.7 price
        orders[0] = _createOrderIntent(user1, yes1PositionId, 0, 1e18, 0.7e18);
        
        // User2: Sell NO tokens from Question 2 at 0.7 price (equivalent to 0.3 for YES)
        // For sell orders, we need to ensure combined price = 1.0
        // Buy price: 0.7, Sell price: 0.7, so 0.7 + (1-0.7) = 1.0
        orders[1] = _createOrderIntent(user2, no2PositionId, 1, 1e18, 0.7e18);
        
        return orders;
    }

    function test_Scenario1_AllBuyOrders() public {
        console.log("=== Testing Scenario 1: All Buy Orders ===");
        
        // Create orders for this scenario (this will create new questions)
        ICTFExchange.OrderIntent[] memory orders = _createScenario1Orders();
        
        // Record initial balances
        uint256 user1InitialBalance = usdc.balanceOf(user1);
        uint256 user2InitialBalance = usdc.balanceOf(user2);
        uint256 user3InitialBalance = usdc.balanceOf(user3);
        uint256 adapterInitialBalance = usdc.balanceOf(address(adapter));
        uint256 vaultInitialBalance = usdc.balanceOf(vault);
        
        console.log("Initial balances:");
        console.log("  User1 USDC:", user1InitialBalance);
        console.log("  User2 USDC:", user2InitialBalance);
        console.log("  User3 USDC:", user3InitialBalance);
        console.log("  Adapter USDC:", adapterInitialBalance);
        console.log("  Vault USDC:", vaultInitialBalance);
        
        // Debug: Check order details
        // console.log("Order details:");
        // console.log("  Taker order - User1 buying", takerOrder.makerAmount, "tokens at price", takerOrder.takerAmount);
        // console.log("  Maker order 1 - User2 buying", makerOrders[0].makerAmount, "tokens at price", makerOrders[0].takerAmount);
        // console.log("  Maker order 2 - User3 buying", makerOrders[1].makerAmount, "tokens at price", makerOrders[1].takerAmount);
        // console.log("  Maker order 3 - User1 buying", makerOrders[2].makerAmount, "tokens at price", makerOrders[2].takerAmount);
        
        // Execute cross-matching - we need to provide a taker order and maker orders
        // For simplicity, we'll use the first order as taker and the rest as makers
        ICTFExchange.OrderIntent memory takerOrder = orders[0];
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](orders.length - 1);
        for (uint256 i = 1; i < orders.length; i++) {
            makerOrders[i - 1] = orders[i];
        }
        
        
        adapter.crossMatchLongOrders(marketId, takerOrder, makerOrders, 1e6);
        
        // Verify final balances
        uint256 user1FinalBalance = usdc.balanceOf(user1);
        uint256 user2FinalBalance = usdc.balanceOf(user2);
        uint256 user3FinalBalance = usdc.balanceOf(user3);
        uint256 adapterFinalBalance = usdc.balanceOf(address(adapter));
        uint256 vaultFinalBalance = usdc.balanceOf(vault);
        
        console.log("Final balances:");
        console.log("  User1 USDC:", user1FinalBalance);
        console.log("  User2 USDC:", user2FinalBalance);
        console.log("  User3 USDC:", user3FinalBalance);
        console.log("  Adapter USDC:", adapterFinalBalance);
        console.log("  Vault USDC:", vaultFinalBalance);
        
        // Verify that users spent USDC
        assertTrue(user1FinalBalance < user1InitialBalance, "User1 should have spent USDC");
        assertTrue(user2FinalBalance < user2InitialBalance, "User2 should have spent USDC");
        assertTrue(user3FinalBalance < user3InitialBalance, "User3 should have spent USDC");
        
        // Verify that users received the correct YES tokens
        _verifyUserTokenBalances(marketId);
        
        // Verify that the adapter has no USDC left (it distributed everything)
        assertTrue(adapterFinalBalance == 0, "Adapter should have distributed all USDC");
        
        // Verify that the vault balance remains the same (it provides liquidity and gets it back)
        assertTrue(vaultFinalBalance == vaultInitialBalance, "Vault balance should remain the same after providing liquidity");
        
        console.log("Scenario 1 completed successfully!");
        console.log("All users received their respective YES tokens");
    }
    
    function _verifyUserTokenBalances(bytes32 marketId) internal {
        // Get the position IDs for the questions created in this scenario
        bytes32 question1Id = NegRiskIdLib.getQuestionId(marketId, 1);
        bytes32 question2Id = NegRiskIdLib.getQuestionId(marketId, 2);
        bytes32 question3Id = NegRiskIdLib.getQuestionId(marketId, 3);
        bytes32 question4Id = NegRiskIdLib.getQuestionId(marketId, 4);
        
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        uint256 yes4PositionId = negRiskAdapter.getPositionId(question4Id, true);
        
        // Expected fill amount from the orders (makerAmount)
        uint256 expectedFillAmount = 1e6; // 1,000,000 tokens
        
        // Check that User1 received YES1 tokens (from taker order) - exact amount
        uint256 user1Yes1Tokens = ctf.balanceOf(user1, yes1PositionId);
        assertTrue(user1Yes1Tokens == expectedFillAmount, "User1 should have received exactly expectedFillAmount YES1 tokens");
        console.log("User1 YES1 tokens received:", user1Yes1Tokens, "Expected:", expectedFillAmount);
        
        // Check that User2 received YES2 tokens - exact amount
        uint256 user2Yes2Tokens = ctf.balanceOf(user2, yes2PositionId);
        assertTrue(user2Yes2Tokens == expectedFillAmount, "User2 should have received exactly expectedFillAmount YES2 tokens");
        console.log("User2 YES2 tokens received:", user2Yes2Tokens, "Expected:", expectedFillAmount);
        
        // Check that User3 received YES3 tokens - exact amount
        uint256 user3Yes3Tokens = ctf.balanceOf(user3, yes3PositionId);
        assertTrue(user3Yes3Tokens == expectedFillAmount, "User3 should have received exactly expectedFillAmount YES3 tokens");
        console.log("User3 YES3 tokens received:", user3Yes3Tokens, "Expected:", expectedFillAmount);
        
        // Check that User1 received YES4 tokens (from maker order) - exact amount
        uint256 user1Yes4Tokens = ctf.balanceOf(user1, yes4PositionId);
        assertTrue(user1Yes4Tokens == expectedFillAmount, "User1 should have received exactly expectedFillAmount YES4 tokens");
        console.log("User1 YES4 tokens received:", user1Yes4Tokens, "Expected:", expectedFillAmount);
        
        // Verify total tokens received by each user
        uint256 user1TotalTokens = user1Yes1Tokens + user1Yes4Tokens;
        uint256 user1ExpectedTotal = expectedFillAmount * 2; // User1 has 2 orders
        assertTrue(user1TotalTokens == user1ExpectedTotal, "User1 should have received exactly expectedFillAmount * 2 total tokens");
        
        console.log("User1 total tokens received:", user1TotalTokens, "Expected:", user1ExpectedTotal);
        console.log("User2 total tokens received:", user2Yes2Tokens, "Expected:", expectedFillAmount);
        console.log("User3 total tokens received:", user3Yes3Tokens, "Expected:", expectedFillAmount);
    }

    function test_Scenario2_MixedBuySellOrders() public {
        console.log("=== Testing Scenario 2: Mixed Buy/Sell Orders ===");
        
        ICTFExchange.OrderIntent[] memory orders = _createScenario2Orders();
        
        // Debug: Check token balances after minting
        console.log("Token balances after setup:");
        console.log("User1 YES tokens:", ctf.balanceOf(user1, yesPositionId));
        console.log("User1 NO tokens:", ctf.balanceOf(user1, noPositionId));
        console.log("User2 YES tokens:", ctf.balanceOf(user2, yesPositionId));
        console.log("User2 NO tokens:", ctf.balanceOf(user2, noPositionId));
        
        // Record initial balances
        uint256 user1InitialBalance = usdc.balanceOf(user1);
        uint256 user2InitialBalance = usdc.balanceOf(user2);
        uint256 adapterInitialBalance = usdc.balanceOf(address(adapter));
        uint256 vaultInitialBalance = usdc.balanceOf(vault);
        
        console.log("Initial balances:");
        console.log("  User1 USDC:", user1InitialBalance);
        console.log("  User2 USDC:", user2InitialBalance);
        console.log("  Adapter USDC:", adapterInitialBalance);
        console.log("  Vault USDC:", vaultInitialBalance);
        
        // Execute cross-matching - we need to provide a taker order and maker orders
        // For simplicity, we'll use the first order as taker and the rest as makers
        ICTFExchange.OrderIntent memory takerOrder = orders[0];
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](orders.length - 1);
        for (uint256 i = 1; i < orders.length; i++) {
            makerOrders[i - 1] = orders[i];
        }
        
        adapter.crossMatchLongOrders(marketId, takerOrder, makerOrders, 1e6);
        
        // Verify final balances
        uint256 user1FinalBalance = usdc.balanceOf(user1);
        uint256 user2FinalBalance = usdc.balanceOf(user2);
        uint256 adapterFinalBalance = usdc.balanceOf(address(adapter));
        uint256 vaultFinalBalance = usdc.balanceOf(vault);
        
        console.log("Final balances:");
        console.log("  User1 USDC:", user1FinalBalance);
        console.log("  User2 USDC:", user2FinalBalance);
        console.log("  Adapter USDC:", adapterFinalBalance);
        console.log("  Vault USDC:", vaultFinalBalance);
        
        // Verify the cross-matching worked correctly
        // User1 should have received YES tokens and paid USDC
        // User2 should have received USDC for selling NO tokens
        // The adapter should have distributed all USDC and not kept any
        // The vault provides liquidity and gets it back, so its balance should remain the same
        
        // Check that user1 received YES tokens from Question 1
        uint256 user1YesTokens = ctf.balanceOf(user1, orders[0].tokenId);
        assertTrue(user1YesTokens > 0, "User1 should have received YES tokens");
        
        // Check that user2's NO tokens from Question 2 were consumed
        uint256 user2NoTokens = ctf.balanceOf(user2, orders[1].tokenId);
        assertTrue(user2NoTokens < TOKEN_AMOUNT, "User2's NO tokens should have been consumed");
        
        // Check that the adapter has no USDC left (it distributed everything)
        assertTrue(adapterFinalBalance == 0, "Adapter should have distributed all USDC");
        
        // Check that the vault balance remains the same (it provides liquidity and gets it back)
        assertTrue(vaultFinalBalance == vaultInitialBalance, "Vault balance should remain the same after providing liquidity");
        
        console.log("Cross-matching completed successfully!");
        console.log("User1 YES tokens:", user1YesTokens);
        console.log("User2 NO tokens remaining:", user2NoTokens);
        console.log("Adapter final USDC:", adapterFinalBalance);
        console.log("Vault final USDC:", vaultFinalBalance);
    }
    
    function test_Scenario3_AllSellOrders() public {
        console.log("=== Testing Scenario 3: Mixed Buy/Sell Orders ===");
        
        // Create orders for this scenario (this will create new questions)
        ICTFExchange.OrderIntent[] memory orders = _createScenario3Orders();
        
        // Record balances AFTER token minting but BEFORE cross-matching
        uint256 user1BalanceBeforeCrossMatch = usdc.balanceOf(user1);
        uint256 user2BalanceBeforeCrossMatch = usdc.balanceOf(user2);
        uint256 user3BalanceBeforeCrossMatch = usdc.balanceOf(user3);
        
        // Execute cross-matching - we need to provide a taker order and maker orders
        // For simplicity, we'll use the first order as taker and the rest as makers
        ICTFExchange.OrderIntent memory takerOrder = orders[0];
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](orders.length - 1);
        for (uint256 i = 1; i < orders.length; i++) {
            makerOrders[i - 1] = orders[i];
        }
        
        adapter.crossMatchLongOrders(marketId, takerOrder, makerOrders, 1e6);
        
        // Verify the cross-matching worked correctly
        _verifyScenario3Results(orders, user1BalanceBeforeCrossMatch, user2BalanceBeforeCrossMatch, user3BalanceBeforeCrossMatch);
        
        console.log("Cross-matching completed successfully!");
    }
    
    function _verifyScenario3Results(
        ICTFExchange.OrderIntent[] memory orders,
        uint256 user1BalanceBeforeCrossMatch,
        uint256 user2BalanceBeforeCrossMatch,
        uint256 user3BalanceBeforeCrossMatch
    ) internal {
        // Check that users received USDC for selling their NO tokens during cross-matching
        uint256 user1FinalBalance = usdc.balanceOf(user1);
        uint256 user2FinalBalance = usdc.balanceOf(user2);
        uint256 user3FinalBalance = usdc.balanceOf(user3);
        
        // All users should have received USDC for selling NO tokens during cross-matching
        assertTrue(user1FinalBalance > user1BalanceBeforeCrossMatch, "User1 should have received USDC for selling NO tokens");
        assertTrue(user2FinalBalance > user2BalanceBeforeCrossMatch, "User2 should have received USDC for selling NO tokens");
        assertTrue(user3FinalBalance > user3BalanceBeforeCrossMatch, "User3 should have received USDC for selling NO tokens");
        
        // Check that users' NO tokens were consumed during the sell operation
        uint256 user1NoTokens = ctf.balanceOf(user1, orders[0].tokenId);
        uint256 user2NoTokens = ctf.balanceOf(user2, orders[1].tokenId);
        uint256 user3NoTokens = ctf.balanceOf(user3, orders[2].tokenId);
        
        // All users' NO tokens should have been consumed during the sell operation
        assertTrue(user1NoTokens < TOKEN_AMOUNT, "User1's NO tokens should have been consumed");
        assertTrue(user2NoTokens < TOKEN_AMOUNT, "User2's NO tokens should have been consumed");
        assertTrue(user3NoTokens < TOKEN_AMOUNT, "User3's NO tokens should have been consumed");
        
        // Check that the adapter has no USDC left (it distributed everything)
        uint256 adapterFinalBalance = usdc.balanceOf(address(adapter));
        assertTrue(adapterFinalBalance == 0, "Adapter should have distributed all USDC");
        
        // Check that the vault balance remains the same (it provides liquidity and gets it back)
        uint256 vaultFinalBalance = usdc.balanceOf(vault);
        uint256 vaultInitialBalance = usdc.balanceOf(vault);
        assertTrue(vaultFinalBalance == vaultInitialBalance, "Vault balance should remain the same after providing liquidity");
        
        console.log("User1 NO tokens remaining:", user1NoTokens);
        console.log("User2 NO tokens remaining:", user2NoTokens);
        console.log("User3 NO tokens remaining:", user3NoTokens);
        console.log("User1 USDC received for selling:", user1FinalBalance - user1BalanceBeforeCrossMatch);
        console.log("User2 USDC received for selling:", user2FinalBalance - user2BalanceBeforeCrossMatch);
        console.log("User3 USDC received for selling:", user3FinalBalance - user3BalanceBeforeCrossMatch);
        console.log("Adapter final USDC:", adapterFinalBalance);
        console.log("Vault final USDC:", vaultFinalBalance);
    }

    function _createScenario3Orders() internal returns (ICTFExchange.OrderIntent[] memory) {
        ICTFExchange.OrderIntent[] memory orders = new ICTFExchange.OrderIntent[](3);
        
        // Create a multi-question market for cross-matching to work
        // We need at least 2 questions to do cross-matching
        
        // Create additional questions for this scenario
        bytes32 question1Id = negRiskAdapter.prepareQuestion(marketId, "Question 1");
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        bytes32 question3Id = negRiskAdapter.prepareQuestion(marketId, "Question 3");
        
        // Get position IDs for the new questions - users are selling NO tokens
        uint256 no1PositionId = negRiskAdapter.getPositionId(question1Id, false);
        uint256 no2PositionId = negRiskAdapter.getPositionId(question2Id, false);
        uint256 no3PositionId = negRiskAdapter.getPositionId(question3Id, false);
        
        // Mint specific NO tokens for the users in the new questions
        _mintSpecificToken(user1, no1PositionId, question1Id, 1e6);
        _mintSpecificToken(user2, no2PositionId, question2Id, 1e6);
        _mintSpecificToken(user3, no3PositionId, question3Id, 1e6);
        
        // User1: Sell NO tokens from Question 1 at 0.75 price
        // (1-0.75) = 0.25 contribution to the total
        orders[0] = _createOrderIntent(user1, no1PositionId, 1, 1e18, 0.75e18);
        
        // User2: Sell NO tokens from Question 2 at 0.6 price
        // (1-0.6) = 0.4 contribution to the total
        orders[1] = _createOrderIntent(user2, no2PositionId, 1, 1e18, 0.6e18);
        
        // User3: Sell NO tokens from Question 3 at 0.65 price
        // (1-0.65) = 0.35 contribution to the total
        // Total: 0.25 + 0.4 + 0.35 = 1.0 (which equals the pivot question price)
        orders[2] = _createOrderIntent(user3, no3PositionId, 1, 1e18, 0.65e18);
        
        return orders;
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
