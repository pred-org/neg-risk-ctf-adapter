// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Test, console} from "forge-std/Test.sol";
import {CrossMatchingAdapter} from "src/CrossMatchingAdapter.sol";
import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
import {NegRiskOperator} from "src/NegRiskOperator.sol";
import {RevNegRiskAdapter} from "src/RevNegRiskAdapter.sol";
import {IRevNegRiskAdapter} from "src/interfaces/IRevNegRiskAdapter.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";
import {Deployer} from "lib/ctf-exchange/src/dev/util/Deployer.sol";
import {TestHelper} from "lib/ctf-exchange/src/dev/TestHelper.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";
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
        // Simple hash implementation for testing
        return keccak256(abi.encode(order));
    }
    
    function validateOrder(ICTFExchange.OrderIntent memory order) external pure {
        // Mock validation - always passes for testing
        // In a real implementation, this would validate signatures, expiration, etc.
    }
    
    function updateOrderStatus(ICTFExchange.OrderIntent memory orderIntent, uint256 makingAmount) external pure {
        // Mock implementation - always succeeds for testing
        // In a real implementation, this would update order status in storage
    }
}

contract CrossMatchingAdapterTest is Test, TestHelper {
    CrossMatchingAdapter public adapter;
    NegRiskAdapter public negRiskAdapter;
    NegRiskOperator public negRiskOperator;
    RevNegRiskAdapter public revNegRiskAdapter;
    ICTFExchange public ctfExchange;
    IConditionalTokens public ctf;
    IERC20 public usdc;
    address public vault;
    
    // Test users
    address public user1;
    address public user2;
    address public user3;
    address public user4;
    
    // Private keys for signing orders
    uint256 public user1PK = 0x1111;
    uint256 public user2PK = 0x2222;
    uint256 public user3PK = 0x3333;
    uint256 public user4PK = 0x4444;

    // Market and question IDs
    bytes32 public marketId;
    bytes32 public questionId;
    bytes32 public conditionId;
    
    // Position IDs for YES/NO tokens
    uint256 public yesPositionId;
    uint256 public noPositionId;
    
    // Test constants
    uint256 public constant INITIAL_USDC_BALANCE = 100000000e6; // 100,000,000 USDC (6 decimals) - enough for orders
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
        negRiskOperator = new NegRiskOperator(address(negRiskAdapter));
        vm.label(address(negRiskOperator), "NegRiskOperator");        vm.label(address(negRiskAdapter), "NegRiskAdapter");
        
        // Deploy CrossMatchingAdapter - we need to provide a mock CTF exchange
        adapter = new CrossMatchingAdapter(negRiskOperator, IERC20(address(usdc)), ICTFExchange(address(ctfExchange)), IRevNegRiskAdapter(address(revNegRiskAdapter)));
        vm.label(address(adapter), "CrossMatchingAdapter");
        
        MockUSDC(address(usdc)).mint(address(vault), 10000000e6); // 10M USDC for vault
        vm.startPrank(address(vault));
        // MockUSDC(address(usdc)).approve(address(negRiskAdapter), type(uint256).max);
        MockUSDC(address(usdc)).approve(address(adapter), type(uint256).max);
        vm.stopPrank();

        // Set up test users
        user1 = vm.addr(user1PK);
        user2 = vm.addr(user2PK);
        user3 = vm.addr(user3PK);
        user4 = vm.addr(user4PK);
        vm.label(user1, "User1");
        vm.label(user2, "User2");
        vm.label(user3, "User3");
        vm.label(user4, "User4");

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
    }
    
    function _setupInitialTokenBalances() internal {
        // Give users initial USDC balances
        _setupUser(user1, INITIAL_USDC_BALANCE);
        _setupUser(user2, INITIAL_USDC_BALANCE);
        _setupUser(user3, INITIAL_USDC_BALANCE);
        _setupUser(user4, INITIAL_USDC_BALANCE);
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
            feeRateBps: 0,
            questionId: questionId,
            intent: ICTFExchange.Intent.LONG,
            signatureType: ICTFExchange.SignatureType.EOA,
            signature: new bytes(0)
        });
        
        return ICTFExchange.OrderIntent({
            tokenId: tokenId,
            side: ICTFExchange.Side(side),
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
    ) internal view returns (ICTFExchange.OrderIntent memory) {
        // Calculate price: for BUY orders, price = (makerAmount * ONE_SIX) / takerAmount
        // This ensures that makerAmount = (price * fillAmount) / ONE_SIX
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
            questionId: questionId,
            intent: ICTFExchange.Intent.LONG,
            feeRateBps: 0,
            signatureType: ICTFExchange.SignatureType.EOA,
            signature: new bytes(0)
        });
        
        // Sign the order
        order.signature = _signMessage(privateKey, ctfExchange.hashOrder(order));
        
        return ICTFExchange.OrderIntent({
            tokenId: tokenId,
            side: ICTFExchange.Side(side),
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            order: order
        });
    }

    function _signMessage(uint256 privateKey, bytes32 message) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, message);
        return abi.encodePacked(r, s, v);
    }
    
    function _createScenario1Orders() internal returns (ICTFExchange.OrderIntent[] memory) {
        ICTFExchange.OrderIntent[] memory orders = new ICTFExchange.OrderIntent[](4);
        
        // For Scenario 1, we need 4 different questions so each user buys a different YES token
        // This way the combined price can equal 1.0 (0.25 + 0.25 + 0.25 + 0.25 = 1.0)
        
        // Create additional questions for this scenario
        // bytes32 question1Id = negRiskAdapter.prepareQuestion(marketId, "Question 1");
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        bytes32 question3Id = negRiskAdapter.prepareQuestion(marketId, "Question 3");
        bytes32 question4Id = negRiskAdapter.prepareQuestion(marketId, "Question 4");
        
        uint256 yes1PositionId = negRiskAdapter.getPositionId(questionId, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        uint256 yes4PositionId = negRiskAdapter.getPositionId(question4Id, true);
        
        // User1: Buy YES1 tokens at 0.25 price
        orders[0] = _createAndSignOrder(user1, yes1PositionId, 0, 0.25e6, 1e6, questionId, user1PK);
        
        // User2: Buy YES2 tokens at 0.25 price
        orders[1] = _createAndSignOrder(user2, yes2PositionId, 0, 0.25e6, 1e6, question2Id, user2PK);
        
        // User3: Buy YES3 tokens at 0.25 price
        orders[2] = _createAndSignOrder(user3, yes3PositionId, 0, 0.25e6, 1e6, question3Id, user3PK);
        
        // User4: Buy YES4 tokens at 0.25 price
        orders[3] = _createAndSignOrder(user4, yes4PositionId, 0, 0.25e6, 1e6, question4Id, user4PK);
        
        return orders;
    }
    
    function _createScenario2Orders() internal returns (ICTFExchange.OrderIntent[] memory) {
        ICTFExchange.OrderIntent[] memory orders = new ICTFExchange.OrderIntent[](2);

        // Create a multi-question market for cross-matching to work
        // We need at least 2 questions to do cross-matching
        
        // Create additional questions for the market
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        
        // Get position IDs for the new questions
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 no2PositionId = negRiskAdapter.getPositionId(question2Id, false);
        
        // Mint specific tokens for the users in the new questions
        _mintSpecificToken(user2, question2Id, 50*1e6);

        vm.prank(user2);
        ctf.setApprovalForAll(address(adapter), true);
        
        // User1: Buy YES tokens from Question 0 (pivot) at 0.5 price
        orders[0] = _createAndSignOrder(user1, yesPositionId, 0, 0.7e6, 1e6, questionId, user1PK);
        
        // User2: Sell NO tokens from Question 2 at 0.3 price
        // For sell orders, we need to ensure combined price = 1.0
        // Buy price: 0.5, Sell price: 0.5, so 0.5 + (1-0.5) = 1.0
        orders[1] = _createAndSignOrder(user2, no2PositionId, 1, 1e6, 0.3e6, question2Id, user2PK);
        
        return orders;
    }

    function test_Scenario1_AllBuyOrders() public {
        // Create orders for this scenario (this will create new questions)
        ICTFExchange.OrderIntent[] memory orders = _createScenario1Orders();
        
        // Record initial balances
        uint256 user1InitialBalance = usdc.balanceOf(user1);
        uint256 user2InitialBalance = usdc.balanceOf(user2);
        uint256 user3InitialBalance = usdc.balanceOf(user3);
        uint256 user4InitialBalance = usdc.balanceOf(user4);
        uint256 vaultInitialBalance = usdc.balanceOf(vault);
        
        // Execute cross-matching - we need to provide a taker order and maker orders
        // For simplicity, we'll use the first order as taker and the rest as makers
        ICTFExchange.OrderIntent memory takerOrder = orders[0];
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](orders.length - 1);
        for (uint256 i = 1; i < orders.length; i++) {
            makerOrders[i - 1] = orders[i];
        }
        
        uint256 fillAmount = 100 * 1e6;
        adapter.crossMatchLongOrders(marketId, takerOrder, makerOrders, fillAmount);
        
        // Verify that users spent USDC
        assertEq(usdc.balanceOf(user1), user1InitialBalance - 0.25e6 * fillAmount/1e6, "User1 should have spent USDC");
        assertEq(usdc.balanceOf(user2), user2InitialBalance - 0.25e6 * fillAmount/1e6, "User2 should have spent USDC");
        assertEq(usdc.balanceOf(user3), user3InitialBalance - 0.25e6 * fillAmount/1e6, "User3 should have spent USDC");
        assertEq(usdc.balanceOf(user4), user4InitialBalance - 0.25e6 * fillAmount/1e6, "User4 should have spent USDC");
        
        // Verify that users received the correct YES tokens
        _verifyUserTokenBalances(marketId);
        
        // Verify that the adapter has no USDC left (it distributed everything)
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have distributed all USDC");
        
        // Verify that the vault balance remains the same (it provides liquidity and gets it back)
        assertEq(usdc.balanceOf(vault), vaultInitialBalance, "Vault balance should remain the same after providing liquidity");
    }
    
    function _verifyUserTokenBalances(bytes32 marketId) internal {
        // Get the position IDs for the questions created in this scenario
        bytes32 question1Id = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 question2Id = NegRiskIdLib.getQuestionId(marketId, 1);
        bytes32 question3Id = NegRiskIdLib.getQuestionId(marketId, 2);
        bytes32 question4Id = NegRiskIdLib.getQuestionId(marketId, 3);
        
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        uint256 yes4PositionId = negRiskAdapter.getPositionId(question4Id, true);
        
        // Expected fill amount from the orders (makerAmount)
        uint256 expectedFillAmount = 100 * 1e6; // 1,000,000 tokens
        
        // Check that User1 received YES1 tokens (from taker order) - exact amount
        uint256 user1Yes1Tokens = ctf.balanceOf(user1, yes1PositionId);
        assertEq(user1Yes1Tokens, expectedFillAmount, "User1 should have received exactly expectedFillAmount YES1 tokens");
        
        // Check that User2 received YES2 tokens - exact amount
        uint256 user2Yes2Tokens = ctf.balanceOf(user2, yes2PositionId);
        assertEq(user2Yes2Tokens, expectedFillAmount, "User2 should have received exactly expectedFillAmount YES2 tokens");
        
        // Check that User3 received YES3 tokens - exact amount
        uint256 user3Yes3Tokens = ctf.balanceOf(user3, yes3PositionId);
        assertEq(user3Yes3Tokens, expectedFillAmount, "User3 should have received exactly expectedFillAmount YES3 tokens");
        
        // Check that User1 received YES4 tokens (from maker order) - exact amount
        uint256 user4Yes4Tokens = ctf.balanceOf(user4, yes4PositionId);
        assertEq(user4Yes4Tokens, expectedFillAmount, "User4 should have received exactly expectedFillAmount YES4 tokens");

        // assert that adapter balances of Yes and No tokens are 0
        assertEq(ctf.balanceOf(address(adapter), yes1PositionId), 0, "Adapter should have no YES1 tokens");
        assertEq(ctf.balanceOf(address(adapter), yes2PositionId), 0, "Adapter should have no YES2 tokens");
        assertEq(ctf.balanceOf(address(adapter), yes3PositionId), 0, "Adapter should have no YES3 tokens");
        assertEq(ctf.balanceOf(address(adapter), yes4PositionId), 0, "Adapter should have no YES4 tokens");
    }

    function test_Scenario2_MixedBuySellOrders() public {
        ICTFExchange.OrderIntent[] memory orders = _createScenario2Orders();
        
        // Record initial balances
        uint256 user1InitialBalance = usdc.balanceOf(user1);
        uint256 user2InitialBalance = usdc.balanceOf(user2);
        uint256 adapterInitialBalance = usdc.balanceOf(address(adapter));
        uint256 vaultInitialBalance = usdc.balanceOf(vault);
        
        // Execute cross-matching - we need to provide a taker order and maker orders
        // For simplicity, we'll use the first order as taker and the rest as makers
        ICTFExchange.OrderIntent memory takerOrder = orders[0];
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](orders.length - 1);
        for (uint256 i = 1; i < orders.length; i++) {
            makerOrders[i - 1] = orders[i];
        }
        
        uint256 fillAmount = 50 * 1e6;
        adapter.crossMatchLongOrders(marketId, takerOrder, makerOrders, fillAmount);
        
        // Verify the cross-matching worked correctly
        // User1 should have received YES tokens and paid USDC
        // User2 should have received USDC for selling NO tokens
        // The adapter should have distributed all USDC and not kept any
        // The vault provides liquidity and gets it back, so its balance should remain the same
        
        // Check that user1 received YES tokens from Question 0 (pivot)
        uint256 user1YesTokens = ctf.balanceOf(user1, orders[0].tokenId);
        assertEq(user1YesTokens, fillAmount, "User1 should have received YES tokens");
        
        // Check that user2's NO tokens from Question 2 were consumed
        uint256 user2NoTokens = ctf.balanceOf(user2, orders[1].tokenId);
        assertEq(user2NoTokens, 0, "User2's NO tokens should have been consumed");

        // User1 pays 0.7 * fillAmount for buying YES tokens
        assertEq(usdc.balanceOf(user1), user1InitialBalance - 0.7e6 * fillAmount / 1e6, "User1 should have spent USDC");
        // User2 receives (1 - 0.3) * fillAmount = 0.7 * fillAmount for selling NO tokens
        assertEq(usdc.balanceOf(user2), user2InitialBalance + 0.7e6 * fillAmount / 1e6, "User2 should have received USDC");
        
        // Check that the adapter has no USDC left (it distributed everything)
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have distributed all USDC");
        
        // Check that the vault balance remains the same (it provides liquidity and gets it back)
        assertEq(usdc.balanceOf(vault), vaultInitialBalance, "Vault balance should remain the same after providing liquidity");
    
        // assert that adapter balances of Yes and No tokens are 0
        assertEq(ctf.balanceOf(address(adapter), orders[0].tokenId), 0, "Adapter should have no YES tokens");
        assertEq(ctf.balanceOf(address(adapter), orders[1].tokenId), 0, "Adapter should have no NO tokens");
    }
    
    function test_Scenario3_AllSellOrders() public {
        // Create orders for this scenario (this will create new questions)
        ICTFExchange.OrderIntent[] memory orders = _createScenario3Orders();
        
        // Record balances AFTER token minting but BEFORE cross-matching
        uint256 user1BalanceBeforeCrossMatch = usdc.balanceOf(user1);
        uint256 user2BalanceBeforeCrossMatch = usdc.balanceOf(user2);
        uint256 user3BalanceBeforeCrossMatch = usdc.balanceOf(user3);
        uint256 vaultInitialBalance = usdc.balanceOf(vault);
        
        // Execute cross-matching - we need to provide a taker order and maker orders
        // For simplicity, we'll use the first order as taker and the rest as makers
        ICTFExchange.OrderIntent memory takerOrder = orders[0];
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](orders.length - 1);
        for (uint256 i = 1; i < orders.length; i++) {
            makerOrders[i - 1] = orders[i];
        }
        
        adapter.crossMatchLongOrders(marketId, takerOrder, makerOrders, 70 * 1e6);

        assertEq(usdc.balanceOf(user1), user1BalanceBeforeCrossMatch + 0.75e6 * 70, "User1 should have spent USDC");
        assertEq(usdc.balanceOf(user2), user2BalanceBeforeCrossMatch + 0.6e6 * 70, "User2 should have received USDC");
        assertEq(usdc.balanceOf(user3), user3BalanceBeforeCrossMatch + 0.65e6 * 70, "User3 should have received USDC");
        
        assertEq(ctf.balanceOf(user1, orders[0].tokenId), 0, "User1 should have spent all NO tokens");
        assertEq(ctf.balanceOf(user2, orders[1].tokenId), 0, "User2 should have spent all NO tokens");
        assertEq(ctf.balanceOf(user3, orders[2].tokenId), 0, "User3 should have spent all NO tokens");

        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have distributed all USDC");
        assertEq(usdc.balanceOf(vault), vaultInitialBalance, "Vault balance should remain the same after providing liquidity");
    }

    function _createScenario3Orders() internal returns (ICTFExchange.OrderIntent[] memory) {
        ICTFExchange.OrderIntent[] memory orders = new ICTFExchange.OrderIntent[](3);
        
        // Create additional questions for this scenario
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        bytes32 question3Id = negRiskAdapter.prepareQuestion(marketId, "Question 3");
        
        // Get position IDs for the new questions - users are selling NO tokens
        uint256 no1PositionId = negRiskAdapter.getPositionId(questionId, false);
        uint256 no2PositionId = negRiskAdapter.getPositionId(question2Id, false);
        uint256 no3PositionId = negRiskAdapter.getPositionId(question3Id, false);
        
        // Mint specific NO tokens for the users in the new questions
        _mintSpecificToken(user1, questionId, 70*1e6);
        _mintSpecificToken(user2, question2Id, 70*1e6);
        _mintSpecificToken(user3, question3Id, 70*1e6);
        
        vm.prank(user1);
        ctf.setApprovalForAll(address(adapter), true);
        vm.prank(user2);
        ctf.setApprovalForAll(address(adapter), true);
        vm.prank(user3);
        ctf.setApprovalForAll(address(adapter), true);
        
        // User1: Sell NO tokens from Question 1 at 0.5 price
        // (1-0.5) = 0.5 contribution to the total
        orders[0] = _createAndSignOrder(user1, no1PositionId, 1, 1e6, 0.25e6, questionId, user1PK);
        
        // User2: Sell NO tokens from Question 2 at 0.5 price
        // (1-0.5) = 0.5 contribution to the total
        // Total: 0.5 + 0.5 = 1.0 ✓
        orders[1] = _createAndSignOrder(user2, no2PositionId, 1, 1e6, 0.4e6, question2Id, user2PK);

        // User3: Sell NO tokens from Question 3 at 0.65 price
        // (1-0.65) = 0.35 contribution to the total
        orders[2] = _createAndSignOrder(user3, no3PositionId, 1, 1e6, 0.35e6, question3Id, user3PK);
        return orders;
    }

    function test_Scenario4_ComplexMixedOrders() public {
        console.log("=== Testing Scenario 4: Complex Mixed Buy/Sell Orders (4 Users) ===");
        
        ICTFExchange.OrderIntent[] memory orders = _createScenario4Orders();
        
        // Record initial balances
        uint256 user1InitialBalance = usdc.balanceOf(user1);
        uint256 user2InitialBalance = usdc.balanceOf(user2);
        uint256 user3InitialBalance = usdc.balanceOf(user3);
        uint256 user4InitialBalance = usdc.balanceOf(user4);
        uint256 adapterInitialBalance = usdc.balanceOf(address(adapter));
        // uint256 vaultInitialBalance = usdc.balanceOf(vault);
        
        // Execute cross-matching
        ICTFExchange.OrderIntent memory takerOrder = orders[0];
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](orders.length - 1);
        for (uint256 i = 1; i < orders.length; i++) {
            makerOrders[i - 1] = orders[i];
        }
        
        console.log("Executing cross-matching with taker order and", makerOrders.length, "maker orders");
        
        uint256 fillAmount = 10 * 1e6;
        adapter.crossMatchLongOrders(marketId, takerOrder, makerOrders, fillAmount);
        
        // Add some basic assertions to understand what's happening
        assertEq(usdc.balanceOf(user1), user1InitialBalance - 0.25e6 * fillAmount/1e6, "User1 should have spent USDC");
        assertEq(usdc.balanceOf(user2), user2InitialBalance + 0.7e6 * fillAmount/1e6, "User2 should have received USDC");
        assertEq(usdc.balanceOf(user3), user3InitialBalance - 0.1e6 * fillAmount/1e6, "User3 balance should have reduced");
        assertEq(usdc.balanceOf(user4), user4InitialBalance + 0.65e6 * fillAmount/1e6, "User4 balance should have changed");

        assertEq(usdc.balanceOf(address(adapter)), adapterInitialBalance, "Adapter should have the same USDC balance after cross-matching");
        
        // Verify final balances and token distributions
        _verifyScenario4Tokens();
        
        console.log("Scenario 4 completed successfully!");
    }
    
    function _createScenario4Orders() internal returns (ICTFExchange.OrderIntent[] memory) {
        ICTFExchange.OrderIntent[] memory orders = new ICTFExchange.OrderIntent[](4);
        
        // Create 4 questions for this complex scenario
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        bytes32 question3Id = negRiskAdapter.prepareQuestion(marketId, "Question 3");
        bytes32 question4Id = negRiskAdapter.prepareQuestion(marketId, "Question 4");
        
        // Get position IDs for all questions
        uint256 yes1PositionId = negRiskAdapter.getPositionId(questionId, true);
        uint256 no2PositionId = negRiskAdapter.getPositionId(question2Id, false);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        uint256 no4PositionId = negRiskAdapter.getPositionId(question4Id, false);
        
        // Also get YES position IDs for questions 2 and 4 (the ones being sold)
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 yes4PositionId = negRiskAdapter.getPositionId(question4Id, true);
        
        // Get position IDs for the pivot question (index 0) - this is created in _setupMarketAndQuestion
        
        // Mint specific tokens for the users
        _mintSpecificToken(user2, question2Id, 1e7);
        _mintSpecificToken(user4, question4Id, 1e7);

        // give approval to adapter to spend the No tokens
        vm.startPrank(user2);
        ctf.setApprovalForAll(address(adapter), true);
        vm.stopPrank();

        vm.startPrank(user4);
        ctf.setApprovalForAll(address(adapter), true);
        vm.stopPrank();
        
        // User A (user1): Buy Yes1 tokens at 0.25 price
        orders[0] = _createAndSignOrder(user1, yes1PositionId, 0, 0.25e6, 1e6, questionId, user1PK);
        
        // User B (user2): Sell No2 tokens at 0.7 price (contributes 0.3 to total: 1-0.7=0.3)
        orders[1] = _createAndSignOrder(user2, no2PositionId, 1, 1e6, 0.3e6, question2Id, user2PK);
        
        // User C (user3): Buy Yes3 tokens at 0.1 price
        orders[2] = _createAndSignOrder(user3, yes3PositionId, 0, 0.1e6, 1e6, question3Id, user3PK);
        
        // User D (user4): Sell No4 tokens at 0.65 price (contributes 0.35 to total: 1-0.65=0.35)
        orders[3] = _createAndSignOrder(user4, no4PositionId, 1, 1e6, 0.35e6, question4Id, user4PK);
        
        // Total combined price: 0.25 + 0.3 + 0.1 + 0.35 = 1.0 ✓
        
        return orders;
    }
    
    function _verifyScenario4Tokens() internal {
        // Get question IDs for verification
        bytes32 question2Id = NegRiskIdLib.getQuestionId(marketId, 1);
        bytes32 question3Id = NegRiskIdLib.getQuestionId(marketId, 2);
        bytes32 question4Id = NegRiskIdLib.getQuestionId(marketId, 3);
        
        uint256 yes1PositionId = negRiskAdapter.getPositionId(questionId, true);
        uint256 no2PositionId = negRiskAdapter.getPositionId(question2Id, false);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        uint256 no4PositionId = negRiskAdapter.getPositionId(question4Id, false);
        
        // Verify token distributions
        uint256 user1Yes1Tokens = ctf.balanceOf(user1, yes1PositionId);
        uint256 user3Yes3Tokens = ctf.balanceOf(user3, yes3PositionId);
        
        assertEq(user1Yes1Tokens, 1e7, "User1 should have received Yes1 tokens");
        assertEq(user3Yes3Tokens, 1e7, "User3 should have received Yes3 tokens");
        
        // Verify that sellers' NO tokens were consumed
        uint256 user2No2Tokens = ctf.balanceOf(user2, no2PositionId);
        uint256 user4No4Tokens = ctf.balanceOf(user4, no4PositionId);
        
        assertEq(user2No2Tokens, 0, "User2's No2 tokens should have been consumed");
        assertEq(user4No4Tokens, 0, "User4's No4 tokens should have been consumed");
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
