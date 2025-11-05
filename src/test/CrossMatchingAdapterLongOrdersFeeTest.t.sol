// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.15;

// import {Test, console} from "forge-std/Test.sol";
// import {CrossMatchingAdapter} from "src/CrossMatchingAdapter.sol";
// import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
// import {NegRiskOperator} from "src/NegRiskOperator.sol";
// import {RevNegRiskAdapter} from "src/RevNegRiskAdapter.sol";
// import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
// import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
// import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";
// import {IRevNegRiskAdapter} from "src/interfaces/IRevNegRiskAdapter.sol";
// import {Deployer} from "lib/ctf-exchange/src/dev/util/Deployer.sol";
// import {TestHelper} from "lib/ctf-exchange/src/dev/TestHelper.sol";
// import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";
// import {WrappedCollateral} from "src/WrappedCollateral.sol";
// import {ICTFExchange} from "src/interfaces/ICTFExchange.sol";
// import {CTFExchange} from "lib/ctf-exchange/src/exchange/CTFExchange.sol";
// import {Side, SignatureType, Order, OrderIntent, Intent} from "lib/ctf-exchange/src/exchange/libraries/OrderStructs.sol";

// contract CrossMatchingAdapterLongOrdersFeeTest is Test, TestHelper {
//     CrossMatchingAdapter public adapter;
//     NegRiskAdapter public negRiskAdapter;
//     NegRiskOperator public negRiskOperator;
//     RevNegRiskAdapter public revNegRiskAdapter;
//     CTFExchange public ctfExchange;
//     IConditionalTokens public ctf;
//     IERC20 public usdc;
//     address public vault;
//     address public oracle;
    
//     uint256[] public dummyPayout;

//     // Test users
//     address public user1; // Arsenal
//     address public user2; // Barcelona
//     address public user3; // Chelsea
//     address public user4; // Spurs
    
//     // Private keys for signing
//     uint256 internal user1PK = 0x1111;
//     uint256 internal user2PK = 0x2222;
//     uint256 internal user3PK = 0x3333;
//     uint256 internal user4PK = 0x4444;

//     // Market and question IDs
//     bytes32 public marketId;
//     bytes32 public questionId1; // Arsenal
//     bytes32 public questionId2; // Barcelona
//     bytes32 public questionId3; // Chelsea
//     bytes32 public questionId4; // Spurs
    
//     // Position IDs for YES/NO tokens
//     uint256 public yesPositionId1; // Arsenal YES
//     uint256 public noPositionId1;  // Arsenal NO
//     uint256 public yesPositionId2; // Barcelona YES
//     uint256 public noPositionId2;  // Barcelona NO
//     uint256 public yesPositionId3; // Chelsea YES
//     uint256 public noPositionId3;  // Chelsea NO
//     uint256 public yesPositionId4; // Spurs YES
//     uint256 public noPositionId4;  // Spurs NO
    
//     // Test constants
//     uint256 public constant INITIAL_USDC_BALANCE = 100000000e6; // 100,000,000 USDC (6 decimals)
//     uint256 public constant TOKEN_AMOUNT = 2e6; // 2 tokens (6 decimals to match USDC)

//     function setUp() public {
//         dummyPayout = [0, 1];
//         oracle = vm.createWallet("oracle").addr;

//         // Deploy real ConditionalTokens contract using Deployer
//         ctf = IConditionalTokens(Deployer.ConditionalTokens());
//         vm.label(address(ctf), "ConditionalTokens");

//         // Deploy mock USDC first
//         usdc = IERC20(address(new MockUSDC()));
//         vm.label(address(usdc), "USDC");
        
//         // Deploy mock vault
//         vault = address(new MockVault());
//         vm.label(vault, "Vault");

//         // Deploy NegRiskAdapter
//         negRiskAdapter = new NegRiskAdapter(address(ctf), address(usdc), vault);
//         negRiskOperator = new NegRiskOperator(address(negRiskAdapter));
//         negRiskOperator.setOracle(address(oracle));
//         vm.label(address(negRiskOperator), "NegRiskOperator");
//         vm.label(address(negRiskAdapter), "NegRiskAdapter");

