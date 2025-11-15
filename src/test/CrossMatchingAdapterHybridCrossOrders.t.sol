// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
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
import {WrappedCollateral} from "src/WrappedCollateral.sol";

// Events for testing
interface ICrossMatchingAdapterEvents {
    event OrderFilled(bytes32 indexed orderHash, address indexed maker, address indexed taker, uint256 makerAssetId, uint256 takerAssetId, uint256 makerAmountFilled, uint256 takerAmountFilled, uint256 fee);
    event OrdersMatched(bytes32 indexed takerOrderHash, address indexed takerOrderMaker, uint256 makerAssetId, uint256 takerAssetId, uint256 makerAmountFilled, uint256 takerAmountFilled);
}

contract CrossMatchingAdapterHybridCrossOrdersTest is Test, TestHelper, ICrossMatchingAdapterEvents {
    struct VerificationParams {
        address[] users;
        uint256[] yesPositionIds;
        uint256[] tokenIndices;
        uint256[] initialUSDC;
        uint256[] initialYES;
        uint256 initialVaultBalance;
        uint256[] takerFillAmount;
        uint256[] makerFillAmounts;
        uint256 expectedFillAmount;
    }

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
        
        negRiskAdapter.addAdmin(address(ctfExchange));

        vm.startPrank(address(ctfExchange));
        ctf.setApprovalForAll(address(negRiskAdapter), true);
        ctf.setApprovalForAll(address(ctfExchange), true);
        vm.stopPrank();

        // Deploy CrossMatchingAdapter
        adapter = new CrossMatchingAdapter(negRiskOperator, ICTFExchange(address(ctfExchange)), IRevNegRiskAdapter(address(revNegRiskAdapter)));
        vm.label(address(adapter), "CrossMatchingAdapter");

        // Add RevNegRiskAdapter as owner of WrappedCollateral so it can mint tokens
        // We need to call this from the NegRiskAdapter since it's the owner
        vm.startPrank(address(negRiskAdapter));
        ctf.setApprovalForAll(address(ctfExchange), true);
        negRiskAdapter.wcol().addOwner(address(revNegRiskAdapter));
        negRiskAdapter.wcol().addOwner(address(adapter));
        vm.stopPrank();

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
    ) internal returns (OrderIntent memory) {
        uint256 price;
        uint256 quantity;
        if (side == uint8(Side.BUY)) {
            price = (makerAmount * 1e6) / takerAmount;
            quantity = takerAmount;
        } else {
            price = (takerAmount * 1e6) / makerAmount;
            quantity = makerAmount;
        }

        bool isYes = true;
        if (intent == uint8(Intent.LONG)) {
            if (side == uint8(Side.BUY)) {
                isYes = true;
            } else {
                isYes = false;
            }
        } else {
            if (side == uint8(Side.SELL)) {
                isYes = true;
            } else {
                isYes = false;
            }
        }
        if (!isYes) {
            price = 1e6 - price;
        }
        
        Order memory order = Order({
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
            intent: Intent(intent),
            signatureType: SignatureType.EOA,
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
        
        return OrderIntent({
            tokenId: tokenId,
            side: Side(side),
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            order: order
        });
    }
    
    function _signMessage(uint256 pk, bytes32 message) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, message);
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice Helper function to derive asset IDs from an order
    function _deriveAssetIds(OrderIntent memory order) internal pure returns (uint256 makerAssetId, uint256 takerAssetId) {
        if (order.side == Side.BUY) return (0, order.tokenId);
        return (order.tokenId, 0);
    }

    /// @notice Helper function to get order hash
    function _getOrderHash(OrderIntent memory order) internal view returns (bytes32) {
        Order memory orderForHash = Order({
            salt: order.order.salt,
            maker: order.order.maker,
            signer: order.order.signer,
            taker: order.order.taker,
            price: order.order.price,
            quantity: order.order.quantity,
            expiration: order.order.expiration,
            nonce: order.order.nonce,
            feeRateBps: order.order.feeRateBps,
            questionId: order.order.questionId,
            intent: Intent(uint8(order.order.intent)),
            signatureType: SignatureType(uint8(order.order.signatureType)),
            signature: order.order.signature
        });
        return ctfExchange.hashOrder(orderForHash);
    }

    /// @notice Helper function to set up OrderFilled event expectations for maker orders
    function _expectMakerOrderFilledEvents(
        OrderIntent[] memory makerOrders,
        uint256[] memory makerFillAmounts,
        uint256 expectedFillAmount,
        address takerMaker
    ) internal {
        for (uint256 i = 0; i < makerOrders.length; i++) {
            bytes32 makerOrderHash = _getOrderHash(makerOrders[i]);
            (uint256 makerMakerAssetId, uint256 makerTakerAssetId) = _deriveAssetIds(makerOrders[i]);
            
            vm.expectEmit(true, true, true, true, address(adapter));
            emit OrderFilled(
                makerOrderHash,
                makerOrders[i].order.maker,
                takerMaker,
                makerMakerAssetId,
                makerTakerAssetId,
                makerFillAmounts[i],
                expectedFillAmount,
                0
            );
        }
    }

    /// @notice Helper function to set up OrderFilled event expectation for taker order
    function _expectTakerOrderFilledEvent(
        OrderIntent memory takerOrder,
        uint256 takerFillAmount,
        uint256 expectedFillAmount
    ) internal {
        bytes32 takerOrderHash = _getOrderHash(takerOrder);
        (uint256 takerMakerAssetId, uint256 takerTakerAssetId) = _deriveAssetIds(takerOrder);
        
        vm.expectEmit(true, true, true, true, address(adapter));
        emit OrderFilled(
            takerOrderHash,
            takerOrder.order.maker,
            address(adapter),
            takerMakerAssetId,
            takerTakerAssetId,
            takerFillAmount,
            expectedFillAmount,
            0
        );
    }

    /// @notice Helper function to set up OrdersMatched event expectation
    function _expectOrdersMatchedEvent(
        OrderIntent memory takerOrder,
        uint256 takerFillAmount,
        uint256 expectedFillAmount
    ) internal {
        bytes32 takerOrderHash = _getOrderHash(takerOrder);
        (uint256 takerMakerAssetId, uint256 takerTakerAssetId) = _deriveAssetIds(takerOrder);
        
        vm.expectEmit(true, true, true, true, address(adapter));
        emit OrdersMatched(
            takerOrderHash,
            takerOrder.order.maker,
            takerMakerAssetId,
            takerTakerAssetId,
            takerFillAmount,
            expectedFillAmount
        );
    }

    /// @notice Helper function to set up OrderFilled event expectations for maker orders (filtered by side)
    function _expectMakerOrderFilledEventsBySide(
        OrderIntent[] memory makerOrders,
        uint256[] memory makerFillAmounts,
        uint256 expectedFillAmount,
        address takerMaker,
        Side side
    ) internal {
        for (uint256 i = 0; i < makerOrders.length; i++) {
            if (makerOrders[i].side == side) {
                bytes32 makerOrderHash = _getOrderHash(makerOrders[i]);
                (uint256 makerMakerAssetId, uint256 makerTakerAssetId) = _deriveAssetIds(makerOrders[i]);
                
                vm.expectEmit(true, true, true, true, address(adapter));
                emit OrderFilled(
                    makerOrderHash,
                    makerOrders[i].order.maker,
                    takerMaker,
                    makerMakerAssetId,
                    makerTakerAssetId,
                    makerFillAmounts[i],
                    expectedFillAmount,
                    0
                );
            }
        }
    }

    function testHybridMatchCrossLongOrders() public {
        console.log("=== Testing Hybrid Match Cross Orders ===");
        
        // Create 5 questions with extreme price distributions
        bytes32[] memory questionIds = new bytes32[](5);
        uint256[] memory yesPositionIds = new uint256[](5);

        questionIds[0] = questionId;
        yesPositionIds[0] = yesPositionId;

        
        for (uint256 i = 1; i < 5; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        makerOrders[0].makerFillAmounts = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            makerOrders[0].makerFillAmounts[i] = 0.1e6;
        }
        
        makerOrders[0].orders = new OrderIntent[](4);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.1e6, 1e6, questionIds[0], 0, _user2PK);
        makerOrders[0].orders[1] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.1e6, 1e6, questionIds[1], 0, _user3PK);
        makerOrders[0].orders[2] = _createAndSignOrder(user4, yesPositionIds[2], 0, 0.1e6, 1e6, questionIds[2], 0, _user4PK);
        makerOrders[0].orders[3] = _createAndSignOrder(user5, yesPositionIds[3], 0, 0.1e6, 1e6, questionIds[3], 0, _user5PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        uint256[] memory takerFillAmount = new uint256[](1);
        takerFillAmount[0] = 0.6e6;

        // Taker order - price 0.6
        // Total prices: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0
        OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[4], 0, 0.6e6, 1e6, questionIds[4], 0, _user1PK);
        
        // Record initial balances using arrays to reduce stack depth
        address[] memory users = new address[](5);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        users[3] = user4;
        users[4] = user5;
        
        uint256[] memory initialUSDC = new uint256[](5);
        uint256[] memory initialYES = new uint256[](5);
        uint256[] memory tokenIndices = new uint256[](5);
        tokenIndices[0] = 4; // user1 -> yesPositionIds[4]
        tokenIndices[1] = 0; // user2 -> yesPositionIds[0]
        tokenIndices[2] = 1; // user3 -> yesPositionIds[1]
        tokenIndices[3] = 2; // user4 -> yesPositionIds[2]
        tokenIndices[4] = 3; // user5 -> yesPositionIds[3]
        
        uint256 initialVaultBalance = usdc.balanceOf(vault);
        
        for (uint256 i = 0; i < 5; i++) {
            initialUSDC[i] = usdc.balanceOf(users[i]);
            initialYES[i] = ctf.balanceOf(users[i], yesPositionIds[tokenIndices[i]]);
        }
        
        // Calculate expected fill amount (same for all orders in cross-match)
        uint256 expectedFillAmount = takerFillAmount[0] * takerOrder.takerAmount / takerOrder.makerAmount;
        
        // Set up event expectations
        _expectMakerOrderFilledEvents(makerOrders[0].orders, makerOrders[0].makerFillAmounts, expectedFillAmount, takerOrder.order.maker);
        _expectTakerOrderFilledEvent(takerOrder, takerFillAmount[0], expectedFillAmount);
        _expectOrdersMatchedEvent(takerOrder, takerFillAmount[0], expectedFillAmount);
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, 0);

        // Verify results using helper function to reduce stack depth
        VerificationParams memory params = VerificationParams({
            users: users,
            yesPositionIds: yesPositionIds,
            tokenIndices: tokenIndices,
            initialUSDC: initialUSDC,
            initialYES: initialYES,
            initialVaultBalance: initialVaultBalance,
            takerFillAmount: takerFillAmount,
            makerFillAmounts: makerOrders[0].makerFillAmounts,
            expectedFillAmount: expectedFillAmount
        });
        _verifyCrossMatchResults(params);
        
        console.log("Extreme price distribution test passed!");
    }

    function testHybridMatchCrossLongOrdersInsufficientBalanceTest() public {
        console.log("=== Testing Hybrid Match Cross Orders Insufficient Balance Test ===");
        
        // Create 5 questions with extreme price distributions
        bytes32[] memory questionIds = new bytes32[](5);
        uint256[] memory yesPositionIds = new uint256[](5);

        questionIds[0] = questionId;
        yesPositionIds[0] = yesPositionId;

        uint256 _userXPK = 0x9999;
        address userX = vm.addr(_userXPK);
        vm.label(userX, "User X");
        
        for (uint256 i = 1; i < 5; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        makerOrders[0].makerFillAmounts = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            makerOrders[0].makerFillAmounts[i] = 0.1e6;
        }
        
        makerOrders[0].orders = new OrderIntent[](4);
        makerOrders[0].orders[0] = _createAndSignOrder(userX, yesPositionIds[0], 0, 0.1e6, 1e6, questionIds[0], 0, _userXPK);
        makerOrders[0].orders[1] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.1e6, 1e6, questionIds[1], 0, _user3PK);
        makerOrders[0].orders[2] = _createAndSignOrder(user4, yesPositionIds[2], 0, 0.1e6, 1e6, questionIds[2], 0, _user4PK);
        makerOrders[0].orders[3] = _createAndSignOrder(user5, yesPositionIds[3], 0, 0.1e6, 1e6, questionIds[3], 0, _user5PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        uint256[] memory takerFillAmount = new uint256[](1);
        takerFillAmount[0] = 0.6e6;

        // Taker order - price 0.6
        // Total prices: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0
        OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[4], 0, 0.6e6, 1e6, questionIds[4], 0, _user1PK);
        
        // Record initial balances using arrays to reduce stack depth
        address[] memory users = new address[](5);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        users[3] = user4;
        users[4] = user5;
        
        uint256[] memory initialUSDC = new uint256[](5);
        uint256[] memory initialYES = new uint256[](5);
        uint256[] memory tokenIndices = new uint256[](5);
        tokenIndices[0] = 4; // user1 -> yesPositionIds[4]
        tokenIndices[1] = 0; // user2 -> yesPositionIds[0]
        tokenIndices[2] = 1; // user3 -> yesPositionIds[1]
        tokenIndices[3] = 2; // user4 -> yesPositionIds[2]
        tokenIndices[4] = 3; // user5 -> yesPositionIds[3]
        
        uint256 initialVaultBalance = usdc.balanceOf(vault);
        
        for (uint256 i = 0; i < 5; i++) {
            initialUSDC[i] = usdc.balanceOf(users[i]);
            initialYES[i] = ctf.balanceOf(users[i], yesPositionIds[tokenIndices[i]]);
        }
        
        vm.expectRevert(bytes("Insufficient balance"));
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, 0);
        
        console.log("Extreme price distribution test passed!");
    }
    
    function testHybridMatchCrossOrdersSellers() public {
        console.log("=== Testing Hybrid Match Cross Orders - Makers Selling, Taker Buying ===");
        
        // Create 5 questions
        bytes32[] memory questionIds = new bytes32[](5);
        uint256[] memory yesPositionIds = new uint256[](5);

        questionIds[0] = questionId;
        yesPositionIds[0] = yesPositionId;
        
        for (uint256 i = 1; i < 5; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        negRiskAdapter.setPrepared(marketId);
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        makerOrders[0].makerFillAmounts = new uint256[](4);
        // For SELL orders, makerFillAmounts is in token amount (1e6 tokens each)
        for (uint256 i = 0; i < 4; i++) {
            makerOrders[0].makerFillAmounts[i] = 1e6;
        }
        
        // Maker orders - all selling YES tokens
        // For SELL orders: side=1, makerAmount=token amount (1e6), takerAmount=USDC amount
        // SHORT intent (0) + SELL side (1) = selling YES tokens
        makerOrders[0].orders = new OrderIntent[](4);
        // Maker 1: selling YES0 at price 0.1 (makerAmount=1e6 tokens, takerAmount=0.1e6 USDC)
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 1, 1e6, 0.1e6, questionIds[0], 1, _user2PK);
        // Maker 2: selling YES1 at price 0.1
        makerOrders[0].orders[1] = _createAndSignOrder(user3, yesPositionIds[1], 1, 1e6, 0.1e6, questionIds[1], 1, _user3PK);
        // Maker 3: selling YES2 at price 0.1
        makerOrders[0].orders[2] = _createAndSignOrder(user4, yesPositionIds[2], 1, 1e6, 0.1e6, questionIds[2], 1, _user4PK);
        // Maker 4: selling YES3 at price 0.1
        makerOrders[0].orders[3] = _createAndSignOrder(user5, yesPositionIds[3], 1, 1e6, 0.1e6, questionIds[3], 1, _user5PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        
        // Taker order - buying NO4 at price 0.6
        // For BUY orders: side=0, makerAmount=USDC amount (0.6e6), takerAmount=token amount (1e6)
        // SHORT intent (0) + BUY side (0) = buying NO tokens
        uint256[] memory takerFillAmount = new uint256[](1);
        takerFillAmount[0] = 0.4e6; // taker wants to spend 0.4e6 USDC
        
        // Get NO position ID for question 4
        uint256 noPositionId4 = negRiskAdapter.getPositionId(questionIds[4], false);
        
        // Taker order - price 0.6, buying NO4 (complementary to selling YES tokens)
        // Total prices: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0
        OrderIntent memory takerOrder = _createAndSignOrder(user1, noPositionId4, 0, 0.4e6, 1e6, questionIds[4], 1, _user1PK);
        
        // Mint YES tokens to makers so they can sell
        _mintTokensToUser(user2, yesPositionIds[0], 5e6);
        _mintTokensToUser(user3, yesPositionIds[1], 5e6);
        _mintTokensToUser(user4, yesPositionIds[2], 5e6);
        _mintTokensToUser(user5, yesPositionIds[3], 5e6);
        
        // Prepare wrapped collateral for minting (needed for cross match)
        // Total USDC needed: 0.1e6 + 0.1e6 + 0.1e6 + 0.1e6 + 0.6e6 = 1.0e6 (for splitting)
        MockUSDC(address(usdc)).mint(address(negRiskAdapter.wcol()), 1e6);
        vm.startPrank(address(negRiskAdapter));
        WrappedCollateral(address(negRiskAdapter.wcol())).mint(1e6);
        WrappedCollateral(address(negRiskAdapter.wcol())).transfer(address(ctf), 1e6);
        vm.stopPrank();
        
        // Record initial balances using arrays to reduce stack depth
        address[] memory users = new address[](5);
        users[0] = user1; // taker
        users[1] = user2; // maker 1
        users[2] = user3; // maker 2
        users[3] = user4; // maker 3
        users[4] = user5; // maker 4
        
        uint256[] memory tokenIndices = new uint256[](5);
        tokenIndices[0] = 4; // user1 -> noPositionId4
        tokenIndices[1] = 0; // user2 -> yesPositionIds[0]
        tokenIndices[2] = 1; // user3 -> yesPositionIds[1]
        tokenIndices[3] = 2; // user4 -> yesPositionIds[2]
        tokenIndices[4] = 3; // user5 -> yesPositionIds[3]
        
        // Store all initial balances in arrays to reduce stack depth
        uint256[] memory initialBalances = new uint256[](11); // 5 USDC + 4 YES + 1 NO + 1 vault
        initialBalances[10] = usdc.balanceOf(vault); // Vault balance
        
        for (uint256 i = 0; i < 5; i++) {
            initialBalances[i] = usdc.balanceOf(users[i]); // USDC balances
            if (i == 0) {
                initialBalances[9] = ctf.balanceOf(users[i], noPositionId4); // NO balance
            } else {
                initialBalances[4 + i] = ctf.balanceOf(users[i], yesPositionIds[tokenIndices[i]]); // YES balances
            }
        }
        
        // Calculate expected fill amount (same for all orders in cross-match)
        uint256 expectedFillAmount = takerFillAmount[0] * takerOrder.takerAmount / takerOrder.makerAmount;
        
        // Set up event expectations for SHORT cross-match
        _expectMakerOrderFilledEvents(makerOrders[0].orders, makerOrders[0].makerFillAmounts, 1e5, takerOrder.order.maker);
        _expectTakerOrderFilledEvent(takerOrder, takerFillAmount[0], expectedFillAmount);
        _expectOrdersMatchedEvent(takerOrder, takerFillAmount[0], expectedFillAmount);
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, 0);

        // Verify results using helper function to reduce stack depth
        _verifyCrossMatchSellersResults(
            users,
            yesPositionIds,
            tokenIndices,
            noPositionId4,
            initialBalances,
            takerFillAmount,
            makerOrders
        );
        
        console.log("Cross match sellers test passed!");
    }

    function testHybridMatchCrossOrdersSellersInvalidSignaturesTest() public {
        console.log("=== Testing Hybrid Match Cross Orders - Makers Selling, Taker Buying ===");
        
        // Create 5 questions
        bytes32[] memory questionIds = new bytes32[](5);
        uint256[] memory yesPositionIds = new uint256[](5);

        questionIds[0] = questionId;
        yesPositionIds[0] = yesPositionId;
        
        for (uint256 i = 1; i < 5; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        negRiskAdapter.setPrepared(marketId);
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        makerOrders[0].makerFillAmounts = new uint256[](4);
        // For SELL orders, makerFillAmounts is in token amount (1e6 tokens each)
        for (uint256 i = 0; i < 4; i++) {
            makerOrders[0].makerFillAmounts[i] = 1e6;
        }
        
        // Maker orders - all selling YES tokens
        // For SELL orders: side=1, makerAmount=token amount (1e6), takerAmount=USDC amount
        // SHORT intent (0) + SELL side (1) = selling YES tokens
        makerOrders[0].orders = new OrderIntent[](4);
        // Maker 1: selling YES0 at price 0.1 (makerAmount=1e6 tokens, takerAmount=0.1e6 USDC)
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 1, 1e6, 0.1e6, questionIds[0], 1, _user3PK);
        // Maker 2: selling YES1 at price 0.1
        makerOrders[0].orders[1] = _createAndSignOrder(user3, yesPositionIds[1], 1, 1e6, 0.1e6, questionIds[1], 1, _user4PK);
        // Maker 3: selling YES2 at price 0.1
        makerOrders[0].orders[2] = _createAndSignOrder(user4, yesPositionIds[2], 1, 1e6, 0.1e6, questionIds[2], 1, _user4PK);
        // Maker 4: selling YES3 at price 0.1
        makerOrders[0].orders[3] = _createAndSignOrder(user5, yesPositionIds[3], 1, 1e6, 0.1e6, questionIds[3], 1, _user5PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        
        // Taker order - buying NO4 at price 0.6
        // For BUY orders: side=0, makerAmount=USDC amount (0.6e6), takerAmount=token amount (1e6)
        // SHORT intent (0) + BUY side (0) = buying NO tokens
        uint256[] memory takerFillAmount = new uint256[](1);
        takerFillAmount[0] = 0.4e6; // taker wants to spend 0.4e6 USDC
        
        // Get NO position ID for question 4
        uint256 noPositionId4 = negRiskAdapter.getPositionId(questionIds[4], false);
        
        // Taker order - price 0.6, buying NO4 (complementary to selling YES tokens)
        // Total prices: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0
        OrderIntent memory takerOrder = _createAndSignOrder(user1, noPositionId4, 0, 0.4e6, 1e6, questionIds[4], 1, _user1PK);
        
        // Mint YES tokens to makers so they can sell
        _mintTokensToUser(user2, yesPositionIds[0], 5e6);
        _mintTokensToUser(user3, yesPositionIds[1], 5e6);
        _mintTokensToUser(user4, yesPositionIds[2], 5e6);
        _mintTokensToUser(user5, yesPositionIds[3], 5e6);
        
        // Prepare wrapped collateral for minting (needed for cross match)
        // Total USDC needed: 0.1e6 + 0.1e6 + 0.1e6 + 0.1e6 + 0.6e6 = 1.0e6 (for splitting)
        MockUSDC(address(usdc)).mint(address(negRiskAdapter.wcol()), 1e6);
        vm.startPrank(address(negRiskAdapter));
        WrappedCollateral(address(negRiskAdapter.wcol())).mint(1e6);
        WrappedCollateral(address(negRiskAdapter.wcol())).transfer(address(ctf), 1e6);
        vm.stopPrank();
        
        // Record initial balances using arrays to reduce stack depth
        address[] memory users = new address[](5);
        users[0] = user1; // taker
        users[1] = user2; // maker 1
        users[2] = user3; // maker 2
        users[3] = user4; // maker 3
        users[4] = user5; // maker 4
        
        uint256[] memory tokenIndices = new uint256[](5);
        tokenIndices[0] = 4; // user1 -> noPositionId4
        tokenIndices[1] = 0; // user2 -> yesPositionIds[0]
        tokenIndices[2] = 1; // user3 -> yesPositionIds[1]
        tokenIndices[3] = 2; // user4 -> yesPositionIds[2]
        tokenIndices[4] = 3; // user5 -> yesPositionIds[3]
        
        // Store all initial balances in arrays to reduce stack depth
        uint256[] memory initialBalances = new uint256[](11); // 5 USDC + 4 YES + 1 NO + 1 vault
        initialBalances[10] = usdc.balanceOf(vault); // Vault balance
        
        for (uint256 i = 0; i < 5; i++) {
            initialBalances[i] = usdc.balanceOf(users[i]); // USDC balances
            if (i == 0) {
                initialBalances[9] = ctf.balanceOf(users[i], noPositionId4); // NO balance
            } else {
                initialBalances[4 + i] = ctf.balanceOf(users[i], yesPositionIds[tokenIndices[i]]); // YES balances
            }
        }
        
        vm.expectRevert(bytes("InvalidSignature()"));
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, 0);
        
        console.log("Cross match sellers test passed!");
    }

    function testHybridMatchCrossOrdersSellersSignatureReuseTest() public {
        console.log("=== Testing Hybrid Match Cross Orders - Makers Selling, Taker Buying ===");
        
        // Create 5 questions
        bytes32[] memory questionIds = new bytes32[](5);
        uint256[] memory yesPositionIds = new uint256[](5);

        questionIds[0] = questionId;
        yesPositionIds[0] = yesPositionId;
        
        for (uint256 i = 1; i < 5; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        negRiskAdapter.setPrepared(marketId);
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        makerOrders[0].makerFillAmounts = new uint256[](4);
        // For SELL orders, makerFillAmounts is in token amount (1e6 tokens each)
        for (uint256 i = 0; i < 4; i++) {
            makerOrders[0].makerFillAmounts[i] = 1e6;
        }
        
        // Maker orders - all selling YES tokens
        // For SELL orders: side=1, makerAmount=token amount (1e6), takerAmount=USDC amount
        // SHORT intent (0) + SELL side (1) = selling YES tokens
        makerOrders[0].orders = new OrderIntent[](4);
        // Maker 1: selling YES0 at price 0.1 (makerAmount=1e6 tokens, takerAmount=0.1e6 USDC)
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 1, 1e6, 0.1e6, questionIds[0], 1, _user2PK);
        // Maker 2: selling YES1 at price 0.1
        makerOrders[0].orders[1] = _createAndSignOrder(user3, yesPositionIds[1], 1, 1e6, 0.1e6, questionIds[1], 1, _user3PK);
        // Maker 3: selling YES2 at price 0.1
        makerOrders[0].orders[2] = _createAndSignOrder(user4, yesPositionIds[2], 1, 1e6, 0.1e6, questionIds[2], 1, _user4PK);
        // Maker 4: selling YES3 at price 0.1
        makerOrders[0].orders[3] = _createAndSignOrder(user5, yesPositionIds[3], 1, 1e6, 0.1e6, questionIds[3], 1, _user5PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        
        // Taker order - buying NO4 at price 0.6
        // For BUY orders: side=0, makerAmount=USDC amount (0.6e6), takerAmount=token amount (1e6)
        // SHORT intent (0) + BUY side (0) = buying NO tokens
        uint256[] memory takerFillAmount = new uint256[](1);
        takerFillAmount[0] = 0.4e6; // taker wants to spend 0.4e6 USDC
        
        // Get NO position ID for question 4
        uint256 noPositionId4 = negRiskAdapter.getPositionId(questionIds[4], false);
        
        // Taker order - price 0.6, buying NO4 (complementary to selling YES tokens)
        // Total prices: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0
        OrderIntent memory takerOrder = _createAndSignOrder(user1, noPositionId4, 0, 0.4e6, 1e6, questionIds[4], 1, _user1PK);
        
        // Mint YES tokens to makers so they can sell
        _mintTokensToUser(user2, yesPositionIds[0], 5e6);
        _mintTokensToUser(user3, yesPositionIds[1], 5e6);
        _mintTokensToUser(user4, yesPositionIds[2], 5e6);
        _mintTokensToUser(user5, yesPositionIds[3], 5e6);
        
        // Prepare wrapped collateral for minting (needed for cross match)
        // Total USDC needed: 0.1e6 + 0.1e6 + 0.1e6 + 0.1e6 + 0.6e6 = 1.0e6 (for splitting)
        MockUSDC(address(usdc)).mint(address(negRiskAdapter.wcol()), 1e6);
        vm.startPrank(address(negRiskAdapter));
        WrappedCollateral(address(negRiskAdapter.wcol())).mint(1e6);
        WrappedCollateral(address(negRiskAdapter.wcol())).transfer(address(ctf), 1e6);
        vm.stopPrank();
        
        // Record initial balances using arrays to reduce stack depth
        address[] memory users = new address[](5);
        users[0] = user1; // taker
        users[1] = user2; // maker 1
        users[2] = user3; // maker 2
        users[3] = user4; // maker 3
        users[4] = user5; // maker 4
        
        uint256[] memory tokenIndices = new uint256[](5);
        tokenIndices[0] = 4; // user1 -> noPositionId4
        tokenIndices[1] = 0; // user2 -> yesPositionIds[0]
        tokenIndices[2] = 1; // user3 -> yesPositionIds[1]
        tokenIndices[3] = 2; // user4 -> yesPositionIds[2]
        tokenIndices[4] = 3; // user5 -> yesPositionIds[3]
        
        // Store all initial balances in arrays to reduce stack depth
        uint256[] memory initialBalances = new uint256[](11); // 5 USDC + 4 YES + 1 NO + 1 vault
        initialBalances[10] = usdc.balanceOf(vault); // Vault balance
        
        for (uint256 i = 0; i < 5; i++) {
            initialBalances[i] = usdc.balanceOf(users[i]); // USDC balances
            if (i == 0) {
                initialBalances[9] = ctf.balanceOf(users[i], noPositionId4); // NO balance
            } else {
                initialBalances[4 + i] = ctf.balanceOf(users[i], yesPositionIds[tokenIndices[i]]); // YES balances
            }
        }
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, 0);

        // order2
        CrossMatchingAdapter.MakerOrder[] memory makerOrder2 = new CrossMatchingAdapter.MakerOrder[](1);
        makerOrder2[0].makerFillAmounts = new uint256[](4);
        // For SELL orders, makerFillAmounts is in token amount (1e6 tokens each)
        for (uint256 i = 0; i < 4; i++) {
            makerOrder2[0].makerFillAmounts[i] = 1e6;
        }
        
        // Maker orders - all selling YES tokens
        // For SELL orders: side=1, makerAmount=token amount (1e6), takerAmount=USDC amount
        // SHORT intent (0) + SELL side (1) = selling YES tokens
        makerOrder2[0].orders = new OrderIntent[](4);

        makerOrder2[0].orders[0] = makerOrders[0].orders[0];
        makerOrder2[0].orders[1] = makerOrders[0].orders[1];
        makerOrder2[0].orders[2] = makerOrders[0].orders[2];
        makerOrder2[0].orders[3] = makerOrders[0].orders[3];
        makerOrder2[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;

        vm.expectRevert(bytes("OrderFilledOrCancelled()"));
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrder2, takerFillAmount, 0);

        
        console.log("Cross match sellers test passed!");
    }

    function testHybridMatchCrossOrdersRefundLeftoverTokens() public {
        console.log("=== Testing Hybrid Match Cross Orders ===");
        
        // Create 5 questions with extreme price distributions
        bytes32[] memory questionIds = new bytes32[](3);
        uint256[] memory yesPositionIds = new uint256[](3);

        questionIds[0] = questionId;
        yesPositionIds[0] = yesPositionId;

        
        for (uint256 i = 1; i < 3; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        makerOrders[0].makerFillAmounts = new uint256[](2);
        makerOrders[0].makerFillAmounts[0] = 0.3e6;
        makerOrders[0].makerFillAmounts[1] = 0.2e6;
        
        makerOrders[0].orders = new OrderIntent[](2);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.3e6, 1e6, questionIds[0], 0, _user2PK);
        makerOrders[0].orders[1] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.2e6, 1e6, questionIds[1], 0, _user3PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        uint256[] memory takerFillAmount = new uint256[](1);
        takerFillAmount[0] = 0.6e6;

        // Taker order - price 0.6
        // Total prices: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0
        OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[2], 0, 0.6e6, 1e6, questionIds[2], 0, _user1PK);
        
        // Record initial balances before execution (using arrays to reduce stack depth)
        uint256[] memory initialBalances = new uint256[](7);
        initialBalances[0] = usdc.balanceOf(user1);
        initialBalances[1] = usdc.balanceOf(user2);
        initialBalances[2] = usdc.balanceOf(user3);
        initialBalances[3] = ctf.balanceOf(user1, yesPositionIds[2]);
        initialBalances[4] = ctf.balanceOf(user2, yesPositionIds[0]);
        initialBalances[5] = ctf.balanceOf(user3, yesPositionIds[1]);
        initialBalances[6] = usdc.balanceOf(vault); // Vault balance
        
        // Calculate expected fill amount (same for all orders in cross-match)
        uint256 expectedFillAmount = takerFillAmount[0] * takerOrder.takerAmount / takerOrder.makerAmount;
        
        // Set up event expectations for LONG cross-match
        _expectMakerOrderFilledEvents(makerOrders[0].orders, makerOrders[0].makerFillAmounts, expectedFillAmount, takerOrder.order.maker);
        _expectTakerOrderFilledEvent(takerOrder, takerFillAmount[0], expectedFillAmount);
        _expectOrdersMatchedEvent(takerOrder, takerFillAmount[0], expectedFillAmount);
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, 0);

        // Verify results using helper function to reduce stack depth
        _verifyCrossMatchRefundResults(
            yesPositionIds,
            initialBalances,
            takerFillAmount,
            makerOrders,
            takerOrder
        );
        
        console.log("Hybrid Match Cross Orders Refund test passed!");
    }

    function testHybridMatchCrossOrdersMixedLong() public {
        console.log("=== Testing Hybrid Match Cross Orders Mixed Long ===");
        
        // Create 5 questions with extreme price distributions
        bytes32[] memory questionIds = new bytes32[](3);
        uint256[] memory yesPositionIds = new uint256[](3);

        questionIds[0] = questionId;
        yesPositionIds[0] = yesPositionId;
        
        for (uint256 i = 1; i < 3; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }

        uint256 noPosId1 = negRiskAdapter.getPositionId(questionIds[1], false);
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        makerOrders[0].makerFillAmounts = new uint256[](2);
        makerOrders[0].makerFillAmounts[0] = 0.3e6;
        makerOrders[0].makerFillAmounts[1] = 1e6;

        _mintTokensToUser(user3, noPosId1, 1e6);
        
        makerOrders[0].orders = new OrderIntent[](2);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.3e6, 1e6, questionIds[0], 0, _user2PK);
        makerOrders[0].orders[1] = _createAndSignOrder(user3, noPosId1, 1, 1e6, 0.9e6, questionIds[1], 0, _user3PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        uint256[] memory takerFillAmount = new uint256[](1);
        takerFillAmount[0] = 0.6e6;

        // Taker order - price 0.6
        // Total prices: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0
        OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[2], 0, 0.6e6, 1e6, questionIds[2], 0, _user1PK);
        
        // Record initial balances before execution (using arrays to reduce stack depth)
        uint256[] memory initialBalances = new uint256[](7);
        initialBalances[0] = usdc.balanceOf(user1);
        initialBalances[1] = usdc.balanceOf(user2);
        initialBalances[2] = usdc.balanceOf(user3);
        initialBalances[3] = ctf.balanceOf(user1, yesPositionIds[2]);
        initialBalances[4] = ctf.balanceOf(user2, yesPositionIds[0]);
        initialBalances[5] = ctf.balanceOf(user3, noPosId1);
        initialBalances[6] = usdc.balanceOf(vault); // Vault balance
        
        // Calculate expected fill amount (same for all orders in cross-match)
        uint256 expectedFillAmount = takerFillAmount[0] * takerOrder.takerAmount / takerOrder.makerAmount;
        
        // Set up event expectations for LONG cross-match with mixed buy/sell
        _expectMakerOrderFilledEventsBySide(makerOrders[0].orders, makerOrders[0].makerFillAmounts, expectedFillAmount, takerOrder.order.maker, Side.BUY);
        _expectMakerOrderFilledEventsBySide(makerOrders[0].orders, makerOrders[0].makerFillAmounts, 0.9e6, takerOrder.order.maker, Side.SELL);
        _expectTakerOrderFilledEvent(takerOrder, takerFillAmount[0], expectedFillAmount);
        _expectOrdersMatchedEvent(takerOrder, takerFillAmount[0], expectedFillAmount);
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, 0);

        // Verify results using helper function to reduce stack depth
        _verifyCrossMatchMixedLongResults(
            yesPositionIds,
            noPosId1,
            initialBalances,
            takerFillAmount,
            makerOrders,
            takerOrder
        );
        
        console.log("Mixed Long cross match test passed!");
    }

    function testHybridMatchCrossOrdersMixedLongResolvedQuestion() public {
        console.log("=== Testing Hybrid Match Cross Orders Mixed Long Resolved Question ===");
        
        // Create 5 questions with extreme price distributions
        bytes32[] memory questionIds = new bytes32[](4);
        uint256[] memory yesPositionIds = new uint256[](4);

        questionIds[0] = questionId;
        yesPositionIds[0] = yesPositionId;
        
        for (uint256 i = 1; i < 4; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }

        vm.prank(oracle);
        negRiskOperator.reportPayouts(bytes32(uint256(4)), dummyPayout);

        negRiskOperator.resolveQuestion(questionIds[3]);

        uint256 noPosId1 = negRiskAdapter.getPositionId(questionIds[1], false);
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        makerOrders[0].makerFillAmounts = new uint256[](2);
        makerOrders[0].makerFillAmounts[0] = 0.3e6;
        makerOrders[0].makerFillAmounts[1] = 1e6;

        _mintTokensToUser(user3, noPosId1, 1e6);
        
        makerOrders[0].orders = new OrderIntent[](2);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.3e6, 1e6, questionIds[0], 0, _user2PK);
        makerOrders[0].orders[1] = _createAndSignOrder(user3, noPosId1, 1, 1e6, 0.9e6, questionIds[1], 0, _user3PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        uint256[] memory takerFillAmount = new uint256[](1);
        takerFillAmount[0] = 0.6e6;

        // Taker order - price 0.6
        // Total prices: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0
        OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[2], 0, 0.6e6, 1e6, questionIds[2], 0, _user1PK);
        
        // Record initial balances before execution (using arrays to reduce stack depth)
        uint256[] memory initialBalances = new uint256[](7);
        initialBalances[0] = usdc.balanceOf(user1);
        initialBalances[1] = usdc.balanceOf(user2);
        initialBalances[2] = usdc.balanceOf(user3);
        initialBalances[3] = ctf.balanceOf(user1, yesPositionIds[2]);
        initialBalances[4] = ctf.balanceOf(user2, yesPositionIds[0]);
        initialBalances[5] = ctf.balanceOf(user3, noPosId1);
        initialBalances[6] = usdc.balanceOf(vault); // Vault balance
        
        // Calculate expected fill amount (same for all orders in cross-match)
        uint256 expectedFillAmount = takerFillAmount[0] * takerOrder.takerAmount / takerOrder.makerAmount;
        
        // Set up event expectations for LONG cross-match with mixed buy/sell
        _expectMakerOrderFilledEventsBySide(makerOrders[0].orders, makerOrders[0].makerFillAmounts, expectedFillAmount, takerOrder.order.maker, Side.BUY);
        _expectMakerOrderFilledEventsBySide(makerOrders[0].orders, makerOrders[0].makerFillAmounts, 0.9e6, takerOrder.order.maker, Side.SELL);
        _expectTakerOrderFilledEvent(takerOrder, takerFillAmount[0], expectedFillAmount);
        _expectOrdersMatchedEvent(takerOrder, takerFillAmount[0], expectedFillAmount);
        
        // Execute hybrid match orders
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, 0);

        // Verify results using helper function to reduce stack depth
        _verifyCrossMatchMixedLongResults(
            yesPositionIds,
            noPosId1,
            initialBalances,
            takerFillAmount,
            makerOrders,
            takerOrder
        );
        
        console.log("Mixed Long cross match test passed!");
    }

    function testHybridMatchCrossOrdersMixedLongResolvedQuestionFails() public {
        console.log("=== Testing Hybrid Match Cross Orders Mixed Long Resolved Question Fail ===");
        
        // Create 5 questions with extreme price distributions
        bytes32[] memory questionIds = new bytes32[](4);
        uint256[] memory yesPositionIds = new uint256[](4);

        questionIds[0] = questionId;
        yesPositionIds[0] = yesPositionId;
        
        for (uint256 i = 1; i < 4; i++) {
            questionIds[i] = negRiskOperator.prepareQuestion(marketId, bytes(abi.encodePacked("Question ", i)), bytes32(i+1));
            yesPositionIds[i] = negRiskAdapter.getPositionId(questionIds[i], true);
            uint256 noPosId = negRiskAdapter.getPositionId(questionIds[i], false);
            _registerTokensWithCTFExchange(yesPositionIds[i], noPosId, negRiskAdapter.getConditionId(questionIds[i]));
        }

        uint256 noPosId1 = negRiskAdapter.getPositionId(questionIds[1], false);
        
        CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
        makerOrders[0].makerFillAmounts = new uint256[](2);
        makerOrders[0].makerFillAmounts[0] = 0.3e6;
        makerOrders[0].makerFillAmounts[1] = 1e6;

        _mintTokensToUser(user3, noPosId1, 1e6);
        
        makerOrders[0].orders = new OrderIntent[](2);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.3e6, 1e6, questionIds[0], 0, _user2PK);
        makerOrders[0].orders[1] = _createAndSignOrder(user3, noPosId1, 1, 1e6, 0.9e6, questionIds[1], 0, _user3PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        uint256[] memory takerFillAmount = new uint256[](1);
        takerFillAmount[0] = 0.6e6;

        // Taker order - price 0.6
        // Total prices: 0.1 + 0.1 + 0.1 + 0.1 + 0.6 = 1.0
        OrderIntent memory takerOrder = _createAndSignOrder(user1, yesPositionIds[2], 0, 0.6e6, 1e6, questionIds[2], 0, _user1PK);
        
        // Execute hybrid match orders
        vm.expectRevert(abi.encodeWithSelector(ICrossMatchingAdapterEE.MissingUnresolvedQuestion.selector, questionIds[3]));
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, 0);
        
        console.log("Mixed Long cross match test failed!");
    }
    
    function _verifyCrossMatchResults(VerificationParams memory params) internal {
        // Verify token balances after execution
        console.log("=== Verifying Token Balances After Hybrid Match ===");
        
        // Verify all users received tokens
        for (uint256 i = 0; i < 5; i++) {
            uint256 tokenId = params.yesPositionIds[params.tokenIndices[i]];
            uint256 balance = ctf.balanceOf(params.users[i], tokenId);
            assertEq(
                balance,
                params.initialYES[i] + params.expectedFillAmount,
                string(abi.encodePacked("User", vm.toString(i + 1), " should receive YES tokens"))
            );
            console.log("User%i YES tokens: %s", i + 1, balance);
        }
        
        // Verify USDC balance changes
        console.log("=== Verifying USDC Balance Changes ===");
        
        // Taker (user1) should have paid USDC
        assertEq(
            usdc.balanceOf(params.users[0]),
            params.initialUSDC[0] - params.takerFillAmount[0],
            "User1 (taker) should pay USDC for buying YES tokens"
        );
        console.log("User1 USDC: %s", usdc.balanceOf(params.users[0]));
        
        // Makers should have paid their respective fill amounts
        for (uint256 i = 1; i < 5; i++) {
            assertEq(
                usdc.balanceOf(params.users[i]),
                params.initialUSDC[i] - params.makerFillAmounts[i - 1],
                string(abi.encodePacked("User", vm.toString(i + 1), " (maker) should pay USDC for buying YES tokens"))
            );
            console.log("User%i USDC: %s", i + 1, usdc.balanceOf(params.users[i]));
        }
        
        // Verify adapter has no remaining tokens or USDC (self-financing)
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
        for (uint256 i = 0; i < 5; i++) {
            assertEq(
                ctf.balanceOf(address(adapter), params.yesPositionIds[i]),
                0,
                string(abi.encodePacked("Adapter should have no remaining YES tokens for question ", vm.toString(i)))
            );
        }
        
        // Verify vault balance remains the same (self-financing)
        assertEq(usdc.balanceOf(vault), params.initialVaultBalance, "Vault balance should remain the same");
        console.log("Vault USDC balance: %s (unchanged)", usdc.balanceOf(vault));
    }
    
    function _verifyCrossMatchSellersResults(
        address[] memory users,
        uint256[] memory yesPositionIds,
        uint256[] memory tokenIndices,
        uint256 noPositionId4,
        uint256[] memory initialBalances,
        uint256[] memory takerFillAmount,
        CrossMatchingAdapter.MakerOrder[] memory makerOrders
    ) internal {
        // initialBalances array indices:
        // [0-4] = initialUSDC for users 0-4
        // [5-8] = initialYES for users 1-4 (indices 5,6,7,8)
        // [9] = initialNO for user 0
        // [10] = initialVaultBalance
        
        // Verify token balances after execution
        console.log("=== Verifying Token Balances After Hybrid Match ===");
        
        // In cross-match, fillAmount is the same for all orders (1e6 tokens)
        // For BUY order: fillAmount = takerFillAmount * takerAmount / makerAmount = 0.4e6 * 1e6 / 0.4e6 = 1e6
        uint256 fillAmount = takerFillAmount[0] * 1e6 / 0.4e6;
        
        // Taker (user1) should receive NO tokens (buying NO with SHORT intent)
        assertEq(
            ctf.balanceOf(users[0], noPositionId4),
            initialBalances[9] + fillAmount,
            "User1 (taker) should receive NO tokens from buying"
        );
        console.log("User1 NO tokens: %s", ctf.balanceOf(users[0], noPositionId4));
        
        // Makers should have sold their YES tokens
        for (uint256 i = 1; i < 5; i++) {
            assertEq(
                ctf.balanceOf(users[i], yesPositionIds[tokenIndices[i]]),
                initialBalances[4 + i] - makerOrders[0].makerFillAmounts[i - 1],
                string(abi.encodePacked("User", vm.toString(i + 1), " should have sold YES tokens"))
            );
            console.log("User%i YES tokens: %s", i + 1, ctf.balanceOf(users[i], yesPositionIds[tokenIndices[i]]));
        }
        
        // Verify USDC balance changes
        console.log("=== Verifying USDC Balance Changes ===");
        
        // Taker (user1) should have paid USDC for buying NO tokens
        assertEq(
            usdc.balanceOf(users[0]),
            initialBalances[0] - takerFillAmount[0],
            "User1 (taker) should pay USDC for buying NO tokens"
        );
        console.log("User1 USDC: %s", usdc.balanceOf(users[0]));
        
        // Makers should have received USDC for selling
        // For SELL orders: receive takerAmount per makerAmount sold
        for (uint256 i = 1; i < 5; i++) {
            uint256 expectedUSDC = makerOrders[0].makerFillAmounts[i - 1] * makerOrders[0].orders[i - 1].takerAmount / makerOrders[0].orders[i - 1].makerAmount;
            assertEq(
                usdc.balanceOf(users[i]),
                initialBalances[i] + expectedUSDC,
                string(abi.encodePacked("User", vm.toString(i + 1), " should receive USDC for selling YES tokens"))
            );
            console.log("User%i USDC: %s", i + 1, usdc.balanceOf(users[i]));
        }
        
        // Verify adapter has no remaining tokens or USDC (self-financing)
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
        for (uint256 i = 0; i < 5; i++) {
            assertEq(
                ctf.balanceOf(address(adapter), yesPositionIds[i]),
                0,
                string(abi.encodePacked("Adapter should have no remaining YES tokens for question ", vm.toString(i)))
            );
        }
        assertEq(ctf.balanceOf(address(adapter), noPositionId4), 0, "Adapter should have no remaining NO tokens for question 4");
        
        // Verify vault balance remains the same (self-financing)
        assertEq(usdc.balanceOf(vault), initialBalances[10], "Vault balance should remain the same");
        console.log("Vault USDC balance: %s (unchanged)", usdc.balanceOf(vault));
    }
    
    function _verifyCrossMatchMixedLongResults(
        uint256[] memory yesPositionIds,
        uint256 noPosId1,
        uint256[] memory initialBalances,
        uint256[] memory takerFillAmount,
        CrossMatchingAdapter.MakerOrder[] memory makerOrders,
        OrderIntent memory takerOrder
    ) internal {
        // initialBalances array indices:
        // [0] = initialUSDC1, [1] = initialUSDC2, [2] = initialUSDC3
        // [3] = initialYES1, [4] = initialYES2, [5] = initialNO3, [6] = initialVaultBalance
        
        // Verify token balances after execution
        console.log("=== Verifying Token Balances After Hybrid Match ===");
        
        // In cross-match, all orders receive the same fillAmount tokens
        // For BUY orders: fillAmount = takerFillAmount * takerAmount / makerAmount = 0.6e6 * 1e6 / 0.6e6 = 1e6
        uint256 expectedFillAmount = takerFillAmount[0] * takerOrder.takerAmount / takerOrder.makerAmount;
        
        // User1 (taker) should receive YES2 tokens
        assertEq(
            ctf.balanceOf(user1, yesPositionIds[2]),
            initialBalances[3] + expectedFillAmount,
            "User1 (taker) should receive YES2 tokens"
        );
        console.log("User1 YES2 tokens: %s", ctf.balanceOf(user1, yesPositionIds[2]));
        
        // User2 (maker) should receive YES0 tokens
        // For BUY order with makerFillAmount=0.3e6: fillAmount = makerFillAmount * takerAmount / makerAmount = 0.3e6 * 1e6 / 0.3e6 = 1e6
        uint256 fillAmountUser2 = makerOrders[0].makerFillAmounts[0] * makerOrders[0].orders[0].takerAmount / makerOrders[0].orders[0].makerAmount;
        assertEq(
            ctf.balanceOf(user2, yesPositionIds[0]),
            initialBalances[4] + fillAmountUser2,
            "User2 (maker) should receive YES0 tokens"
        );
        console.log("User2 YES0 tokens: %s", ctf.balanceOf(user2, yesPositionIds[0]));
        
        // User3 (maker) should have sold NO1 tokens
        assertEq(
            ctf.balanceOf(user3, noPosId1),
            initialBalances[5] - makerOrders[0].makerFillAmounts[1],
            "User3 (maker) should have sold NO1 tokens"
        );
        console.log("User3 NO1 tokens: %s", ctf.balanceOf(user3, noPosId1));
        
        // Verify USDC balance changes
        console.log("=== Verifying USDC Balance Changes ===");
        
        // User1 (taker) should have paid USDC for buying YES2 tokens
        assertEq(
            usdc.balanceOf(user1),
            initialBalances[0] - takerFillAmount[0],
            "User1 (taker) should pay USDC for buying YES2 tokens"
        );
        console.log("User1 USDC: %s", usdc.balanceOf(user1));
        
        // User2 (maker) should have paid USDC for buying YES0 tokens
        assertEq(
            usdc.balanceOf(user2),
            initialBalances[1] - makerOrders[0].makerFillAmounts[0],
            "User2 (maker) should pay USDC for buying YES0 tokens"
        );
        console.log("User2 USDC: %s", usdc.balanceOf(user2));
        
        // User3 (maker) should have received USDC for selling NO1 tokens
        // For SELL order: receive takerAmount per makerAmount sold = 0.9e6 * 1e6 / 1e6 = 0.9e6
        uint256 expectedUSDCUser3 = makerOrders[0].makerFillAmounts[1] * makerOrders[0].orders[1].takerAmount / makerOrders[0].orders[1].makerAmount;
        assertEq(
            usdc.balanceOf(user3),
            initialBalances[2] + expectedUSDCUser3,
            "User3 (maker) should receive USDC for selling NO1 tokens"
        );
        console.log("User3 USDC: %s", usdc.balanceOf(user3));
        
        // Verify adapter has no remaining tokens or USDC (self-financing)
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(
                ctf.balanceOf(address(adapter), yesPositionIds[i]),
                0,
                string(abi.encodePacked("Adapter should have no remaining YES tokens for question ", vm.toString(i)))
            );
        }
        assertEq(
            ctf.balanceOf(address(adapter), noPosId1),
            0,
            "Adapter should have no remaining NO tokens for question 1"
        );
        
        // Verify vault balance remains the same (self-financing)
        assertEq(usdc.balanceOf(vault), initialBalances[6], "Vault balance should remain the same");
        console.log("Vault USDC balance: %s (unchanged)", usdc.balanceOf(vault));
    }
    
    function _verifyCrossMatchRefundResults(
        uint256[] memory yesPositionIds,
        uint256[] memory initialBalances,
        uint256[] memory takerFillAmount,
        CrossMatchingAdapter.MakerOrder[] memory makerOrders,
        OrderIntent memory takerOrder
    ) internal {
        // initialBalances array indices:
        // [0] = initialUSDC1, [1] = initialUSDC2, [2] = initialUSDC3
        // [3] = initialYES1, [4] = initialYES2, [5] = initialYES3, [6] = initialVaultBalance
        
        // Verify token balances after execution
        console.log("=== Verifying Token Balances After Hybrid Match ===");
        
        // In cross-match, all orders receive the same fillAmount tokens
        // For BUY orders: fillAmount = takerFillAmount * takerAmount / makerAmount = 0.6e6 * 1e6 / 0.6e6 = 1e6
        uint256 expectedFillAmount = takerFillAmount[0] * takerOrder.takerAmount / takerOrder.makerAmount;
        
        // User1 (taker) should receive YES2 tokens
        assertEq(
            ctf.balanceOf(user1, yesPositionIds[2]),
            initialBalances[3] + expectedFillAmount,
            "User1 (taker) should receive YES2 tokens"
        );
        console.log("User1 YES2 tokens: %s", ctf.balanceOf(user1, yesPositionIds[2]));
        
        // User2 (maker) should receive YES0 tokens
        // For BUY order with makerFillAmount=0.3e6: fillAmount = makerFillAmount * takerAmount / makerAmount = 0.3e6 * 1e6 / 0.3e6 = 1e6
        uint256 fillAmountUser2 = makerOrders[0].makerFillAmounts[0] * makerOrders[0].orders[0].takerAmount / makerOrders[0].orders[0].makerAmount;
        assertEq(
            ctf.balanceOf(user2, yesPositionIds[0]),
            initialBalances[4] + fillAmountUser2,
            "User2 (maker) should receive YES0 tokens"
        );
        console.log("User2 YES0 tokens: %s", ctf.balanceOf(user2, yesPositionIds[0]));
        
        // User3 (maker) should receive YES1 tokens
        // For BUY order with makerFillAmount=0.2e6: fillAmount = makerFillAmount * takerAmount / makerAmount = 0.2e6 * 1e6 / 0.2e6 = 1e6
        uint256 fillAmountUser3 = makerOrders[0].makerFillAmounts[1] * makerOrders[0].orders[1].takerAmount / makerOrders[0].orders[1].makerAmount;
        assertEq(
            ctf.balanceOf(user3, yesPositionIds[1]),
            initialBalances[5] + fillAmountUser3,
            "User3 (maker) should receive YES1 tokens"
        );
        console.log("User3 YES1 tokens: %s", ctf.balanceOf(user3, yesPositionIds[1]));
        
        // Verify USDC balance changes
        console.log("=== Verifying USDC Balance Changes ===");
        
        // Total fill amounts: 0.3e6 + 0.2e6 + 0.6e6 = 1.1e6, but cross-match only needs 1.0e6
        // So user1 (taker) should receive 0.1e6 USDC refund
        // User1 (taker) should have paid takerFillAmount but get refund of 0.1e6
        // Expected: initialUSDC[0] - takerFillAmount[0] + 0.1e6
        uint256 expectedRefund = 0.1e6;
        assertEq(
            usdc.balanceOf(user1),
            initialBalances[0] - takerFillAmount[0] + expectedRefund,
            "User1 (taker) should pay USDC and receive 0.1e6 refund"
        );
        console.log("User1 USDC: %s (should have refund of 0.1e6)", usdc.balanceOf(user1));
        
        // User2 (maker) should have paid USDC for buying YES0 tokens
        assertEq(
            usdc.balanceOf(user2),
            initialBalances[1] - makerOrders[0].makerFillAmounts[0],
            "User2 (maker) should pay USDC for buying YES0 tokens"
        );
        console.log("User2 USDC: %s", usdc.balanceOf(user2));
        
        // User3 (maker) should have paid USDC for buying YES1 tokens
        assertEq(
            usdc.balanceOf(user3),
            initialBalances[2] - makerOrders[0].makerFillAmounts[1],
            "User3 (maker) should pay USDC for buying YES1 tokens"
        );
        console.log("User3 USDC: %s", usdc.balanceOf(user3));
        
        // Verify adapter has no remaining tokens or USDC (self-financing)
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(
                ctf.balanceOf(address(adapter), yesPositionIds[i]),
                0,
                string(abi.encodePacked("Adapter should have no remaining YES tokens for question ", vm.toString(i)))
            );
        }
        
        // Verify vault balance remains the same (self-financing)
        assertEq(usdc.balanceOf(vault), initialBalances[6], "Vault balance should remain the same");
        console.log("Vault USDC balance: %s (unchanged)", usdc.balanceOf(vault));
    }
    
    function _checkVaultBalanceUnchanged(uint256 initialBalance) internal {
        assertEq(usdc.balanceOf(vault), initialBalance, "Vault balance should remain the same");
        console.log("Vault USDC balance: %s (unchanged)", usdc.balanceOf(vault));
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
