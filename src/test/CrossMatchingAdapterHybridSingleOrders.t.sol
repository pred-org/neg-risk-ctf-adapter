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

contract CrossMatchingAdapterHybridSingleOrdersTest is Test, TestHelper {
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
        ctf.setApprovalForAll(address(negRiskAdapter), true);
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

    function testSingleOrdersMergeOneTest() public {
      console.log("=== Testing Single Orders Merge One Test ===");
        
      // Create 1 single order
      CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
      uint256[] memory takerFillAmounts = new uint256[](1);
        
      makerOrders[0].orders = new ICTFExchange.OrderIntent[](1);
      // Yes tokens selling order
      // For sell order: makerAmount = token amount (1e6), takerAmount = USDC amount (0.45e6)
      // price = 0.55$ per token
      makerOrders[0].orders[0] = _createAndSignOrder(
          user1, 
          yesPositionId, 
          1, 
          1e6, 
          0.45e6, 
          questionId, 
          1, 
          _user1PK
        );
      makerOrders[0].orderType = CrossMatchingAdapter.OrderType.SINGLE;
      makerOrders[0].makerFillAmounts = new uint256[](1);
      makerOrders[0].makerFillAmounts[0] = 1e6;
      takerFillAmounts[0] = 1e6;

      _mintTokensToUser(user1, yesPositionId, 5e6);
      _mintTokensToUser(user2, noPositionId, 5e6);

      MockUSDC(address(usdc)).mint(address(negRiskAdapter.wcol()), 1e6);
      vm.startPrank(address(negRiskAdapter));
      WrappedCollateral(address(negRiskAdapter.wcol())).mint(1e6);
      WrappedCollateral(address(negRiskAdapter.wcol())).transfer(address(ctf), 1e6);
      vm.stopPrank();
        
      // Taker order - NO tokens selling order
      // For sell order: makerAmount = token amount (1e6), takerAmount = USDC amount (0.55e6)
      // price = 0.45$
      ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user2, noPositionId, 1, 1e6, 0.55e6, questionId, 0, _user2PK);

      console.log("=== Taker Order ===");
      // Log taker order
      console2.log("=== Taker Order ===");
      console2.log("TokenId:", takerOrder.tokenId);
      console2.log("Side:", uint8(takerOrder.side));
      console2.log("MakerAmount:", takerOrder.makerAmount);
      console2.log("TakerAmount:", takerOrder.takerAmount);
      console2.log("Price:", takerOrder.order.price);
      console2.log("Quantity:", takerOrder.order.quantity);
      console2.log("Maker:", takerOrder.order.maker);
      console2.log("QuestionId:", uint256(takerOrder.order.questionId));
      console2.log("Intent:", uint8(takerOrder.order.intent));

      // Store initial balances
      uint256 initialUser1USDC = usdc.balanceOf(user1);
      uint256 initialUser2USDC = usdc.balanceOf(user2);
      uint256 initialUser1YES = ctf.balanceOf(user1, yesPositionId);
      uint256 initialUser2NO = ctf.balanceOf(user2, noPositionId);

      // Execute hybrid match orders (1 single order)
      adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmounts, 1);

      // Verify token balances after execution
      console.log("=== Verifying Token Balances After Hybrid Match ===");
      
      // User1 (maker) should have sold YES tokens (selling YES)
      // For SELL order: loses makerFillAmount tokens = 1e6 YES tokens
      assertEq(ctf.balanceOf(user1, yesPositionId), initialUser1YES - makerOrders[0].makerFillAmounts[0], "User1 should have sold YES tokens");
      console.log("User1 YES tokens: %s", ctf.balanceOf(user1, yesPositionId));
      
      // User2 (taker) should have sold NO tokens (selling NO)
      // For SELL order: loses takerFillAmount tokens = 1e6 NO tokens
      assertEq(ctf.balanceOf(user2, noPositionId), initialUser2NO - takerFillAmounts[0], "User2 should have sold NO tokens");
      console.log("User2 NO tokens: %s", ctf.balanceOf(user2, noPositionId));
      
      // Verify USDC balance changes
      console.log("=== Verifying USDC Balance Changes ===");
      
      // User1 should have received USDC for selling YES tokens
      // For SELL order: receives takerAmount (0.45e6) USDC minus fees
      // Since feeRateBps is 0, receives full takerAmount
      assertEq(usdc.balanceOf(user1), initialUser1USDC + makerOrders[0].orders[0].takerAmount, "User1 should receive USDC for selling YES tokens");
      console.log("User1 USDC: %s", usdc.balanceOf(user1));
      
      // User2 should have received USDC for selling NO tokens
      // For SELL order: receives takerAmount (0.55e6) USDC minus fees
      // Since feeRateBps is 0, receives full takerAmount
      assertEq(usdc.balanceOf(user2), initialUser2USDC + takerOrder.takerAmount, "User2 should receive USDC for selling NO tokens");
      console.log("User2 USDC: %s", usdc.balanceOf(user2));
      
      // Verify adapter has no remaining tokens or USDC (self-financing)
      assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
      assertEq(ctf.balanceOf(address(adapter), yesPositionId), 0, "Adapter should have no remaining YES tokens");
      assertEq(ctf.balanceOf(address(adapter), noPositionId), 0, "Adapter should have no remaining NO tokens");
        
      console.log("Single orders merge one test passed!");
    }

    function testSingleOrdersComplementaryOneTest() public {
      console.log("=== Testing Single Orders Complementary One Test ===");
        
      // Create 1 single order
      CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
      uint256[] memory takerFillAmounts = new uint256[](1);
        
      makerOrders[0].orders = new ICTFExchange.OrderIntent[](1);
      // NO tokens buying order
      // For buy order: makerAmount = USDC amount (0.55e6), takerAmount = token amount (1e6)
      // price = 0.55$ per token
      makerOrders[0].orders[0] = _createAndSignOrder(
          user1, 
          noPositionId, 
          0, 
          0.55e6, 
          1e6, 
          questionId, 
          1, 
          _user1PK
        );
      makerOrders[0].orderType = CrossMatchingAdapter.OrderType.SINGLE;
      makerOrders[0].makerFillAmounts = new uint256[](1);
      makerOrders[0].makerFillAmounts[0] = 0.55e6;
      takerFillAmounts[0] = 1e6;

      _mintTokensToUser(user2, noPositionId, 5e6);
        
      // Taker order - NO tokens selling order
      // For sell order: makerAmount = token amount (1e6), takerAmount = USDC amount (0.55e6)
      // price = 0.45$ per token
      ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user2, noPositionId, 1, 1e6, 0.55e6, questionId, 0, _user2PK);

      // console.log("=== Taker Order ===");
      // // Log taker order
      // console2.log("=== Taker Order ===");
      // console2.log("TokenId:", takerOrder.tokenId);
      // console2.log("Side:", uint8(takerOrder.side));
      // console2.log("MakerAmount:", takerOrder.makerAmount);
      // console2.log("TakerAmount:", takerOrder.takerAmount);
      // console2.log("Price:", takerOrder.order.price);
      // console2.log("Quantity:", takerOrder.order.quantity);
      // console2.log("Maker:", takerOrder.order.maker);
      // console2.log("QuestionId:", uint256(takerOrder.order.questionId));
      // console2.log("Intent:", uint8(takerOrder.order.intent));

      // Store initial balances
      uint256 initialUser1USDC = usdc.balanceOf(user1);
      uint256 initialUser2USDC = usdc.balanceOf(user2);
      uint256 initialUser2NO = ctf.balanceOf(user2, noPositionId);

      // Execute hybrid match orders (1 single order)
      adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmounts, 1);

      // Verify token balances after execution
      console.log("=== Verifying Token Balances After Hybrid Match ===");
      
      // User1 (maker) should receive NO tokens (buying NO)
      // For BUY order: makerFillAmount * takerAmount / makerAmount = 0.55e6 * 1e6 / 0.55e6 = 1e6 NO tokens
      assertEq(ctf.balanceOf(user1, noPositionId), makerOrders[0].makerFillAmounts[0] * makerOrders[0].orders[0].takerAmount / makerOrders[0].orders[0].makerAmount, "User1 should receive NO tokens from maker order");
      // console.log("User1 NO tokens: %s", ctf.balanceOf(user1, noPositionId));
      
      // User2 (taker) should have sold NO tokens (selling NO)
      // For SELL order: loses takerFillAmount tokens = 1e6 NO tokens
      assertEq(ctf.balanceOf(user2, noPositionId), initialUser2NO - takerFillAmounts[0], "User2 should have sold NO tokens");
      // console.log("User2 NO tokens: %s", ctf.balanceOf(user2, noPositionId));
      
      // Verify USDC balance changes
      console.log("=== Verifying USDC Balance Changes ===");
      
      // User1 should have paid USDC for buying NO tokens
      assertEq(usdc.balanceOf(user1), initialUser1USDC - makerOrders[0].makerFillAmounts[0], "User1 should pay USDC for buying NO tokens");
      // console.log("User1 USDC: %s", usdc.balanceOf(user1));
      
      // User2 should have received USDC for selling NO tokens
      // For SELL order: receives takerFillAmount * takerAmount / makerAmount = 1e6 * 0.55e6 / 1e6 = 0.55e6 USDC
      assertEq(usdc.balanceOf(user2), initialUser2USDC + (takerFillAmounts[0] * takerOrder.takerAmount / takerOrder.makerAmount), "User2 should receive USDC for selling NO tokens");
      // console.log("User2 USDC: %s", usdc.balanceOf(user2));
      
      // Verify adapter has no remaining tokens or USDC (self-financing)
      assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
      assertEq(ctf.balanceOf(address(adapter), noPositionId), 0, "Adapter should have no remaining NO tokens");
        
      console.log("Single orders complementary one test passed!");
    }

    function testSingleOrdersMintOneTest() public {
      console.log("=== Testing Single Orders Mint One Test ===");
        
      // Create 1 single order
      CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](1);
      makerOrders[0].makerFillAmounts = new uint256[](1);
      uint256[] memory takerFillAmounts = new uint256[](1);
        
      makerOrders[0].orders = new ICTFExchange.OrderIntent[](1);
      // YES tokens buying order
      // For buy order: makerAmount = USDC amount (0.55e6), takerAmount = token amount (1e6)
      // price = 0.55$ per token
      makerOrders[0].orders[0] = _createAndSignOrder(
          user1, 
          yesPositionId, 
          0, 
          0.55e6, 
          1e6, 
          questionId, 
          0, 
          _user1PK
        );
      makerOrders[0].orderType = CrossMatchingAdapter.OrderType.SINGLE;
      makerOrders[0].makerFillAmounts[0] = 0.55e6;
      takerFillAmounts[0] = 0.45e6;
        
      // Taker order - NO tokens buying order
      // For buy order: makerAmount = USDC amount (0.45e6), takerAmount = token amount (1e6)
      // price = 0.45$ per token
      ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user2, noPositionId, 0, 0.45e6, 1e6, questionId, 1, _user2PK);

      // Log 0th maker order
      console.log("=== 0th Maker Order ===");
      console2.log("Order Type:", uint8(makerOrders[0].orderType));
      console2.log("Number of orders:", makerOrders[0].orders.length);
      if (makerOrders[0].orders.length > 0) {
        console2.log("TokenId:", makerOrders[0].orders[0].tokenId);
        console2.log("Side:", uint8(makerOrders[0].orders[0].side));
        console2.log("MakerAmount:", makerOrders[0].orders[0].makerAmount);
        console2.log("TakerAmount:", makerOrders[0].orders[0].takerAmount);
        console2.log("Price:", makerOrders[0].orders[0].order.price);
        console2.log("Quantity:", makerOrders[0].orders[0].order.quantity);
        console2.log("Maker:", makerOrders[0].orders[0].order.maker);
        console2.log("QuestionId:", uint256(makerOrders[0].orders[0].order.questionId));
        console2.log("Intent:", uint8(makerOrders[0].orders[0].order.intent));
      }
      console2.log("MakerFillAmount:", makerOrders[0].makerFillAmounts[0]);

      // Log taker order
      console2.log("=== Taker Order ===");
      console2.log("TokenId:", takerOrder.tokenId);
      console2.log("Side:", uint8(takerOrder.side));
      console2.log("MakerAmount:", takerOrder.makerAmount);
      console2.log("TakerAmount:", takerOrder.takerAmount);
      console2.log("Price:", takerOrder.order.price);
      console2.log("Quantity:", takerOrder.order.quantity);
      console2.log("Maker:", takerOrder.order.maker);
      console2.log("QuestionId:", uint256(takerOrder.order.questionId));
      console2.log("Intent:", uint8(takerOrder.order.intent));

      // Store initial USDC balances
      uint256 initialUser1USDC = usdc.balanceOf(user1);
      uint256 initialUser2USDC = usdc.balanceOf(user2);

      // Execute hybrid match orders (1 single order)
      adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmounts, 1);

      // Verify token balances after execution
      console.log("=== Verifying Token Balances After Hybrid Match ===");
      
      // User1 (maker) should receive YES tokens
      // For BUY order: makerFillAmount * takerAmount / makerAmount = 0.55e6 * 1e6 / 0.55e6 = 1e6 YES tokens
      assertEq(ctf.balanceOf(user1, yesPositionId), makerOrders[0].makerFillAmounts[0] * makerOrders[0].orders[0].takerAmount / makerOrders[0].orders[0].makerAmount, "User1 should receive YES tokens from maker order");
      console.log("User1 YES tokens: %s", ctf.balanceOf(user1, yesPositionId));
      
      // User2 (taker) should receive NO tokens
      // For BUY order: takerFillAmount * takerAmount / makerAmount = 0.45e6 * 1e6 / 0.45e6 = 1e6 NO tokens
      assertEq(ctf.balanceOf(user2, noPositionId), takerFillAmounts[0] * takerOrder.takerAmount / takerOrder.makerAmount, "User2 should receive NO tokens from taker order");
      console.log("User2 NO tokens: %s", ctf.balanceOf(user2, noPositionId));
      
      // Verify USDC balance changes
      console.log("=== Verifying USDC Balance Changes ===");
      
      // User1 should have paid USDC for buying YES tokens
      assertEq(usdc.balanceOf(user1), initialUser1USDC - makerOrders[0].makerFillAmounts[0], "User1 should pay USDC for buying YES tokens");
      console.log("User1 USDC: %s", usdc.balanceOf(user1));
      
      // User2 should have paid USDC for buying NO tokens
      assertEq(usdc.balanceOf(user2), initialUser2USDC - takerFillAmounts[0], "User2 should pay USDC for buying NO tokens");
      console.log("User2 USDC: %s", usdc.balanceOf(user2));
      
      // Verify adapter has no remaining tokens or USDC (self-financing)
      assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
      assertEq(ctf.balanceOf(address(adapter), yesPositionId), 0, "Adapter should have no remaining YES tokens");
      assertEq(ctf.balanceOf(address(adapter), noPositionId), 0, "Adapter should have no remaining NO tokens");
        
      console.log("Single orders mint one test passed!");
    }

    // function testSingleOrdersMergeMultipleTest() public {
    //   console.log("=== Testing Single Orders Merge Multiple Test ===");
        
    //   // Create 3 single orders
    //   CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](3);
    //   uint256[][] memory makerFillAmounts = new uint256[][](3);
    //   for (uint256 i = 0; i < 3; i++) {
    //     makerFillAmounts[i] = new uint256[](1);
    //   }
    //   uint256[] memory takerFillAmounts = new uint256[](3);
        
    //   for (uint256 i = 0; i < 3; i++) {
    //     makerOrders[i].orders = new ICTFExchange.OrderIntent[](1);
    //     _mintTokensToUser(vm.addr(1000 + i), yesPositionId, 1e6);

    //     _setupUser(vm.addr(1000 + i), 1e6);
    //     vm.label(vm.addr(1000 + i), string(abi.encodePacked("User random", vm.toString(i))));

    //     makerOrders[i].orders[0] = _createAndSignOrder(
    //       vm.addr(1000 + i), 
    //       yesPositionId, 
    //       1, 
    //       1e6, 
    //       0.45e6, 
    //       questionId, 
    //       1, 
    //       1000 + i
    //     );
    //     makerOrders[i].orderType = CrossMatchingAdapter.OrderType.SINGLE;
    //     makerFillAmounts[i][0] = 1e6;
    //     takerFillAmounts[i] = 1e6;
    //   }

    //   _mintTokensToUser(user1, yesPositionId, 5e6);
    //   _mintTokensToUser(user2, noPositionId, 5e6);

    //   MockUSDC(address(usdc)).mint(address(negRiskAdapter.wcol()), 3e6);
    //   vm.startPrank(address(negRiskAdapter));
    //   WrappedCollateral(address(negRiskAdapter.wcol())).mint(3e6);
    //   WrappedCollateral(address(negRiskAdapter.wcol())).transfer(address(ctf), 3e6);
    //   vm.stopPrank();
        
    //   // Taker order - price 0.45 (minting one NO token)
    //   ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user2, noPositionId, 1, 3e6, 0.55e6 * 3, questionId, 0, _user2PK);

    //   // Log all maker orders
    //   console2.log("=== Maker Orders ===");
    //   console2.log("Number of maker orders:", makerOrders.length);
      
    //   for (uint256 i = 0; i < makerOrders.length; i++) {
    //     console2.log("--- Maker Order", i, "---");
    //     console2.log("  Order Type:", uint8(makerOrders[i].orderType));
    //     console2.log("  Number of orders in makerOrder:", makerOrders[i].orders.length);
    //     console2.log("  Maker Fill Amount:", makerFillAmounts[i][0]);
    //     console2.log("  Taker Fill Amount:", takerFillAmounts[i]);
        
    //     for (uint256 j = 0; j < makerOrders[i].orders.length; j++) {
    //       console2.log("  --- Order Intent", j, "---");
    //       console2.log("    TokenId:", makerOrders[i].orders[j].tokenId);
    //       console2.log("    Side:", uint8(makerOrders[i].orders[j].side));
    //       console2.log("    MakerAmount:", makerOrders[i].orders[j].makerAmount);
    //       console2.log("    TakerAmount:", makerOrders[i].orders[j].takerAmount);
          
    //       console2.log("    Order.salt:", makerOrders[i].orders[j].order.salt);
    //       console2.log("    Order.maker:", uint256(uint160(makerOrders[i].orders[j].order.maker)));
    //       console2.log("    Order.signer:", uint256(uint160(makerOrders[i].orders[j].order.signer)));
    //       console2.log("    Order.taker:", uint256(uint160(makerOrders[i].orders[j].order.taker)));
    //       console2.log("    Order.price:", makerOrders[i].orders[j].order.price);
    //       console2.log("    Order.quantity:", makerOrders[i].orders[j].order.quantity);
    //       console2.log("    Order.expiration:", makerOrders[i].orders[j].order.expiration);
    //       console2.log("    Order.nonce:", makerOrders[i].orders[j].order.nonce);
    //       console2.log("    Order.questionId:", uint256(makerOrders[i].orders[j].order.questionId));
    //       console2.log("    Order.intent:", uint8(makerOrders[i].orders[j].order.intent));
    //       console2.log("    Order.feeRateBps:", makerOrders[i].orders[j].order.feeRateBps);
    //       console2.log("    Order.signatureType:", uint8(makerOrders[i].orders[j].order.signatureType));
    //       console2.log("    Order.signature.length:", makerOrders[i].orders[j].order.signature.length);
    //     }
    //   }

    //   console.log("=== Taker Order ===");
    //   // Log taker order
    //   console2.log("=== Taker Order ===");
    //   console2.log("TokenId:", takerOrder.tokenId);
    //   console2.log("Side:", uint8(takerOrder.side));
    //   console2.log("MakerAmount:", takerOrder.makerAmount);
    //   console2.log("TakerAmount:", takerOrder.takerAmount);
    //   console2.log("Price:", takerOrder.order.price);
    //   console2.log("Quantity:", takerOrder.order.quantity);
    //   console2.log("Maker:", takerOrder.order.maker);
    //   console2.log("QuestionId:", uint256(takerOrder.order.questionId));
    //   console2.log("Intent:", uint8(takerOrder.order.intent));

    //   // Store initial balances
    //   uint256 initialUser2USDC = usdc.balanceOf(user2);
    //   uint256 initialUser2NO = ctf.balanceOf(user2, noPositionId);
      
    //   // Store initial balances for each maker
    //   uint256[] memory initialMakerUSDC = new uint256[](3);
    //   uint256[] memory initialMakerYES = new uint256[](3);
    //   for (uint256 i = 0; i < 3; i++) {
    //     initialMakerUSDC[i] = usdc.balanceOf(vm.addr(1000 + i));
    //     initialMakerYES[i] = ctf.balanceOf(vm.addr(1000 + i), yesPositionId);
    //   }

    //   // Execute hybrid match orders (3 single orders)
    //   adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, takerFillAmounts, 3);

    //   // Verify token balances after execution
    //   console.log("=== Verifying Token Balances After Hybrid Match ===");
      
    //   // Verify each maker has sold their YES tokens
    //   for (uint256 i = 0; i < 3; i++) {
    //     address maker = vm.addr(1000 + i);
    //     // For SELL order: loses makerFillAmount tokens = 1e6 YES tokens
    //     assertEq(ctf.balanceOf(maker, yesPositionId), initialMakerYES[i] - makerFillAmounts[i][0], 
    //       string(abi.encodePacked("Maker ", vm.toString(i), " should have sold YES tokens")));
    //     console.log("Maker %s YES tokens: %s", i, ctf.balanceOf(maker, yesPositionId));
    //   }
      
    //   // User2 (taker) should have sold NO tokens
    //   // For SELL order: loses makerAmount (3e6) NO tokens
    //   assertEq(ctf.balanceOf(user2, noPositionId), initialUser2NO - takerOrder.makerAmount, "User2 should have sold NO tokens");
    //   console.log("User2 NO tokens: %s", ctf.balanceOf(user2, noPositionId));
      
    //   // Verify USDC balance changes
    //   console.log("=== Verifying USDC Balance Changes ===");
      
    //   // Verify each maker received USDC for selling YES tokens
    //   for (uint256 i = 0; i < 3; i++) {
    //     address maker = vm.addr(1000 + i);
    //     // For SELL order: receives takerAmount (0.45e6) USDC minus fees
    //     // Since feeRateBps is 0, receives full takerAmount
    //     assertEq(usdc.balanceOf(maker), initialMakerUSDC[i] + makerOrders[i].orders[0].takerAmount, 
    //       string(abi.encodePacked("Maker ", vm.toString(i), " should receive USDC for selling YES tokens")));
    //     console.log("Maker %s USDC: %s", i, usdc.balanceOf(maker));
    //   }
      
    //   // User2 should have received USDC for selling NO tokens
    //   // For SELL order: receives takerAmount (1.65e6) USDC minus fees
    //   // Since feeRateBps is 0, receives full takerAmount
    //   assertEq(usdc.balanceOf(user2), initialUser2USDC + takerOrder.takerAmount, "User2 should receive USDC for selling NO tokens");
    //   console.log("User2 USDC: %s", usdc.balanceOf(user2));
      
    //   // Verify adapter has no remaining tokens or USDC (self-financing)
    //   assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
    //   assertEq(ctf.balanceOf(address(adapter), yesPositionId), 0, "Adapter should have no remaining YES tokens");
    //   assertEq(ctf.balanceOf(address(adapter), noPositionId), 0, "Adapter should have no remaining NO tokens");
        
    //   console.log("Single orders merge multiple test passed!");
    // }

    // function testSingleOrdersComplementaryMultipleTest() public {
    //   console.log("=== Testing Single Orders Complementary Multiple Test ===");
        
    //   // Create 3 single orders
    //   CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](3);
    //   uint256[][] memory makerFillAmounts = new uint256[][](3);
    //   for (uint256 i = 0; i < 3; i++) {
    //     makerFillAmounts[i] = new uint256[](1);
    //   }
    //   uint256[] memory takerFillAmounts = new uint256[](3);
        
    //   for (uint256 i = 0; i < 3; i++) {
    //     makerOrders[i].orders = new ICTFExchange.OrderIntent[](1);
        
    //     _setupUser(vm.addr(1000 + i), 1e6);
    //     vm.label(vm.addr(1000 + i), string(abi.encodePacked("User random", vm.toString(i))));

    //     // NO tokens buying order for each maker
    //     // For buy order: makerAmount = USDC amount (0.55e6), takerAmount = token amount (1e6)
    //     // price = 0.55$ per token
    //     makerOrders[i].orders[0] = _createAndSignOrder(
    //       vm.addr(1000 + i), 
    //       noPositionId, 
    //       0, 
    //       0.55e6, 
    //       1e6, 
    //       questionId, 
    //       1, 
    //       1000 + i
    //     );
    //     makerOrders[i].orderType = CrossMatchingAdapter.OrderType.SINGLE;
    //     makerFillAmounts[i][0] = 0.55e6;
    //     takerFillAmounts[i] = 1e6;
    //   }

    //   // Taker needs NO tokens to sell
    //   _mintTokensToUser(user2, noPositionId, 5e6);
        
    //   // Taker order - NO tokens selling order
    //   // For sell order: makerAmount = token amount (3e6), takerAmount = USDC amount (1.65e6)
    //   // price = 0.45$ per token (1.65e6 / 3e6 = 0.55, but sell side means price 0.45)
    //   ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user2, noPositionId, 1, 3e6, 1.65e6, questionId, 0, _user2PK);

    //   // Log all maker orders
    //   console2.log("=== Maker Orders ===");
    //   console2.log("Number of maker orders:", makerOrders.length);
      
    //   for (uint256 i = 0; i < makerOrders.length; i++) {
    //     console2.log("--- Maker Order", i, "---");
    //     console2.log("  Order Type:", uint8(makerOrders[i].orderType));
    //     console2.log("  Number of orders in makerOrder:", makerOrders[i].orders.length);
    //     console2.log("  Maker Fill Amount:", makerFillAmounts[i][0]);
    //     console2.log("  Taker Fill Amount:", takerFillAmounts[i]);
        
    //     for (uint256 j = 0; j < makerOrders[i].orders.length; j++) {
    //       console2.log("  --- Order Intent", j, "---");
    //       console2.log("    TokenId:", makerOrders[i].orders[j].tokenId);
    //       console2.log("    Side:", uint8(makerOrders[i].orders[j].side));
    //       console2.log("    MakerAmount:", makerOrders[i].orders[j].makerAmount);
    //       console2.log("    TakerAmount:", makerOrders[i].orders[j].takerAmount);
          
    //       console2.log("    Order.salt:", makerOrders[i].orders[j].order.salt);
    //       console2.log("    Order.maker:", uint256(uint160(makerOrders[i].orders[j].order.maker)));
    //       console2.log("    Order.signer:", uint256(uint160(makerOrders[i].orders[j].order.signer)));
    //       console2.log("    Order.taker:", uint256(uint160(makerOrders[i].orders[j].order.taker)));
    //       console2.log("    Order.price:", makerOrders[i].orders[j].order.price);
    //       console2.log("    Order.quantity:", makerOrders[i].orders[j].order.quantity);
    //       console2.log("    Order.expiration:", makerOrders[i].orders[j].order.expiration);
    //       console2.log("    Order.nonce:", makerOrders[i].orders[j].order.nonce);
    //       console2.log("    Order.questionId:", uint256(makerOrders[i].orders[j].order.questionId));
    //       console2.log("    Order.intent:", uint8(makerOrders[i].orders[j].order.intent));
    //       console2.log("    Order.feeRateBps:", makerOrders[i].orders[j].order.feeRateBps);
    //       console2.log("    Order.signatureType:", uint8(makerOrders[i].orders[j].order.signatureType));
    //       console2.log("    Order.signature.length:", makerOrders[i].orders[j].order.signature.length);
    //     }
    //   }

    //   console.log("=== Taker Order ===");
    //   // Log taker order
    //   console2.log("=== Taker Order ===");
    //   console2.log("TokenId:", takerOrder.tokenId);
    //   console2.log("Side:", uint8(takerOrder.side));
    //   console2.log("MakerAmount:", takerOrder.makerAmount);
    //   console2.log("TakerAmount:", takerOrder.takerAmount);
    //   console2.log("Price:", takerOrder.order.price);
    //   console2.log("Quantity:", takerOrder.order.quantity);
    //   console2.log("Maker:", takerOrder.order.maker);
    //   console2.log("QuestionId:", uint256(takerOrder.order.questionId));
    //   console2.log("Intent:", uint8(takerOrder.order.intent));

    //   // Store initial balances
    //   uint256 initialUser2USDC = usdc.balanceOf(user2);
    //   uint256 initialUser2NO = ctf.balanceOf(user2, noPositionId);
      
    //   // Store initial balances for each maker
    //   uint256[] memory initialMakerUSDC = new uint256[](3);
    //   for (uint256 i = 0; i < 3; i++) {
    //     initialMakerUSDC[i] = usdc.balanceOf(vm.addr(1000 + i));
    //   }

    //   // Execute hybrid match orders (3 single orders)
    //   adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, takerFillAmounts, 3);

    //   // Verify token balances after execution
    //   console.log("=== Verifying Token Balances After Hybrid Match ===");
      
    //   // Verify each maker has received NO tokens
    //   for (uint256 i = 0; i < 3; i++) {
    //     address maker = vm.addr(1000 + i);
    //     // For BUY order: receives makerFillAmount * takerAmount / makerAmount = 0.55e6 * 1e6 / 0.55e6 = 1e6 NO tokens
    //     assertEq(ctf.balanceOf(maker, noPositionId), makerFillAmounts[i][0] * makerOrders[i].orders[0].takerAmount / makerOrders[i].orders[0].makerAmount, 
    //       string(abi.encodePacked("Maker ", vm.toString(i), " should receive NO tokens")));
    //     console.log("Maker %s NO tokens: %s", i, ctf.balanceOf(maker, noPositionId));
    //   }
      
    //   // User2 (taker) should have sold NO tokens
    //   // For SELL order: loses makerAmount (3e6) NO tokens
    //   assertEq(ctf.balanceOf(user2, noPositionId), initialUser2NO - takerOrder.makerAmount, "User2 should have sold NO tokens");
    //   console.log("User2 NO tokens: %s", ctf.balanceOf(user2, noPositionId));
      
    //   // Verify USDC balance changes
    //   console.log("=== Verifying USDC Balance Changes ===");
      
    //   // Verify each maker paid USDC for buying NO tokens
    //   for (uint256 i = 0; i < 3; i++) {
    //     address maker = vm.addr(1000 + i);
    //     // For BUY order: pays makerFillAmount (0.55e6) USDC
    //     assertEq(usdc.balanceOf(maker), initialMakerUSDC[i] - makerFillAmounts[i][0], 
    //       string(abi.encodePacked("Maker ", vm.toString(i), " should pay USDC for buying NO tokens")));
    //     console.log("Maker %s USDC: %s", i, usdc.balanceOf(maker));
    //   }
      
    //   // User2 should have received USDC for selling NO tokens
    //   // For SELL order: receives takerAmount (1.65e6) USDC minus fees
    //   // Since feeRateBps is 0, receives full takerAmount
    //   assertEq(usdc.balanceOf(user2), initialUser2USDC + takerOrder.takerAmount, "User2 should receive USDC for selling NO tokens");
    //   console.log("User2 USDC: %s", usdc.balanceOf(user2));
      
    //   // Verify adapter has no remaining tokens or USDC (self-financing)
    //   assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
    //   assertEq(ctf.balanceOf(address(adapter), yesPositionId), 0, "Adapter should have no remaining YES tokens");
    //   assertEq(ctf.balanceOf(address(adapter), noPositionId), 0, "Adapter should have no remaining NO tokens");
        
    //   console.log("Single orders complementary multiple test passed!");
    // }

    // function testSingleOrdersMintMultipleTest() public {
    //   console.log("=== Testing Single Orders Mint Multiple Test ===");
        
    //   // Create 3 single orders
    //   CrossMatchingAdapter.MakerOrder[] memory makerOrders = new CrossMatchingAdapter.MakerOrder[](3);
    //   uint256[][] memory makerFillAmounts = new uint256[][](3);
    //   for (uint256 i = 0; i < 3; i++) {
    //     makerFillAmounts[i] = new uint256[](1);
    //   }
    //   uint256[] memory takerFillAmounts = new uint256[](3);
        
    //   for (uint256 i = 0; i < 3; i++) {
    //     makerOrders[i].orders = new ICTFExchange.OrderIntent[](1);
        
    //     _setupUser(vm.addr(1000 + i), 1e6);
    //     vm.label(vm.addr(1000 + i), string(abi.encodePacked("User random", vm.toString(i))));

    //     // YES tokens buying order for each maker
    //     // For buy order: makerAmount = USDC amount (0.55e6), takerAmount = token amount (1e6)
    //     // price = 0.55$ per token
    //     makerOrders[i].orders[0] = _createAndSignOrder(
    //       vm.addr(1000 + i), 
    //       yesPositionId, 
    //       0, 
    //       0.55e6, 
    //       1e6, 
    //       questionId, 
    //       0, 
    //       1000 + i
    //     );
    //     makerOrders[i].orderType = CrossMatchingAdapter.OrderType.SINGLE;
    //     makerFillAmounts[i][0] = 0.55e6;
    //     takerFillAmounts[i] = 0.45e6;
    //   }
        
    //   // Taker order - NO tokens buying order
    //   // For buy order: makerAmount = USDC amount (1.35e6), takerAmount = token amount (3e6)
    //   // price = 0.45$ per token (1.35e6 / 3e6 = 0.45)
    //   ICTFExchange.OrderIntent memory takerOrder = _createAndSignOrder(user2, noPositionId, 0, 1.35e6, 3e6, questionId, 1, _user2PK);

    //   // Prepare wrapped collateral for minting (total needed: 3e6 for YES + 3e6 for NO = 6e6)
    //   MockUSDC(address(usdc)).mint(address(negRiskAdapter.wcol()), 6e6);
    //   vm.startPrank(address(negRiskAdapter));
    //   WrappedCollateral(address(negRiskAdapter.wcol())).mint(6e6);
    //   WrappedCollateral(address(negRiskAdapter.wcol())).transfer(address(ctf), 6e6);
    //   vm.stopPrank();

    //   // Log all maker orders
    //   console2.log("=== Maker Orders ===");
    //   console2.log("Number of maker orders:", makerOrders.length);
      
    //   for (uint256 i = 0; i < makerOrders.length; i++) {
    //     console2.log("--- Maker Order", i, "---");
    //     console2.log("  Order Type:", uint8(makerOrders[i].orderType));
    //     console2.log("  Number of orders in makerOrder:", makerOrders[i].orders.length);
    //     console2.log("  Maker Fill Amount:", makerFillAmounts[i][0]);
    //     console2.log("  Taker Fill Amount:", takerFillAmounts[i]);
        
    //     for (uint256 j = 0; j < makerOrders[i].orders.length; j++) {
    //       console2.log("  --- Order Intent", j, "---");
    //       console2.log("    TokenId:", makerOrders[i].orders[j].tokenId);
    //       console2.log("    Side:", uint8(makerOrders[i].orders[j].side));
    //       console2.log("    MakerAmount:", makerOrders[i].orders[j].makerAmount);
    //       console2.log("    TakerAmount:", makerOrders[i].orders[j].takerAmount);
          
    //       console2.log("    Order.salt:", makerOrders[i].orders[j].order.salt);
    //       console2.log("    Order.maker:", uint256(uint160(makerOrders[i].orders[j].order.maker)));
    //       console2.log("    Order.signer:", uint256(uint160(makerOrders[i].orders[j].order.signer)));
    //       console2.log("    Order.taker:", uint256(uint160(makerOrders[i].orders[j].order.taker)));
    //       console2.log("    Order.price:", makerOrders[i].orders[j].order.price);
    //       console2.log("    Order.quantity:", makerOrders[i].orders[j].order.quantity);
    //       console2.log("    Order.expiration:", makerOrders[i].orders[j].order.expiration);
    //       console2.log("    Order.nonce:", makerOrders[i].orders[j].order.nonce);
    //       console2.log("    Order.questionId:", uint256(makerOrders[i].orders[j].order.questionId));
    //       console2.log("    Order.intent:", uint8(makerOrders[i].orders[j].order.intent));
    //       console2.log("    Order.feeRateBps:", makerOrders[i].orders[j].order.feeRateBps);
    //       console2.log("    Order.signatureType:", uint8(makerOrders[i].orders[j].order.signatureType));
    //       console2.log("    Order.signature.length:", makerOrders[i].orders[j].order.signature.length);
    //     }
    //   }

    //   console.log("=== Taker Order ===");
    //   // Log taker order
    //   console2.log("=== Taker Order ===");
    //   console2.log("TokenId:", takerOrder.tokenId);
    //   console2.log("Side:", uint8(takerOrder.side));
    //   console2.log("MakerAmount:", takerOrder.makerAmount);
    //   console2.log("TakerAmount:", takerOrder.takerAmount);
    //   console2.log("Price:", takerOrder.order.price);
    //   console2.log("Quantity:", takerOrder.order.quantity);
    //   console2.log("Maker:", takerOrder.order.maker);
    //   console2.log("QuestionId:", uint256(takerOrder.order.questionId));
    //   console2.log("Intent:", uint8(takerOrder.order.intent));

    //   // Store initial USDC balances
    //   uint256 initialUser2USDC = usdc.balanceOf(user2);
      
    //   // Store initial balances for each maker
    //   uint256[] memory initialMakerUSDC = new uint256[](3);
    //   for (uint256 i = 0; i < 3; i++) {
    //     initialMakerUSDC[i] = usdc.balanceOf(vm.addr(1000 + i));
    //   }

    //   // Execute hybrid match orders (3 single orders)
    //   adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, makerFillAmounts, takerFillAmounts, 3);

    //   // Verify token balances after execution
    //   console.log("=== Verifying Token Balances After Hybrid Match ===");
      
    //   // Verify each maker has received YES tokens
    //   for (uint256 i = 0; i < 3; i++) {
    //     address maker = vm.addr(1000 + i);
    //     // For BUY order: receives makerFillAmount * takerAmount / makerAmount = 0.55e6 * 1e6 / 0.55e6 = 1e6 YES tokens
    //     assertEq(ctf.balanceOf(maker, yesPositionId), makerFillAmounts[i][0] * makerOrders[i].orders[0].takerAmount / makerOrders[i].orders[0].makerAmount, 
    //       string(abi.encodePacked("Maker ", vm.toString(i), " should receive YES tokens from maker order")));
    //     console.log("Maker %s YES tokens: %s", i, ctf.balanceOf(maker, yesPositionId));
    //   }
      
    //   // User2 (taker) should receive NO tokens
    //   // For BUY order: receives takerFillAmount * takerAmount / makerAmount
    //   // Total takerFillAmounts: 0.45e6 * 3 = 1.35e6
    //   // Total tokens: 1.35e6 * 3e6 / 1.35e6 = 3e6 NO tokens
    //   uint256 totalTakerFillAmount = 0;
    //   for (uint256 i = 0; i < 3; i++) {
    //     totalTakerFillAmount += takerFillAmounts[i];
    //   }
    //   uint256 expectedNOAmount = totalTakerFillAmount * takerOrder.takerAmount / takerOrder.makerAmount;
    //   assertEq(ctf.balanceOf(user2, noPositionId), expectedNOAmount, "User2 should receive NO tokens from taker order");
    //   console.log("User2 NO tokens: %s", ctf.balanceOf(user2, noPositionId));
      
    //   // Verify USDC balance changes
    //   console.log("=== Verifying USDC Balance Changes ===");
      
    //   // Verify each maker paid USDC for buying YES tokens
    //   for (uint256 i = 0; i < 3; i++) {
    //     address maker = vm.addr(1000 + i);
    //     // For BUY order: pays makerFillAmount (0.55e6) USDC
    //     assertEq(usdc.balanceOf(maker), initialMakerUSDC[i] - makerFillAmounts[i][0], 
    //       string(abi.encodePacked("Maker ", vm.toString(i), " should pay USDC for buying YES tokens")));
    //     console.log("Maker %s USDC: %s", i, usdc.balanceOf(maker));
    //   }
      
    //   // User2 should have paid USDC for buying NO tokens
    //   // Total takerFillAmounts: 0.45e6 * 3 = 1.35e6
    //   assertEq(usdc.balanceOf(user2), initialUser2USDC - totalTakerFillAmount, "User2 should pay USDC for buying NO tokens");
    //   console.log("User2 USDC: %s", usdc.balanceOf(user2));
      
    //   // Verify adapter has no remaining tokens or USDC (self-financing)
    //   assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no remaining USDC");
    //   assertEq(ctf.balanceOf(address(adapter), yesPositionId), 0, "Adapter should have no remaining YES tokens");
    //   assertEq(ctf.balanceOf(address(adapter), noPositionId), 0, "Adapter should have no remaining NO tokens");
        
    //   console.log("Single orders mint multiple test passed!");
    // }
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