//         // Deploy real CTFExchange
//         ctfExchange = new CTFExchange(address(usdc), address(negRiskAdapter), address(0), address(0));
//         vm.label(address(ctfExchange), "CTFExchange");
        
//         // Set up CTFExchange admin and operator roles
//         vm.startPrank(address(this));
//         ctfExchange.addAdmin(address(this));
//         ctfExchange.addOperator(address(this));
//         vm.stopPrank();

//         revNegRiskAdapter = new RevNegRiskAdapter(address(ctf), address(usdc), vault, INegRiskAdapter(address(negRiskAdapter)));
//         vm.label(address(revNegRiskAdapter), "RevNegRiskAdapter");
        
//         // Deploy CrossMatchingAdapter
//         adapter = new CrossMatchingAdapter(negRiskOperator, IERC20(address(usdc)), ICTFExchange(address(ctfExchange)), IRevNegRiskAdapter(address(revNegRiskAdapter)));
//         vm.label(address(adapter), "CrossMatchingAdapter");
        
//         // Add adapter as operator after deployment
//         vm.startPrank(address(this));
//         ctfExchange.addOperator(address(adapter));
//         vm.stopPrank();

//         vm.prank(address(adapter));
//         ctf.setApprovalForAll(address(revNegRiskAdapter), true);

//         vm.prank(address(revNegRiskAdapter));
//         ctf.setApprovalForAll(address(negRiskAdapter), true);

//         // Add RevNegRiskAdapter as owner of WrappedCollateral
//         // The NegRiskAdapter is the owner of WrappedCollateral, so we need to call from its address
//         vm.startPrank(address(negRiskAdapter));
//         negRiskAdapter.wcol().addOwner(address(revNegRiskAdapter));
//         vm.stopPrank();
        
//         // Setup vault with USDC and approve adapter
//         MockUSDC(address(usdc)).mint(address(vault), 1000000000e6); // 1 billion USDC
//         vm.startPrank(address(vault));
//         usdc.approve(address(adapter), type(uint256).max);
//         vm.stopPrank();

//         // Create test users
//         user1 = vm.addr(user1PK);
//         user2 = vm.addr(user2PK);
//         user3 = vm.addr(user3PK);
//         user4 = vm.addr(user4PK);
        
//         vm.label(user1, "User1");
//         vm.label(user2, "User2");
//         vm.label(user3, "User3");
//         vm.label(user4, "User4");

//         // Give users USDC
//         MockUSDC(address(usdc)).mint(user1, INITIAL_USDC_BALANCE);
//         MockUSDC(address(usdc)).mint(user2, INITIAL_USDC_BALANCE);
//         MockUSDC(address(usdc)).mint(user3, INITIAL_USDC_BALANCE);
//         MockUSDC(address(usdc)).mint(user4, INITIAL_USDC_BALANCE);

//         // Approve adapter to spend users' USDC
//         vm.prank(user1);
//         usdc.approve(address(adapter), type(uint256).max);
//         vm.prank(user2);
//         usdc.approve(address(adapter), type(uint256).max);
//         vm.prank(user3);
//         usdc.approve(address(adapter), type(uint256).max);
//         vm.prank(user4);
//         usdc.approve(address(adapter), type(uint256).max);

//         // Setup market and questions
//         _setupMarket();
//         _setupTokens();
//     }

//     function _mintTokensToUser(address user, uint256 tokenId, uint256 amount) internal {
//         dealERC1155(address(ctf), user, tokenId, amount);
//     }

//     function _setupMarket() internal {
//         // Create market
//         marketId = negRiskOperator.prepareMarket(0, "Premier League Winner");
        
//         // Create 4 questions
//         questionId1 = negRiskOperator.prepareQuestion(marketId, "Arsenal", bytes32(uint256(1)));
//         questionId2 = negRiskOperator.prepareQuestion(marketId, "Barcelona", bytes32(uint256(2)));
//         questionId3 = negRiskOperator.prepareQuestion(marketId, "Chelsea", bytes32(uint256(3)));
//         questionId4 = negRiskOperator.prepareQuestion(marketId, "Spurs", bytes32(uint256(4)));
//     }

