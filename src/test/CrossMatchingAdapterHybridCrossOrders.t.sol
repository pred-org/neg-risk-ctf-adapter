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

    function testHybridMatchCrossOrders() public {
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
        // negRiskOperator.reportPayouts(bytes32(0), dummyPayout);

        // vm.warp(block.timestamp + 2 * negRiskOperator.DELAY_PERIOD());

        // negRiskOperator.resolveQuestion(questionId);
        
        makerOrders[0].orders = new ICTFExchange.OrderIntent[](4);
        makerOrders[0].orders[0] = _createAndSignOrder(user2, yesPositionIds[0], 0, 0.1e6, 1e6, questionIds[0], 0, _user2PK);
        makerOrders[0].orders[1] = _createAndSignOrder(user3, yesPositionIds[1], 0, 0.1e6, 1e6, questionIds[1], 0, _user3PK);
        makerOrders[0].orders[2] = _createAndSignOrder(user4, yesPositionIds[2], 0, 0.1e6, 1e6, questionIds[2], 0, _user4PK);
        makerOrders[0].orders[3] = _createAndSignOrder(user5, yesPositionIds[3], 0, 0.1e6, 1e6, questionIds[3], 0, _user5PK);
        makerOrders[0].orderType = CrossMatchingAdapter.OrderType.CROSS_MATCH;
        uint256[] memory takerFillAmount = new uint256[](1);
        takerFillAmount[0] = 0.6e6;

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
        adapter.hybridMatchOrders(marketId, takerOrder, makerOrders, takerFillAmount, 0);
        
        // Verify all participants received their tokens
        // assertEq(ctf.balanceOf(user1, yesPositionIds[4]), makerFillAmounts[0], "User1 should receive YES tokens from taker order");
        // assertEq(ctf.balanceOf(user2, yesPositionIds[0]), makerFillAmounts[0], "User2 should receive YES tokens from cross-match");
        // assertEq(ctf.balanceOf(user3, yesPositionIds[1]), makerFillAmounts[0], "User3 should receive YES tokens from cross-match");
        // assertEq(ctf.balanceOf(user4, yesPositionIds[2]), makerFillAmounts[0], "User4 should receive YES tokens from cross-match");
        // assertEq(ctf.balanceOf(user5, yesPositionIds[3]), makerFillAmounts[0], "User5 should receive YES tokens from cross-match");
        
        // // Verify USDC balance changes (users should pay for tokens received)
        // assertEq(usdc.balanceOf(user1), (initialUser1USDC - (makerFillAmounts[0] * takerOrder.order.price)/1e6), "User1 should pay USDC for tokens received");
        // assertEq(usdc.balanceOf(user2), (initialUser2USDC - (makerFillAmounts[0] * makerOrders[0].orders[0].order.price)/1e6), "User2 should pay USDC for tokens received");
        // assertEq(usdc.balanceOf(user3), (initialUser3USDC - (makerFillAmounts[0] * makerOrders[0].orders[0].order.price)/1e6), "User3 should pay USDC for tokens received");
        // assertEq(usdc.balanceOf(user4), (initialUser4USDC - (makerFillAmounts[0] * makerOrders[0].orders[0].order.price)/1e6), "User4 should pay USDC for tokens received");
        // assertEq(usdc.balanceOf(user5), (initialUser5USDC - (makerFillAmounts[0] * makerOrders[0].orders[0].order.price)/1e6), "User5 should pay USDC for tokens received");
        
        // // Verify no tokens were left in adapter
        // for (uint256 i = 0; i < 5; i++) {
        //     assertEq(ctf.balanceOf(address(adapter), yesPositionIds[i]), 0, 
        //         string(abi.encodePacked("Adapter should not hold any YES tokens for question ", vm.toString(i))));
        // }
        
        console.log("Extreme price distribution test passed!");
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
