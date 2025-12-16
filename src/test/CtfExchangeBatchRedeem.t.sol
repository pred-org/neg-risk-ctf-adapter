// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {TestHelper, console} from "src/dev/TestHelper.sol";
import {CtfExchangeBatchRedeem} from "src/CtfExchangeBatchRedeem.sol";
import {ICtfExchangeBatchRedeemEE} from "src/CtfExchangeBatchRedeem.sol";
import {USDC} from "src/test/mock/USDC.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";
import {DeployLib} from "src/dev/libraries/DeployLib.sol";
import {CTHelpers} from "src/libraries/CTHelpers.sol";
import {Helpers} from "src/libraries/Helpers.sol";

contract CtfExchangeBatchRedeemTest is TestHelper {
    CtfExchangeBatchRedeem batchRedeem;
    USDC usdc;
    IConditionalTokens ctf;
    address admin;
    address operator;
    address oracle;
    address user1;
    address user2;

    function setUp() public {
        oracle = vm.createWallet("oracle").addr;
        admin = vm.createWallet("admin").addr;
        operator = vm.createWallet("operator").addr;
        user1 = vm.createWallet("user1").addr;
        user2 = vm.createWallet("user2").addr;

        ctf = IConditionalTokens(DeployLib.deployConditionalTokens());
        usdc = new USDC();

        // Deploy the batch redeem contract as admin
        vm.prank(admin);
        batchRedeem = new CtfExchangeBatchRedeem(address(ctf), address(usdc));

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
        
        // Verify addresses are correctly set
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
        bytes32 conditionId = keccak256("test condition");
        address[] memory users = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(0x2e938bed)); // NoTokensToRedeem selector
        batchRedeem.batchRedeemCondition(conditionId, users, amounts, amounts);
    }

    function test_customBatchRedeemInvalidLengths() public {
        bytes32 conditionId = keccak256("test condition");
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
        batchRedeem.batchRedeemCondition(conditionId, users, yesAmounts, noAmounts);
    }

    function test_onlyOperatorCanRedeem() public {
        bytes32 conditionId = keccak256("test condition");
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.prank(user1); // Not an operator
        vm.expectRevert(ICtfExchangeBatchRedeemEE.NotOperator.selector);
        batchRedeem.batchRedeemCondition(conditionId, users, amounts, amounts);
    }

    /*//////////////////////////////////////////////////////////////
                        CORE REDEMPTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_batchRedeemWithResolvedCondition() public {
        console.log("=== Testing Batch Redemption with Resolved Condition ===");
        
        // Create a condition directly on ConditionalTokens
        bytes32 questionId = keccak256("Will it rain tomorrow?");
        bytes32 conditionId = _prepareCondition(questionId);
        
        // Get position IDs
        // CTFExchange uses opposite mapping: index 1 = NO, index 2 = YES (opposite of NegRiskAdapter)
        uint256 yesPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 2)
        );
        uint256 noPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 1)
        );
        
        // Distribute tokens to users
        uint256 tokenAmount = 100e6; // 100 tokens
        _distributeTokensToUsers(conditionId, tokenAmount);
        
        // Record initial balances
        uint256 user1InitialUSDC = usdc.balanceOf(user1);
        uint256 user2InitialUSDC = usdc.balanceOf(user2);
        uint256 user1InitialYes = ctf.balanceOf(user1, yesPositionId);
        uint256 user1InitialNo = ctf.balanceOf(user1, noPositionId);
        uint256 user2InitialYes = ctf.balanceOf(user2, yesPositionId);
        uint256 user2InitialNo = ctf.balanceOf(user2, noPositionId);
        
        // Resolve the condition (YES wins: payoutNumerators [0, 1])
        _resolveCondition(questionId, true);
        
        // Prepare batch redemption data
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory yesAmounts = new uint256[](2);
        yesAmounts[0] = 50e6;
        yesAmounts[1] = 30e6;
        uint256[] memory noAmounts = new uint256[](2);
        noAmounts[0] = 0;
        noAmounts[1] = 0;
        
        // Execute batch redemption
        vm.prank(operator);
        batchRedeem.batchRedeemCondition(conditionId, users, yesAmounts, noAmounts);
        
        // Verify results - inline verification to avoid stack too deep
        assertEq(ctf.balanceOf(user1, yesPositionId), user1InitialYes - yesAmounts[0], "User1 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user1, noPositionId), user1InitialNo - noAmounts[0], "User1 NO tokens should be reduced");
        assertEq(ctf.balanceOf(user2, yesPositionId), user2InitialYes - yesAmounts[1], "User2 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user2, noPositionId), user2InitialNo - noAmounts[1], "User2 NO tokens should be reduced");
        
        // Calculate expected and verify USDC balances
        assertEq(usdc.balanceOf(user1), user1InitialUSDC + _calculateExpectedPayout(conditionId, yesAmounts[0], noAmounts[0]), "User1 final USDC should match expected balance");
        assertEq(usdc.balanceOf(user2), user2InitialUSDC + _calculateExpectedPayout(conditionId, yesAmounts[1], noAmounts[1]), "User2 final USDC should match expected balance");
        
        assertEq(ctf.balanceOf(address(batchRedeem), yesPositionId), 0, "Batch redeem contract should have no YES tokens");
        assertEq(ctf.balanceOf(address(batchRedeem), noPositionId), 0, "Batch redeem contract should have no NO tokens");
        
        console.log("Batch redemption with resolved condition completed successfully!");
    }

    function test_batchRedeemWithUnresolvedCondition() public {
        console.log("=== Testing Batch Redemption with Unresolved Condition ===");
        
        // Create a condition directly on ConditionalTokens
        bytes32 questionId = keccak256("Will the stock market crash?");
        bytes32 conditionId = _prepareCondition(questionId);
        
        // Get position IDs
        // CTFExchange uses opposite mapping: index 1 = NO, index 2 = YES (opposite of NegRiskAdapter)
        uint256 yesPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 2)
        );
        uint256 noPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 1)
        );
        
        // Distribute tokens to users
        uint256 tokenAmount = 100e6; // 100 tokens
        _distributeTokensToUsers(conditionId, tokenAmount);
        
        // Record initial balances
        uint256 user1InitialUSDC = usdc.balanceOf(user1);
        uint256 user2InitialUSDC = usdc.balanceOf(user2);
        
        // DON'T resolve the condition - test redemption of unresolved positions
        
        // Prepare batch redemption data
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory yesAmounts = new uint256[](2);
        yesAmounts[0] = 50e6;
        yesAmounts[1] = 30e6;
        uint256[] memory noAmounts = new uint256[](2);
        noAmounts[0] = 0;
        noAmounts[1] = 0;
        
        // Execute batch redemption - should fail for unresolved condition
        vm.prank(operator);
        vm.expectRevert("result for condition not received yet");
        batchRedeem.batchRedeemCondition(conditionId, users, yesAmounts, noAmounts);
        
        console.log("Batch redemption with unresolved condition correctly failed as expected!");
    }

    function test_batchRedeemCustomAmounts() public {
        console.log("=== Testing Batch Redemption with Custom Amounts ===");
        
        // Create a condition directly on ConditionalTokens
        bytes32 questionId = keccak256("Will Bitcoin reach $100k?");
        bytes32 conditionId = _prepareCondition(questionId);
        
        // Distribute tokens to users
        uint256 tokenAmount = 100e6; // 100 tokens
        _distributeTokensToUsers(conditionId, tokenAmount);
        
        // Record initial balances
        uint256 user1InitialUSDC = usdc.balanceOf(user1);
        uint256 user2InitialUSDC = usdc.balanceOf(user2);
        
        // Resolve the condition (NO wins: [0, 1])
        _resolveCondition(questionId, false);
        
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
        batchRedeem.batchRedeemCondition(conditionId, users, yesAmounts, noAmounts);
        
        // Verify results - inline verification to avoid stack too deep
        uint256 customYesPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 2)
        );
        uint256 customNoPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 1)
        );
        
        assertEq(ctf.balanceOf(user1, customYesPositionId), 100e6 - yesAmounts[0], "User1 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user1, customNoPositionId), 100e6 - noAmounts[0], "User1 NO tokens should be reduced");
        assertEq(ctf.balanceOf(user2, customYesPositionId), 100e6 - yesAmounts[1], "User2 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user2, customNoPositionId), 100e6 - noAmounts[1], "User2 NO tokens should be reduced");
        
        // Calculate expected and verify USDC balances
        assertEq(usdc.balanceOf(user1), user1InitialUSDC + _calculateExpectedPayout(conditionId, yesAmounts[0], noAmounts[0]), "User1 final USDC should match expected balance");
        assertEq(usdc.balanceOf(user2), user2InitialUSDC + _calculateExpectedPayout(conditionId, yesAmounts[1], noAmounts[1]), "User2 final USDC should match expected balance");
        
        assertEq(ctf.balanceOf(address(batchRedeem), customYesPositionId), 0, "Batch redeem contract should have no YES tokens");
        assertEq(ctf.balanceOf(address(batchRedeem), customNoPositionId), 0, "Batch redeem contract should have no NO tokens");
        
        console.log("Custom batch redemption completed successfully!");
    }

    function test_batchRedeemWith5050Resolution() public {
        console.log("=== Testing Batch Redemption with 50-50 Resolution ===");
        
        // Create a condition directly on ConditionalTokens
        bytes32 questionId = keccak256("Will it be a tie?");
        bytes32 conditionId = _prepareCondition(questionId);
        
        // Distribute tokens to users
        uint256 tokenAmount = 100e6; // 100 tokens
        _distributeTokensToUsers(conditionId, tokenAmount);
        
        // Record initial balances
        uint256 user1InitialUSDC = usdc.balanceOf(user1);
        uint256 user2InitialUSDC = usdc.balanceOf(user2);
        
        // Resolve with 50-50 payouts [1, 1]
        _resolveCondition5050(questionId);
        
        // Prepare batch redemption data
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory yesAmounts = new uint256[](2);
        yesAmounts[0] = 50e6; // User1 redeems 50 YES tokens
        yesAmounts[1] = 30e6; // User2 redeems 30 YES tokens
        uint256[] memory noAmounts = new uint256[](2);
        noAmounts[0] = 0;
        noAmounts[1] = 0;
        
        // Execute batch redemption
        vm.prank(operator);
        batchRedeem.batchRedeemCondition(conditionId, users, yesAmounts, noAmounts);
        
        // Calculate expected USDC balances
        // 50-50 resolution: payoutNumerators [1, 1] means both get partial payout
        // payoutNumerators[0] = 1 (NO), payoutNumerators[1] = 1 (YES)
        // payoutDenominator = 2 (1 + 1)
        // User1: 50 YES tokens * (1/2) + 0 NO tokens * (1/2) = 25 USDC
        // User2: 30 YES tokens * (1/2) + 0 NO tokens * (1/2) = 15 USDC
        uint256 user1ExpectedUSDC = user1InitialUSDC + _calculateExpectedPayout(conditionId, yesAmounts[0], noAmounts[0]);
        uint256 user2ExpectedUSDC = user2InitialUSDC + _calculateExpectedPayout(conditionId, yesAmounts[1], noAmounts[1]);
        
        // Verify final balances match expected
        uint256 user1FinalUSDC = usdc.balanceOf(user1);
        uint256 user2FinalUSDC = usdc.balanceOf(user2);
        
        console.log("Final USDC balances (50-50 resolution):");
        console.log("User1 USDC:", user1FinalUSDC);
        console.log("User2 USDC:", user2FinalUSDC);
        console.log("User1 Expected USDC:", user1ExpectedUSDC);
        console.log("User2 Expected USDC:", user2ExpectedUSDC);
        
        // Verify exact expected balances
        assertEq(user1FinalUSDC, user1ExpectedUSDC, "User1 final USDC should match expected balance");
        assertEq(user2FinalUSDC, user2ExpectedUSDC, "User2 final USDC should match expected balance");
        
        console.log("50-50 resolution batch redemption completed successfully!");
    }


    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate expected payout for a user based on redemption amounts and condition resolution
    function _calculateExpectedPayout(
        bytes32 conditionId,
        uint256 yesAmount,
        uint256 noAmount
    ) internal view returns (uint256) {
        uint256 denom = ctf.payoutDenominator(conditionId);
        uint256 yesNum = ctf.payoutNumerators(conditionId, 1);
        uint256 noNum = ctf.payoutNumerators(conditionId, 0);
        return (yesAmount * yesNum / denom) + (noAmount * noNum / denom);
    }

    function _prepareCondition(bytes32 questionId) internal returns (bytes32 conditionId) {
        conditionId = CTHelpers.getConditionId(oracle, questionId, 2);
        
        // Prepare condition on ConditionalTokens
        vm.prank(oracle);
        ctf.prepareCondition(oracle, questionId, 2);
        
        return conditionId;
    }

    function _resolveCondition(bytes32 questionId, bool outcome) internal {
        uint256[] memory payouts = new uint256[](2);
        // CTF payout array indices map to outcome slots:
        // payoutNumerators[0] = outcome slot 0 → index set 1 (NO in CTFExchange)
        // payoutNumerators[1] = outcome slot 1 → index set 2 (YES in CTFExchange)
        if (outcome) {
            payouts[0] = 0; // NO gets 0
            payouts[1] = 1; // YES wins - gets 1
        } else {
            payouts[0] = 1; // NO wins - gets 1
            payouts[1] = 0; // YES gets 0
        }
        
        vm.prank(oracle);
        ctf.reportPayouts(questionId, payouts);
    }

    function _resolveCondition5050(bytes32 questionId) internal {
        uint256[] memory payouts = new uint256[](2);
        // CTF payout array indices map to outcome slots:
        // payoutNumerators[0] = outcome slot 0 → index set 1 (NO in CTFExchange)
        // payoutNumerators[1] = outcome slot 1 → index set 2 (YES in CTFExchange)
        payouts[0] = 1; // NO gets 1
        payouts[1] = 1; // YES gets 1 (50-50 split)
        
        vm.prank(oracle);
        ctf.reportPayouts(questionId, payouts);
    }

    function _mintConditionalTokens(address to, bytes32 conditionId, uint256 amount) internal {
        uint256[] memory partition = Helpers.partition(); // [1, 2]
        
        vm.startPrank(to);
        
        // Ensure user has enough USDC for the split operation
        uint256 requiredAmount = amount;
        if (usdc.balanceOf(to) < requiredAmount) {
            usdc.mint(to, requiredAmount - usdc.balanceOf(to));
        }
        
        // Approve USDC spending by ConditionalTokens
        usdc.approve(address(ctf), type(uint256).max);
        
        // Split position directly on ConditionalTokens
        ctf.splitPosition(address(usdc), bytes32(0), conditionId, partition, amount);
        
        vm.stopPrank();
        
        console.log("Minted conditional tokens for", to);
    }

    function _distributeTokensToUsers(bytes32 conditionId, uint256 amount) internal {
        // Get position IDs
        // CTFExchange uses opposite mapping: index 1 = NO, index 2 = YES (opposite of NegRiskAdapter)
        uint256 yesPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 2)
        );
        uint256 noPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 1)
        );
        
        // Mint tokens for user1
        _mintConditionalTokens(user1, conditionId, amount);
        
        // Mint tokens for user2
        _mintConditionalTokens(user2, conditionId, amount);
        
        // Give approval to batch redeem contract
        vm.prank(user1);
        ctf.setApprovalForAll(address(batchRedeem), true);
        
        vm.prank(user2);
        ctf.setApprovalForAll(address(batchRedeem), true);
        
        console.log("Distributed tokens:");
        console.log("User1 YES tokens:", ctf.balanceOf(user1, yesPositionId));
        console.log("User1 NO tokens:", ctf.balanceOf(user1, noPositionId));
        console.log("User2 YES tokens:", ctf.balanceOf(user2, yesPositionId));
        console.log("User2 NO tokens:", ctf.balanceOf(user2, noPositionId));
    }

    function _verifyBatchRedemptionResultsWithExpected(
        bytes32 conditionId,
        address[] memory users,
        uint256[] memory yesAmounts,
        uint256[] memory noAmounts,
        uint256 user1InitialUSDC,
        uint256 user2InitialUSDC,
        uint256 user1InitialYes,
        uint256 user1InitialNo,
        uint256 user2InitialYes,
        uint256 user2InitialNo,
        uint256 user1ExpectedUSDC,
        uint256 user2ExpectedUSDC
    ) internal {
        // CTFExchange uses opposite mapping: index 1 = NO, index 2 = YES
        uint256 yesPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 2)
        );
        uint256 noPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 1)
        );
        
        // Check token balances after redemption
        assertEq(ctf.balanceOf(user1, yesPositionId), user1InitialYes - yesAmounts[0], "User1 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user1, noPositionId), user1InitialNo - noAmounts[0], "User1 NO tokens should be reduced");
        assertEq(ctf.balanceOf(user2, yesPositionId), user2InitialYes - yesAmounts[1], "User2 YES tokens should be reduced");
        assertEq(ctf.balanceOf(user2, noPositionId), user2InitialNo - noAmounts[1], "User2 NO tokens should be reduced");
        
        // Check USDC balances and verify against expected
        uint256 user1FinalUSDC = usdc.balanceOf(user1);
        uint256 user2FinalUSDC = usdc.balanceOf(user2);
        
        console.log("Final USDC balances:");
        console.log("User1 USDC:", user1FinalUSDC);
        console.log("User2 USDC:", user2FinalUSDC);
        console.log("User1 Expected USDC:", user1ExpectedUSDC);
        console.log("User2 Expected USDC:", user2ExpectedUSDC);
        
        // Verify exact expected balances
        assertEq(user1FinalUSDC, user1ExpectedUSDC, "User1 final USDC should match expected balance");
        assertEq(user2FinalUSDC, user2ExpectedUSDC, "User2 final USDC should match expected balance");
        
        // Check that batch redeem contract has no leftover tokens
        assertEq(ctf.balanceOf(address(batchRedeem), yesPositionId), 0, "Batch redeem contract should have no YES tokens");
        assertEq(ctf.balanceOf(address(batchRedeem), noPositionId), 0, "Batch redeem contract should have no NO tokens");
    }

    function _verifyCustomBatchRedemptionResultsWithExpected(
        bytes32 conditionId,
        address[] memory users,
        uint256[] memory yesAmounts,
        uint256[] memory noAmounts,
        uint256 user1InitialUSDC,
        uint256 user2InitialUSDC,
        uint256 user1ExpectedUSDC,
        uint256 user2ExpectedUSDC
    ) internal {
        // CTFExchange uses opposite mapping: index 1 = NO, index 2 = YES
        uint256 yesPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 2)
        );
        uint256 noPositionId = CTHelpers.getPositionId(
            address(usdc),
            CTHelpers.getCollectionId(bytes32(0), conditionId, 1)
        );
        
        // Check token balances after redemption
        assertEq(ctf.balanceOf(user1, yesPositionId), 100e6 - yesAmounts[0], "User1 YES tokens should be reduced by custom amount");
        assertEq(ctf.balanceOf(user1, noPositionId), 100e6 - noAmounts[0], "User1 NO tokens should be reduced by custom amount");
        assertEq(ctf.balanceOf(user2, yesPositionId), 100e6 - yesAmounts[1], "User2 YES tokens should be reduced by custom amount");
        assertEq(ctf.balanceOf(user2, noPositionId), 100e6 - noAmounts[1], "User2 NO tokens should be reduced by custom amount");
        
        // Check USDC balances and verify against expected
        uint256 user1FinalUSDC = usdc.balanceOf(user1);
        uint256 user2FinalUSDC = usdc.balanceOf(user2);
        
        console.log("Final USDC balances (custom):");
        console.log("User1 USDC:", user1FinalUSDC);
        console.log("User2 USDC:", user2FinalUSDC);
        console.log("User1 Expected USDC:", user1ExpectedUSDC);
        console.log("User2 Expected USDC:", user2ExpectedUSDC);
        
        // Verify exact expected balances
        assertEq(user1FinalUSDC, user1ExpectedUSDC, "User1 final USDC should match expected balance");
        assertEq(user2FinalUSDC, user2ExpectedUSDC, "User2 final USDC should match expected balance");
        
        // Check that batch redeem contract has no leftover tokens
        assertEq(ctf.balanceOf(address(batchRedeem), yesPositionId), 0, "Batch redeem contract should have no YES tokens");
        assertEq(ctf.balanceOf(address(batchRedeem), noPositionId), 0, "Batch redeem contract should have no NO tokens");
    }
}