//     function _setupTokens() internal {
//         // Get position IDs
//         yesPositionId1 = negRiskAdapter.getPositionId(questionId1, true);
//         noPositionId1 = negRiskAdapter.getPositionId(questionId1, false);
//         yesPositionId2 = negRiskAdapter.getPositionId(questionId2, true);
//         noPositionId2 = negRiskAdapter.getPositionId(questionId2, false);
//         yesPositionId3 = negRiskAdapter.getPositionId(questionId3, true);
//         noPositionId3 = negRiskAdapter.getPositionId(questionId3, false);
//         yesPositionId4 = negRiskAdapter.getPositionId(questionId4, true);
//         noPositionId4 = negRiskAdapter.getPositionId(questionId4, false);

//         // Register tokens with CTFExchange
//         _registerTokensWithCTFExchange();
//     }

//     function _registerTokensWithCTFExchange() internal {
//         // Register all token pairs with CTFExchange
//         vm.startPrank(address(this));
//         ctfExchange.registerToken(yesPositionId1, noPositionId1, negRiskAdapter.getConditionId(questionId1));
//         ctfExchange.registerToken(yesPositionId2, noPositionId2, negRiskAdapter.getConditionId(questionId2));
//         ctfExchange.registerToken(yesPositionId3, noPositionId3, negRiskAdapter.getConditionId(questionId3));
//         ctfExchange.registerToken(yesPositionId4, noPositionId4, negRiskAdapter.getConditionId(questionId4));
//         vm.stopPrank();
//     }

//     function test_crossMatchLongOrders_feeCollection() public {
//         uint256 fillAmount = 1e6; // 1 token
//         uint256 takerFeeBps = 100; // 1% fee
//         uint256 makerFeeBps = 50;  // 0.5% fee

//         // Create taker order (BUY Arsenal YES)
//         ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(
//             user1,
//             questionId1,
//             true, // YES
//             ICTFExchange.Side.BUY,
//             ICTFExchange.Intent.LONG,
//             250000, // 0.25 price
//             fillAmount,
//             takerFeeBps,
//             user1PK
//         );

//         // Create maker orders (BUY different questions in same market)
//         ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](3);
//         makerOrders[0] = _createOrderIntent(
//             user2,
//             questionId2, // Different question
//             true, // YES
//             ICTFExchange.Side.BUY,
//             ICTFExchange.Intent.LONG,
//             250000, // 0.25 price
//             fillAmount,
//             makerFeeBps,
//             user2PK
//         );
//         makerOrders[1] = _createOrderIntent(
//             user3,
//             questionId3, // Different question
//             true, // YES
//             ICTFExchange.Side.BUY,
//             ICTFExchange.Intent.LONG,
//             250000, // 0.25 price
//             fillAmount,
//             makerFeeBps,
//             user3PK
//         );
//         makerOrders[2] = _createOrderIntent(
//             user4,
//             questionId4, // Different question
//             true, // YES
//             ICTFExchange.Side.BUY,
//             ICTFExchange.Intent.LONG,
//             250000, // 0.25 price
//             fillAmount,
//             makerFeeBps,
//             user4PK
//         );

//         // Record initial balances
//         uint256 initialNegAdapterYES1 = ctf.balanceOf(address(negRiskAdapter), yesPositionId1);
//         uint256 initialNegAdapterYES2 = ctf.balanceOf(address(negRiskAdapter), yesPositionId2);
//         uint256 initialNegAdapterYES3 = ctf.balanceOf(address(negRiskAdapter), yesPositionId3);
//         uint256 initialNegAdapterYES4 = ctf.balanceOf(address(negRiskAdapter), yesPositionId4);

//         // Execute cross-matching
//         vm.prank(user1);
//         adapter.crossMatchLongOrders(marketId, takerOrder, makerOrders, fillAmount);

//         // Calculate expected fees
//         uint256 expectedTakerFee = _calculateExpectedFee(takerOrder, fillAmount);
//         uint256 expectedMaker1Fee = _calculateExpectedFee(makerOrders[0], fillAmount);
//         uint256 expectedMaker2Fee = _calculateExpectedFee(makerOrders[1], fillAmount);
//         uint256 expectedMaker3Fee = _calculateExpectedFee(makerOrders[2], fillAmount);

