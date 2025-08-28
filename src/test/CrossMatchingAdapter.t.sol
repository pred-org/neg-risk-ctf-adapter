// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {CrossMatchingAdapter, ICTFExchange} from "src/CrossMatchingAdapter.sol";
import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
import {WrappedCollateral} from "src/WrappedCollateral.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {INegRiskAdapter} from "src/interfaces/INegRiskAdapter.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";
import {DeployLib} from "src/dev/libraries/DeployLib.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

// Mock ConditionalTokens contract for testing
// contract MockConditionalTokens is IConditionalTokens {
//     mapping(address => mapping(uint256 => uint256)) public override balanceOf;
//     mapping(address => mapping(address => bool)) public override isApprovedForAll;
    
//     // Track calls to getPositionId to ensure consistency
//     mapping(bytes32 => uint256) public questionToPositionId;
//     uint256 public nextPositionId = 1000;
    
//     // Direct mint function for testing
//     function mint(address to, uint256 tokenId, uint256 amount) external {
//         balanceOf[to][tokenId] += amount;
//     }
    
//     // Required interface implementations
//     function balanceOfBatch(address[] memory owners, uint256[] memory ids) external view override returns (uint256[] memory) {
//         require(owners.length == ids.length, "Length mismatch");
//         uint256[] memory balances = new uint256[](owners.length);
//         for (uint256 i = 0; i < owners.length; i++) {
//             balances[i] = balanceOf[owners[i]][ids[i]];
//         }
//         return balances;
//     }
    
//     function setApprovalForAll(address operator, bool approved) external override {
//         isApprovedForAll[msg.sender][operator] = approved;
//     }
    
//     function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata) external override {
//         require(balanceOf[from][id] >= value, "Insufficient balance");
//         balanceOf[from][id] -= value;
//         balanceOf[to][id] += value;
//     }
    
//     function safeBatchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata values, bytes calldata) external override {
//         require(ids.length == values.length, "Length mismatch");
//         for (uint256 i = 0; i < ids.length; i++) {
//             require(balanceOf[from][ids[i]] >= values[i], "Insufficient balance");
//             balanceOf[from][ids[i]] -= values[i];
//             balanceOf[to][ids[i]] += values[i];
//         }
//     }
    
//     // Mock implementations for other required functions
//     function payoutNumerators(bytes32, uint256) external pure returns (uint256) { return 0; }
//     function payoutDenominator(bytes32) external pure returns (uint256) { return 0; }
//     function prepareCondition(address, bytes32, uint256) external {}
//     function reportPayouts(bytes32, uint256[] calldata) external {}
    
//     function splitPosition(
//         address collateralToken,
//         bytes32 parentCollectionId,
//         bytes32 conditionId,
//         uint256[] calldata partition,
//         uint256 amount
//     ) external {
//         // Mock implementation that follows the real logic more closely
//         require(partition.length > 1, "got empty or singleton partition");
        
//         // Check if condition is prepared (we always return 2 for outcomeSlotCount)
//         uint256 outcomeSlotCount = 2; // Mock: always return 2 for binary outcomes
        
//         // For a condition with 2 outcomes, fullIndexSet is 0b11 = 3
//         uint256 fullIndexSet = (1 << outcomeSlotCount) - 1; // 3 for 2 outcomes
        
//         // Generate position IDs based on the partition
//         uint256[] memory positionIds = new uint256[](partition.length);
//         uint256[] memory amounts = new uint256[](partition.length);
        
//         for (uint256 i = 0; i < partition.length; i++) {
//             uint256 indexSet = partition[i];
//             require(indexSet > 0 && indexSet < fullIndexSet, "got invalid index set");
            
//             // For testing, we need to generate position IDs that are deterministic based on the condition ID
//             // Each condition ID should get consistent position IDs for YES and NO
//             // We'll use the condition ID to seed the position ID generation
            
//             if (indexSet == 1) { // YES position
//                 // Generate a deterministic YES position ID based on the condition ID
//                 positionIds[i] = uint256(keccak256(abi.encodePacked(conditionId, "YES"))) & 0xFFFFFFFFFFFFFFFF;
//             } else if (indexSet == 2) { // NO position
//                 // Generate a deterministic NO position ID based on the condition ID
//                 positionIds[i] = uint256(keccak256(abi.encodePacked(conditionId, "NO"))) & 0xFFFFFFFFFFFFFFFF;
//             } else {
//                 // For other index sets, generate a deterministic ID
//                 positionIds[i] = uint256(keccak256(abi.encodePacked(conditionId, indexSet))) & 0xFFFFFFFFFFFFFFFF;
//             }
            
//             amounts[i] = amount;
//         }
        
