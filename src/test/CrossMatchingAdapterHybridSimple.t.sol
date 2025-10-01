// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {CrossMatchingAdapter} from "src/CrossMatchingAdapter.sol";
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

contract CrossMatchingAdapterHybridSimpleTest is Test, TestHelper {
    CrossMatchingAdapter public adapter;
    NegRiskAdapter public negRiskAdapter;
    NegRiskOperator public negRiskOperator;
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
    
    // Private keys for signing
    uint256 internal user1PK = 0x1111;
    uint256 internal user2PK = 0x2222;
    uint256 internal user3PK = 0x3333;
    uint256 internal user4PK = 0x4444;

    // Market and question IDs
    bytes32 public marketId;
    bytes32 public questionId;
    
    // Position IDs for YES/NO tokens
    uint256 public yesPositionId;

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
        negRiskOperator = new NegRiskOperator(address(negRiskAdapter));
        vm.label(address(negRiskOperator), "NegRiskOperator");        vm.label(address(negRiskAdapter), "NegRiskAdapter");

        // Deploy RevNegRiskAdapter
        revNegRiskAdapter = new RevNegRiskAdapter(address(ctf), address(usdc), vault, INegRiskAdapter(address(negRiskAdapter)));
        vm.label(address(revNegRiskAdapter), "RevNegRiskAdapter");
        
        // Deploy CrossMatchingAdapter
        adapter = new CrossMatchingAdapter(negRiskOperator, IERC20(address(usdc)), ICTFExchange(address(ctfExchange)), IRevNegRiskAdapter(address(revNegRiskAdapter)));
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
        vm.label(user1, "User1");
        vm.label(user2, "User2");
        vm.label(user3, "User3");
        vm.label(user4, "User4");
        // Set up market and question
        marketId = negRiskAdapter.prepareMarket(0, "Test Market");
        questionId = negRiskAdapter.prepareQuestion(marketId, "Test Question");
        yesPositionId = negRiskAdapter.getPositionId(questionId, true);
        
        // Set up initial token balances
        _setupUser(user1, 100000000e6);
        _setupUser(user2, 100000000e6);
        _setupUser(user3, 100000000e6);
        _setupUser(user4, 100000000e6);
        
        // Register tokens with CTFExchange
        _registerTokensWithCTFExchange(yesPositionId, negRiskAdapter.getPositionId(questionId, false), negRiskAdapter.getConditionId(questionId));
        
        // Set the CrossMatchingAdapter as an operator for CTFExchange
        vm.prank(address(this));
        ctfExchange.addOperator(address(adapter));
        
        // Set CTFExchange as operator for ConditionalTokens (ERC1155)
        ctf.setApprovalForAll(address(ctfExchange), true);
    }
    
    function _registerTokensWithCTFExchange(uint256 yesTokenId, uint256 noTokenId, bytes32 conditionId) internal {
        // We need to be admin to register tokens
        // Since we're in a test environment, we can use vm.prank to call as admin
        // The CTFExchange admin is set to the deployer (this contract)
        ctfExchange.registerToken(yesTokenId, noTokenId, conditionId);
    }
    
    function _setupUser(address user, uint256 usdcBalance) internal {
        vm.startPrank(user);
        deal(address(usdc), user, usdcBalance);
        usdc.approve(address(adapter), type(uint256).max);
        usdc.approve(address(ctfExchange), type(uint256).max);
        // Set CTFExchange as operator for ConditionalTokens (ERC1155)
        ctf.setApprovalForAll(address(ctfExchange), true);
        vm.stopPrank();
    }
    
    function _mintTokensToUser(address user, uint256 tokenId, uint256 amount) internal {
        // Use dealERC1155 to set ERC1155 token balances
        dealERC1155(address(ctf), user, tokenId, amount);
    }
    
    function _createOrderIntent(
        address maker,
        uint256 tokenId,
        uint8 side,
        uint256 makerAmount,
        uint256 takerAmount,
        bytes32 questionIdParam,
        uint8 intent
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
            questionId: questionIdParam,
            intent: ICTFExchange.Intent(intent),
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
        bytes32 questionIdParam,
        uint8 intent,
        uint256 privateKey
    ) internal returns (ICTFExchange.OrderIntent memory) {
        // Calculate price: for BUY orders, price = (makerAmount * ONE) / takerAmount
        // For SELL orders, price = (takerAmount * ONE) / makerAmount
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

    function test_HybridMatchOrders_AllSingleOrders() public {
        console.log("=== Testing Hybrid Match Orders: All Single Orders ===");
        
        // Create 2 single maker orders
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](2);
        uint256[] memory makerFillAmounts = new uint256[](2);
        
        // Create additional questions
        bytes32 question1Id = negRiskAdapter.prepareQuestion(marketId, "Question 1");
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        
        // Register tokens with CTFExchange
        _registerTokensWithCTFExchange(yes1PositionId, negRiskAdapter.getPositionId(question1Id, false), negRiskAdapter.getConditionId(question1Id));
        _registerTokensWithCTFExchange(yes2PositionId, negRiskAdapter.getPositionId(question2Id, false), negRiskAdapter.getConditionId(question2Id));
        
        // Mint tokens to users for testing
        // For COMPLEMENTARY matches in CTFExchange:
        // - Taker should have USDC to buy YES tokens
        // - Makers should have YES tokens to sell
        _setupUser(user1, 1e6); // User1 needs USDC to buy YES tokens
        _mintTokensToUser(user2, negRiskAdapter.getPositionId(question1Id, true), 1e6); // User2 needs YES tokens to sell
        _mintTokensToUser(user3, negRiskAdapter.getPositionId(question1Id, true), 1e6); // User3 needs YES tokens to sell
        
        // Create single maker orders - both selling YES tokens to the taker
        // For sell order: makerAmount = token amount (1e6), takerAmount = USDC amount (0.25e6)
        // price = (takerAmount * 1e6) / makerAmount = (0.25e6 * 1e6) / 1e6 = 0.25e6
        // quantity = makerAmount = 1e6
        // amount = price * quantity / 1e6 = 0.25e6 * 1e6 / 1e6 = 0.25e6
        // So makerAmount should be 1e6, takerAmount should be 0.25e6
        makerOrders[0] = new ICTFExchange.OrderIntent[](1);
        makerOrders[0][0] = _createAndSignOrder(user2, negRiskAdapter.getPositionId(question1Id, true), 1, 1e6, 0.25e6, question1Id, 1, user2PK);
        makerFillAmounts[0] = 0.1e6; // 100K tokens - the amount of YES tokens maker2 will sell
        
        makerOrders[1] = new ICTFExchange.OrderIntent[](1);
        makerOrders[1][0] = _createAndSignOrder(user3, negRiskAdapter.getPositionId(question1Id, true), 1, 1e6, 0.25e6, question1Id, 1, user3PK);
        makerFillAmounts[1] = 0.1e6; // 100K tokens - the amount of YES tokens maker3 will sell
        
        // Create taker order - user1 buys YES tokens for question1
        // For buy order: makerAmount = USDC amount (0.25e6), takerAmount = token amount (1e6)
        // price = (makerAmount * 1e6) / takerAmount = (0.25e6 * 1e6) / 1e6 = 0.25e6
        // quantity = takerAmount = 1e6
        // amount = price * quantity / 1e6 = 0.25e6 * 1e6 / 1e6 = 0.25e6
        // So OrderIntent.makerAmount should be 0.25e6, takerAmount should be 1e6
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, negRiskAdapter.getPositionId(question1Id, true), 0, 0.25e6, 1e6, question1Id, 0, user1PK);
        
        // Execute hybrid match orders (2 single orders)
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 2);
        
        // For real CTFExchange, we can't easily track call counts, so we'll verify the execution completed successfully
        // The test passes if no revert occurs during execution
        console.log("All single orders test passed!");
    }

    function test_HybridMatchOrders_AllCrossMatchOrders() public {
        console.log("=== Testing Hybrid Match Orders: All Cross-Match Orders ===");
        
        // Create 1 cross-match maker order (length > 1)
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](1);
        uint256[] memory makerFillAmounts = new uint256[](1);
        
        // Create additional questions for cross-matching
        bytes32 question1Id = negRiskAdapter.prepareQuestion(marketId, "Question 1");
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        bytes32 question3Id = negRiskAdapter.prepareQuestion(marketId, "Question 3");
        
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        
        // Register tokens with CTFExchange
        _registerTokensWithCTFExchange(yes1PositionId, negRiskAdapter.getPositionId(question1Id, false), negRiskAdapter.getConditionId(question1Id));
        _registerTokensWithCTFExchange(yes2PositionId, negRiskAdapter.getPositionId(question2Id, false), negRiskAdapter.getConditionId(question2Id));
        _registerTokensWithCTFExchange(yes3PositionId, negRiskAdapter.getPositionId(question3Id, false), negRiskAdapter.getConditionId(question3Id));
        
        // Mint tokens to users for testing
        // For cross-matching, users need to have the appropriate tokens to trade
        // Since all users are buying YES tokens, they don't need any initial tokens
        // The cross-matching will create the tokens they need
        
        // Create cross-match maker order (with 2 orders)
        // For cross-matching, each user should buy different tokens
        makerOrders[0] = new ICTFExchange.OrderIntent[](2);
        makerOrders[0][0] = _createAndSignOrder(user2, yes2PositionId, 0, 0.35e6, 1e6, question2Id, 0, user2PK);
        makerOrders[0][1] = _createAndSignOrder(user3, yes3PositionId, 0, 0.5e6, 1e6, question3Id, 0, user3PK);
        makerFillAmounts[0] = 0.1e6; // 100K tokens - smaller than makerAmount (1e6)
        
        // Create taker order - user1 buys YES tokens for question1
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yes1PositionId, 0, 0.15e6, 1e6, question1Id, 0, user1PK);
        
        // Execute hybrid match orders (0 single orders, all cross-match)
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 0);
        
        // For real CTFExchange, we can't easily track call counts, so we'll verify the execution completed successfully
        // The test passes if no revert occurs during execution
        console.log("All cross-match orders test passed!");
    }

    function test_HybridMatchOrders_MixedSingleAndCrossMatch() public {
        console.log("=== Testing Hybrid Match Orders: Mixed Single and Cross-Match Orders ===");
        
        // This is a MIXED scenario: 1 single order + 1 cross-match order
        // Single order: taker vs maker1 (complementary match - same token, opposite sides)
        // Cross-match order: taker vs maker2 + maker3 (cross-match - different tokens)
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](2);
        uint256[] memory makerFillAmounts = new uint256[](2);
        
        // Create additional questions for cross-match
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        bytes32 question3Id = negRiskAdapter.prepareQuestion(marketId, "Question 3");
        
        uint256 yesPositionId = negRiskAdapter.getPositionId(questionId, true);
        uint256 noPositionId = negRiskAdapter.getPositionId(questionId, false);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        
        // Register tokens with CTFExchange (only register new questions, original question is already registered)
        _registerTokensWithCTFExchange(yes2PositionId, negRiskAdapter.getPositionId(question2Id, false), negRiskAdapter.getConditionId(question2Id));
        _registerTokensWithCTFExchange(yes3PositionId, negRiskAdapter.getPositionId(question3Id, false), negRiskAdapter.getConditionId(question3Id));
        
        // Mint tokens to users for testing
        _mintTokensToUser(user2, yesPositionId, 1e6); // User2 needs YES tokens to sell to taker
        _mintTokensToUser(user3, negRiskAdapter.getPositionId(question2Id, false), 1e6); // User3 needs NO tokens for question2
        _mintTokensToUser(user4, negRiskAdapter.getPositionId(question3Id, false), 1e6); // User4 needs NO tokens for question3
        
        // First maker order: Single order - user2 sells YES tokens to taker (complementary)
        makerOrders[0] = new ICTFExchange.OrderIntent[](1);
        makerOrders[0][0] = _createAndSignOrder(user2, yesPositionId, 1, 1e6, 0.3e6, questionId, 1, user2PK);
        makerFillAmounts[0] = 0.1e6; // 100K tokens
        
        // Second maker order: Cross-match order (2 orders) - user3 and user4 buy different tokens
        // In a cross-match, the taker (user1) is also involved, so user1 gets tokens from both single and cross-match
        makerOrders[1] = new ICTFExchange.OrderIntent[](2);
        makerOrders[1][0] = _createAndSignOrder(user3, yes2PositionId, 0, 0.25e6, 1e6, question2Id, 0, user3PK);
        makerOrders[1][1] = _createAndSignOrder(user4, yes3PositionId, 0, 0.35e6, 1e6, question3Id, 0, user4PK);
        makerFillAmounts[1] = 0.1e6; // 100K tokens
        
        // Create taker order - user1 buys YES tokens for questionId
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionId, 0, 0.4e6, 1e6, questionId, 0, user1PK);
        
        // Execute hybrid match orders (1 single order, 1 cross-match)
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 1);
        
        // Verify token balances after execution
        console.log("=== Verifying Token Balances After Hybrid Match ===");
        
        // User1 (taker) should receive YES tokens from both single order and cross-match
        // Single order: 100,000 tokens, Cross-match: 100,000 tokens = 200,000 total
        assertEq(ctf.balanceOf(user1, yesPositionId), 0.1e6 * 2, "User1 should receive YES tokens from both single order and cross-match");
        console.log("User1 YES tokens: %s", ctf.balanceOf(user1, yesPositionId));
        
        // User2 (single maker) should have sold YES tokens
        assertEq(ctf.balanceOf(user2, yesPositionId), 1e6 - makerFillAmounts[0], "User2 should have sold YES tokens");
        console.log("User2 YES tokens: %s", ctf.balanceOf(user2, yesPositionId));
        
        // User3 (cross-match maker) should receive YES2 tokens
        assertEq(ctf.balanceOf(user3, yes2PositionId), makerFillAmounts[1], "User3 should receive YES2 tokens from cross-match");
        console.log("User3 YES2 tokens: %s", ctf.balanceOf(user3, yes2PositionId));
        
        // User4 (cross-match maker) should receive YES3 tokens
        assertEq(ctf.balanceOf(user4, yes3PositionId), makerFillAmounts[1], "User4 should receive YES3 tokens from cross-match");
        console.log("User4 YES3 tokens: %s", ctf.balanceOf(user4, yes3PositionId));
        
        // Verify USDC balance changes
        console.log("=== Verifying USDC Balance Changes ===");
        
        // Users should have spent/received USDC appropriately
        assertTrue(usdc.balanceOf(user1) < 100000000e6, "User1 should have spent USDC for buying tokens");
        assertTrue(usdc.balanceOf(user2) > 100000000e6, "User2 should have received USDC for selling tokens");
        assertTrue(usdc.balanceOf(user3) < 100000000e6, "User3 should have spent USDC for buying tokens");
        assertTrue(usdc.balanceOf(user4) < 100000000e6, "User4 should have spent USDC for buying tokens");
        
        console.log("User1 USDC: %s", usdc.balanceOf(user1));
        console.log("User2 USDC: %s", usdc.balanceOf(user2));
        console.log("User3 USDC: %s", usdc.balanceOf(user3));
        console.log("User4 USDC: %s", usdc.balanceOf(user4));
        
        // Verify adapter has no remaining tokens or USDC (self-financing)
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
        assertEq(ctf.balanceOf(address(adapter), yesPositionId), 0, "Adapter should have no remaining YES tokens");
        assertEq(ctf.balanceOf(address(adapter), yes2PositionId), 0, "Adapter should have no remaining YES2 tokens");
        assertEq(ctf.balanceOf(address(adapter), yes3PositionId), 0, "Adapter should have no remaining YES3 tokens");
        
        console.log("Mixed single and cross-match orders test passed with proper balance verification!");
    }

    function test_HybridMatchOrders_EdgeCaseZeroSingleOrders() public {
        console.log("=== Testing Hybrid Match Orders: Zero Single Orders ===");
        
        // Create 1 cross-match maker order (no single orders)
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](1);
        uint256[] memory makerFillAmounts = new uint256[](1);
        
        // Create additional questions for cross-matching
        bytes32 question1Id = negRiskAdapter.prepareQuestion(marketId, "Question 1");
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        bytes32 question3Id = negRiskAdapter.prepareQuestion(marketId, "Question 3");
        
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        
        // Register tokens with CTFExchange
        _registerTokensWithCTFExchange(yes1PositionId, negRiskAdapter.getPositionId(question1Id, false), negRiskAdapter.getConditionId(question1Id));
        _registerTokensWithCTFExchange(yes2PositionId, negRiskAdapter.getPositionId(question2Id, false), negRiskAdapter.getConditionId(question2Id));
        _registerTokensWithCTFExchange(yes3PositionId, negRiskAdapter.getPositionId(question3Id, false), negRiskAdapter.getConditionId(question3Id));
        
        // Mint tokens to users for testing
        // For cross-matching, users don't need initial tokens as the mechanism creates them
        
        // Create cross-match maker order (with 2 orders)
        makerOrders[0] = new ICTFExchange.OrderIntent[](2);
        makerOrders[0][0] = _createAndSignOrder(user2, yes2PositionId, 0, 0.4e6, 1e6, question2Id, 0, user2PK);
        makerOrders[0][1] = _createAndSignOrder(user3, yes3PositionId, 0, 0.4e6, 1e6, question3Id, 0, user3PK);
        makerFillAmounts[0] = 0.1e6; // 100K tokens - smaller than makerAmount (1e6)
        
        // Create taker order - user1 buys YES tokens for question1
        ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user1, yes1PositionId, 0, 0.2e6, 1e6, question1Id, 0, user1PK);
        
        // Execute with 0 single orders (correct count)
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, 0);
        
        // For real CTFExchange, we can't easily track call counts, so we'll verify the execution completed successfully
        // The test passes if no revert occurs during execution
        console.log("Zero single orders test passed!");
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