//         // Verify NegRiskAdapter received all fees in YES tokens
//         uint256 finalNegAdapterYES1 = ctf.balanceOf(address(negRiskAdapter), yesPositionId1);
//         uint256 finalNegAdapterYES2 = ctf.balanceOf(address(negRiskAdapter), yesPositionId2);
//         uint256 finalNegAdapterYES3 = ctf.balanceOf(address(negRiskAdapter), yesPositionId3);
//         uint256 finalNegAdapterYES4 = ctf.balanceOf(address(negRiskAdapter), yesPositionId4);
        
//         assertEq(finalNegAdapterYES1 - initialNegAdapterYES1, expectedTakerFee, "NegRiskAdapter should receive taker fee in YES tokens");
//         assertEq(finalNegAdapterYES2 - initialNegAdapterYES2, expectedMaker1Fee, "NegRiskAdapter should receive maker1 fee in YES tokens");
//         assertEq(finalNegAdapterYES3 - initialNegAdapterYES3, expectedMaker2Fee, "NegRiskAdapter should receive maker2 fee in YES tokens");
//         assertEq(finalNegAdapterYES4 - initialNegAdapterYES4, expectedMaker3Fee, "NegRiskAdapter should receive maker3 fee in YES tokens");

//         // Verify users received their tokens (after fees)
//         assertEq(ctf.balanceOf(user1, yesPositionId1), 990000, "User1 should receive Arsenal YES tokens after fees");
//         assertEq(ctf.balanceOf(user2, yesPositionId2), 995000, "User2 should receive Barcelona YES tokens after fees");
//         assertEq(ctf.balanceOf(user3, yesPositionId3), 995000, "User3 should receive Chelsea YES tokens after fees");
//         assertEq(ctf.balanceOf(user4, yesPositionId4), 995000, "User4 should receive Spurs YES tokens after fees");
//     }

//     function test_crossMatchLongOrders_mixedBuySellOrders() public {
//         uint256 fillAmount = 1e6; // 1 token
//         uint256 feeBps = 100; // 1% fee

//         // Create taker order (BUY Arsenal YES)
//         ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(
//             user1,
//             questionId1,
//             true, // YES
//             ICTFExchange.Side.BUY,
//             ICTFExchange.Intent.LONG,
//             350000, // 0.35 price
//             fillAmount,
//             feeBps,
//             user1PK
//         );

//         // mint NO tokens to user2 for question2
//         _mintTokensToUser(user2, noPositionId2, fillAmount);
//         vm.prank(user2);
//         ctf.setApprovalForAll(address(adapter), true);

//         // Create mixed maker orders (2 BUY, 1 SELL)
//         ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](3);
//         makerOrders[0] = _createOrderIntent(
//             user2,
//             questionId2,
//             false, // NO
//             ICTFExchange.Side.SELL,
//             ICTFExchange.Intent.LONG,
//             300000, // 0.30 price
//             fillAmount,
//             feeBps,
//             user2PK
//         );

//         // mint NO tokens to user3 for question3
//         _mintTokensToUser(user3, noPositionId3, fillAmount);
//         vm.prank(user3);
//         ctf.setApprovalForAll(address(adapter), true);

//         makerOrders[1] = _createOrderIntent(
//             user3,
//             questionId3,
//             false, // NO
//             ICTFExchange.Side.SELL,
//             ICTFExchange.Intent.LONG,
//             200000, // 0.20 price
//             fillAmount,
//             feeBps,
//             user3PK
//         );

//         makerOrders[2] = _createOrderIntent(
//             user4,
//             questionId4,
//             true, // YES
//             ICTFExchange.Side.BUY,
//             ICTFExchange.Intent.LONG,
//             150000, // 0.15 price
//             fillAmount,
//             feeBps,
//             user4PK
//         );

//         // Give adapter some USDC to handle sell orders
//         // MockUSDC(address(usdc)).mint(address(adapter), 1000000e6); // 1 million USDC
//         MockUSDC(address(usdc)).mint(address(negRiskAdapter.wcol()), 1e6); // 1 million USDC