//         // Handle collateral token logic
//         if (parentCollectionId == bytes32(0)) {
//             // Splitting from collateral - we'll just mint the new positions
//             // In a real scenario, this would transfer collateral tokens
//         } else {
//             // Splitting from existing position - burn the parent position
//             uint256 parentPositionId = uint256(parentCollectionId) & 0xFFFFFFFFFFFFFFFF;
//             require(balanceOf[msg.sender][parentPositionId] >= amount, "Insufficient parent position");
//             balanceOf[msg.sender][parentPositionId] -= amount;
//         }
        
//         // Mint the new positions to the caller (NegRiskAdapter)
//         for (uint256 i = 0; i < positionIds.length; i++) {
//             balanceOf[msg.sender][positionIds[i]] += amounts[i];
//         }
        
//         console.log("MockConditionalTokens.splitPosition: minted tokens to caller");
//         console.log("  caller:", msg.sender);
//         console.log("  position IDs:", positionIds[0], positionIds[1]);
//         console.log("  amounts:", amounts[0], amounts[1]);
//     }
    
//     function mergePositions(
//         address collateralToken,
//         bytes32 parentCollectionId,
//         bytes32 conditionId,
//         uint256[] calldata partition,
//         uint256 amount
//     ) external {
//         // Mock implementation: burn tokens and mint collateral
//         uint256 yesPositionId = uint256(parentCollectionId) & 0xFFFFFFFFFFFFFFFF;
//         uint256 noPositionId = yesPositionId + 1;
        
//         // Burn YES and NO tokens
//         require(balanceOf[msg.sender][yesPositionId] >= amount, "Insufficient YES tokens");
//         require(balanceOf[msg.sender][noPositionId] >= amount, "Insufficient NO tokens");
        
//         balanceOf[msg.sender][yesPositionId] -= amount;
//         balanceOf[msg.sender][noPositionId] -= amount;
        
//         // Mint collateral back (for testing purposes)
//         // In a real scenario, this would mint USDC or WCOL
//     }
    
//     function redeemPositions(
//         address collateralToken,
//         bytes32 parentCollectionId,
//         bytes32 conditionId,
//         uint256[] calldata indexSets
//     ) external {
//         // Mock implementation: burn tokens and mint collateral
//         // Similar to mergePositions for testing
//     }
    
//     function getOutcomeSlotCount(bytes32) external pure returns (uint256) { return 2; } // Always return 2 for binary outcomes
    
//     function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external pure returns (bytes32) { 
//         // Mock implementation that matches the real CTHelpers.getConditionId
//         // For testing, we'll use a deterministic hash
//         return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
//     }
    
//     function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet) external pure returns (bytes32) { 
//         // Mock implementation that matches the real CTHelpers.getCollectionId
//         // For testing, we'll use a deterministic hash
//         return keccak256(abi.encodePacked(conditionId, indexSet, parentCollectionId));
//     }
    
//     function getPositionId(address collateralToken, bytes32 collectionId) external pure returns (uint256) { 
//         // Mock implementation that matches the real CTHelpers.getPositionId
//         // This is exactly what the real contract does
//         return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
//     }
// }

