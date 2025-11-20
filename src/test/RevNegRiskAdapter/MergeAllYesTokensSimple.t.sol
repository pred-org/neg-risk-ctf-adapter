// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {console, RevNegRiskAdapter_SetUp} from "src/test/RevNegRiskAdapter/RevNegRiskAdapterSetUp.t.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";
import {IConditionalTokens} from "src/interfaces/IConditionalTokens.sol";

contract RevNegRiskAdapter_MergeAllYesTokensSimple_Test is RevNegRiskAdapter_SetUp {
    uint256 constant QUESTION_COUNT_MAX = 32;
    bytes32 marketId;
    bytes32 questionId0;
    bytes32 conditionId0;
    uint256 positionIdFalse0;
    uint256 positionIdTrue0;

    function _before(uint256 _questionCount, uint256 _feeBips, uint256 _amount) internal {
        bytes memory data = new bytes(0);

        // prepare market
        vm.prank(oracle);
        marketId = nrAdapter.prepareMarket(_feeBips, data);

        uint8 i = 0;

        // prepare questions and split initial liquidity to alice
        while (i < _questionCount) {
            vm.prank(oracle);
            bytes32 questionId = nrAdapter.prepareQuestion(marketId, data);
            bytes32 conditionId = nrAdapter.getConditionId(questionId);

            // split position to alice
            vm.startPrank(alice);
            usdc.mint(alice, _amount);
            usdc.approve(address(nrAdapter), _amount);
            nrAdapter.splitPosition(conditionId, _amount);
            vm.stopPrank();

            // Store the 0th question details for resolution
            if (i == 0) {
                questionId0 = questionId;
                conditionId0 = conditionId;
                positionIdFalse0 = nrAdapter.getPositionId(questionId, false);
                positionIdTrue0 = nrAdapter.getPositionId(questionId, true);
            }

            ++i;
        }

        nrAdapter.setPrepared(marketId);

        assertEq(nrAdapter.getQuestionCount(marketId), _questionCount);

        // Resolve the 0th question as TRUE
        vm.prank(oracle);
        nrAdapter.reportOutcome(questionId0, true);

        // send YES positions to brian for ALL questions
        {
            i = 0;
            while (i < _questionCount) {
                uint256 positionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                ctf.balanceOf(alice, positionId);
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, positionId, _amount, "");
                assertEq(ctf.balanceOf(brian, positionId), _amount);
                ++i;
            }
        }

        // Give Brian approval for the merge operation
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), _amount);
        ctf.setApprovalForAll(address(revAdapter), true);
        vm.stopPrank();
    }

    function _beforeWithoutApprovals(uint256 _questionCount, uint256 _feeBips, uint256 _amount) internal {
        // Set up market with questions
        vm.prank(oracle);
        marketId = nrAdapter.prepareMarket(_feeBips, "");

        uint8 i = 0;
        bytes32 questionId0;
        bytes32 conditionId0;
        while (i < _questionCount) {
            vm.prank(oracle);
            bytes32 questionId = nrAdapter.prepareQuestion(marketId, "");
            bytes32 conditionId = nrAdapter.getConditionId(questionId);
            
            if (i == 0) {
                questionId0 = questionId;
                conditionId0 = conditionId;
            }
            ++i;
        }

        nrAdapter.setPrepared(marketId);

        // Alice splits position to get YES/NO tokens for ALL questions
        vm.startPrank(alice);
        usdc.mint(alice, _amount * _questionCount);
        usdc.approve(address(nrAdapter), _amount * _questionCount);
        
        // Split position for each question
        for (uint8 j = 0; j < _questionCount; ++j) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(marketId, j);
            bytes32 conditionId = nrAdapter.getConditionId(questionId);
            nrAdapter.splitPosition(conditionId, _amount);
        }
        vm.stopPrank();

        // Resolve the 0th question as TRUE
        vm.prank(oracle);
        nrAdapter.reportOutcome(questionId0, true);

        // send YES positions to brian for ALL questions
        {
            i = 0;
            while (i < _questionCount) {
                uint256 positionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                ctf.balanceOf(alice, positionId);
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, positionId, _amount, "");
                assertEq(ctf.balanceOf(brian, positionId), _amount);
                ++i;
            }
        }

        // Give Brian USDC approval but NOT CTF approval
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), _amount);
        // ctf.setApprovalForAll(address(revAdapter), true); // This is intentionally commented out
        vm.stopPrank();
    }

    function _after(uint256 _questionCount, uint256 _amount) internal {
        // check balances
        {
            uint8 i = 0;
            uint256 yesPositionsCount = 0;

            while (i < _questionCount) {
                if (i != 0) { // All questions except the 0th (which was resolved)
                    // YES positions should be gone from brian
                    uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                    uint256 noPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), false);

                    // brian has no more of the yes tokens
                    assertEq(ctf.balanceOf(brian, yesPositionId), 0, "Brian yes tokens should be 0");
                    // they are all at the yes token burn address
                    assertEq(ctf.balanceOf(revAdapter.getYesTokenBurnAddress(), yesPositionId), _amount, "Yes tokens should be at the yes token burn address");
                    // rev adapter should have no conditional tokens
                    assertEq(ctf.balanceOf(address(revAdapter), yesPositionId), 0, "Yes tokens should be 0");
                    assertEq(ctf.balanceOf(address(revAdapter), noPositionId), 0, "No tokens should be 0");
                    ++yesPositionsCount;
                } else {
                    // 0th question (resolved) - both YES and NO tokens should be gone from brian
                    uint256 targetYesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                    uint256 targetNoPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), false);

                    // brian should have no tokens for the resolved question
                    assertEq(ctf.balanceOf(brian, targetYesPositionId), 0, "Brian yes tokens should be 0 for resolved question");
                    assertEq(ctf.balanceOf(brian, targetNoPositionId), 0, "Brian no tokens should be 0 for resolved question");
                    
                    // The target YES position should be consumed during merging (except for the fee amount)
                    uint256 feeBips = nrAdapter.getFeeBips(marketId);
                    uint256 feeAmount = (_amount * feeBips) / FEE_BIPS_MAX;
                    uint256 expectedRemainingYesTokens = feeAmount;
                    assertEq(ctf.balanceOf(address(revAdapter), targetYesPositionId), expectedRemainingYesTokens, "Yes tokens should remain equal to fee amount");
                    // rev adapter should have no NO tokens (they were used for merging)
                    assertEq(ctf.balanceOf(address(revAdapter), targetNoPositionId), 0, "Rev adapter should have no NO tokens");
                    
                    // Verify that the YES tokens for the resolved question are also burned
                    // The YES tokens created from split are burned, but the fee amount remains in the adapter
                    address burnAddress = revAdapter.getYesTokenBurnAddress();
                    assertEq(ctf.balanceOf(burnAddress, targetYesPositionId), _amount, "Resolved question YES tokens should be at burn address");
                }
                ++i;
            }

            assertEq(yesPositionsCount + 1, _questionCount);

            // brian should have USDC from the merge operation (amount after fees)
            uint256 feeBips = nrAdapter.getFeeBips(marketId);
            uint256 feeAmount = (_amount * feeBips) / FEE_BIPS_MAX;
            uint256 expectedUsdcAmount = _amount - feeAmount;
            assertEq(usdc.balanceOf(brian), expectedUsdcAmount, "Brian should have USDC from merge");

            // The CTF WCOL balance should be 0
            assertEq(wcol.balanceOf(address(revAdapter)), 0, "WCOL balance should be 0");
        }
    }

    function test_mergeAllYesTokens_resolvedQuestion(uint256 _questionCount, uint256 _feeBips, uint128 _amount) public {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX); // between 2 and QUESTION_COUNT_MAX questions

        _before(_questionCount, _feeBips, _amount);

        // merge all yes tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, 0, _amount);
            revAdapter.mergeAllYesTokens(marketId, _amount);
        }

        _after(_questionCount, _amount);
    }

    function test_mergeAllYesTokens_resolvedQuestion_noFees(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        uint256 _feeBips = 0;

        _before(_questionCount, _feeBips, _amount);

        // merge all yes tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, 0, _amount);
            revAdapter.mergeAllYesTokens(marketId, _amount);
        }

        _after(_questionCount, _amount);
    }

    function test_mergeAllYesTokens_resolvedQuestion_maxFees(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        uint256 _feeBips = FEE_BIPS_MAX;

        _before(_questionCount, _feeBips, _amount);

        // merge all yes tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, 0, _amount);
            revAdapter.mergeAllYesTokens(marketId, _amount);
        }

        _after(_questionCount, _amount);
    }

    function test_mergeAllYesTokens_resolvedQuestion_zeroAmount(uint256 _questionCount) public {
        uint256 amount = 0;

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);

        _before(_questionCount, 0, amount);

        {
            vm.prank(brian);
            revAdapter.mergeAllYesTokens(marketId, amount);
        }
    }

    function test_revert_mergeAllYesTokens_marketNotPrepared(bytes32 _marketId) public {
        vm.expectRevert(MarketNotPrepared.selector);
        revAdapter.mergeAllYesTokens(_marketId, 0);
    }

    function test_revert_mergeAllYesTokens_noConvertiblePositions() public {
        vm.prank(oracle);
        marketId = nrAdapter.prepareMarket(0, "");

        nrAdapter.setPrepared(marketId);

        // 0 questions prepared
        vm.expectRevert(NoConvertiblePositions.selector);
        revAdapter.mergeAllYesTokens(marketId, 0);

        vm.prank(oracle);
        nrAdapter.prepareQuestion(marketId, "");

        // 1 question prepared
        vm.expectRevert(NoConvertiblePositions.selector);
        revAdapter.mergeAllYesTokens(marketId, 0);

        vm.prank(oracle);
        nrAdapter.prepareQuestion(marketId, "");

        // 2 questions prepared - should work (but need to set up approvals first)
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), 0);
        ctf.setApprovalForAll(address(revAdapter), true);
        vm.stopPrank();
        
        vm.prank(brian);
        revAdapter.mergeAllYesTokens(marketId, 0);
    }

    function test_revert_mergeAllYesTokens_userNotApproved(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);

        // Set up market and positions but WITHOUT approvals
        _beforeWithoutApprovals(_questionCount, 0, _amount);

        // Try to merge without approval - should revert
        vm.prank(brian);
        vm.expectRevert();
        revAdapter.mergeAllYesTokens(marketId, _amount);
    }

    function test_revert_mergeAllYesTokens_insufficientYesTokens(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);

        _before(_questionCount, 0, _amount);

        // Remove some YES tokens from brian for a non-target question
        // This will cause the function to revert when trying to transfer insufficient tokens
        uint256 nonTargetIndex = 1; // Use question 1 since 0 is the target
        uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, uint8(nonTargetIndex)), true);
        vm.prank(brian);
        ctf.safeTransferFrom(brian, alice, yesPositionId, _amount, "");

        // Try to merge - this should revert due to insufficient YES tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            // The function should revert when trying to transfer insufficient YES tokens
            vm.expectRevert();
            revAdapter.mergeAllYesTokens(marketId, _amount);
        }
    }

    function test_mergeAllYesTokens_wcolBalanceConsistency(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);

        _before(_questionCount, 0, _amount);

        // merge all yes tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);
            revAdapter.mergeAllYesTokens(marketId, _amount);
        }

        // WCOL balance should always be 0 after execution
        uint256 wcolBalanceAfter = wcol.balanceOf(address(revAdapter));
        assertEq(wcolBalanceAfter, 0, "WCOL balance must be 0 after mergeAllYesTokens");
        
        // Verify burn address balance
        address burnAddress = revAdapter.getYesTokenBurnAddress();
        for (uint256 i = 0; i < _questionCount; i++) {
            uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, uint8(i)), true);
            // For non-resolved questions (i != 0), YES tokens should be burned
            // For resolved question (i == 0), YES tokens should also be burned
            assertEq(ctf.balanceOf(burnAddress, yesPositionId), _amount, string(abi.encodePacked("YES tokens for question ", vm.toString(i), " should be burned")));
        }
    }

    function test_mergeAllYesTokens_eventEmission(uint256 _questionCount, uint128 _amount) public {
        vm.assume(_amount > 0);

        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);

        _before(_questionCount, 0, _amount);

        // merge all yes tokens and verify event
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit(true, true, true, true);
            emit PositionsConverted(brian, marketId, 0, _amount);
            revAdapter.mergeAllYesTokens(marketId, _amount);
        }
    }

    /// @notice Test that the resolved question behavior is correct
    /// @dev This test specifically verifies that when the 0th question is resolved,
    /// the mergeAllYesTokens function still works correctly
    function test_mergeAllYesTokens_resolvedQuestionBehavior() public {
        uint256 questionCount = 3;
        uint256 feeBips = 0;
        uint128 amount = 1000;

        _before(questionCount, feeBips, amount);

        // Record initial balances
        uint256 initialUsdcBalance = usdc.balanceOf(brian);
        uint256 initialWcolBalance = wcol.balanceOf(address(revAdapter));

        // merge all yes tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, marketId, 0, amount);
            revAdapter.mergeAllYesTokens(marketId, amount);
        }

        // Verify final balances
        uint256 finalUsdcBalance = usdc.balanceOf(brian);
        uint256 finalWcolBalance = wcol.balanceOf(address(revAdapter));

        // Brian should have received USDC from the merge
        assertEq(finalUsdcBalance, initialUsdcBalance + amount, "Brian should receive USDC from merge");
        
        // WCOL balance should be 0
        assertEq(finalWcolBalance, 0, "WCOL balance should be 0");
        assertEq(initialWcolBalance, 0, "Initial WCOL balance should be 0");

        // All YES tokens should be burned
        for (uint256 i = 0; i < questionCount; i++) {
            uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, uint8(i)), true);
            assertEq(ctf.balanceOf(brian, yesPositionId), 0, "Brian should have no YES tokens");
            assertEq(ctf.balanceOf(revAdapter.getYesTokenBurnAddress(), yesPositionId), amount, "YES tokens should be burned");
        }
    }

    /// @notice Test with different resolved outcomes
    function test_mergeAllYesTokens_resolvedQuestionFalse() public {
        uint256 questionCount = 3;
        uint256 feeBips = 0;
        uint128 amount = 1000;

        bytes memory data = new bytes(0);

        // prepare market
        vm.prank(oracle);
        bytes32 testMarketId = nrAdapter.prepareMarket(feeBips, data);

        uint8 i = 0;

        // prepare questions and split initial liquidity to alice
        while (i < questionCount) {
            vm.prank(oracle);
            bytes32 questionId = nrAdapter.prepareQuestion(testMarketId, data);
            bytes32 conditionId = nrAdapter.getConditionId(questionId);

            // split position to alice
            vm.startPrank(alice);
            usdc.mint(alice, amount);
            usdc.approve(address(nrAdapter), amount);
            nrAdapter.splitPosition(conditionId, amount);
            vm.stopPrank();

            // Store the 0th question details for resolution
            if (i == 0) {
                questionId0 = questionId;
                conditionId0 = conditionId;
                positionIdFalse0 = nrAdapter.getPositionId(questionId, false);
                positionIdTrue0 = nrAdapter.getPositionId(questionId, true);
            }

            ++i;
        }

        nrAdapter.setPrepared(testMarketId);

        // Resolve the 0th question as FALSE
        vm.prank(oracle);
        nrAdapter.reportOutcome(questionId0, false);

        // send YES positions to brian for ALL questions
        {
            i = 0;
            while (i < questionCount) {
                uint256 positionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(testMarketId, i), true);
                ctf.balanceOf(alice, positionId);
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, positionId, amount, "");
                assertEq(ctf.balanceOf(brian, positionId), amount);
                ++i;
            }
        }

        // Give Brian approval for the merge operation
        vm.startPrank(brian);
        usdc.approve(address(revAdapter), amount);
        ctf.setApprovalForAll(address(revAdapter), true);
        vm.stopPrank();

        // merge all yes tokens
        {
            vm.startPrank(brian);
            ctf.setApprovalForAll(address(revAdapter), true);

            vm.expectEmit();
            emit PositionsConverted(brian, testMarketId, 0, amount);
            revAdapter.mergeAllYesTokens(testMarketId, amount);
        }

        // Verify Brian received USDC
        assertEq(usdc.balanceOf(brian), amount, "Brian should receive USDC from merge");
        
        // WCOL balance should be 0
        assertEq(wcol.balanceOf(address(revAdapter)), 0, "WCOL balance should be 0");
        
        // Verify all YES tokens are burned
        address burnAddress = revAdapter.getYesTokenBurnAddress();
        for (uint256 i = 0; i < questionCount; i++) {
            uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(testMarketId, uint8(i)), true);
            assertEq(ctf.balanceOf(brian, yesPositionId), 0, "Brian should have no YES tokens");
            assertEq(ctf.balanceOf(burnAddress, yesPositionId), amount, "YES tokens should be burned");
        }
    }
}