//         // Record initial balances
//         uint256 initialNegAdapterYES1 = ctf.balanceOf(address(negRiskAdapter), yesPositionId1);
//         uint256 initialNegAdapterYES4 = ctf.balanceOf(address(negRiskAdapter), yesPositionId4);
//         uint256 initialVaultUSDC = usdc.balanceOf(vault);

//         // Execute cross-matching
//         vm.prank(user1);
//         adapter.crossMatchLongOrders(marketId, takerOrder, makerOrders, fillAmount);

//         // Calculate expected fees
//         uint256 expectedTakerFee = _calculateExpectedFee(takerOrder, fillAmount);
//         uint256 expectedMaker1Fee = _calculateExpectedFee(makerOrders[0], fillAmount);
//         uint256 expectedMaker2Fee = _calculateExpectedFee(makerOrders[1], fillAmount);
//         uint256 expectedMaker3Fee = _calculateExpectedFee(makerOrders[2], fillAmount);

//         // Verify NegRiskAdapter received BUY order fees in YES tokens
//         uint256 finalNegAdapterYES1 = ctf.balanceOf(address(negRiskAdapter), yesPositionId1);
//         uint256 finalNegAdapterYES4 = ctf.balanceOf(address(negRiskAdapter), yesPositionId4);
//         assertEq(finalNegAdapterYES1 - initialNegAdapterYES1, expectedTakerFee, "NegRiskAdapter should receive taker fee in YES tokens");
//         assertEq(finalNegAdapterYES4 - initialNegAdapterYES4, expectedMaker3Fee, "NegRiskAdapter should receive maker3 fee in YES tokens");

//         // Verify vault received SELL order fees in USDC
//         uint256 finalVaultUSDC = usdc.balanceOf(vault);
//         uint256 totalSellFees = expectedMaker1Fee + expectedMaker2Fee;
//         assertEq(finalVaultUSDC - initialVaultUSDC, totalSellFees, "Vault should receive SELL order fees in USDC");
//     }

//     function test_crossMatchLongOrders_differentFeeRates() public {
//         uint256 fillAmount = 1e6; // 1 token
        
//         // Test with different fee rates
//         uint256[] memory feeRates = new uint256[](4);
//         feeRates[0] = 0;    // No fees
//         feeRates[1] = 50;   // 0.5%
//         feeRates[2] = 100;  // 1%
//         feeRates[3] = 500;  // 5%

//         for (uint256 i = 0; i < feeRates.length; i++) {
//             uint256 feeBps = feeRates[i];
            
//             // Reset user balances
//             MockUSDC(address(usdc)).mint(user1, INITIAL_USDC_BALANCE);
//             MockUSDC(address(usdc)).mint(user2, INITIAL_USDC_BALANCE);
//             MockUSDC(address(usdc)).mint(user3, INITIAL_USDC_BALANCE);
//             MockUSDC(address(usdc)).mint(user4, INITIAL_USDC_BALANCE);

//             // Create orders with current fee rate
//             ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(
//                 user1,
//                 questionId1,
//                 true, // YES
//                 ICTFExchange.Side.BUY,
//                 ICTFExchange.Intent.LONG,
//                 350000, // 0.35 price
//                 fillAmount,
//                 feeBps,
//                 user1PK
//             );

//             ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](3);
//             makerOrders[0] = _createOrderIntent(
//                 user2,
//                 questionId2,
//                 true, // YES
//                 ICTFExchange.Side.BUY,
//                 ICTFExchange.Intent.LONG,
//                 300000, // 0.30 price
//                 fillAmount,
//                 feeBps,
//                 user2PK
//             );
//             makerOrders[1] = _createOrderIntent(
//                 user3,
//                 questionId3,
//                 true, // YES
//                 ICTFExchange.Side.BUY,
//                 ICTFExchange.Intent.LONG,
//                 200000, // 0.20 price
//                 fillAmount,
//                 feeBps,
//                 user3PK
//             );
//             makerOrders[2] = _createOrderIntent(
//                 user4,
//                 questionId4,
//                 true, // YES
//                 ICTFExchange.Side.BUY,
//                 ICTFExchange.Intent.LONG,
//                 150000, // 0.15 price
//                 fillAmount,
//                 feeBps,
//                 user4PK
//             );