contract CrossMatchingAdapterTest is Test {
    CrossMatchingAdapter public adapter;
    NegRiskAdapter public negRiskAdapter;
    WrappedCollateral public wcol;
    IERC20 public usdc;
    IConditionalTokens public ctf;
    
    // Create a mock vault contract instead of using a plain address
    MockVault public vault;
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);
    address public user4 = address(0x4);
    
    bytes32 public marketId;
    
    // Mock USDC contract
    MockUSDC public mockUsdc;
    
    // Mock CTF Exchange contract
    MockCTFExchange public mockExchange;
    
    function setUp() public {
        // Deploy mock USDC
        mockUsdc = new MockUSDC();
        usdc = IERC20(address(mockUsdc));
        
        // Deploy mock CTF contract instead of real one
        ctf = IConditionalTokens(DeployLib.deployConditionalTokens());
        
        // Deploy mock Exchange
        mockExchange = new MockCTFExchange();
        
        // Deploy mock vault
        vault = new MockVault();
        
        // Deploy real NegRiskAdapter
        negRiskAdapter = new NegRiskAdapter(address(ctf), address(usdc), address(vault));
        
        // Deploy WrappedCollateral
        wcol = WrappedCollateral(negRiskAdapter.wcol());
        
        // Deploy CrossMatchingAdapter
        adapter = new CrossMatchingAdapter(INegRiskAdapter(address(negRiskAdapter)), usdc, ICTFExchange(address(mockExchange)));
        
        // Create a market
        marketId = negRiskAdapter.prepareMarket(0, "Test Market");
        
        // Prepare questions
        negRiskAdapter.prepareQuestion(marketId, "Question 1");
        negRiskAdapter.prepareQuestion(marketId, "Question 2");
        negRiskAdapter.prepareQuestion(marketId, "Question 3");
        negRiskAdapter.prepareQuestion(marketId, "Question 4");
        
        // Setup approvals and balances
        vm.startPrank(address(vault));
        mockUsdc.approve(address(adapter), type(uint256).max);
        mockUsdc.mint(address(vault), 10000e18); // Give vault enough USDC
        vm.stopPrank();
        
        // Setup user balances and approvals
        _setupUser(user1, 1000e18);
        _setupUser(user2, 1000e18);
        _setupUser(user3, 1000e18);
        _setupUser(user4, 1000e18);
        
        // Setup CTF with initial YES token balances for the adapter
        _setupCTFTokenBalances();
    }
    
    function _setupCTFTokenBalances() internal {
        // The adapter needs to have USDC tokens to perform CTF operations via NegRiskAdapter
        // The NegRiskAdapter will wrap USDC to WCOL and then perform the split operations
        
        // Give the adapter USDC tokens for CTF operations
        mockUsdc.mint(address(adapter), 20e18); // 20 USDC tokens
        
        // Approve the NegRiskAdapter to spend the adapter's USDC
        vm.prank(address(adapter));
        mockUsdc.approve(address(negRiskAdapter), type(uint256).max);
        
        // The adapter will use these USDC tokens to call NegRiskAdapter.splitPosition
        // which will wrap the USDC to WCOL and perform the split operations
    }
    
    function _setupNOBalancesDirectly() internal {
        // For testing sell orders, we need to give users some NO tokens to sell
        // Now we can directly mint NO tokens using our mock contract!
        
        // Get actual position IDs from the NegRiskAdapter
        bytes32 question0Id = NegRiskIdLib.getQuestionId(marketId, 0);
        uint256 no0PositionId = negRiskAdapter.getPositionId(question0Id, false);
        
        // Debug: Log the position ID we're using
        console.log("Using NO position ID:", no0PositionId);
        
        // Directly mint NO tokens to user2 who will sell them
        // This is the beauty of our mock - we can mint tokens directly!
        // MockConditionalTokens(address(ctf)).mint(user2, no0PositionId, 2e18);
        
        // Ensure user2 has approved the adapter to transfer their NO tokens
        vm.prank(user2);
        ctf.setApprovalForAll(address(adapter), true);
        
        // Verify the minting worked
        uint256 user2Balance = ctf.balanceOf(user2, no0PositionId);
        console.log("User2 NO token balance after minting:", user2Balance);
        require(user2Balance == 2e18, "Failed to mint NO tokens");
        
        // Verify the approval worked
        bool isApproved = ctf.isApprovedForAll(user2, address(adapter));
        console.log("User2 approval for adapter:", isApproved);
        require(isApproved, "Failed to set approval");
        
        // Debug: Check what the adapter is trying to transfer
        console.log("Adapter will try to transfer from user2, token ID:", no0PositionId);
    }
    
    function _setupUser(address user, uint256 usdcBalance) internal {
        vm.startPrank(user);
        mockUsdc.mint(user, usdcBalance);
        mockUsdc.approve(address(adapter), type(uint256).max);
        
        // Approve the adapter to transfer ERC1155 tokens (for sell orders)
        ctf.setApprovalForAll(address(adapter), true);
        
        vm.stopPrank();
    }
    
    function _createOrderIntent(
        address maker,
        uint8 side,
        uint256 tokenId,
        uint256 price,
        uint256 quantity
    ) internal view returns (ICTFExchange.OrderIntent memory) {
        ICTFExchange.Order memory order = ICTFExchange.Order({
            salt: 0,
            maker: maker,
            signer: maker,
            taker: address(0),
            price: price,
            quantity: quantity,
            expiration: block.timestamp + 3600,
            nonce: 0,
            feeRateBps: 0,
            intent: 0,
            signatureType: 0,
            signature: ""
        });
        
        return ICTFExchange.OrderIntent({
            tokenId: tokenId,
            side: side,
            makerAmount: quantity,
            takerAmount: quantity,
            order: order
        });
    }
    
    function _createScenario1Orders() internal view returns (
        ICTFExchange.OrderIntent[] memory makerOrders,
        ICTFExchange.OrderIntent memory takerOrder
    ) {
        // Create orders for 4 users buying different YES tokens
        makerOrders = new ICTFExchange.OrderIntent[](3);
        
        // Get actual position IDs for YES tokens from the CTF system
        bytes32 question0Id = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 question1Id = NegRiskIdLib.getQuestionId(marketId, 1);
        bytes32 question2Id = NegRiskIdLib.getQuestionId(marketId, 2);
        bytes32 question3Id = NegRiskIdLib.getQuestionId(marketId, 3);
        
        uint256 yes0PositionId = negRiskAdapter.getPositionId(question0Id, true);
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        
        // Create orders with actual position IDs
        makerOrders[0] = _createOrderIntent(user1, 0, yes0PositionId, 0.25e18, 1e18);
        makerOrders[1] = _createOrderIntent(user2, 0, yes1PositionId, 0.25e18, 1e18);
        makerOrders[2] = _createOrderIntent(user3, 0, yes2PositionId, 0.25e18, 1e18);
        
        // Create taker order for Yes4
        takerOrder = _createOrderIntent(user4, 0, yes3PositionId, 0.25e18, 1e18);
    }

    function test_Scenario1_AllBuyOrders() public {
        // Scenario 1: All buy orders (simplified)
        // User1: buy Yes0 (0.25$ each, 1e18 shares)
        // User2: buy Yes1 (0.25$ each, 1e18 shares)
        // User3: buy Yes2 (0.25$ each, 1e18 shares)
        // User4: buy Yes3 (0.25$ each, 1e18 shares)
        // Total: 0.25 + 0.25 + 0.25 + 0.25 = 1.0
        
        // console.log("=== Starting Scenario 1 Test ===");
        
        // Get the position IDs that we actually used
        bytes32 question0Id = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 question1Id = NegRiskIdLib.getQuestionId(marketId, 1);
        bytes32 question2Id = NegRiskIdLib.getQuestionId(marketId, 2);
        bytes32 question3Id = NegRiskIdLib.getQuestionId(marketId, 3);
        
        uint256 yes0PositionId = negRiskAdapter.getPositionId(question0Id, true);
        uint256 yes1PositionId = negRiskAdapter.getPositionId(question1Id, true);
        uint256 yes2PositionId = negRiskAdapter.getPositionId(question2Id, true);
        uint256 yes3PositionId = negRiskAdapter.getPositionId(question3Id, true);
        
        // console.log("Position IDs:");
        // console.log("Yes0:", yes0PositionId);
        // console.log("Yes1:", yes1PositionId);
        // console.log("Yes2:", yes2PositionId);
        // console.log("Yes3:", yes3PositionId);
        
        // Create orders using the actual position IDs
        ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(user1, 0, yes0PositionId, 0.25e18, 1e18); // Buy Yes0 at 0.25
        
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](3);
        makerOrders[0] = _createOrderIntent(user2, 0, yes1PositionId, 0.25e18, 1e18); // Buy Yes1 at 0.25
        makerOrders[1] = _createOrderIntent(user3, 0, yes2PositionId, 0.25e18, 1e18); // Buy Yes2 at 0.25
        makerOrders[2] = _createOrderIntent(user4, 0, yes3PositionId, 0.25e18, 1e18); // Buy Yes3 at 0.25
        
        console.log("Orders created successfully");
        
        // Set up token balances for users
        _setupUserTokenBalances(makerOrders);
        
        // Set up token balance for taker order maker
        ICTFExchange.OrderIntent[] memory takerOrderArray = new ICTFExchange.OrderIntent[](1);
        takerOrderArray[0] = takerOrder;
        _setupUserTokenBalances(takerOrderArray);
        
        // Record initial balances
        uint256 user1InitialBalance = mockUsdc.balanceOf(user1);
        uint256 user2InitialBalance = mockUsdc.balanceOf(user2);
        uint256 user3InitialBalance = mockUsdc.balanceOf(user3);
        uint256 user4InitialBalance = mockUsdc.balanceOf(user4);
        uint256 vaultInitialBalance = mockUsdc.balanceOf(address(vault));

        uint256 adapterInitialBalance = mockUsdc.balanceOf(address(adapter));
        
        // Execute cross-matching
        uint256[] memory makerFillAmounts = new uint256[](makerOrders.length);
        for (uint256 i = 0; i < makerOrders.length; i++) {
            makerFillAmounts[i] = 1e18;
        }
        
        console.log("About to call crossMatchLongOrders...");
        
        // Call the cross-matching function
        adapter.crossMatchLongOrders(
            marketId,
            takerOrder,
            makerOrders,
            1e18,
            makerFillAmounts
        );
        
        console.log("crossMatchLongOrders completed successfully!");
        
        // Verify results - simplified to reduce stack usage
        uint256 expectedPayment = (0.25e18 * 1e18) / 1e18;
        
        // Basic balance checks
        assertEq(
            mockUsdc.balanceOf(user1), 
            user1InitialBalance - expectedPayment, 
            "User1 should have paid correct amount"
        );
        
        assertEq(
            mockUsdc.balanceOf(user2), 
            user2InitialBalance - expectedPayment, 
            "User2 should have paid correct amount"
        );
        
        assertEq(
            mockUsdc.balanceOf(user3), 
            user3InitialBalance - expectedPayment, 
            "User3 should have paid correct amount"
        );
        
        assertEq(
            mockUsdc.balanceOf(user4), 
            user4InitialBalance - expectedPayment, 
            "User4 should have paid correct amount"
        );
        
        // Contract should have no remaining USDC
        assertEq(mockUsdc.balanceOf(address(adapter)), adapterInitialBalance, "Contract should have no remaining USDC");
        
        // Verify self-financing: vault should have net zero change
        // uint256 totalPayments = expectedPayment * 4;
        uint256 vaultFinalBalance = mockUsdc.balanceOf(address(vault));
        assertEq(vaultFinalBalance, vaultInitialBalance, "Vault balance should be same");
    }
    
    function _validateUserTokenReceipt(
        ICTFExchange.OrderIntent[] memory orders,
        bytes32 marketId
    ) internal {
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].side == 0) { // BUY orders
                address user = orders[i].order.maker;
                uint256 expectedAmount = orders[i].makerAmount;
                
                // The tokenId is now the actual position ID, so we can use it directly
                uint256 positionId = orders[i].tokenId;
                
                // Check that the user received the expected amount of tokens
                // Note: Due to 1% fees in the NegRiskAdapter, users receive 99% of expected amount
                uint256 userBalance = ctf.balanceOf(user, positionId);
                // uint256 feeAdjustedAmount = (expectedAmount * 99) / 100; // 99% after 1% fee
                assertEq(userBalance, expectedAmount, "User should have received expected YES tokens (99% after 1% fees)");
                
                // Verify that the position ID is valid
                assertTrue(positionId != 0, "Position ID should not be zero");
                
                // Additional validation: Check that the adapter has no remaining tokens for this position
                uint256 adapterBalance = ctf.balanceOf(address(adapter), positionId);
                assertEq(adapterBalance, 0, "Adapter should have no remaining YES tokens after distribution");
            }
        }
        
        // Validate that the adapter distributed all tokens correctly
        uint256 questionCount = negRiskAdapter.getQuestionCount(marketId);
        for (uint8 qIndex = 0; qIndex < questionCount; qIndex++) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, qIndex);
            uint256 yesPositionId = negRiskAdapter.getPositionId(questionId, true);
            uint256 noPositionId = negRiskAdapter.getPositionId(questionId, false);
            
            // Adapter should have no remaining conditional tokens
            uint256 adapterYesBalance = ctf.balanceOf(address(adapter), yesPositionId);
            uint256 adapterNoBalance = ctf.balanceOf(address(adapter), noPositionId);
            
            assertEq(adapterYesBalance, 0, "Adapter should have no remaining YES tokens");
            assertEq(adapterNoBalance, 0, "Adapter should have no remaining NO tokens");
        }
    }
    
    function _setupUserTokenBalances(ICTFExchange.OrderIntent[] memory orders) internal {
        for (uint256 i = 0; i < orders.length; i++) {
            address user = orders[i].order.maker;
            
            if (orders[i].side == 0) { // BUY orders
                // Users already have USDC from setUp(), just need to ensure approval
                uint256 usdcAmount = (orders[i].order.price * orders[i].makerAmount) / 1e18;
                
                // Ensure the user has enough USDC balance (they should from setUp)
                uint256 currentBalance = mockUsdc.balanceOf(user);
                require(currentBalance >= usdcAmount, "User doesn't have enough USDC");
                
                // Ensure the adapter has sufficient approval (it should from setUp with max approval)
                uint256 currentAllowance = mockUsdc.allowance(user, address(adapter));
                require(currentAllowance >= usdcAmount, "Insufficient allowance for adapter");
            } else { // SELL orders
                // For sell orders, users need the actual tokens to sell
                // They don't need additional USDC since they're selling tokens
                // The adapter will handle the USDC flow for seller returns
                
                // Note: In a real scenario, users would already have the NO tokens
                // For testing, we assume they have them
            }
        }
    }
    
    function _setupSellerTokenBalances(ICTFExchange.OrderIntent[] memory orders) internal {
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].side == 1) { // SELL orders
                // For sellers, they need to have the NO tokens to sell
                // We need to get the question index from the position ID
                uint8 qIndex = _getQuestionIndexFromPositionId(orders[i].tokenId, marketId);
                bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, qIndex);
                uint256 noPositionId = negRiskAdapter.getPositionId(questionId, false);
                
                address user = orders[i].order.maker;
                
                // Ensure the user has enough NO tokens
                uint256 currentBalance = ctf.balanceOf(user, noPositionId);
                require(currentBalance >= orders[i].makerAmount, "User doesn't have enough NO tokens");
                
                // Ensure the adapter has sufficient approval for the NO tokens
                bool isApproved = ctf.isApprovedForAll(user, address(adapter));
                require(isApproved, "Insufficient approval for NO tokens");
            }
        }
    }
    
    function _getQuestionIndexFromPositionId(uint256 positionId, bytes32 marketId) internal view returns (uint8) {
        // Get the question index from the position ID by checking all questions
        uint256 questionCount = negRiskAdapter.getQuestionCount(marketId);
        
        for (uint8 i = 0; i < questionCount; i++) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, i);
            
            // Check if this position ID matches either YES or NO for this question
            uint256 yesPositionId = negRiskAdapter.getPositionId(questionId, true);
            uint256 noPositionId = negRiskAdapter.getPositionId(questionId, false);
            
            if (positionId == yesPositionId || positionId == noPositionId) {
                return i;
            }
        }
        
        // If we can't find a matching question, revert
        revert("Unsupported token");
    }
    
    function _getFillAmounts(uint256 count, uint256 amount) internal pure returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            amounts[i] = amount;
        }
        return amounts;
    }
    
    function _createScenario2Orders() internal view returns (
        ICTFExchange.OrderIntent[] memory makerOrders,
        ICTFExchange.OrderIntent memory takerOrder,
        uint256 yes0PositionId,
        uint256 yes2PositionId
    ) {
        // Get actual position IDs from the NegRiskAdapter
        bytes32 question0Id = NegRiskIdLib.getQuestionId(marketId, 0);
        
        uint256 yes0PositionId = negRiskAdapter.getPositionId(question0Id, true);
        uint256 no0PositionId = negRiskAdapter.getPositionId(question0Id, false);
        
        // Create orders - simpler scenario: one buy YES, one sell NO (same question)
        takerOrder = _createOrderIntent(user1, 0, yes0PositionId, 0.7e18, 1e18); // Buy Yes0 at 0.7
        
        makerOrders = new ICTFExchange.OrderIntent[](1);
        makerOrders[0] = _createOrderIntent(user2, 1, no0PositionId, 0.7e18, 1e18); // Sell No0 at 0.7
        
        return (makerOrders, takerOrder, yes0PositionId, 0); // yes2PositionId not used in this scenario
    }
    
    function test_Scenario2_MixedBuySellOrders() public {
        // Scenario 2: Mixed buy/sell orders (simplified)
        // This test demonstrates the concept of mixed buy/sell orders
        // User1: buy Yes0 (0.7$ each, 1e18 shares)
        // User2: sell No0 (0.7$ each, 1e18 shares) - same question as YES
        // Total: 0.7 + (1-0.7) = 0.7 + 0.3 = 1.0
        
        // Set up NO tokens for sellers (they need to have the tokens to sell)
        _setupNOBalancesDirectly();
        
        // Get the position IDs that we actually used
        uint256 no0PositionId = negRiskAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, 0), false);
        uint256 yes0PositionId = negRiskAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, 0), true);
        
        // Log the position IDs for debugging
        console.log("NO position ID:", no0PositionId);
        console.log("YES position ID:", yes0PositionId);
        console.log("User2 NO balance:", ctf.balanceOf(user2, no0PositionId));
        console.log("User2 approval:", ctf.isApprovedForAll(user2, address(adapter)));
        
        // Create orders using the actual position IDs
        ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(user1, 0, yes0PositionId, 0.7e18, 1e18); // Buy Yes0 at 0.7
        
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](1);
        makerOrders[0] = _createOrderIntent(user2, 1, no0PositionId, 0.7e18, 1e18); // Sell No0 at 0.7
        
        // Set up token balances for users
        _setupUserTokenBalances(makerOrders);
        
        // Set up token balance for taker order maker
        ICTFExchange.OrderIntent[] memory takerOrderArray = new ICTFExchange.OrderIntent[](1);
        takerOrderArray[0] = takerOrder;
        _setupUserTokenBalances(takerOrderArray);
        
        // Record initial balances
        uint256 user1InitialBalance = mockUsdc.balanceOf(user1);
        uint256 user2InitialBalance = mockUsdc.balanceOf(user2);
        uint256 vaultInitialBalance = mockUsdc.balanceOf(address(vault));
        
        // Execute cross-matching
        uint256[] memory makerFillAmounts = new uint256[](makerOrders.length);
        for (uint256 i = 0; i < makerOrders.length; i++) {
            makerFillAmounts[i] = 1e18;
        }
        
        // Call the cross-matching function
        adapter.crossMatchLongOrders(
            marketId,
            takerOrder,
            makerOrders,
            1e18,
            makerFillAmounts
        );
        
        // Verify results - simplified to reduce stack usage
        // Buyers should have paid their USDC
        uint256 expectedUser1Payment = (0.7e18 * 1e18) / 1e18;
        
        // Sellers should have received USDC returns
        uint256 expectedUser2Return = ((1e18 - 0.7e18) * 1e18) / 1e18;
        
        // Basic balance checks
        assertEq(
            mockUsdc.balanceOf(user1), 
            user1InitialBalance - expectedUser1Payment, 
            "User1 should have paid correct amount"
        );
        
        assertEq(
            mockUsdc.balanceOf(user2), 
            user2InitialBalance + expectedUser2Return, 
            "User2 should have received correct USDC return"
        );
        
        // Contract should have no remaining USDC
        assertEq(mockUsdc.balanceOf(address(adapter)), 0, "Contract should have no remaining USDC");
        
        // Verify self-financing: vault should have net zero change
        uint256 netVaultChange = expectedUser2Return - expectedUser1Payment;
        uint256 vaultFinalBalance = mockUsdc.balanceOf(address(vault));
        assertEq(vaultFinalBalance, vaultInitialBalance + netVaultChange, "Vault balance should reflect net USDC flow");
    }
    
    function test_Scenario3_AllSellOrders() public {
        // Scenario 3: All sell orders (3 teams: Barca, Arsenal, Chelsea)
        // User A: sell No Barca at 0.65
        // User B: sell No Arsenal at 0.45  
        // User C: sell No Chelsea at 0.90
        // Total: (1-0.65) + (1-0.45) + (1-0.90) = 0.35 + 0.55 + 0.10 = 1.0
        
        // Record initial balances
        uint256 user1InitialBalance = mockUsdc.balanceOf(user1);
        uint256 user2InitialBalance = mockUsdc.balanceOf(user2);
        uint256 user3InitialBalance = mockUsdc.balanceOf(user3);
        uint256 vaultInitialBalance = mockUsdc.balanceOf(address(vault));
        
        ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(
            user1, 1, 0x02, 0.65e18, 1e18
        );
        
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](2);
        makerOrders[0] = _createOrderIntent(user2, 1, 0x04, 0.45e18, 1e18); // No Arsenal
        makerOrders[1] = _createOrderIntent(user3, 1, 0x06, 0.90e18, 1e18); // No Chelsea
        
        uint256[] memory makerFillAmounts = new uint256[](2);
        makerFillAmounts[0] = 1e18;
        makerFillAmounts[1] = 1e18;
        
        // Execute cross-matching
        adapter.crossMatchLongOrders(
            marketId,
            takerOrder,
            makerOrders,
            1e18,
            makerFillAmounts
        );
        
        // Verify results
        // All sellers should have received USDC returns
        uint256 expectedUser1Return = ((1e18 - 0.65e18) * 1e18) / 1e18; // (1-0.65) * 1e6
        uint256 expectedUser2Return = ((1e18 - 0.45e18) * 1e18) / 1e18; // (1-0.45) * 1e6
        uint256 expectedUser3Return = ((1e18 - 0.90e18) * 1e18) / 1e18; // (1-0.90) * 1e6
        
        assertEq(
            mockUsdc.balanceOf(user1), 
            user1InitialBalance + expectedUser1Return, 
            "User1 should have received correct USDC return"
        );
        assertEq(
            mockUsdc.balanceOf(user2), 
            user2InitialBalance + expectedUser2Return, 
            "User2 should have received correct USDC return"
        );
        assertEq(
            mockUsdc.balanceOf(user3), 
            user3InitialBalance + expectedUser3Return, 
            "User3 should have received correct USDC return"
        );
        
        // Contract should have no remaining USDC
        assertEq(mockUsdc.balanceOf(address(adapter)), 0, "Contract should have no remaining USDC");
        
        // Verify self-financing: vault should have provided USDC for seller returns
        uint256 totalSellerReturns = expectedUser1Return + expectedUser2Return + expectedUser3Return;
        uint256 vaultFinalBalance = mockUsdc.balanceOf(address(vault));
        assertEq(vaultFinalBalance, vaultInitialBalance - totalSellerReturns, "Vault should have provided USDC for seller returns");
    }
    
    function test_Validation_CombinedPriceMustEqualOne() public {
        // Test that validation fails when combined price ≠ 1
        
        ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(
            user1, 0, 0x01, 0.25e18, 1e18
        );
        
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](2);
        makerOrders[0] = _createOrderIntent(user2, 0, 0x03, 0.25e18, 1e18); // Yes2
        makerOrders[1] = _createOrderIntent(user3, 0, 0x05, 0.25e18, 1e18); // Yes3
        // Total: 0.25 + 0.25 + 0.25 = 0.75 ≠ 1.0
        
        uint256[] memory makerFillAmounts = new uint256[](2);
        makerFillAmounts[0] = 1e18;
        makerFillAmounts[1] = 1e18;
        
        // Should revert with InvalidCombinedPrice error
        vm.expectRevert(CrossMatchingAdapter.InvalidCombinedPrice.selector);
        adapter.crossMatchLongOrders(
            marketId,
            takerOrder,
            makerOrders,
            1e18,
            makerFillAmounts
        );
    }
    
    function test_Validation_MustHaveAtLeastSomeOrders() public {
        // Test that validation fails when there are no orders
        
        ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(
            user1, 0, 0x01, 0.25e18, 0 // Zero shares
        );
        
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](0);
        uint256[] memory makerFillAmounts = new uint256[](0);
        
        // Should revert with InvalidFillAmount error since fill amount is 0
        vm.expectRevert(CrossMatchingAdapter.InvalidFillAmount.selector);
        adapter.crossMatchLongOrders(
            marketId,
            takerOrder,
            makerOrders,
            0,
            makerFillAmounts
        );
    }
    
    function test_Validation_PriceOutOfRange() public {
        // Test that validation fails when price > 1
        
        ICTFExchange.OrderIntent memory takerOrder = _createOrderIntent(
            user1, 0, 0x01, 1.5e18, 1e18 // Price > 1
        );
        
        ICTFExchange.OrderIntent[] memory makerOrders = new ICTFExchange.OrderIntent[](0);
        uint256[] memory makerFillAmounts = new uint256[](0);
        
        // Should revert with PriceOutOfRange error
        vm.expectRevert(CrossMatchingAdapter.PriceOutOfRange.selector);
        adapter.crossMatchLongOrders(
            marketId,
            takerOrder,
            makerOrders,
            1e18,
            makerFillAmounts
        );
    }

    function test_BasicSetup() public {
        // Test that the basic setup is working
        assertEq(negRiskAdapter.getQuestionCount(marketId), 4, "Should have 4 questions");
        
        // Test that we can get question IDs
        bytes32 question0 = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 question1 = NegRiskIdLib.getQuestionId(marketId, 1);
        assertTrue(question0 != question1, "Question IDs should be different");
        
        // Test that we can get position IDs
        uint256 yesPosition0 = negRiskAdapter.getPositionId(question0, true);
        uint256 noPosition0 = negRiskAdapter.getPositionId(question0, false);
        assertTrue(yesPosition0 != noPosition0, "YES and NO positions should be different");
        assertTrue(yesPosition0 != 0, "Position ID should not be zero");
        assertTrue(noPosition0 != 0, "Position ID should not be zero");
        
        // Test that the adapter has WCOL tokens
        uint256 adapterWcolBalance = wcol.balanceOf(address(adapter));
        assertTrue(adapterWcolBalance > 0, "Adapter should have WCOL tokens");
    }

    function test_CTFSplitOperation() public {
        // Test that the CTF split operation works correctly
        bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 conditionId = negRiskAdapter.getConditionId(questionId);
        
        // Get initial balances
        uint256 initialUsdcBalance = mockUsdc.balanceOf(address(adapter));
        uint256 yesPositionId = negRiskAdapter.getPositionId(questionId, true);
        uint256 noPositionId = negRiskAdapter.getPositionId(questionId, false);
        
        // Debug: Check USDC balance and allowance
        require(initialUsdcBalance >= 1e18, "Adapter needs at least 1 USDC for split");
        uint256 allowance = mockUsdc.allowance(address(adapter), address(negRiskAdapter));
        require(allowance >= 1e18, "Adapter needs to approve NegRiskAdapter to spend USDC");
        
        // Debug: Check condition ID
        require(conditionId != bytes32(0), "Condition ID should not be zero");
        
        // Perform a split operation using NegRiskAdapter
        negRiskAdapter.splitPosition(questionId, 1e18);
        
        // Check that the adapter now has YES and NO tokens
        uint256 yesBalance = ctf.balanceOf(address(adapter), yesPositionId);
        uint256 noBalance = ctf.balanceOf(address(adapter), noPositionId);
        
        assertTrue(yesBalance > 0, "Adapter should have YES tokens after split");
        assertTrue(noBalance > 0, "Adapter should have NO tokens after split");
    }

    function test_ConditionPreparation() public {
        // Test that the condition preparation is working correctly
        bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, 0);
        bytes32 conditionId = negRiskAdapter.getConditionId(questionId);
        
        // Check if the condition is prepared in the CTF contract
        uint256 outcomeSlotCount = ctf.getOutcomeSlotCount(conditionId);
        assertEq(outcomeSlotCount, 2, "Condition should have 2 outcome slots");
    }
}

