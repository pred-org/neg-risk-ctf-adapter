// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {CrossMatchingAdapter, ICTFExchange} from "src/CrossMatchingAdapter.sol";
import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
import {RevNegRiskAdapter} from "src/RevNegRiskAdapter.sol";
import {IRevNegRiskAdapter} from "src/interfaces/IRevNegRiskAdapter.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";
import {Deployer} from "lib/ctf-exchange/src/dev/util/Deployer.sol";
import {TestHelper} from "lib/ctf-exchange/src/dev/TestHelper.sol";

contract MockCTFExchange {
    uint256 public matchOrdersCallCount;
    ICTFExchange.OrderIntent internal lastTakerOrder;
    ICTFExchange.OrderIntent[] internal lastMakerOrders;
    uint256 public lastTakerFillAmount;
    uint256[] internal lastMakerFillAmounts;

    function matchOrders(
        ICTFExchange.OrderIntent memory takerOrder,
        ICTFExchange.OrderIntent[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) external {
        matchOrdersCallCount++;
        lastTakerOrder = takerOrder;
        
        // Copy maker orders to storage
        delete lastMakerOrders;
        for (uint256 i = 0; i < makerOrders.length; i++) {
            lastMakerOrders.push(makerOrders[i]);
        }
        
        lastTakerFillAmount = takerFillAmount;
        
        // Copy fill amounts to storage
        delete lastMakerFillAmounts;
        for (uint256 i = 0; i < makerFillAmounts.length; i++) {
            lastMakerFillAmounts.push(makerFillAmounts[i]);
        }
    }

    function reset() external {
        matchOrdersCallCount = 0;
        delete lastMakerOrders;
        delete lastMakerFillAmounts;
    }

    function getLastTakerOrder() external view returns (ICTFExchange.OrderIntent memory) {
        return lastTakerOrder;
    }

    function getLastMakerOrders() external view returns (ICTFExchange.OrderIntent[] memory) {
        return lastMakerOrders;
    }

    function getLastMakerFillAmounts() external view returns (uint256[] memory) {
        return lastMakerFillAmounts;
    }
}

contract CrossMatchingAdapterHybridSimpleTest is Test, TestHelper {
    CrossMatchingAdapter public adapter;
    NegRiskAdapter public negRiskAdapter;
    RevNegRiskAdapter public revNegRiskAdapter;
    MockCTFExchange public ctfExchange;
    IConditionalTokens public ctf;
    IERC20 public usdc;
    address public vault;
    
    // Test users
    address public user1;
    address public user2;
    address public user3;
    address public user4;

    // Market and question IDs
    bytes32 public marketId;
    bytes32 public questionId;
    
    // Position IDs for YES/NO tokens
    uint256 public yesPositionId;

    function setUp() public {
        // Deploy real ConditionalTokens contract using Deployer
        ctf = IConditionalTokens(Deployer.ConditionalTokens());
        vm.label(address(ctf), "ConditionalTokens");

        ctfExchange = new MockCTFExchange();
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

        // Setup vault with USDC and approve adapter
        MockUSDC(address(usdc)).mint(address(vault), 1000000000e6);
        vm.startPrank(address(vault));
        MockUSDC(address(usdc)).approve(address(adapter), type(uint256).max);
        vm.stopPrank();

        // Set up test users
        user1 = address(0x1111);
        user2 = address(0x2222);
        user3 = address(0x3333);
        user4 = address(0x4444);
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
            intent: intent,
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

    function test_HybridMatchOrders_AllSingleOrders() public {
        console.log("=== Testing Hybrid Match Orders: All Single Orders ===");
        
        // Reset mock exchange
        ctfExchange.reset();
        
        // Create 2 single maker orders
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](2);
        uint256[] memory makerFillAmounts = new uint256[](2);
        
        // Create additional questions
        bytes32 question1Id = negRiskAdapter.prepareQuestion(marketId, "Question 1");
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        
        // Create single maker orders
        makerOrders[0] = new ICTFExchange.OrderIntent[](1);
        makerOrders[0][0] = _createOrderIntent(user2, yes1PositionId, 0, 1e6, 0.75e6, question1Id, 0);
        makerFillAmounts[0] = 30 * 1e6;
        
        makerOrders[1] = new ICTFExchange.OrderIntent[](1);
        makerOrders[1][0] = _createOrderIntent(user3, yes2PositionId, 0, 1e6, 0.75e6, question2Id, 0);
        makerFillAmounts[1] = 70 * 1e6;
        
        // Create taker order
        ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(user1, yesPositionId, 0, 1e6, 0.25e6, questionId, 0);
        uint256 takerFillAmount = 100 * 1e6;
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts);
        
        // Verify that matchOrders was called only once (batch optimization)
        assertEq(ctfExchange.matchOrdersCallCount(), 1, "matchOrders should be called only once for batch processing");
        
        // Verify the batch call parameters
        ICTFExchange.OrderIntent memory lastTakerOrder = ctfExchange.getLastTakerOrder();
        ICTFExchange.OrderIntent[] memory lastMakerOrders = ctfExchange.getLastMakerOrders();
        
        assertEq(lastTakerOrder.order.maker, user1, "Taker order maker should be user1");
        assertEq(lastMakerOrders.length, 2, "Should have 2 maker orders in batch");
        assertEq(ctfExchange.lastTakerFillAmount(), takerFillAmount, "Taker fill amount should match");
        assertEq(ctfExchange.getLastMakerFillAmounts().length, 2, "Should have 2 maker fill amounts");
        
        // Verify individual maker orders in the batch
        assertEq(lastMakerOrders[0].order.maker, user2, "First maker should be user2");
        assertEq(lastMakerOrders[1].order.maker, user3, "Second maker should be user3");
        
        console.log("All single orders test passed!");
    }

    function test_HybridMatchOrders_AllCrossMatchOrders() public {
        console.log("=== Testing Hybrid Match Orders: All Cross-Match Orders ===");
        
        // Reset mock exchange
        ctfExchange.reset();
        
        // Create 1 cross-match maker order (length > 1)
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](1);
        uint256[] memory makerFillAmounts = new uint256[](1);
        
        // Create additional questions for cross-matching
        bytes32 question1Id = negRiskAdapter.prepareQuestion(marketId, "Question 1");
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        
        // Create cross-match maker order (with 2 orders)
        makerOrders[0] = new ICTFExchange.OrderIntent[](2);
        makerOrders[0][0] = _createOrderIntent(user2, yes1PositionId, 0, 1e6, 0.35e6, question1Id, 0);
        makerOrders[0][1] = _createOrderIntent(user3, yes2PositionId, 0, 1e6, 0.5e6, question2Id, 0);
        makerFillAmounts[0] = 100 * 1e6;
        
        // Create taker order
        ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(user1, yesPositionId, 0, 1e6, 0.15e6, questionId, 0);
        uint256 takerFillAmount = 100 * 1e6;
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts);
        
        // Verify that matchOrders was NOT called (all orders are cross-match)
        assertEq(ctfExchange.matchOrdersCallCount(), 0, "matchOrders should not be called for cross-match orders");
        
        console.log("All cross-match orders test passed!");
    }

    function test_HybridMatchOrders_MixedSingleAndCrossMatch() public {
        console.log("=== Testing Hybrid Match Orders: Mixed Single and Cross-Match Orders ===");
        
        // Reset mock exchange
        ctfExchange.reset();
        
        // Create mixed orders: 1 single + 1 cross-match
        ICTFExchange.OrderIntent[][] memory makerOrders = new ICTFExchange.OrderIntent[][](2);
        uint256[] memory makerFillAmounts = new uint256[](2);
        
        // Create additional questions
        bytes32 question1Id = negRiskAdapter.prepareQuestion(marketId, "Question 1");
        bytes32 question2Id = negRiskAdapter.prepareQuestion(marketId, "Question 2");
        bytes32 question3Id = negRiskAdapter.prepareQuestion(marketId, "Question 3");
        
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        
        // First maker order: Single order
        makerOrders[0] = new ICTFExchange.OrderIntent[](1);
        makerOrders[0][0] = _createOrderIntent(user2, yes1PositionId, 0, 1e6, 0.6e6, question1Id, 0);
        makerFillAmounts[0] = 40 * 1e6;
        
        // Second maker order: Cross-match order (2 orders)
        makerOrders[1] = new ICTFExchange.OrderIntent[](2);
        makerOrders[1][0] = _createOrderIntent(user3, yes2PositionId, 0, 1e6, 0.25e6, question2Id, 0);
        makerOrders[1][1] = _createOrderIntent(user4, yes3PositionId, 0, 1e6, 0.35e6, question3Id, 0);
        makerFillAmounts[1] = 60 * 1e6;
        
        // Create taker order
        ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(user1, yesPositionId, 0, 1e6, 0.4e6, questionId, 0);
        uint256 takerFillAmount = 100 * 1e6;
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, makerFillAmounts);
        
        // Verify that matchOrders was called only once for the 1 single order
        assertEq(ctfExchange.matchOrdersCallCount(), 1, "matchOrders should be called once for single orders");
        
        // Verify the batch call contains only the 1 single order
        ICTFExchange.OrderIntent[] memory lastMakerOrders = ctfExchange.getLastMakerOrders();
        assertEq(lastMakerOrders.length, 1, "Should have 1 single maker order in batch");
        assertEq(ctfExchange.getLastMakerFillAmounts().length, 1, "Should have 1 maker fill amount");
        
        // Verify the single order is in the batch
        assertEq(lastMakerOrders[0].order.maker, user2, "Single maker should be user2");
        
        console.log("Mixed single and cross-match orders test passed!");
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
