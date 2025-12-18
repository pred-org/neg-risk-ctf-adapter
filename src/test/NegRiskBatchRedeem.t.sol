// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {TestHelper, console} from "src/dev/TestHelper.sol";
import {NegRiskBatchRedeem} from "src/NegRiskBatchRedeem.sol";
import {NegRiskAdapter} from "src/NegRiskAdapter.sol";
import {USDC} from "src/test/mock/USDC.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {DeployLib} from "src/dev/libraries/DeployLib.sol";

contract NegRiskBatchRedeemTest is TestHelper {
    NegRiskBatchRedeem batchRedeem;
    NegRiskAdapter adapter;
    USDC usdc;
    IConditionalTokens ctf;
    address vault;
    address admin;
    address operator;
    address user1;
    address user2;

    function setUp() public {
        vault = vm.createWallet("vault").addr;
        admin = vm.createWallet("admin").addr;
        operator = vm.createWallet("operator").addr;
        user1 = vm.createWallet("user1").addr;
        user2 = vm.createWallet("user2").addr;

        ctf = IConditionalTokens(DeployLib.deployConditionalTokens());
        usdc = new USDC();

        // Deploy the NegRiskAdapter first
        vm.prank(admin);
        adapter = new NegRiskAdapter(address(ctf), address(usdc), vault);

        // Deploy the batch redeem contract as admin
        vm.prank(admin);
        batchRedeem = new NegRiskBatchRedeem(address(adapter));

        // Add operator
        vm.prank(admin);
        batchRedeem.addOperator(operator);

        // Mint USDC to users
        usdc.mint(user1, 1000e6);
        usdc.mint(user2, 1000e6);
    }

    function test_initialization() public {
        assertTrue(batchRedeem.isAdmin(admin));
        assertTrue(batchRedeem.isOperator(admin)); // Deployer is also an operator
        assertTrue(batchRedeem.isOperator(operator));
        assertFalse(batchRedeem.isOperator(user1));
        
        // Verify adapter addresses are correctly set
        assertEq(address(batchRedeem.negRiskAdapter()), address(adapter));
        assertEq(address(batchRedeem.ctf()), address(ctf));
        assertEq(address(batchRedeem.col()), address(usdc));
    }

    function test_addRemoveAdmin() public {
        address newAdmin = vm.createWallet("newAdmin").addr;
        
        // Add admin
        vm.prank(admin);
        batchRedeem.addAdmin(newAdmin);
        assertTrue(batchRedeem.isAdmin(newAdmin));

        // Remove admin
        vm.prank(admin);
        batchRedeem.removeAdmin(newAdmin);
        assertFalse(batchRedeem.isAdmin(newAdmin));
    }

    function test_addRemoveOperator() public {
        address newOperator = vm.createWallet("newOperator").addr;
        
        // Add operator
        vm.prank(admin);
        batchRedeem.addOperator(newOperator);
        assertTrue(batchRedeem.isOperator(newOperator));

        // Remove operator
        vm.prank(admin);
        batchRedeem.removeOperator(newOperator);
        assertFalse(batchRedeem.isOperator(newOperator));
    }

    function test_noTokensToRedeem() public {
        bytes32 questionId = keccak256("test question");
        address[] memory users = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(0x2e938bed)); // NoTokensToRedeem selector
        batchRedeem.batchRedeemQuestion(questionId, users, amounts, amounts);
    }

    function test_customBatchRedeemInvalidLengths() public {
        bytes32 questionId = keccak256("test question");
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory yesAmounts = new uint256[](1); // Wrong length
        yesAmounts[0] = 100e6;
        uint256[] memory noAmounts = new uint256[](2);
        noAmounts[0] = 100e6;
        noAmounts[1] = 100e6;

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(0x9d89020a)); // InvalidArrayLength selector
        batchRedeem.batchRedeemQuestion(questionId, users, yesAmounts, noAmounts);
    }

    /*//////////////////////////////////////////////////////////////
                        CORE REDEMPTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_batchRedeemWithResolvedQuestion() public {
        console.log("=== Testing Batch Redemption with Resolved Question ===");
        
        // Create a new market and question for this test
        bytes32 testMarketId = adapter.prepareMarket(0, "Test Market for Redemption");
        bytes32 testQuestionId = adapter.prepareQuestion(testMarketId, "Will it rain tomorrow?");
        
        // Get position IDs
        uint256 yesPositionId = adapter.getPositionId(testQuestionId, true);
        uint256 noPositionId = adapter.getPositionId(testQuestionId, false);
        
        // Distribute tokens to users
        uint256 tokenAmount = 100e6; // 100 tokens
        _distributeTokensToUsers(testQuestionId, tokenAmount);
        
        // Record initial balances
        uint256 user1InitialUSDC = usdc.balanceOf(user1);
        uint256 user2InitialUSDC = usdc.balanceOf(user2);
        uint256 user1InitialYes = ctf.balanceOf(user1, yesPositionId);
        uint256 user1InitialNo = ctf.balanceOf(user1, noPositionId);
        uint256 user2InitialYes = ctf.balanceOf(user2, yesPositionId);
        uint256 user2InitialNo = ctf.balanceOf(user2, noPositionId);
        
        console.log("Initial balances:");
        console.log("User1 USDC:", user1InitialUSDC);
        console.log("User2 USDC:", user2InitialUSDC);
        console.log("User1 YES tokens:", user1InitialYes);
        console.log("User1 NO tokens:", user1InitialNo);
        console.log("User2 YES tokens:", user2InitialYes);
        console.log("User2 NO tokens:", user2InitialNo);
        
        // Resolve the question (YES wins)
        adapter.reportOutcome(testQuestionId, true);
        
        // Prepare batch redemption data
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6; // User1 redeems 50 tokens
        amounts[1] = 30e6; // User2 redeems 30 tokens
        
        // Execute batch redemption
        vm.prank(operator);
        batchRedeem.batchRedeemQuestion(testQuestionId, users, amounts, amounts);
        
        // Verify results - inline verification to avoid stack too deep
        // (yesPositionId and noPositionId already defined above)
        assertEq(ctf.balanceOf(user1, yesPositionId), user1InitialYes - amounts[0], "User1 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user1, noPositionId), user1InitialNo - amounts[0], "User1 NO tokens should be reduced");
        assertEq(ctf.balanceOf(user2, yesPositionId), user2InitialYes - amounts[1], "User2 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user2, noPositionId), user2InitialNo - amounts[1], "User2 NO tokens should be reduced");
        
        // Calculate expected and verify USDC balances
        // NegRiskAdapter: payoutNumerators[0] = YES, payoutNumerators[1] = NO
        // YES wins: payoutNumerators[0] = 1, payoutNumerators[1] = 0
        bytes32 conditionId = adapter.getConditionId(testQuestionId);
        assertEq(usdc.balanceOf(user1), user1InitialUSDC + _calculateExpectedPayout(conditionId, amounts[0], amounts[0]), "User1 final USDC should match expected balance");
        assertEq(usdc.balanceOf(user2), user2InitialUSDC + _calculateExpectedPayout(conditionId, amounts[1], amounts[1]), "User2 final USDC should match expected balance");
        
        assertEq(ctf.balanceOf(address(batchRedeem), yesPositionId), 0, "Batch redeem contract should have no YES tokens");
        assertEq(ctf.balanceOf(address(batchRedeem), noPositionId), 0, "Batch redeem contract should have no NO tokens");
        
        console.log("Batch redemption with resolved question completed successfully!");
    }

    function test_batchRedeemWithUnresolvedQuestion() public {
        console.log("=== Testing Batch Redemption with Unresolved Question ===");
        
        // Create a new market and question for this test
        bytes32 testMarketId = adapter.prepareMarket(0, "Test Market for Unresolved Redemption");
        bytes32 testQuestionId = adapter.prepareQuestion(testMarketId, "Will the stock market crash?");
        
        // Get position IDs
        uint256 yesPositionId = adapter.getPositionId(testQuestionId, true);
        uint256 noPositionId = adapter.getPositionId(testQuestionId, false);
        
        // Distribute tokens to users
        uint256 tokenAmount = 100e6; // 100 tokens
        _distributeTokensToUsers(testQuestionId, tokenAmount);
        
        // Record initial balances
        uint256 user1InitialUSDC = usdc.balanceOf(user1);
        uint256 user2InitialUSDC = usdc.balanceOf(user2);
        uint256 user1InitialYes = ctf.balanceOf(user1, yesPositionId);
        uint256 user1InitialNo = ctf.balanceOf(user1, noPositionId);
        uint256 user2InitialYes = ctf.balanceOf(user2, yesPositionId);
        uint256 user2InitialNo = ctf.balanceOf(user2, noPositionId);
        
        console.log("Initial balances (unresolved):");
        console.log("User1 USDC:", user1InitialUSDC);
        console.log("User2 USDC:", user2InitialUSDC);
        console.log("User1 YES tokens:", user1InitialYes);
        console.log("User1 NO tokens:", user1InitialNo);
        console.log("User2 YES tokens:", user2InitialYes);
        console.log("User2 NO tokens:", user2InitialNo);
        
        // DON'T resolve the question - test redemption of unresolved positions
        
        // Prepare batch redemption data
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6; // User1 redeems 50 tokens
        amounts[1] = 30e6; // User2 redeems 30 tokens
        
        // Execute batch redemption - should fail for unresolved question
        vm.prank(operator);
        vm.expectRevert("result for condition not received yet");
        batchRedeem.batchRedeemQuestion(testQuestionId, users, amounts, amounts);
        
        console.log("Batch redemption with unresolved question correctly failed as expected!");
    }

    function test_batchRedeemCustomAmounts() public {
        console.log("=== Testing Batch Redemption with Custom Amounts ===");
        
        // Create a new market and question for this test
        bytes32 testMarketId = adapter.prepareMarket(0, "Test Market for Custom Redemption");
        bytes32 testQuestionId = adapter.prepareQuestion(testMarketId, "Will Bitcoin reach $100k?");
        
        // Get position IDs
        // uint256 yesPositionId = adapter.getPositionId(testQuestionId, true);
        // uint256 noPositionId = adapter.getPositionId(testQuestionId, false);
        
        // Distribute tokens to users
        uint256 tokenAmount = 100e6; // 100 tokens
        _distributeTokensToUsers(testQuestionId, tokenAmount);
        
        // Record initial balances
        uint256 user1InitialUSDC = usdc.balanceOf(user1);
        uint256 user2InitialUSDC = usdc.balanceOf(user2);
        
        // Resolve the question (NO wins)
        adapter.reportOutcome(testQuestionId, false);
        
        // Prepare custom batch redemption data
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory yesAmounts = new uint256[](2);
        yesAmounts[0] = 20e6; // User1 redeems 20 YES tokens
        yesAmounts[1] = 10e6; // User2 redeems 10 YES tokens
        uint256[] memory noAmounts = new uint256[](2);
        noAmounts[0] = 30e6; // User1 redeems 30 NO tokens
        noAmounts[1] = 15e6; // User2 redeems 15 NO tokens
        
        // Execute custom batch redemption
        vm.prank(operator);
        batchRedeem.batchRedeemQuestion(testQuestionId, users, yesAmounts, noAmounts);
        
        // Verify results - inline verification to avoid stack too deep
        uint256 customYesPositionId = adapter.getPositionId(testQuestionId, true);
        uint256 customNoPositionId = adapter.getPositionId(testQuestionId, false);
        
        assertEq(ctf.balanceOf(user1, customYesPositionId), 100e6 - yesAmounts[0], "User1 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user1, customNoPositionId), 100e6 - noAmounts[0], "User1 NO tokens should be reduced");
        assertEq(ctf.balanceOf(user2, customYesPositionId), 100e6 - yesAmounts[1], "User2 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user2, customNoPositionId), 100e6 - noAmounts[1], "User2 NO tokens should be reduced");
        
        // Calculate expected and verify USDC balances
        // NegRiskAdapter: payoutNumerators[0] = YES, payoutNumerators[1] = NO
        // NO wins: payoutNumerators[0] = 0, payoutNumerators[1] = 1
        bytes32 conditionId = adapter.getConditionId(testQuestionId);
        assertEq(usdc.balanceOf(user1), user1InitialUSDC + _calculateExpectedPayout(conditionId, yesAmounts[0], noAmounts[0]), "User1 final USDC should match expected balance");
        assertEq(usdc.balanceOf(user2), user2InitialUSDC + _calculateExpectedPayout(conditionId, yesAmounts[1], noAmounts[1]), "User2 final USDC should match expected balance");
        
        assertEq(ctf.balanceOf(address(batchRedeem), customYesPositionId), 0, "Batch redeem contract should have no YES tokens");
        assertEq(ctf.balanceOf(address(batchRedeem), customNoPositionId), 0, "Batch redeem contract should have no NO tokens");
        
        console.log("Custom batch redemption completed successfully!");
    }

    function test_batchRedeemMultipleQuestions() public {
        console.log("=== Testing Batch Redemption with Multiple Questions ===");
        
        // Create a new market with multiple questions
        bytes32 testMarketId = adapter.prepareMarket(0, "Test Market with Multiple Questions");
        bytes32 question1Id = adapter.prepareQuestion(testMarketId, "Question 1: Will Team A win?");
        bytes32 question2Id = adapter.prepareQuestion(testMarketId, "Question 2: Will Team B win?");
        
        // Distribute tokens for both questions
        _distributeTokensToUsers(question1Id, 100e6);
        _distributeTokensToUsers(question2Id, 100e6);
        
        // Resolve questions differently
        adapter.reportOutcome(question1Id, true);  // Question 1: YES wins
        adapter.reportOutcome(question2Id, false); // Question 2: NO wins
        
        // Test redemption for Question 1 (YES wins)
        address[] memory users1 = new address[](2);
        users1[0] = user1;
        users1[1] = user2;
        uint256[] memory amounts1 = new uint256[](2);
        amounts1[0] = 50e6;
        amounts1[1] = 30e6;
        
        vm.prank(operator);
        batchRedeem.batchRedeemQuestion(question1Id, users1, amounts1, amounts1);
        
        // Test redemption for Question 2 (NO wins)
        address[] memory users2 = new address[](2);
        users2[0] = user1;
        users2[1] = user2;
        uint256[] memory amounts2 = new uint256[](2);
        amounts2[0] = 20e6;
        amounts2[1] = 25e6;
        
        vm.prank(operator);
        batchRedeem.batchRedeemQuestion(question2Id, users2, amounts2, amounts2);
        
        // Verify final balances
        uint256 user1FinalUSDC = usdc.balanceOf(user1);
        uint256 user2FinalUSDC = usdc.balanceOf(user2);
        
        console.log("Final USDC balances after multiple redemptions:");
        console.log("User1 USDC:", user1FinalUSDC);
        console.log("User2 USDC:", user2FinalUSDC);
        
        // Users should have received USDC from both redemptions
        // Initial balance: 1B - 200M (for 2 questions) = 800M
        // Expected payouts: User1: 50M + 20M = 70M, User2: 30M + 25M = 55M
        assertTrue(user1FinalUSDC > 800_000_000, "User1 should have received USDC from redemptions");
        assertTrue(user2FinalUSDC > 800_000_000, "User2 should have received USDC from redemptions");
        
        console.log("Multiple questions batch redemption completed successfully!");
    }

    function test_batchRedeemOneUserYesOnlyOneUserNoOnly() public {
        console.log("=== Testing Batch Redemption: User1 YES only, User2 NO only ===");
        
        // Create a new market and question for this test
        bytes32 testMarketId = adapter.prepareMarket(0, "Test Market for Split Token Redemption");
        bytes32 testQuestionId = adapter.prepareQuestion(testMarketId, "Will Ethereum reach $5000?");
        
        // Get position IDs
        uint256 yesPositionId = adapter.getPositionId(testQuestionId, true);
        uint256 noPositionId = adapter.getPositionId(testQuestionId, false);
        
        // Mint tokens for user1 (will get YES + NO)
        uint256 tokenAmount = 1e6;
        _mintConditionalTokens(user1, testQuestionId, tokenAmount);
        
        // Mint tokens for user2 (will get YES + NO)
        _mintConditionalTokens(user2, testQuestionId, tokenAmount);
        
        // Transfer all NO tokens from user1 to user2
        vm.prank(user1);
        ctf.safeTransferFrom(user1, user2, noPositionId, tokenAmount, "");
        
        // Transfer all YES tokens from user2 to user1
        vm.prank(user2);
        ctf.safeTransferFrom(user2, user1, yesPositionId, tokenAmount, "");
        
        // Now transfer excess tokens away to get exact amounts:
        // User1 should have exactly 1e6 YES (transfer 1e6 YES to a burn address)
        // User2 should have exactly 1e6 NO (transfer 1e6 NO to a burn address)
        address burnAddress = address(0xDead);
        vm.prank(user1);
        ctf.safeTransferFrom(user1, burnAddress, yesPositionId, tokenAmount, "");
        
        vm.prank(user2);
        ctf.safeTransferFrom(user2, burnAddress, noPositionId, tokenAmount, "");
        
        // Give approval to batch redeem contract
        vm.prank(user1);
        ctf.setApprovalForAll(address(batchRedeem), true);
        
        vm.prank(user2);
        ctf.setApprovalForAll(address(batchRedeem), true);
        
        // Verify initial token distribution
        assertEq(ctf.balanceOf(user1, yesPositionId), tokenAmount, "User1 should have exactly 1e6 YES tokens");
        assertEq(ctf.balanceOf(user1, noPositionId), 0, "User1 should have 0 NO tokens");
        assertEq(ctf.balanceOf(user2, yesPositionId), 0, "User2 should have 0 YES tokens");
        assertEq(ctf.balanceOf(user2, noPositionId), tokenAmount, "User2 should have exactly 1e6 NO tokens");
        
        console.log("Initial token distribution:");
        console.log("User1 YES tokens:", ctf.balanceOf(user1, yesPositionId));
        console.log("User1 NO tokens:", ctf.balanceOf(user1, noPositionId));
        console.log("User2 YES tokens:", ctf.balanceOf(user2, yesPositionId));
        console.log("User2 NO tokens:", ctf.balanceOf(user2, noPositionId));
        
        // Record initial USDC balances (after token minting and transfers)
        uint256 user1InitialUSDC = usdc.balanceOf(user1);
        uint256 user2InitialUSDC = usdc.balanceOf(user2);
        
        console.log("Initial USDC balances:");
        console.log("User1 USDC:", user1InitialUSDC);
        console.log("User2 USDC:", user2InitialUSDC);
        
        // Resolve the question (YES wins)
        adapter.reportOutcome(testQuestionId, true);
        
        // Prepare batch redemption data
        // User1: redeem 1e6 YES tokens, 0 NO tokens
        // User2: redeem 0 YES tokens, 1e6 NO tokens
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory yesAmounts = new uint256[](2);
        yesAmounts[0] = 1e6; // User1 redeems 1e6 YES tokens
        yesAmounts[1] = 0;   // User2 redeems 0 YES tokens
        uint256[] memory noAmounts = new uint256[](2);
        noAmounts[0] = 0;    // User1 redeems 0 NO tokens
        noAmounts[1] = 1e6;  // User2 redeems 1e6 NO tokens
        
        // Execute batch redemption
        vm.prank(operator);
        batchRedeem.batchRedeemQuestion(testQuestionId, users, yesAmounts, noAmounts);
        
        // Verify token balances after redemption (all tokens should be redeemed)
        assertEq(ctf.balanceOf(user1, yesPositionId), 0, "User1 should have 0 YES tokens remaining (all redeemed)");
        assertEq(ctf.balanceOf(user1, noPositionId), 0, "User1 should still have 0 NO tokens");
        assertEq(ctf.balanceOf(user2, yesPositionId), 0, "User2 should still have 0 YES tokens");
        assertEq(ctf.balanceOf(user2, noPositionId), 0, "User2 should have 0 NO tokens remaining (all redeemed)");
        
        // Calculate expected and verify USDC balances
        // NegRiskAdapter: payoutNumerators[0] = YES, payoutNumerators[1] = NO
        // YES wins: payoutNumerators[0] = 1, payoutNumerators[1] = 0
        bytes32 conditionId = adapter.getConditionId(testQuestionId);
        assertEq(usdc.balanceOf(user1), user1InitialUSDC + _calculateExpectedPayout(conditionId, yesAmounts[0], noAmounts[0]), "User1 final USDC should match expected balance");
        assertEq(usdc.balanceOf(user2), user2InitialUSDC + _calculateExpectedPayout(conditionId, yesAmounts[1], noAmounts[1]), "User2 final USDC should match expected balance");
        
        // Check that batch redeem contract has no leftover tokens
        assertEq(ctf.balanceOf(address(batchRedeem), yesPositionId), 0, "Batch redeem contract should have no YES tokens");
        assertEq(ctf.balanceOf(address(batchRedeem), noPositionId), 0, "Batch redeem contract should have no NO tokens");
        
        console.log("Batch redemption with split tokens completed successfully!");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate expected payout for a user based on redemption amounts and condition resolution
    /// @notice NegRiskAdapter: payoutNumerators[0] = YES, payoutNumerators[1] = NO
    function _calculateExpectedPayout(
        bytes32 conditionId,
        uint256 yesAmount,
        uint256 noAmount
    ) internal view returns (uint256) {
        uint256 denom = ctf.payoutDenominator(conditionId);
        uint256 yesNum = ctf.payoutNumerators(conditionId, 0); // YES (outcome slot 0)
        uint256 noNum = ctf.payoutNumerators(conditionId, 1);  // NO (outcome slot 1)
        return (yesAmount * yesNum / denom) + (noAmount * noNum / denom);
    }

    function _mintConditionalTokens(address to, bytes32 questionId, uint256 amount) internal {
        // This follows the pattern from CrossMatchingAdapterTest.sol
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
        usdc.approve(address(adapter), type(uint256).max);
        
        // Approve ERC1155 transfers by the adapter
        ctf.setApprovalForAll(address(adapter), true);
        
        // Get the condition ID for this question from the NegRiskAdapter
        bytes32 conditionId = adapter.getConditionId(questionId);
        
        // Use NegRiskAdapter's splitPosition function with the correct condition ID
        adapter.splitPosition(conditionId, amount);
        
        vm.stopPrank();
        
        console.log("Minted conditional tokens for", to);
    }

    function _distributeTokensToUsers(bytes32 questionId, uint256 amount) internal {
        // Get position IDs
        uint256 yesPositionId = adapter.getPositionId(questionId, true);
        uint256 noPositionId = adapter.getPositionId(questionId, false);
        
        // Mint tokens for user1
        _mintConditionalTokens(user1, questionId, amount);
        
        // Mint tokens for user2
        _mintConditionalTokens(user2, questionId, amount);
        
        // Give approval to batch redeem contract
        vm.prank(user1);
        ctf.setApprovalForAll(address(batchRedeem), true);
        
        vm.prank(user2);
        ctf.setApprovalForAll(address(batchRedeem), true);
        
        // Also give approval to the adapter for token minting
        vm.prank(user1);
        ctf.setApprovalForAll(address(adapter), true);
        
        vm.prank(user2);
        ctf.setApprovalForAll(address(adapter), true);
        
        console.log("Distributed tokens:");
        console.log("User1 YES tokens:", ctf.balanceOf(user1, yesPositionId));
        console.log("User1 NO tokens:", ctf.balanceOf(user1, noPositionId));
        console.log("User2 YES tokens:", ctf.balanceOf(user2, yesPositionId));
        console.log("User2 NO tokens:", ctf.balanceOf(user2, noPositionId));
    }

    function _verifyBatchRedemptionResults(
        bytes32 questionId,
        address[] memory users,
        uint256[] memory amounts,
        uint256 user1InitialUSDC,
        uint256 user2InitialUSDC,
        uint256 user1InitialYes,
        uint256 user1InitialNo,
        uint256 user2InitialYes,
        uint256 user2InitialNo
    ) internal {
        uint256 yesPositionId = adapter.getPositionId(questionId, true);
        uint256 noPositionId = adapter.getPositionId(questionId, false);
        
        // Check token balances after redemption
        assertEq(ctf.balanceOf(user1, yesPositionId), user1InitialYes - amounts[0], "User1 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user1, noPositionId), user1InitialNo - amounts[0], "User1 NO tokens should be reduced");
        assertEq(ctf.balanceOf(user2, yesPositionId), user2InitialYes - amounts[1], "User2 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user2, noPositionId), user2InitialNo - amounts[1], "User2 NO tokens should be reduced");
        
        // Check USDC balances - users should have received collateral back
        uint256 user1FinalUSDC = usdc.balanceOf(user1);
        uint256 user2FinalUSDC = usdc.balanceOf(user2);
        
        console.log("Final USDC balances:");
        console.log("User1 USDC:", user1FinalUSDC);
        console.log("User2 USDC:", user2FinalUSDC);
        
        // Users should have received USDC back (collateral from redeemed tokens)
        assertTrue(user1FinalUSDC > user1InitialUSDC, "User1 should have received USDC from redemption");
        assertTrue(user2FinalUSDC > user2InitialUSDC, "User2 should have received USDC from redemption");
        
        // Check that batch redeem contract has no leftover tokens
        assertEq(ctf.balanceOf(address(batchRedeem), yesPositionId), 0, "Batch redeem contract should have no YES tokens");
        assertEq(ctf.balanceOf(address(batchRedeem), noPositionId), 0, "Batch redeem contract should have no NO tokens");
    }

    function _verifyBatchRedemptionResultsUnresolved(
        bytes32 questionId,
        address[] memory users,
        uint256[] memory amounts,
        uint256 user1InitialUSDC,
        uint256 user2InitialUSDC,
        uint256 user1InitialYes,
        uint256 user1InitialNo,
        uint256 user2InitialYes,
        uint256 user2InitialNo
    ) internal {
        uint256 yesPositionId = adapter.getPositionId(questionId, true);
        uint256 noPositionId = adapter.getPositionId(questionId, false);
        
        // Check token balances after redemption
        assertEq(ctf.balanceOf(user1, yesPositionId), user1InitialYes - amounts[0], "User1 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user1, noPositionId), user1InitialNo - amounts[0], "User1 NO tokens should be reduced");
        assertEq(ctf.balanceOf(user2, yesPositionId), user2InitialYes - amounts[1], "User2 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user2, noPositionId), user2InitialNo - amounts[1], "User2 NO tokens should be reduced");
        
        // Check USDC balances - for unresolved questions, users get back their collateral
        uint256 user1FinalUSDC = usdc.balanceOf(user1);
        uint256 user2FinalUSDC = usdc.balanceOf(user2);
        
        console.log("Final USDC balances (unresolved):");
        console.log("User1 USDC:", user1FinalUSDC);
        console.log("User2 USDC:", user2FinalUSDC);
        
        // Users should have received USDC back (collateral from redeemed tokens)
        assertTrue(user1FinalUSDC > user1InitialUSDC, "User1 should have received USDC from redemption");
        assertTrue(user2FinalUSDC > user2InitialUSDC, "User2 should have received USDC from redemption");
        
        // Check that batch redeem contract has no leftover tokens
        assertEq(ctf.balanceOf(address(batchRedeem), yesPositionId), 0, "Batch redeem contract should have no YES tokens");
        assertEq(ctf.balanceOf(address(batchRedeem), noPositionId), 0, "Batch redeem contract should have no NO tokens");
    }

    function _verifyCustomBatchRedemptionResults(
        bytes32 questionId,
        address[] memory users,
        uint256[] memory yesAmounts,
        uint256[] memory noAmounts,
        uint256 user1InitialUSDC,
        uint256 user2InitialUSDC
    ) internal {
        uint256 yesPositionId = adapter.getPositionId(questionId, true);
        uint256 noPositionId = adapter.getPositionId(questionId, false);
        
        // Check token balances after redemption
        assertEq(ctf.balanceOf(user1, yesPositionId), 100e6 - yesAmounts[0], "User1 YES tokens should be reduced by custom amount");
        assertEq(ctf.balanceOf(user1, noPositionId), 100e6 - noAmounts[0], "User1 NO tokens should be reduced by custom amount");
        assertEq(ctf.balanceOf(user2, yesPositionId), 100e6 - yesAmounts[1], "User2 YES tokens should be reduced by custom amount");
        assertEq(ctf.balanceOf(user2, noPositionId), 100e6 - noAmounts[1], "User2 NO tokens should be reduced by custom amount");
        
        // Check USDC balances
        uint256 user1FinalUSDC = usdc.balanceOf(user1);
        uint256 user2FinalUSDC = usdc.balanceOf(user2);
        
        console.log("Final USDC balances (custom):");
        console.log("User1 USDC:", user1FinalUSDC);
        console.log("User2 USDC:", user2FinalUSDC);
        
        // Users should have received USDC back
        assertTrue(user1FinalUSDC > user1InitialUSDC, "User1 should have received USDC from custom redemption");
        assertTrue(user2FinalUSDC > user2InitialUSDC, "User2 should have received USDC from custom redemption");
        
        // Check that batch redeem contract has no leftover tokens
        assertEq(ctf.balanceOf(address(batchRedeem), yesPositionId), 0, "Batch redeem contract should have no YES tokens");
        assertEq(ctf.balanceOf(address(batchRedeem), noPositionId), 0, "Batch redeem contract should have no NO tokens");
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