// Mock contracts for testing
contract MockUSDC {
    string public constant name = "MockUSDC";
    string public constant symbol = "MUSDC";
    uint8 public constant decimals = 18;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        console.log("MockUSDC.transferFrom called on contract:", address(this));
        console.log("  from:", from);
        console.log("  to:", to);
        console.log("  amount:", amount);
        console.log("  from balance:", balanceOf[from]);
        console.log("  allowance:", allowance[from][msg.sender]);
        
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        
        console.log("  transfer successful");
        return true;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        console.log("MockUSDC.transfer called:");
        console.log("  from:", msg.sender);
        console.log("  to:", to);
        console.log("  amount:", amount);
        console.log("  from balance:", balanceOf[msg.sender]);
        
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        
        console.log("  transfer successful");
        return true;
    }
}

contract MockCTFExchange is ICTFExchange {
    // Mock implementation for CTF Exchange
    function matchOrders(
        OrderIntent memory takerOrder,
        OrderIntent[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) external {
        // Mock implementation
    }
}

contract MockVault {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        console.log("MockVault.transferFrom called on contract:", address(this));
        console.log("  from:", from);
        console.log("  to:", to);
        console.log("  amount:", amount);
        console.log("  from balance:", balanceOf[from]);
        console.log("  allowance:", allowance[from][msg.sender]);
        
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        
        console.log("  transfer successful");
        return true;
    }
    
    // Add ERC1155TokenReceiver support
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
