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
        batchRedeem.batchRedeemConditionCustom(conditionId, users, amounts, amounts);
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
        batchRedeem.batchRedeemConditionCustom(conditionId, users, yesAmounts, noAmounts);
    }

    function test_onlyOperatorCanRedeem() public {
        bytes32 conditionId = keccak256("test condition");
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.prank(user1); // Not an operator
        vm.expectRevert(ICtfExchangeBatchRedeemEE.NotOperator.selector);
        batchRedeem.batchRedeemConditionCustom(conditionId, users, amounts, amounts);
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
        
        console.log("Initial balances:");
        console.log("User1 USDC:", user1InitialUSDC);
        console.log("User2 USDC:", user2InitialUSDC);
        console.log("User1 YES tokens:", user1InitialYes);
        console.log("User1 NO tokens:", user1InitialNo);
        console.log("User2 YES tokens:", user2InitialYes);
        console.log("User2 NO tokens:", user2InitialNo);
        
        // Resolve the condition (YES wins: [1, 0])
        _resolveCondition(questionId, true);
        
        // Prepare batch redemption data
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory yesAmounts = new uint256[](2);
        yesAmounts[0] = 50e6; // User1 redeems 50 YES tokens
        yesAmounts[1] = 30e6; // User2 redeems 30 YES tokens
        uint256[] memory noAmounts = new uint256[](2);
        noAmounts[0] = 0; // User1 redeems 0 NO tokens
        noAmounts[1] = 0; // User2 redeems 0 NO tokens
        
        // Execute batch redemption
        vm.prank(operator);
        batchRedeem.batchRedeemConditionCustom(conditionId, users, yesAmounts, noAmounts);
        
        // Verify results
        _verifyBatchRedemptionResults(
            conditionId,
            users,
            yesAmounts,
            noAmounts,
            user1InitialUSDC,
            user2InitialUSDC,
            user1InitialYes,
            user1InitialNo,
            user2InitialYes,
            user2InitialNo
        );
        
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
        batchRedeem.batchRedeemConditionCustom(conditionId, users, yesAmounts, noAmounts);
        
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
        batchRedeem.batchRedeemConditionCustom(conditionId, users, yesAmounts, noAmounts);
        
        // Verify results
        _verifyCustomBatchRedemptionResults(
            conditionId,
            users,
            yesAmounts,
            noAmounts,
            user1InitialUSDC,
            user2InitialUSDC
        );
        
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
        batchRedeem.batchRedeemConditionCustom(conditionId, users, yesAmounts, noAmounts);
        
        // With 50-50 resolution, users should get partial payout
        uint256 user1FinalUSDC = usdc.balanceOf(user1);
        uint256 user2FinalUSDC = usdc.balanceOf(user2);
        
        console.log("Final USDC balances (50-50 resolution):");
        console.log("User1 USDC:", user1FinalUSDC);
        console.log("User2 USDC:", user2FinalUSDC);
        
        // Users should have received some USDC (partial payout from 50-50)
        assertTrue(user1FinalUSDC > user1InitialUSDC, "User1 should have received USDC from 50-50 redemption");
        assertTrue(user2FinalUSDC > user2InitialUSDC, "User2 should have received USDC from 50-50 redemption");
        
        console.log("50-50 resolution batch redemption completed successfully!");
    }


    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _prepareCondition(bytes32 questionId) internal returns (bytes32 conditionId) {
        conditionId = CTHelpers.getConditionId(oracle, questionId, 2);
        
        // Prepare condition on ConditionalTokens
        vm.prank(oracle);
        ctf.prepareCondition(oracle, questionId, 2);
        
        return conditionId;
    }

    function _resolveCondition(bytes32 questionId, bool outcome) internal {
        uint256[] memory payouts = new uint256[](2);
        if (outcome) {
            payouts[0] = 1; // YES wins
            payouts[1] = 0;
        } else {
            payouts[0] = 0;
            payouts[1] = 1; // NO wins
        }
        
        vm.prank(oracle);
        ctf.reportPayouts(questionId, payouts);
    }

    function _resolveCondition5050(bytes32 questionId) internal {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1; // YES gets 1
        payouts[1] = 1; // NO gets 1 (50-50 split)
        
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

    function _verifyBatchRedemptionResults(
        bytes32 conditionId,
        address[] memory users,
        uint256[] memory yesAmounts,
        uint256[] memory noAmounts,
        uint256 user1InitialUSDC,
        uint256 user2InitialUSDC,
        uint256 user1InitialYes,
        uint256 user1InitialNo,
        uint256 user2InitialYes,
        uint256 user2InitialNo
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

    function _verifyCustomBatchRedemptionResults(
        bytes32 conditionId,
        address[] memory users,
        uint256[] memory yesAmounts,
        uint256[] memory noAmounts,
        uint256 user1InitialUSDC,
        uint256 user2InitialUSDC
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