//             // Record initial balances for YES tokens
//             uint256 initialNegAdapterYES1 = ctf.balanceOf(address(negRiskAdapter), yesPositionId1);
//             uint256 initialNegAdapterYES2 = ctf.balanceOf(address(negRiskAdapter), yesPositionId2);
//             uint256 initialNegAdapterYES3 = ctf.balanceOf(address(negRiskAdapter), yesPositionId3);
//             uint256 initialNegAdapterYES4 = ctf.balanceOf(address(negRiskAdapter), yesPositionId4);

//             // Execute cross-matching
//             vm.prank(user1);
//             adapter.crossMatchLongOrders(marketId, takerOrder, makerOrders, fillAmount);

//             // Calculate expected fees
//             uint256 expectedTakerFee = _calculateExpectedFee(takerOrder, fillAmount);
//             uint256 expectedMaker1Fee = _calculateExpectedFee(makerOrders[0], fillAmount);
//             uint256 expectedMaker2Fee = _calculateExpectedFee(makerOrders[1], fillAmount);
//             uint256 expectedMaker3Fee = _calculateExpectedFee(makerOrders[2], fillAmount);

//             // Verify NegRiskAdapter received correct fees in YES tokens
//             assertEq(ctf.balanceOf(address(negRiskAdapter), yesPositionId1) - initialNegAdapterYES1, expectedTakerFee, "NegRiskAdapter should receive taker fee");
//             assertEq(ctf.balanceOf(address(negRiskAdapter), yesPositionId2) - initialNegAdapterYES2, expectedMaker1Fee, "NegRiskAdapter should receive maker1 fee");
//             assertEq(ctf.balanceOf(address(negRiskAdapter), yesPositionId3) - initialNegAdapterYES3, expectedMaker2Fee, "NegRiskAdapter should receive maker2 fee");
//             assertEq(ctf.balanceOf(address(negRiskAdapter), yesPositionId4) - initialNegAdapterYES4, expectedMaker3Fee, "NegRiskAdapter should receive maker3 fee");
//         }
//     }

//     function test_crossMatchLongOrders_feeCalculationAccuracy() public {
//         uint256 fillAmount = 1e6; // 1 token
//         uint256 feeBps = 250; // 2.5% fee

//         // Create order with specific price to test fee calculation
//         ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(
//             user1,
//             questionId1,
//             true, // YES
//             ICTFExchange.Side.BUY,
//             ICTFExchange.Intent.LONG,
//             500000, // 0.50 price
//             fillAmount,
//             feeBps,
//             user1PK
//         );

//         ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](1);
//         makerOrders[0] = _createOrderIntent(
//             user2,
//             questionId2,
//             true, // YES
//             ICTFExchange.Side.BUY,
//             ICTFExchange.Intent.LONG,
//             500000, // 0.50 price
//             fillAmount,
//             feeBps,
//             user2PK
//         );

//         vm.startPrank(oracle);
//         negRiskOperator.reportPayouts(bytes32(uint256(3)), dummyPayout);
//         negRiskOperator.reportPayouts(bytes32(uint256(4)), dummyPayout);
//         vm.stopPrank();

//         vm.warp(block.timestamp + 2 * negRiskOperator.DELAY_PERIOD());
//         negRiskOperator.resolveQuestion(questionId3);
//         negRiskOperator.resolveQuestion(questionId4);

//         // Record initial balances
//         uint256 initialNegAdapterYES1 = ctf.balanceOf(address(negRiskAdapter), yesPositionId1);
//         uint256 initialNegAdapterYES2 = ctf.balanceOf(address(negRiskAdapter), yesPositionId2);

//         // Calculate expected fees manually
//         uint256 expectedTakerFee = _calculateExpectedFee(takerOrder, fillAmount);
//         uint256 expectedMakerFee = _calculateExpectedFee(makerOrders[0], fillAmount);

//         // Execute cross-matching
//         vm.prank(user1);
//         adapter.crossMatchLongOrders(marketId, takerOrder, makerOrders, fillAmount);

//         // Verify NegRiskAdapter received fees in YES tokens
//         uint256 finalNegAdapterYES1 = ctf.balanceOf(address(negRiskAdapter), yesPositionId1);
//         uint256 finalNegAdapterYES2 = ctf.balanceOf(address(negRiskAdapter), yesPositionId2);
        
//         assertEq(finalNegAdapterYES1 - initialNegAdapterYES1, expectedTakerFee, "NegRiskAdapter should receive taker fee");
//         assertEq(finalNegAdapterYES2 - initialNegAdapterYES2, expectedMakerFee, "NegRiskAdapter should receive maker fee");

//         // Verify fee calculation formula using NegRiskAdapter logic
//         // fee = (fillAmount * feeBps) / 10000
//         uint256 expectedFee = (fillAmount * feeBps) / 10000;
        
//         assertEq(expectedTakerFee, expectedFee, "Fee calculation should match NegRiskAdapter formula");
//     }

//     function _createOrderIntent(
//         address maker,
//         bytes32 questionId,
//         bool isYes,
//         ICTFExchange.Side side,
//         ICTFExchange.Intent intent,
//         uint256 price,
//         uint256 quantity,
//         uint256 feeRateBps,
//         uint256 privateKey
//     ) internal returns (ICTFExchange.OrderIntent memory) {
//         uint256 tokenId = negRiskAdapter.getPositionId(questionId, isYes);
        
//         ICTFExchange.Order memory order = ICTFExchange.Order({
//             salt: 1,
//             maker: maker,
//             signer: maker,
//             taker: address(0),
//             price: price,
//             quantity: quantity,
//             expiration: 0,
//             nonce: 0,
//             questionId: questionId,
//             intent: intent,
//             feeRateBps: feeRateBps,
//             signatureType: ICTFExchange.SignatureType.EOA,
//             signature: new bytes(0)
//         });

//         // Create a proper Order struct for hashing
//         Order memory hashOrder = Order({
//             salt: order.salt,
//             maker: order.maker,
//             signer: order.signer,
//             taker: order.taker,
//             price: order.price,
//             quantity: order.quantity,
//             expiration: order.expiration,
//             nonce: order.nonce,
//             questionId: order.questionId,
//             intent: Intent(uint8(order.intent)),
//             feeRateBps: order.feeRateBps,
//             signatureType: SignatureType(uint8(order.signatureType)),
//             signature: order.signature
//         });

//         // Sign the order
//         order.signature = _signMessage(privateKey, ctfExchange.hashOrder(hashOrder));

//         return ICTFExchange.OrderIntent({
//             order: order,
//             side: side,
//             tokenId: tokenId,
//             makerAmount: quantity,
//             takerAmount: quantity
//         });
//     }

//     function _signMessage(uint256 privateKey, bytes32 message) internal pure returns (bytes memory) {
//         (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, message);
//         return abi.encodePacked(r, s, v);
//     }

//     function _calculateExpectedFee(
//         ICTFExchange.OrderIntent memory orderIntent,
//         uint256 fillAmount
//     ) internal pure returns (uint256) {
//         // Use NegRiskAdapter fee logic: feeAmount = (amount * feeBips) / FEE_DENOMINATOR
//         return (fillAmount * orderIntent.order.feeRateBps) / 10000;
//     }

// }

// // Mock contracts for testing
// contract MockUSDC {
//     mapping(address => uint256) public balanceOf;
//     mapping(address => mapping(address => uint256)) public allowance;
    
//     string public name = "USD Coin";
//     string public symbol = "USDC";
//     uint8 public decimals = 6;
    
//     function mint(address to, uint256 amount) external {
//         balanceOf[to] += amount;
//     }
    
//     function transfer(address to, uint256 amount) external returns (bool) {
//         balanceOf[msg.sender] -= amount;
//         balanceOf[to] += amount;
//         return true;
//     }
    
//     function transferFrom(address from, address to, uint256 amount) external returns (bool) {
//         allowance[from][msg.sender] -= amount;
//         balanceOf[from] -= amount;
//         balanceOf[to] += amount;
//         return true;
//     }
    
//     function approve(address spender, uint256 amount) external returns (bool) {
//         allowance[msg.sender][spender] = amount;
//         return true;
//     }
// }

// contract MockVault {
//     // Simple mock vault for testing
// }
